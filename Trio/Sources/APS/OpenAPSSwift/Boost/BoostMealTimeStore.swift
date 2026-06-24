import Foundation

/// Persists the V6 meal-time history (rolling window of CONFIRMED-commit timestamps) so the
/// MealTimeLearner can cluster habitual meal times and the determination can fire an
/// anticipatory pre-meal target. Recorded by the adapter on a fresh CONFIRMED; read by the
/// determination's V6 pre-meal check. UserDefaults-backed, thread-safe.
final class BoostMealTimeStore: @unchecked Sendable {
    static let shared = BoostMealTimeStore()

    private let key = "boost_mealtime_history"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var history: MealTimeHistory {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = defaults.data(forKey: key),
                  let h = try? JSONDecoder().decode(MealTimeHistory.self, from: data)
            else { return MealTimeHistory() }
            return h
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
        }
    }

    /// Record a fresh CONFIRMED commit at `clock` (trims to the learner's window).
    func recordConfirmed(at clock: Date) {
        history = MealTimeLearner.record(history, tsMs: clock.timeIntervalSince1970 * 1000.0)
    }
}
