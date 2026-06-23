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

    private var observers: [HKObserverQuery] = []

    private var stepType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .stepCount) }
    private var hrType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .heartRate) }
    private var restingHRType: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .restingHeartRate) }
    private var bpmUnit: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    // Night window (AAPS defaults) until settings land: 22:00–07:00.
    private let nightStartMinute = 22 * 60
    private let nightEndMinute = 7 * 60

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
        let now = Date()
        let nowMs = now.timeIntervalSince1970 * 1000.0

        async let steps5Task = sumSteps(since: now.addingTimeInterval(-300), now: now)
        async let steps15Task = sumSteps(since: now.addingTimeInterval(-900), now: now)
        async let steps30Task = sumSteps(since: now.addingTimeInterval(-1800), now: now)
        async let steps60Task = sumSteps(since: now.addingTimeInterval(-3600), now: now)
        async let hrAvgTask = avgQuantity(hrType, unit: bpmUnit, since: now.addingTimeInterval(-900), now: now)
        async let latestHrTask = latestQuantity(hrType, unit: bpmUnit, since: now.addingTimeInterval(-900), now: now)
        async let restingTask = latestQuantity(restingHRType, unit: bpmUnit, since: now.addingTimeInterval(-7 * 86400), now: now)

        let steps5 = Int(await steps5Task)
        let steps15 = Int(await steps15Task)
        let steps30 = await steps30Task
        let steps60 = Int(await steps60Task)
        let avgHr = await hrAvgTask ?? 0
        let latestHr = await latestHrTask ?? 0
        let restingHr = await restingTask ?? 0
        let restingForCalc = restingHr > 0 ? restingHr : 60

        let prev = BoostActivityStore.shared.snapshot

        // 1) Activity classification (step-only by default; HR fusion off until that setting lands).
        var thresholds = ActivityThresholds()
        thresholds.hrRestingBpm = Int(restingForCalc)
        let activity = ActivityClassifier.classify(ActivityInputs(
            steps5: steps5, steps15: steps15, steps30: Int(steps30), steps60: steps60,
            avgHeartRate: avgHr, thresholds: thresholds
        ))

        // 2) Sleep state machine (autoBySleep on; thresholds = AAPS defaults).
        let nowMinute = Calendar.current.component(.hour, from: now) * 60
            + Calendar.current.component(.minute, from: now)
        let sleep = SleepStateDetector.step(
            SleepDetectorInputs(
                avgHeartRate: avgHr,
                restingHeartRate: restingForCalc,
                steps15min: steps15,
                nowMinuteOfDay: nowMinute,
                nightStartMinute: nightStartMinute,
                nightEndMinute: nightEndMinute,
                preSleepLeadMin: 60,
                sleepHysteresisMin: 10,
                wakeHrHysteresisMin: 5,
                mlMealLikely: nil,
                nowMs: nowMs,
                autoBySleep: true
            ),
            prev?.sleepState ?? SleepDetectorState(state: .awake, enteredAtMs: nowMs)
        )
        let asleep = sleep.state == .sleeping

        // 3) Post-exercise recovery (enabled; per-type window/scale).
        let recovery = PostExerciseRecovery.step(
            nowMs: nowMs,
            exerciseActive: activity.exerciseActive,
            exerciseType: activity.state.rawValue,
            config: PostExerciseConfig(enabled: true),
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
