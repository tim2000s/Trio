// BoostV5Adapter — Trio-side glue between Trio's determine-basal context and the (pure, tested)
// BoostV5Core engine. Lives in the Trio target so it can read Trio's typed models. Extracts the
// engine inputs, runs decide(), and (in .active mode) overrides the determination's SMB; in
// .shadow mode it only annotates the reason. baseInsulinReq = the stock Determination's insulinReq,
// exactly as AAPS V5 takes Boost-V1's insulinReq — V5 adds no sensitivity logic of its own.

import Foundation

enum BoostV5Adapter {

    private static func dbl(_ d: Decimal?) -> Double? { d.map { ($0 as NSDecimalNumber).doubleValue } }

    /// Minimum sgv over the last 60 min (mg/dL); high default when no recent data (≈ no recent low).
    private static func recentLowBg(_ glucose: [BloodGlucose], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-3600)
        let recent = glucose.filter { $0.dateString >= cutoff }.compactMap { $0.sgv }
        return Double(recent.min() ?? 120)
    }

    /// Run the V5 engine for this cycle against the stock determination + glucose status.
    /// Returns the decision; the caller decides whether to act on it (mode-gated).
    static func run(
        determination: Determination,
        glucoseStatus: GlucoseStatus,
        glucose: [BloodGlucose],
        maxIob: Double,
        roundSmbTo: Double,
        microBolusAllowed: Bool,
        clock: Date,
        store: BoostV5Store = .shared
    ) -> V5Decision {
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
            mlHypoRisk: nil,          // ML scores wired in a later phase
            mlMealLikely: nil,        // nil → score renormalize path after a few cycles
            recentLowBg: recentLowBg(glucose, now: clock),
            cumulativeRise30min: max(0.0, shortAvg * 6.0),
            hour: Calendar.current.component(.hour, from: clock),
            exerciseActive: false,    // HealthKit activity wired in a later phase
            inPostExerciseWindow: false,
            fastCarbConfirmEnabled: true
        )

        let decision = BoostV5Engine.decide(inputs, persisted: store.loadState())
        store.saveState(decision.newPersistedState)
        return decision
    }

    /// Compact telemetry string appended to the determination reason (shadow + active).
    static func reasonTag(_ d: V5Decision, mode: BoostMode) -> String {
        let st = d.mealHypothesis.rawValue
        let smb = String(format: "%.2f", d.finalDose)
        return "boostV5[\(mode.rawValue)]: state=\(st) score=\(String(format: "%.2f", d.score)) wouldSMB=\(smb)U;"
    }
}
