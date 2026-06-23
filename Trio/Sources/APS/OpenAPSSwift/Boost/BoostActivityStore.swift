import Foundation

/// Latest activity/sleep reading derived from HealthKit, written by `BoostActivityMonitor`
/// and read at decision time by `BoostV5Adapter`. Decoupled via a small persisted snapshot
/// so the (synchronous) determine-basal path never blocks on an async HealthKit query.
/// Carries the derived V5 context (exercise / post-exercise / asleep) plus the sleep and
/// post-exercise machine states so the monitor can advance them cycle-to-cycle.
struct BoostActivitySnapshot: Codable, Sendable {
    var steps30min: Double
    var latestHeartRate: Double // most recent HR sample (bpm), 0 if none
    var restingHeartRate: Double // Apple's resting HR baseline (bpm), 0 if unavailable

    // Derived V5 context
    var exerciseActive: Bool
    var inPostExerciseWindow: Bool
    var asleep: Bool
    var exerciseState: String // ExerciseState rawValue (telemetry)
    var profilePercent: Double // would-apply profile % from activity classification
    var targetBgMgdl: Double? // would-apply activity target (nil = no change)

    var lastExerciseAt: Date?

    // Persisted machine states (advanced by the monitor each refresh)
    var sleepState: SleepDetectorState?
    var recoveryState: RecoveryState?

    var updatedAt: Date
}

final class BoostActivityStore: @unchecked Sendable {
    static let shared = BoostActivityStore()

    private let key = "boost_activity_snapshot_v2"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var snapshot: BoostActivitySnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(BoostActivitySnapshot.self, from: data)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: key)
            }
        }
    }

    /// V5 context flags for the adapter, guarding on freshness (≤ 30 min). Stale → all false.
    func flags(now: Date) -> (exerciseActive: Bool, inPostExerciseWindow: Bool, asleep: Bool) {
        guard let snap = snapshot, now.timeIntervalSince(snap.updatedAt) <= 1800 else {
            return (false, false, false)
        }
        return (snap.exerciseActive, snap.inPostExerciseWindow, snap.asleep)
    }
}
