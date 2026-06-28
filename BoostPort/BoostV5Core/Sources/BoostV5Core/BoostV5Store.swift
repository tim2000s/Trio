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
    // Serializes access to the persisted state. NOTE: loadState()/saveState() each take this lock
    // only for their own call, so calling them as a pair does NOT make the read-modify-write atomic.
    // Use mutateState(_:) for the load→decide→save cycle — it holds the lock across the whole span,
    // which is what guards against an overlap between the scheduled loop and a manual determine call.
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

    /// Atomically load → mutate → save the persisted state under a single critical section.
    /// `body` receives the current state `inout`; whatever it leaves in `state` is persisted.
    /// This is the only safe way to run the load→decide→save cycle when a scheduled loop and a
    /// manual determine call can overlap, since it prevents a lost-update (last-writer-wins) race.
    public func mutateState<T>(_ body: (inout V5PersistedState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        var state: V5PersistedState
        if let data = defaults.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode(V5PersistedState.self, from: data)
        {
            state = decoded
        } else {
            state = V5PersistedState()
        }
        let result = body(&state)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
        return result
    }
}
