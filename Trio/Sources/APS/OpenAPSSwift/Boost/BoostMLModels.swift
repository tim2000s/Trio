import Foundation

/// Loads + caches the bundled Boost ML models (hypo risk + meal likelihood) and runs
/// inference. Pure tree-walk inference lives in `BoostTreeModel` (BoostV5Core); this is
/// the Trio-target glue that finds the JSON in the app bundle and caches the parsed model.
///
/// Layer-A retrofit, identical to AAPS: outputs feed mlHypoRisk / mlMealLikely. In shadow
/// mode they only annotate; in active mode they steer the V5 score + safety gates.
enum BoostMLModels {
    /// 8-feature vector, in the model's expected order:
    /// 0 cgm_mgdl, 1 iob_iob, 2 iob_basaliob, 3 bg_above_target,
    /// 4 direction_num, 5 hour, 6 iob_activity, 7 sug_insulinReq
    struct Features {
        var cgmMgdl: Double
        var iobTotal: Double
        var iobBasal: Double
        var bgAboveTarget: Double
        var directionNum: Double
        var hour: Double
        var iobActivity: Double
        var insulinReq: Double

        var vector: [Double] {
            [cgmMgdl, iobTotal, iobBasal, bgAboveTarget, directionNum, hour, iobActivity, insulinReq]
        }
    }

    private static let hypo = LazyModel(resource: "hypo_risk_model")
    private static let meal = LazyModel(resource: "meal_likelihood_model")

    /// P(hypo event in next 4h) in [0,1], or nil if the model couldn't load. 8-feature path.
    static func hypoRisk(_ f: Features) -> Double? { hypo.model?.predict(f.vector) }

    /// Declared feature names of the loaded hypo model (8 = v9 legacy, 53 = v12), or nil if it
    /// couldn't load. Lets the caller route between the legacy 8-feature path and the v12
    /// windowed-lookback feature builder (mirrors AAPS `getFeatureNames()` dispatch).
    static func hypoFeatureNames() -> [String]? { hypo.model?.featureNames }

    /// P(hypo event in next 4h) from a full feature vector (v12: 53 features built by
    /// `BoostMlFeatureBuilder`), or nil if the model couldn't load.
    static func hypoRisk(vector: [Double]) -> Double? { hypo.model?.predict(vector) }

    /// P(BG peak ≥ current+50 within 90 min) in [0,1], or nil if the model couldn't load.
    static func mealLikely(_ f: Features) -> Double? { meal.model?.predict(f.vector) }

    /// Idempotent, thread-safe lazy loader (mirrors AAPS BoostRiskModel.ensureLoaded):
    /// one load attempt per model; never retries if the asset is missing.
    private final class LazyModel: @unchecked Sendable {
        private let resource: String
        private let lock = NSLock()
        private var attempted = false
        private var cached: BoostTreeModel?

        init(resource: String) { self.resource = resource }

        var model: BoostTreeModel? {
            lock.lock()
            defer { lock.unlock() }
            if attempted { return cached }
            attempted = true
            // Try the boost/ subdirectory first, then a flattened bundle-root copy.
            let url = Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: "boost")
                ?? Bundle.main.url(forResource: resource, withExtension: "json")
            guard let url, let data = try? Data(contentsOf: url) else {
                debug(.openAPS, "BoostMLModels: \(resource).json not found in bundle")
                return nil
            }
            cached = try? BoostTreeModel.from(jsonData: data)
            if cached == nil { debug(.openAPS, "BoostMLModels: failed to parse \(resource).json") }
            return cached
        }
    }
}

/// Persists the v12 ML lookback ring buffer across loop cycles and process restarts (mirrors
/// AAPS `StringKey.ApsBoostMlRingBuffer` — loaded each cycle, the current snapshot pushed, then
/// saved back). UserDefaults-backed, lock-guarded. Holds the serialized JSON string so the
/// `BoostMlFeatureBuilder.RingBuffer` shape can evolve without a migration.
enum BoostMlRingBufferStore {
    private static let key = "boost_ml_ring_buffer_v12"
    private static let lock = NSLock()
    private static let defaults = UserDefaults.standard

    static func load() -> BoostMlFeatureBuilder.RingBuffer {
        lock.lock()
        defer { lock.unlock() }
        let raw = defaults.string(forKey: key) ?? ""
        return BoostMlFeatureBuilder.deserialize(raw)
    }

    static func save(_ buffer: BoostMlFeatureBuilder.RingBuffer) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(BoostMlFeatureBuilder.serialize(buffer), forKey: key)
    }
}
