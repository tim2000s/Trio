import Foundation

/// Latest activity/sleep reading derived from HealthKit, written by `BoostActivityMonitor`
/// and read at decision time by `BoostV5Adapter`. Decoupled via a small persisted snapshot
/// so the (synchronous) determine-basal path never blocks on an async HealthKit query.
/// Carries the derived V5 context (exercise / post-exercise / asleep) plus the sleep and
/// post-exercise machine states so the monitor can advance them cycle-to-cycle.
struct BoostActivitySnapshot: Codable, Sendable {
    var steps30min: Double
    // 60-min step total — the steps-based sleep-in (lie-in) backstop reads this (2026-07-02). Optional
    // so snapshots persisted before this field decode (missing → nil, treated as no step data).
    var steps60min: Double? = nil
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

    // Activity-load source abstraction (2026-06-28, SHADOW telemetry — not applied to dosing).
    // All optional so older persisted snapshots decode (missing keys → nil).
    var stepSource: String? = nil // auto-resolved active step source: appleWatch|garmin|hk:x|iphone
    var stepSourceStates: String? = nil // per-source freshness+coverage, best-trust first: "src(f,Nd)"
    var activityBaselineSteps: Double? = nil // bridged-window median (in active source's units)
    var activityRatio: Double? = nil // decay-weighted recent load ÷ baseline
    var activityWouldDeltaIsfPct: Double? = nil // signed: + raise ISF (activity) / − lower (inactivity)
    var activityIntradayDeltaIsfPct: Double? = nil // raise-only would-ΔISF from intraday pace
    var activityBridge: String? = nil // donors bridging the baseline window (+"(raw)" if uncalibrated)
    var hrSource: String? = nil // live HR source: appleWatch|garmin|hk:x, nil if feed died
    var hrSourceStates: String? = nil // per-source "src(fresh,count,ageMin)"

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

/// Persists the 28-day `SleepHistoryTracker.History` (AAPS `StringKey.ApsBoostSleepHistory`).
/// `BoostActivityMonitor` records sleep/wake transitions into it and reads the learned
/// aggregate (night window + resting HR) to feed the sleep detector. UserDefaults-backed,
/// lock-guarded; stored as the serialized JSON string.
enum BoostSleepHistoryStore {
    private static let key = "boost_sleep_history_v1"
    private static let lock = NSLock()
    private static let defaults = UserDefaults.standard

    static func load() -> SleepHistoryTracker.History {
        lock.lock()
        defer { lock.unlock() }
        return SleepHistoryTracker.deserialize(defaults.string(forKey: key) ?? "")
    }

    static func save(_ history: SleepHistoryTracker.History) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(SleepHistoryTracker.serialize(history), forKey: key)
    }
}
