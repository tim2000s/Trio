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

    /// P(hypo event in next 4h) in [0,1], or nil if the model couldn't load.
    static func hypoRisk(_ f: Features) -> Double? { hypo.model?.predict(f.vector) }

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
