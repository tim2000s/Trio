import Foundation

public enum BoostMode: String, Sendable {
    case off // stock Trio only
    case shadow // run V5, log what it would do, do NOT change dosing
    case active // V5 drives the SMB
}

public final class BoostV5Store {
    public static let shared = BoostV5Store()
    private let modeKey = "boost_v5_mode"
    private let stateKey = "boost_v5_persisted_state"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var mode: BoostMode {
        get { BoostMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .shadow }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    public func loadState() -> V5PersistedState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(V5PersistedState.self, from: data)
        else { return V5PersistedState() }
        return state
    }

    public func saveState(_ state: V5PersistedState) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey) }
    }
}
