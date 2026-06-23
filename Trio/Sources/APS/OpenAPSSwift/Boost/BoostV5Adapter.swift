import Foundation

enum BoostV5Adapter {
    private static func dbl(_ d: Decimal?) -> Double? { d.map { ($0 as NSDecimalNumber).doubleValue } }

    /// Minimum sgv over the last 60 min (mg/dL); high default when no recent data (≈ no recent low).
    private static func recentLowBg(_ glucose: [BloodGlucose], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-3600)
        let recent = glucose.filter { $0.dateString >= cutoff }.compactMap(\.sgv)
        return Double(recent.min() ?? 120)
    }

    /// Run the V5 engine for this cycle against the stock determination + glucose status.
    /// Returns the decision; the caller decides whether to act on it (mode-gated).
    /// Map a 5-min BG delta (mg/dL) to the model's numeric trend feature (-2…+2),
    /// approximating the Nightscout trend arrows the AAPS model was trained on.
    private static func directionNum(fromDelta delta: Double) -> Double {
        switch delta {
        case 9...: return 2 // double up
        case 3 ..< 9: return 1 // single / 45° up
        case -3 ... 3: return 0 // flat
        case -9 ..< -3: return -1 // single / 45° down
        default: return -2 // double down
        }
    }

    static func run(
        determination: Determination,
        glucoseStatus: GlucoseStatus,
        glucose: [BloodGlucose],
        iobData: [IobResult],
        maxIob: Double,
        roundSmbTo: Double,
        microBolusAllowed: Bool,
        mode: BoostMode,
        clock: Date,
        store: BoostV5Store = .shared
    ) -> Result {
        let delta = (glucoseStatus.delta as NSDecimalNumber).doubleValue
        let shortAvg = (glucoseStatus.shortAvgDelta as NSDecimalNumber).doubleValue
        let longAvg = (glucoseStatus.longAvgDelta as NSDecimalNumber).doubleValue
        let bg = (glucoseStatus.glucose as NSDecimalNumber).doubleValue
        let maxDelta = (glucoseStatus.maxDelta as NSDecimalNumber).doubleValue
        let deltaAccl = 100.0 * (delta - shortAvg) / max(abs(shortAvg), 2.0)

        let eventualBg = determination.eventualBG.map(Double.init) ?? bg
        let targetBg = dbl(determination.current_target) ?? 100
        let baseInsulinReq = max(0.0, dbl(determination.insulinReq) ?? 0.0)
        let iob = dbl(determination.iob) ?? 0.0
        let minGuardBg = dbl(determination.minGuardBG) ?? bg
        let minGuardThreshold = dbl(determination.threshold) ?? 80.0
        let hour = Calendar.current.component(.hour, from: clock)

        // ── ML scores (Layer-A retrofit): pure-Swift LightGBM inference on 8 features. ──
        // basaliob / activity come from the current IOB sample; the rest from the
        // determination + glucose status. nil if the bundled model didn't load.
        let current = iobData.first
        let mlFeatures = BoostMLModels.Features(
            cgmMgdl: bg,
            iobTotal: current.map { ($0.iob as NSDecimalNumber).doubleValue } ?? iob,
            iobBasal: current.map { ($0.basaliob as NSDecimalNumber).doubleValue } ?? 0.0,
            bgAboveTarget: bg - targetBg,
            directionNum: directionNum(fromDelta: delta),
            hour: Double(hour),
            iobActivity: current.map { ($0.activity as NSDecimalNumber).doubleValue } ?? 0.0,
            insulinReq: baseInsulinReq
        )
        let mlHypoRisk = BoostMLModels.hypoRisk(mlFeatures)
        let mlMealLikely = BoostMLModels.mealLikely(mlFeatures)

        let inputs = V5Inputs(
            delta: delta,
            shortAvgDelta: shortAvg,
            deltaAccl: deltaAccl,
            bg: bg,
            eventualBg: eventualBg,
            targetBg: targetBg,
            maxDelta: maxDelta,
            minGuardBg: minGuardBg,
            minGuardThreshold: minGuardThreshold,
            deltaHistory: [longAvg, shortAvg, delta],
            iob: iob,
            maxIob: maxIob,
            baseInsulinReq: baseInsulinReq,
            roundSmbTo: roundSmbTo,
            enableSmbPreChecks: microBolusAllowed,
            mlHypoRisk: mlHypoRisk, // bundled LightGBM; nil → score renormalize path
            mlMealLikely: mlMealLikely, // bundled LightGBM; nil → score renormalize path
            recentLowBg: recentLowBg(glucose, now: clock),
            cumulativeRise30min: max(0.0, shortAvg * 6.0),
            hour: hour,
            exerciseActive: false, // HealthKit activity wired in a later phase
            inPostExerciseWindow: false,
            fastCarbConfirmEnabled: true
        )

        let decision = BoostV5Engine.decide(inputs, persisted: store.loadState())
        store.saveState(decision.newPersistedState)
        let reason = reasonTag(decision, mode: mode, mlHypoRisk: mlHypoRisk, mlMealLikely: mlMealLikely)
        return Result(decision: decision, reason: reason)
    }

    /// What the harness consumes: the engine decision plus the telemetry string to append.
    struct Result {
        let decision: V5Decision
        let reason: String
    }

    /// Compact telemetry string appended to the determination reason (shadow + active).
    static func reasonTag(_ d: V5Decision, mode: BoostMode, mlHypoRisk: Double?, mlMealLikely: Double?) -> String {
        let st = d.mealHypothesis.rawValue
        let smb = String(format: "%.2f", d.finalDose)
        let ml = { () -> String in
            func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
            return " ml(hypo=\(fmt(mlHypoRisk)) meal=\(fmt(mlMealLikely)))"
        }()
        return "boostV5[\(mode.rawValue)]: state=\(st) score=\(String(format: "%.2f", d.score)) wouldSMB=\(smb)U;\(ml)"
    }
}
