import Foundation
import HealthKit
import Swinject

/// Reads step + heart-rate activity from HealthKit and publishes a `BoostActivitySnapshot`
/// for the Boost V5 engine's exercise modifiers. Observer queries (with background delivery,
/// the entitlement is already present) refresh the snapshot when new data arrives; an initial
/// refresh runs at launch. Inert until the user grants Health read access (queries silently
/// return nothing) — exactly the AAPS pattern.
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

    // Detection thresholds (conservative; shadow-only effect on dosing).
    private let activeStepThreshold: Double = 600 // ~brisk walking sustained over 30 min
    private let hrAboveRestingThreshold: Double = 25 // bpm over resting → likely exertion

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
        async let stepsTask = sumSteps(since: now.addingTimeInterval(-1800), now: now)
        async let hrTask = latestQuantity(hrType, unit: bpmUnit, since: now.addingTimeInterval(-900), now: now)
        async let restingTask = latestQuantity(restingHRType, unit: bpmUnit, since: now.addingTimeInterval(-7 * 86400), now: now)

        let steps30 = await stepsTask
        let latestHR = await hrTask ?? 0
        let restingHR = await restingTask ?? 0

        let active = steps30 >= activeStepThreshold
            || (restingHR > 0 && latestHR >= restingHR + hrAboveRestingThreshold)

        var snap = BoostActivitySnapshot(
            steps30min: steps30,
            latestHeartRate: latestHR,
            restingHeartRate: restingHR,
            exerciseActive: active,
            lastExerciseAt: BoostActivityStore.shared.snapshot?.lastExerciseAt,
            updatedAt: now
        )
        if active { snap.lastExerciseAt = now }
        BoostActivityStore.shared.snapshot = snap

        debug(
            .service,
            "BoostActivityMonitor: steps30=\(Int(steps30)) hr=\(Int(latestHR)) rhr=\(Int(restingHR)) active=\(active)"
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
