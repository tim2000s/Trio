import Foundation
// Note: BoostV5Core sources are compiled into the Trio app target (not a separate module), so
// `BoostAutoConfigKnob` is used directly — no `import BoostV5Core` (which would fail to resolve).

/// Persistence and scheduling for the periodic auto-config re-derivation (AAPS 2026-08-03).
///
/// The pure decision lives in `BoostV5AutoConfigApply.redrive`. This holds the three pieces of state
/// it needs across runs and answers whether an evaluation is due.
///
/// - the BASELINE per knob: the derived value at the last write, advanced only on a write, so
///   movement suppressed by the deadband or held by the raise guard accumulates rather than
///   being lost.
/// - the PENDING value per knob: a quantised knob's proposed value awaiting its second consecutive
///   derivation, which is what stops it flapping across a threshold.
/// - the last evaluation time, for the cadence.
///
/// UserDefaults rather than Preferences, matching `BoostActivityStore` and `BoostMealTimeStore`:
/// this is bookkeeping about the derivation rather than a setting anyone edits, and it should not
/// travel with an exported settings file. An import carrying someone else's baselines would make
/// the first re-derivation track a movement that never happened on this device.
enum BoostRedriveStore {
    /// Evaluation cadence. Evaluating often is cheap once the filter, rather than the schedule,
    /// decides whether to write.
    static let interval: TimeInterval = 7 * 86400
    /// History window. Fourteen days is noise-dominated: two independent 14-day derivations of the
    /// same fortnight differ by 0.69 U [0.30, 1.17] on the confirmed cap.
    static let windowDays = 28

    private static let baselineKey = "boost.redrive.baseline"
    private static let pendingKey = "boost.redrive.pending"
    private static let lastRunKey = "boost.redrive.lastRunMs"

    private static let lock = NSLock()

    /// Whether an evaluation is due. The first call on a fresh install returns true, which records
    /// the baselines and writes no tracked knob.
    static func isDue(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let last = UserDefaults.standard.double(forKey: lastRunKey)
        guard last > 0 else { return true }
        return now.timeIntervalSince1970 - last >= interval
    }

    static func markRun(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastRunKey)
    }

    static func baseline(_ knob: BoostAutoConfigKnob) -> Double? {
        map(baselineKey)[knob.rawValue]
    }

    static func setBaseline(_ knob: BoostAutoConfigKnob, _ value: Double) {
        update(baselineKey) { $0[knob.rawValue] = value }
    }

    static func pending(_ knob: BoostAutoConfigKnob) -> Double? {
        map(pendingKey)[knob.rawValue]
    }

    static func setPending(_ knob: BoostAutoConfigKnob, _ value: Double?) {
        update(pendingKey) { $0[knob.rawValue] = value }
    }

    /// Clear everything. Used by tests for isolation.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: baselineKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        UserDefaults.standard.removeObject(forKey: lastRunKey)
    }

    private static func map(_ key: String) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    private static func update(_ key: String, _ mutate: (inout [String: Double]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var m = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        mutate(&m)
        UserDefaults.standard.set(m, forKey: key)
    }
}
