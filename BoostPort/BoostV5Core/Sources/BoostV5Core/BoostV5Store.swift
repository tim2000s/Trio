import Foundation

public enum BoostMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off // stock Trio only
    case shadow // run V5, log what it would do, do NOT change dosing
    case active // V5 drives the SMB

    public var id: String { rawValue }

    /// Human-facing label for the settings picker.
    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .shadow: return "Shadow (log only)"
        case .active: return "Active (doses)"
        }
    }
}

public final class BoostV5Store: @unchecked Sendable {
    public static let shared = BoostV5Store()
    private let modeKey = "boost_v5_mode"
    private let stateKey = "boost_v5_persisted_state"
    private let defaults: UserDefaults
    // Guards the load→modify→save of the persisted state against an overlap between the scheduled
    // loop and a manual determine call (parity with BoostActivityStore/BoostMealTimeStore locking).
    private let lock = NSLock()
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var mode: BoostMode {
        get {
            lock.lock()
            defer { lock.unlock() }
            return BoostMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .shadow
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(newValue.rawValue, forKey: modeKey)
        }
    }

    public func loadState() -> V5PersistedState {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(V5PersistedState.self, from: data)
        else { return V5PersistedState() }
        return state
    }

    public func saveState(_ state: V5PersistedState) {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }
}
