import Foundation

/// Latest activity reading derived from HealthKit (steps + heart rate), written by
/// `BoostActivityMonitor` and read at decision time by `BoostV5Adapter`. Decoupled via a
/// small persisted snapshot so the (synchronous) determine-basal path never blocks on an
/// async HealthKit query. Shadow-safe: it only informs the V5 exercise modifiers.
struct BoostActivitySnapshot: Codable, Sendable {
    var steps30min: Double // step count over the last 30 minutes
    var latestHeartRate: Double // most recent HR sample (bpm), 0 if none
    var restingHeartRate: Double // Apple's resting HR baseline (bpm), 0 if unavailable
    var exerciseActive: Bool // computed at refresh: elevated steps or HR
    var lastExerciseAt: Date? // most recent time exercise was detected
    var updatedAt: Date
}

final class BoostActivityStore: @unchecked Sendable {
    static let shared = BoostActivityStore()

    private let key = "boost_activity_snapshot"
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

    /// Derive the V5 exercise flags from the latest snapshot, guarding on freshness.
    /// `exerciseActive` only counts if the snapshot is recent (≤ 30 min); the post-exercise
    /// window runs for 2h after the last detected activity.
    func flags(now: Date) -> (exerciseActive: Bool, inPostExerciseWindow: Bool) {
        guard let snap = snapshot else { return (false, false) }
        let fresh = now.timeIntervalSince(snap.updatedAt) <= 1800
        let active = fresh && snap.exerciseActive
        let postWindow = !active && (snap.lastExerciseAt.map { now.timeIntervalSince($0) <= 7200 } ?? false)
        return (active, postWindow)
    }
}
