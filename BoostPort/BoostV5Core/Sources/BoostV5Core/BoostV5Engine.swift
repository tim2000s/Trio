import Foundation

public struct V5Inputs {
    // Glucose status
    public var delta: Double
    public var shortAvgDelta: Double
    public var deltaAccl: Double
    public var bg: Double
    public var eventualBg: Double
    public var targetBg: Double
    public var maxDelta: Double
    public var minGuardBg: Double
    public var minGuardThreshold: Double
    public var deltaHistory: [Double]
    // IOB / dose context
    public var iob: Double
    public var maxIob: Double
    public var baseInsulinReq: Double
    public var roundSmbTo: Double
    public var enableSmbPreChecks: Bool
    // ML outputs
    public var mlHypoRisk: Double?
    public var mlMealLikely: Double?
    public var riskAtProjectedIob: ((Double) -> Double)?
    // Cycle context
    public var recentLowBg: Double
    public var cumulativeRise30min: Double
    public var hour: Int
    public var exerciseActive: Bool
    public var inPostExerciseWindow: Bool
    public var asleep: Bool
    public var fastCarbConfirmEnabled: Bool
    public var sensorQualityOk: Bool
    // Reset triggers
    public var profileSwitched: Bool
    public var pumpDisconnected: Bool
    public var loopSuspended: Bool
    public var timeJumpMinutes: Double
    // Knobs
    public var aggressionUserKnob: Double
    public var hypoCautionUserKnob: Double
    public var sensitivityUserKnob: Double
    public var confirmedCapU: Double
    public var committedCapU: Double

    public init(
        delta: Double, shortAvgDelta: Double, deltaAccl: Double, bg: Double, eventualBg: Double,
        targetBg: Double, maxDelta: Double, minGuardBg: Double, minGuardThreshold: Double,
        deltaHistory: [Double], iob: Double, maxIob: Double, baseInsulinReq: Double, roundSmbTo: Double,
        enableSmbPreChecks: Bool, mlHypoRisk: Double? = nil, mlMealLikely: Double? = nil,
        riskAtProjectedIob: ((Double) -> Double)? = nil, recentLowBg: Double, cumulativeRise30min: Double,
        hour: Int, exerciseActive: Bool, inPostExerciseWindow: Bool, asleep: Bool = false,
        fastCarbConfirmEnabled: Bool = false, sensorQualityOk: Bool = true, profileSwitched: Bool = false,
        pumpDisconnected: Bool = false, loopSuspended: Bool = false, timeJumpMinutes: Double = 0.0,
        aggressionUserKnob: Double = 1.0, hypoCautionUserKnob: Double = 1.0, sensitivityUserKnob: Double = 1.0,
        confirmedCapU: Double = SafetyGateConstants.maxConfirmedCommitDoseU,
        committedCapU: Double = SafetyGateConstants.maxCommittedDoseU
    ) {
        self.delta = delta
        self.shortAvgDelta = shortAvgDelta
        self.deltaAccl = deltaAccl
        self.bg = bg
        self.eventualBg = eventualBg
        self.targetBg = targetBg
        self.maxDelta = maxDelta
        self.minGuardBg = minGuardBg
        self.minGuardThreshold = minGuardThreshold
        self.deltaHistory = deltaHistory
        self.iob = iob
        self.maxIob = maxIob
        self.baseInsulinReq = baseInsulinReq
        self.roundSmbTo = roundSmbTo
        self.enableSmbPreChecks = enableSmbPreChecks
        self.mlHypoRisk = mlHypoRisk
        self.mlMealLikely = mlMealLikely
        self.riskAtProjectedIob = riskAtProjectedIob
        self.recentLowBg = recentLowBg
        self.cumulativeRise30min = cumulativeRise30min
        self.hour = hour
        self.exerciseActive = exerciseActive
        self.inPostExerciseWindow = inPostExerciseWindow
        self.asleep = asleep
        self.fastCarbConfirmEnabled = fastCarbConfirmEnabled
        self.sensorQualityOk = sensorQualityOk
        self.profileSwitched = profileSwitched
        self.pumpDisconnected = pumpDisconnected
        self.loopSuspended = loopSuspended
        self.timeJumpMinutes = timeJumpMinutes
        self.aggressionUserKnob = aggressionUserKnob
        self.hypoCautionUserKnob = hypoCautionUserKnob
        self.sensitivityUserKnob = sensitivityUserKnob
        self.confirmedCapU = confirmedCapU
        self.committedCapU = committedCapU
    }
}

public struct V5PersistedState: Codable, Equatable, Sendable {
    public var mealHypothesis: MealHypothesisState
    public var mlMealLikelyNullStreak: Int
    /// Epoch-ms of the last decide() — the host uses it to detect a time jump / long gap
    /// (incl. app restart) and reset the meal hypothesis. Managed by the adapter, not decide().
    public var lastRunMs: Double?
    public init(
        mealHypothesis: MealHypothesisState = MealHypothesisState(),
        mlMealLikelyNullStreak: Int = 0,
        lastRunMs: Double? = nil
    ) {
        self.mealHypothesis = mealHypothesis
        self.mlMealLikelyNullStreak = mlMealLikelyNullStreak
        self.lastRunMs = lastRunMs
    }
}

public struct V5Decision {
    public let finalDose: Double
    public let score: Double
    public let scoreComponents: ScoreComponents
    public let mlWeightsRenormalized: Bool
    public let mealHypothesis: MealHypothesis
    public let mealHypothesisAge: Int
    public let stateReset: Bool
    public let aggressionBudget: AggressionBudgetResult
    public let actionMultiplier: Double
    public let insulinToDeliver: Double
    public let phase3: Phase3Result
    public let newPersistedState: V5PersistedState
}

public enum BoostV5Engine {
    /// One full V5 cycle. Pure over inputs + prior state.
    public static func decide(_ inputs: V5Inputs, persisted: V5PersistedState) -> V5Decision {
        let (resetState, didReset) = MealHypothesisEngine.resetIfNeeded(
            current: persisted.mealHypothesis,
            profileSwitched: inputs.profileSwitched, pumpDisconnected: inputs.pumpDisconnected,
            loopSuspended: inputs.loopSuspended, timeJumpMinutes: inputs.timeJumpMinutes
        )

        let nextNullStreak = inputs.mlMealLikely == nil ? persisted.mlMealLikelyNullStreak + 1 : 0
        let scoreResult = MealSignalScoreEngine.mealSignalScore(
            delta: inputs.delta, deltaAccl: inputs.deltaAccl, mlMealLikely: inputs.mlMealLikely,
            recentLowBg: inputs.recentLowBg, hour: inputs.hour, exerciseActive: inputs.exerciseActive,
            cumulativeRise30min: inputs.cumulativeRise30min, mlMealLikelyNullStreak: nextNullStreak
        )

        // AggressionBudget is HOISTED above the state step — it is state-independent (takes no
        // meal-state input), so computing it first lets the OBSERVING→CONFIRMED dose-adequacy gate
        // size the prospective commit-shot. Pure reorder, no behaviour change. (2026-07-02, mirrors
        // AAPS 4bfd7bea32.)
        let budget = AggressionBudgetEngine.aggressionBudget(
            baseInsulinReq: inputs.baseInsulinReq, mlHypoRisk: inputs.mlHypoRisk,
            inPostExerciseWindow: inputs.inPostExerciseWindow,
            hypoCautionUserKnob: inputs.hypoCautionUserKnob, sensitivityUserKnob: inputs.sensitivityUserKnob
        )

        // Dose-adequacy gate for OBSERVING→CONFIRMED (2026-07-02): the single per-session commit-shot
        // must beat one routine COMMITTED hold cycle (committedCapU) to be worth spending — else a
        // trivial pre-meal upswing burns the token and the committedInSession lock starves the meal on
        // holds alone. Uses the mlHypoRisk-DAMPED budget, so confirm is also held back when hypo risk
        // is elevated. Clamped strictly below confirmedCapU so a manual committedCap ≥ confirmedCap
        // can't make the gate unsatisfiable (which would silently disable V6 meal response). Fast-carb
        // fast-path is exempt (handled inside step()).
        let prospectiveConfirmShot = budget.budget *
            MealActionMultiplier.value(for: .confirmed, aggressionUserKnob: inputs.aggressionUserKnob)
        let confirmDoseFloor = min(
            inputs.committedCapU,
            MealHypothesisConstants.confirmDoseFloorMaxFracOfConfirmedCap * inputs.confirmedCapU
        )
        let confirmDoseAdequate = prospectiveConfirmShot > confirmDoseFloor

        let newHypothesisState = MealHypothesisEngine.step(
            current: resetState, score: scoreResult.score, eventualBg: inputs.eventualBg,
            targetBg: inputs.targetBg, delta: inputs.delta, deltaAccl: inputs.deltaAccl,
            deltaDeclining: MealHypothesisEngine.deltaDeclining(inputs.deltaHistory, windowCycles: 2),
            asleep: inputs.asleep, exerciseActive: inputs.exerciseActive,
            fastConfirmEnabled: inputs.fastCarbConfirmEnabled,
            confirmDoseAdequate: confirmDoseAdequate
        )

        let actionMult = MealActionMultiplier.value(for: newHypothesisState.state, aggressionUserKnob: inputs.aggressionUserKnob)
        let rawInsulinToDeliver = budget.budget * actionMult
        let velocityFactor = SafetyGates.velocityScaledDoseFactor(inputs.cumulativeRise30min)
        let velocityScaled = rawInsulinToDeliver * velocityFactor
        let insulinToDeliver = SafetyGates.applyStateDoseCap(
            newHypothesisState.state,
            velocityScaled,
            confirmedCapU: inputs.confirmedCapU,
            committedCapU: inputs.committedCapU
        )

        let phase3 = SafetyGates.applyPhase3(Phase3Inputs(
            insulinToDeliver: insulinToDeliver, enableSmbPreChecks: inputs.enableSmbPreChecks,
            minGuardBg: inputs.minGuardBg, minGuardThreshold: inputs.minGuardThreshold,
            maxDelta: inputs.maxDelta, bg: inputs.bg, iob: inputs.iob, maxIob: inputs.maxIob,
            deltaAccl: inputs.deltaAccl, delta: inputs.delta, baseInsulinReq: inputs.baseInsulinReq,
            roundSmbTo: inputs.roundSmbTo, sensorQualityOk: inputs.sensorQualityOk,
            riskAtProjectedIob: inputs.riskAtProjectedIob, mlHypoRisk: inputs.mlHypoRisk
        ))

        return V5Decision(
            finalDose: phase3.finalDose, score: scoreResult.score, scoreComponents: scoreResult.components,
            mlWeightsRenormalized: scoreResult.mlWeightsRenormalized, mealHypothesis: newHypothesisState.state,
            mealHypothesisAge: newHypothesisState.ageCycles, stateReset: didReset, aggressionBudget: budget,
            actionMultiplier: actionMult, insulinToDeliver: insulinToDeliver, phase3: phase3,
            newPersistedState: V5PersistedState(mealHypothesis: newHypothesisState, mlMealLikelyNullStreak: nextNullStreak)
        )
    }
}
