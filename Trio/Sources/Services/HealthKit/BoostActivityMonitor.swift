import Foundation
import HealthKit
import Swinject

/// Reads step + heart-rate activity from HealthKit and publishes a `BoostActivitySnapshot`
/// for the Boost V5 engine's context (exercise / post-exercise / asleep). Observer queries
/// (with background delivery) refresh on new data; an initial refresh runs at launch. Inert
/// until the user grants Health read access (queries silently return nothing).
///
/// Each refresh runs the ported sensing modules: ActivityClassifier (step buckets + HR),
/// SleepStateDetector, and PostExerciseRecovery — advancing the latter two machines from the
/// previous snapshot's persisted state. Thresholds/windows use AAPS defaults until the Boost
/// settings tree lands. Sleep + post-exercise are enabled here (they steer V5 conservatively:
/// no fast-carb overnight, reduced budget post-exercise); both become user settings later.
protocol BoostActivityMonitor {
    func refresh() async
}

final class BaseBoostActivityMonitor: BoostActivityMonitor, Injectable {
    @Injected() private var healthKitStore: HKHealthStore!
    @Injected() private var storage: FileStorage!

    private var observers: [HKObserverQuery] = []

    // Serialize refreshes. The step + HR observer callbacks (plus the launch refresh) each
    // fire refresh() on their own Task; without serialization two concurrent runs read the
    // same previous snapshot, advance the sleep/recovery state machines independently, and
    // the last writer wins — silently dropping a machine transition. Chaining each refresh
    // after the previous one makes the prev-read → step → snapshot-write atomic. The lock
    // only guards the brief chain swap, never an `await`.
    private let refreshLock = NSLock()
    private var refreshChain: Task<Void, Never>?

    private var stepType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .stepCount) }
    private var hrType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .heartRate) }
    private var restingHRType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .restingHeartRate) }
    private var bpmUnit: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    private func d(_ v: Decimal) -> Double { (v as NSDecimalNumber).doubleValue }

    /// Max minutes the learned sleep window may move from the configured night start/end.
    private static let learnedWindowBandMin = 90

    /// Clamp a learned minute-of-day to within ±band of the configured minute-of-day, on the 24h
    /// circle; returns `configured` when `learned` is nil. Caps how far the learned sleep window can
    /// drift from the user's configured times — the safety bound that, with the genuine-wake-only
    /// training in SleepHistoryTracker, stops the night-window collapse. Mirrors the AAPS plugin.
    static func clampToConfiguredBand(_ learned: Int?, _ configured: Int, bandMin: Int = learnedWindowBandMin) -> Int {
        guard let learned else { return configured }
        let delta = ((learned - configured + 1440 + 720) % 1440) - 720 // signed circular delta [-720,719]
        let clamped = min(max(delta, -bandMin), bandMin)
        return ((configured + clamped) % 1440 + 1440) % 1440
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        guard HKHealthStore.isHealthDataAvailable() else { return }
        startObserving()
        Task { await refresh() }
        debug(.service, "BoostActivityMonitor did create")
    }

    private func startObserving() {
        for type in [stepType, hrType].compactMap({ $0 }) {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task {
                    await self?.refresh()
                    completion()
                }
            }
            healthKitStore.execute(query)
            observers.append(query)
            healthKitStore.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    func refresh() async {
        refreshLock.lock()
        let previous = refreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRefresh()
        }
        refreshChain = task
        refreshLock.unlock()
        await task.value
    }

    private func performRefresh() async {
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1000.0

        async let steps5Task = sumSteps(since: now.addingTimeInterval(-300), now: now)
        async let steps15Task = sumSteps(since: now.addingTimeInterval(-900), now: now)
        async let steps30Task = sumSteps(since: now.addingTimeInterval(-1800), now: now)
        async let steps60Task = sumSteps(since: now.addingTimeInterval(-3600), now: now)
        async let hrAvgTask = avgQuantity(hrType, unit: bpmUnit, since: now.addingTimeInterval(-900), now: now)
        async let latestHrTask = latestQuantity(hrType, unit: bpmUnit, since: now.addingTimeInterval(-900), now: now)
        async let restingTask = latestQuantity(restingHRType, unit: bpmUnit, since: now.addingTimeInterval(-7 * 86400), now: now)
        // Raw HR samples for the sleep detector: it computes its own duration-weighted average
        // AND freshness/drought from per-sample timestamps. ~16 min covers the 5-min average
        // window, the 10-min freshness cutoff, and the 15-min fresh-sample count. Drought beyond
        // this window is carried by the persisted lastFreshHrSampleMs.
        async let hrReadingsTask = fetchHrReadings(since: now.addingTimeInterval(-16 * 60), now: now)

        let steps5 = Int(await steps5Task)
        let steps15 = Int(await steps15Task)
        let steps30 = await steps30Task
        let steps60 = Int(await steps60Task)
        let avgHr = await hrAvgTask ?? 0
        let latestHr = await latestHrTask ?? 0
        let restingHr = await restingTask ?? 0
        let hrReadings = await hrReadingsTask
        let restingForCalc = restingHr > 0 ? restingHr : 60

        let prev = BoostActivityStore.shared.snapshot
        let prefs = storage.retrieve(OpenAPS.Settings.preferences, as: Preferences.self) ?? Preferences()

        // 1) Activity classification — thresholds from user settings.
        // Prefer the measured HealthKit resting HR; fall back to the configured value.
        let resting = restingHr > 0 ? restingHr : d(prefs.boostHrRestingBpm)
        _ = restingForCalc
        let thresholds = ActivityThresholds(
            steps5: Int(d(prefs.boostActivitySteps5)),
            steps15: Int(d(prefs.boostActivitySteps15)),
            steps30: Int(d(prefs.boostActivitySteps30)),
            steps60: Int(d(prefs.boostActivitySteps60)),
            activityPct: d(prefs.boostActivityPct),
            inactivitySteps: Int(d(prefs.boostInactivitySteps)),
            inactivityPct: d(prefs.boostInactivityPct),
            hrMaxBpm: Int(d(prefs.boostHrMaxBpm)),
            hrRestingBpm: Int(resting),
            hrStressDetection: prefs.boostHrStressDetection,
            hrIntegrationEnabled: prefs.boostHrIntegrationEnabled
        )
        let activity = ActivityClassifier.classify(ActivityInputs(
            steps5: steps5, steps15: steps15, steps30: Int(steps30), steps60: steps60,
            avgHeartRate: avgHr, thresholds: thresholds
        ))

        // 2) Sleep state machine — uses the LEARNED night window + resting HR once enough
        // sessions exist (AAPS SleepHistoryTracker.aggregate → effective values feed the
        // detector; the night-mode clock window itself stays configured). Below the learning
        // threshold these fall back to the configured night window / measured resting HR.
        let history = BoostSleepHistoryStore.load()
        let offsetMs = Double(TimeZone.current.secondsFromGMT(for: now)) * 1000.0
        let agg = SleepHistoryTracker.aggregate(history, localOffsetMs: offsetMs)
        let configNightStart = Int(d(prefs.boostNightModeStartHour) * 60)
        let configNightEnd = Int(d(prefs.boostNightModeEndHour) * 60)
        // The learned window may only nudge the configured night start/end by ±BAND, and the wake
        // side trains on genuine wakes only (see SleepHistoryTracker). Together these anchor the
        // hard sleep/wake bounds to the configured times and cap how far learning can move them —
        // preventing the self-reinforcing earlier-every-night collapse. No/insufficient data →
        // effective == configured.
        let effectiveNightStart = Self.clampToConfiguredBand(agg.sleepStartMinAvg, configNightStart)
        let effectiveNightEnd = Self.clampToConfiguredBand(agg.wakeMinAvg, configNightEnd)
        let effectiveResting = agg.restingHrBpm.map(Double.init) ?? resting

        let nowMinute = Calendar.current.component(.hour, from: now) * 60
            + Calendar.current.component(.minute, from: now)
        let sleep = SleepStateDetector.step(
            SleepDetectorInputs(
                hrReadings: hrReadings,
                hrWindowMinutes: 5,
                restingHeartRate: effectiveResting,
                steps15min: steps15,
                nowMinuteOfDay: nowMinute,
                nightStartMinute: effectiveNightStart,
                nightEndMinute: effectiveNightEnd,
                preSleepLeadMin: 60,
                sleepHysteresisMin: 10,
                wakeHrHysteresisMin: 5,
                mlMealLikely: nil,
                nowMs: nowMs,
                autoBySleep: prefs.boostNightModeAutoBySleep
            ),
            prev?.sleepState ?? SleepDetectorState(state: .awake, enteredAtMs: nowMs)
        )
        let asleep = sleep.state == .sleeping

        // Record sleep/wake transitions into the rolling history (AAPS: onSleepStart on any
        // non-SLEEPING→SLEEPING; onWake on SLEEPING→non-SLEEPING, with HR p10 over the sleep
        // period + the preceding awake period). The learned aggregate then shapes future cycles.
        let prevSleepState = prev?.sleepState?.state ?? .awake
        if prevSleepState != .sleeping, sleep.state == .sleeping {
            BoostSleepHistoryStore.save(SleepHistoryTracker.onSleepStart(history, sleepStartMs: nowMs))
        } else if prevSleepState == .sleeping, sleep.state != .sleeping, let openStart = history.openSleepStartMs {
            let sleepHr = await fetchHrBpms(since: Date(timeIntervalSince1970: openStart / 1000.0), to: now)
            let daytimeHr: [Double]
            if let lastWake = SleepHistoryTracker.lastWakeMs(history), lastWake < openStart {
                daytimeHr = await fetchHrBpms(
                    since: Date(timeIntervalSince1970: lastWake / 1000.0),
                    to: Date(timeIntervalSince1970: openStart / 1000.0)
                )
            } else {
                daytimeHr = []
            }
            BoostSleepHistoryStore.save(SleepHistoryTracker.onWake(
                history, wakeMs: nowMs, sleepHrBpms: sleepHr, daytimeHrBpms: daytimeHr,
                wakeReason: sleep.wakeReason
            ))
        }

        // 3) Post-exercise recovery — config from settings.
        let recovery = PostExerciseRecovery.step(
            nowMs: nowMs,
            exerciseActive: activity.exerciseActive,
            exerciseType: activity.state.rawValue,
            config: PostExerciseConfig(
                recoveryHours: d(prefs.boostPostExerciseHours),
                recoveryTargetMgdl: d(prefs.boostPostExerciseTarget),
                recoveryScale: d(prefs.boostPostExerciseScale),
                minDurationMin: Int(d(prefs.boostPostExerciseMinDuration)),
                enabled: prefs.boostPostExerciseEnabled
            ),
            state: prev?.recoveryState ?? RecoveryState()
        )

        let snap = BoostActivitySnapshot(
            steps30min: steps30,
            latestHeartRate: latestHr,
            restingHeartRate: restingHr,
            exerciseActive: activity.exerciseActive,
            inPostExerciseWindow: recovery.inRecoveryWindow,
            asleep: asleep,
            exerciseState: activity.state.rawValue,
            profilePercent: activity.profilePercent,
            targetBgMgdl: activity.targetBgMgdl,
            lastExerciseAt: activity.exerciseActive ? now : prev?.lastExerciseAt,
            sleepState: sleep,
            recoveryState: recovery.newState,
            updatedAt: now
        )
        BoostActivityStore.shared.snapshot = snap

        debug(
            .service,
            "BoostActivityMonitor: steps5/15/30/60=\(steps5)/\(steps15)/\(Int(steps30))/\(steps60) hr=\(Int(latestHr)) rhr=\(Int(restingHr)) state=\(activity.state.rawValue) asleep=\(asleep) postEx=\(recovery.inRecoveryWindow)"
        )
    }

    private func sumSteps(since: Date, now: Date) async -> Double {
        guard let stepType else { return 0 }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0)
            }
            healthKitStore.execute(query)
        }
    }

    /// Raw HR samples in the window, mapped to `SleepHrReading` for the sleep detector. Each
    /// sample's `timestampMs` is its end date; `durationMs` is the sample span floored at a 1 s
    /// nominal so HealthKit's (typically instantaneous) samples make the detector's duration-
    /// weighted average degrade to a simple mean rather than divide-by-zero.
    private func fetchHrReadings(since: Date, now: Date) async -> [SleepHrReading] {
        guard let hrType else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let readings = (samples as? [HKQuantitySample] ?? []).map { s in
                    SleepHrReading(
                        timestampMs: s.endDate.timeIntervalSince1970 * 1000.0,
                        beatsPerMinute: s.quantity.doubleValue(for: self.bpmUnit),
                        durationMs: max(s.endDate.timeIntervalSince(s.startDate) * 1000.0, 1000.0),
                        isValid: true
                    )
                }
                continuation.resume(returning: readings)
            }
            healthKitStore.execute(query)
        }
    }

    /// HR sample BPM values over an arbitrary [since, to] window — used at a SLEEPING→AWAKE
    /// transition to summarise the just-ended sleep period (and the preceding awake period) into
    /// p10s for SleepHistoryTracker. Empty if no HR access / no samples.
    private func fetchHrBpms(since: Date, to: Date) async -> [Double] {
        guard let hrType, to > since else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: to)
            let query = HKSampleQuery(
                sampleType: hrType, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                let bpms = (samples as? [HKQuantitySample] ?? []).map { $0.quantity.doubleValue(for: self.bpmUnit) }
                continuation.resume(returning: bpms)
            }
            healthKitStore.execute(query)
        }
    }

    private func avgQuantity(_ type: HKQuantityType?, unit: HKUnit, since: Date, now: Date) async -> Double? {
        guard let type else { return nil }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, _ in
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            healthKitStore.execute(query)
        }
    }

    private func latestQuantity(_ type: HKQuantityType?, unit: HKUnit, since: Date, now: Date) async -> Double? {
        guard let type else { return nil }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            healthKitStore.execute(query)
        }
    }
}
