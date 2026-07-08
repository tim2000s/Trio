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
    func requestAuthorization()
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

    /// Request HealthKit READ access for Boost's activity inputs (steps, heart rate, resting HR).
    /// The observers are registered at launch but stay inert until read access is granted, and the
    /// app otherwise only requests Health access via the separate Apple Health integration toggle —
    /// so without this, enabling Boost leaves activity / sleep / post-exercise sensing silently off.
    /// Called when the user enables Boost. Idempotent: iOS shows the prompt only until the user has
    /// made a choice, then calls back immediately. Refreshes on completion so sensing engages.
    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes = Set([stepType, hrType, restingHRType].compactMap { $0 })
        guard !readTypes.isEmpty else { return }
        healthKitStore.requestAuthorization(toShare: [], read: readTypes) { [weak self] success, _ in
            guard success else { return }
            Task { await self?.refresh() }
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
        // Per-source step history + today's cumulative counts. Fetched here (ahead of the sleep
        // detector) so the lump-tolerant genuine-wake evidence (2026-07-03, AAPS 5f7a481f28) can see
        // today's cumulative steps; also reused by the activity-load section below.
        let (multi, todayBySource, todayIndex) = await fetchStepsBySource(
            days: ActivityLoadTracker.Const.windowDays, now: now
        )
        // stepsToday = highest cumulative today count across all sources (AAPS: max(wear, phone)) —
        // -1 when no source reported, so the detector falls back to the legacy 15-min bucket.
        let stepsTodayCumulative = todayBySource.values.max() ?? -1
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
                autoBySleep: prefs.boostNightModeAutoBySleep,
                stepsToday: stepsTodayCumulative
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

        // 4) Activity-load source abstraction (SHADOW): pick the active step source across ALL
        // HealthKit writers (Apple Watch > Garmin > other > iPhone), build the per-source history,
        // and compute the bridged baseline + would-ΔISF. Telemetry only — not applied to dosing.
        // (multi/todayBySource/todayIndex fetched above, ahead of the sleep detector.)
        let freshSources = await freshStepSources(minutes: 20, now: now)
        let candidateSources = Set(multi.sources.keys).union(todayBySource.keys)
        let states = candidateSources.map { src in
            StepSourceResolver.SourceState(
                source: src,
                fresh: freshSources.contains(src),
                coverageDays: multi.sources[src]?.days.count ?? 0,
                stepsToday: todayBySource[src] ?? 0
            )
        }
        let stepRes = StepSourceResolver.resolve(states)
        // Baseline from the PHONE-ANCHORED rolling window — the iPhone runs continuously across watch
        // SWAPS (one watch ceases as the next starts → they never overlap), so it is the calibration
        // frame; worn sources are scaled into phone units. Replaces watch-to-watch bridging, which
        // could never calibrate a swap. (2026-07-02, AAPS a3bb4afc2a.)
        let bridged = ActivityLoadTracker.phoneAnchoredWindow(multi, todayIndex: todayIndex)
        let load = ActivityLoadTracker.compute(bridged.history, todayIndex: todayIndex)
        // Intraday "running hot?" — today's count converted to PHONE units so it matches the
        // phone-anchored baseline (worn-source today × phone/worn calibration).
        let stepsTodayPhone = ActivityLoadTracker.toPhoneUnits(
            steps: stepRes.stepsToday, activeSource: stepRes.active, multi: multi
        )
        let intraday = ActivityLoadTracker.intradayLoad(
            stepsToday: stepsTodayPhone,
            baseline: load.baselineSteps,
            hourOfDay: Calendar.current.component(.hour, from: now)
        )
        let bridgeNote = bridged.donorsUsed.isEmpty
            ? "phone"
            : "phone<-" + bridged.donorsUsed.joined(separator: "+") + (bridged.calibrated ? "" : "(raw)")

        // 5) HR source visibility (SHADOW) — which device feeds HR + silent-death detection.
        let hrSourceReadings = await fetchHrSourceReadings(since: now.addingTimeInterval(-16 * 60), now: now)
        let hrRes = HrSourceResolver.resolve(hrSourceReadings, now: now)

        let snap = BoostActivitySnapshot(
            steps30min: steps30,
            steps60min: Double(steps60),
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
            stepSource: stepRes.active,
            stepSourceStates: stepRes.note,
            activityBaselineSteps: load.baselineSteps,
            activityRatio: load.ratio,
            activityWouldDeltaIsfPct: load.wouldDeltaIsfPct,
            activityIntradayDeltaIsfPct: intraday,
            activityBridge: bridgeNote,
            hrSource: hrRes.active,
            hrSourceStates: hrRes.note,
            updatedAt: now
        )
        BoostActivityStore.shared.snapshot = snap

        debug(
            .service,
            "BoostActivityMonitor: steps5/15/30/60=\(steps5)/\(steps15)/\(Int(steps30))/\(steps60) hr=\(Int(latestHr)) rhr=\(Int(restingHr)) state=\(activity.state.rawValue) asleep=\(asleep) postEx=\(recovery.inRecoveryWindow)"
        )
        debug(
            .service,
            "BoostActivitySource: step=\(stepRes.active ?? "none") [\(stepRes.note)] base=\(load.baselineSteps.map { String(Int($0)) } ?? "nil") ratio=\(load.ratio.map { String(format: "%.2f", $0) } ?? "nil") wouldΔISF=\(load.wouldDeltaIsfPct.map { String(format: "%.1f", $0) } ?? "nil")% bridge=\(bridgeNote) hr=\(hrRes.active ?? "none") [\(hrRes.note)]"
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

    // MARK: - Activity-load source abstraction (2026-06-28, SHADOW)

    /// Local epoch-day index — mirrors AAPS `DailyStepHistoryTracker.dayIndex`.
    private func dayIndex(_ date: Date, _ offsetMs: Double) -> Int {
        Int((date.timeIntervalSince1970 * 1000.0 + offsetMs) / 86_400_000.0)
    }

    /// Canonical source id for an `HKSource` — prefer its name (Apple Watch / iPhone carry the device
    /// name; Garmin's name "Garmin Connect" and bundle both contain "garmin").
    private func canonicalId(_ source: HKSource) -> String {
        StepSourceResolver.canonical(source.name.isEmpty ? source.bundleIdentifier : source.name)
    }

    /// Per-source COMPLETED-day step totals over `days` days + today-by-source, via one
    /// statistics-collection query split by source. HealthKit is the persistent per-source store, so
    /// the multi-source history is rebuilt each refresh (no app-side persistence needed).
    private func fetchStepsBySource(days: Int, now: Date)
    async -> (multi: ActivityLoadTracker.MultiSourceHistory, todayBySource: [String: Int], todayIndex: Int)
    {
        guard let stepType else { return (.init(), [:], 0) }
        let cal = Calendar.current
        let offsetMs = Double(cal.timeZone.secondsFromGMT(for: now)) * 1000.0
        let todayIndex = dayIndex(now, offsetMs)
        let anchor = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -days, to: anchor) ?? anchor
        var interval = DateComponents()
        interval.day = 1
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum, .separateBySource],
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, _ in
                var perSource: [String: [ActivityLoadTracker.DailyStepTotal]] = [:]
                var todayBySource: [String: Int] = [:]
                collection?.enumerateStatistics(from: start, to: now) { stats, _ in
                    let di = self.dayIndex(stats.startDate, offsetMs)
                    for src in stats.sources ?? [] {
                        guard let qty = stats.sumQuantity(for: src) else { continue }
                        let steps = Int(qty.doubleValue(for: .count()))
                        if steps <= 0 { continue }
                        let canon = self.canonicalId(src)
                        if di < todayIndex {
                            perSource[canon, default: []].append(.init(dayIndex: di, steps: steps, source: canon))
                        } else {
                            todayBySource[canon, default: 0] += steps
                        }
                    }
                }
                var multi = ActivityLoadTracker.MultiSourceHistory()
                for (src, totals) in perSource {
                    multi = ActivityLoadTracker.mergeSource(multi, source: src, totals: totals, todayIndex: todayIndex)
                }
                continuation.resume(returning: (multi, todayBySource, todayIndex))
            }
            healthKitStore.execute(query)
        }
    }

    /// Canonical step sources that produced steps in the last `minutes` minutes — the "fresh" set.
    private func freshStepSources(minutes: Double, now: Date) async -> Set<String> {
        guard let stepType else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-minutes * 60), end: now)
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum, .separateBySource]
            ) { _, stats, _ in
                var fresh = Set<String>()
                for src in stats?.sources ?? [] {
                    if let qty = stats?.sumQuantity(for: src), qty.doubleValue(for: .count()) > 0 {
                        fresh.insert(self.canonicalId(src))
                    }
                }
                continuation.resume(returning: fresh)
            }
            healthKitStore.execute(query)
        }
    }

    /// Recent HR samples tagged with their source, for `HrSourceResolver` (visibility only).
    private func fetchHrSourceReadings(since: Date, now: Date) async -> [HrSourceResolver.Reading] {
        guard let hrType else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: now)
            let query = HKSampleQuery(
                sampleType: hrType, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, samples, _ in
                let readings = (samples as? [HKQuantitySample] ?? []).map { s in
                    HrSourceResolver.Reading(device: s.sourceRevision.source.name, timestamp: s.endDate)
                }
                continuation.resume(returning: readings)
            }
            healthKitStore.execute(query)
        }
    }
}
