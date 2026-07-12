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
    /// True when inside the post-rescue window (rolling 45-min CGM low < 75 mg/dL — same source and
    /// threshold as the override seam's post-rescue cap). Gates the composed floor off (both the
    /// would-add computation and, when `composedFloorActive`, the delivered floor). 2026-07-06, AAPS
    /// e0f18ddd0e / 730b3dcb2c.
    public var postRescueWindow: Bool
    /// V1's would-dose SMB this cycle (the base determination's `units`, BEFORE any V6 override), U.
    /// Used only by the composed floor: RECOVERING is a non-meal state capped at V1's would-dose at
    /// the override seam (2026-07-04 non-meal-state cap), so the floored dose is bounded the same
    /// way. Nil = bound unavailable (not applied).
    public var v1WouldDoseU: Double?
    /// Composed brake-floor ACTIVATION (`boostV5ComposedFloorActive` AND V6 is the active doser).
    /// False (default) = shadow: `floorWouldAdd` logs what the floor WOULD add, delivered dosing
    /// untouched. True = the delivered dose is floored at the composed-floor target on qualifying
    /// cycles (see decide()). Per-user activation only — TBR-gated by guidance. 2026-07, AAPS 730b3dcb2c.
    public var composedFloorActive: Bool
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
        fastCarbConfirmEnabled: Bool = false, sensorQualityOk: Bool = true,
        postRescueWindow: Bool = false, v1WouldDoseU: Double? = nil, composedFloorActive: Bool = false,
        profileSwitched: Bool = false,
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
        self.postRescueWindow = postRescueWindow
        self.v1WouldDoseU = v1WouldDoseU
        self.composedFloorActive = composedFloorActive
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
    /// Previous cycle's meal_signal_score — input to the sustained-score early confirm
    /// (`confirmMinObservingAgeScoreReady`, 2026-07-03, AAPS 242a6e179d). Deliberately NOT
    /// serialized (excluded from CodingKeys, mirroring the AAPS in-memory-cache-only idiom):
    /// it survives across cycles only via BoostV5Store's in-memory cache, so a process restart
    /// loses it, which fails safe (streak=false → legacy confirm timing for one cycle).
    public var lastCycleScore: Double? = nil

    enum CodingKeys: String, CodingKey {
        // lastCycleScore intentionally omitted — in-memory only (see its doc comment).
        case mealHypothesis
        case mlMealLikelyNullStreak
        case lastRunMs
    }

    public init(
        mealHypothesis: MealHypothesisState = MealHypothesisState(),
        mlMealLikelyNullStreak: Int = 0,
        lastRunMs: Double? = nil,
        lastCycleScore: Double? = nil
    ) {
        self.mealHypothesis = mealHypothesis
        self.mlMealLikelyNullStreak = mlMealLikelyNullStreak
        self.lastRunMs = lastRunMs
        self.lastCycleScore = lastCycleScore
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
    /// Composed Phase-3 floor (F = `ComposedFloor.fraction`) telemetry — dual semantics keyed on
    /// `V5Inputs.composedFloorActive`; nil when the floor conditions are unmet either way:
    ///  - toggle OFF (shadow): extra U the floor WOULD have added this cycle vs the pipeline output;
    ///    never affects `finalDose`.
    ///  - toggle ON (activation): the uplift actually APPLIED to `finalDose` (delivered-with-floor −
    ///    what-unfloored-would-have-delivered); 0.0 when no uplift.
    /// See `ComposedFloor.targetDose`. 2026-07-06/07, AAPS e0f18ddd0e + 730b3dcb2c.
    public let floorWouldAdd: Double?
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
        // 2026-07-02 (9545323fb1): size the shot as it would actually DELIVER — including velocity
        // scaling — not the pre-velocity raw. Backtest: 35.8% of raw-gate passes delivered BELOW the
        // floor after velocity scaling, re-creating the starvation the gate exists to prevent. The
        // velocityFactor is hoisted here (pure fn of inputs) and reused for the delivered dose below.
        let velocityFactor = SafetyGates.velocityScaledDoseFactor(inputs.cumulativeRise30min)
        let prospectiveConfirmShot = budget.budget *
            MealActionMultiplier.value(for: .confirmed, aggressionUserKnob: inputs.aggressionUserKnob) * velocityFactor
        // 2026-07-06 (AAPS 311703ddf5): the committedCap term of the floor is PINNED at the factory
        // default (0.5 U) so a user-raised committedCap can't silently tighten the confirm gate —
        // see MealHypothesisConstants.confirmDoseFloorU.
        let confirmDoseFloor = MealHypothesisConstants.confirmDoseFloorU(
            committedCapU: inputs.committedCapU,
            confirmedCapU: inputs.confirmedCapU
        )
        let confirmDoseAdequate = prospectiveConfirmShot > confirmDoseFloor

        // 2026-07-03 sustained-score early confirm input (AAPS 242a6e179d): was LAST cycle's
        // score already confirm-ready? Sourced from the in-memory persisted state (nil on cold
        // start → false → legacy timing).
        let scoreReadyStreak = (persisted.lastCycleScore ?? 0.0) >= MealHypothesisConstants.confirmScore

        let newHypothesisState = MealHypothesisEngine.step(
            current: resetState, score: scoreResult.score, eventualBg: inputs.eventualBg,
            targetBg: inputs.targetBg, delta: inputs.delta, deltaAccl: inputs.deltaAccl,
            deltaDeclining: MealHypothesisEngine.deltaDeclining(inputs.deltaHistory, windowCycles: 2),
            asleep: inputs.asleep, exerciseActive: inputs.exerciseActive,
            // 2026-07-02 (1245d33a9a): post-hypo rescue-carb guard — the fast-carb fast-path is
            // suppressed when the 60-min low is below the rescue threshold, since a rescue-carb rebound
            // routinely satisfies the fast-path signals yet is exempt from the confirmDoseAdequate gate.
            fastConfirmEnabled: MealHypothesisEngine.fastConfirmAllowed(
                inputs.fastCarbConfirmEnabled, recentLowBg: inputs.recentLowBg
            ),
            confirmDoseAdequate: confirmDoseAdequate,
            scoreReadyStreak: scoreReadyStreak // 2026-07-03 sustained-score early confirm (hoisted above)
        )

        let actionMult = MealActionMultiplier.value(for: newHypothesisState.state, aggressionUserKnob: inputs.aggressionUserKnob)
        let rawInsulinToDeliver = budget.budget * actionMult
        // velocityFactor hoisted above the confirm dose gate (reused here). (2026-07-02, 9545323fb1)
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

        // 2026-07-06/07 composed Phase-3 floor (AAPS e0f18ddd0e + 730b3dcb2c). Computed here because
        // this is the one place the whole composed multiplier stack (state mult × velocityFactor ×
        // iobHeadroomBrake × decelerationBrake) has already been applied (phase3.finalDose). Target
        // semantics: nil = floor conditions unmet; 0.0 = a Phase-3 HARD gate fired; else the bounded
        // floored dose min(budget × F, committedCapU) (v1-bounded in RECOVERING). See ComposedFloor.
        let floorTarget = ComposedFloor.targetDose(
            state: newHypothesisState.state,
            bg: inputs.bg,
            eventualBg: inputs.eventualBg,
            targetBg: inputs.targetBg,
            asleep: inputs.asleep,
            postRescueWindow: inputs.postRescueWindow,
            budgetU: budget.budget,
            committedCapU: inputs.committedCapU,
            v1WouldDoseU: inputs.v1WouldDoseU,
            hardGateFired: phase3.reductions.hardGateFired != nil
        )
        let finalDose: Double
        let floorWouldAdd: Double?
        if !inputs.composedFloorActive {
            // SHADOW (toggle OFF, or V6 not the active doser) — zero dosing-path effect; the field
            // records what the floor WOULD have added.
            finalDose = phase3.finalDose
            floorWouldAdd = floorTarget.map { max(0.0, $0 - phase3.finalDose) }
        } else {
            // ACTIVE (per-user activation): deliver max(pipeline dose, floored dose). The floored
            // dose passes through the SAME downstream clamps the pipeline dose already received after
            // the soft-brake product, so no hard gate or cap is bypassed (see ComposedFloor). The
            // override-seam caps (non-meal v1-bound, post-rescue cap, cumulative cap, sleep/boost-
            // active gates) all still run downstream on finalDose; RECOVERING is v1-bounded inside
            // the target so the logged uplift matches what the seam delivers.
            let deliverableFloor: Double = floorTarget.map { target in
                var f = min(target, max(0.0, inputs.maxIob - inputs.iob))
                f = min(f, SafetyGates.dynamicSpikeCap(inputs.baseInsulinReq))
                if inputs.roundSmbTo > 0.0 { f = floor(f / inputs.roundSmbTo + 1E-9) * inputs.roundSmbTo }
                return max(0.0, f)
            } ?? 0.0
            finalDose = max(phase3.finalDose, deliverableFloor)
            floorWouldAdd = floorTarget.map { _ in finalDose - phase3.finalDose }
        }

        return V5Decision(
            finalDose: finalDose, score: scoreResult.score, scoreComponents: scoreResult.components,
            mlWeightsRenormalized: scoreResult.mlWeightsRenormalized, mealHypothesis: newHypothesisState.state,
            mealHypothesisAge: newHypothesisState.ageCycles, stateReset: didReset, aggressionBudget: budget,
            actionMultiplier: actionMult, insulinToDeliver: insulinToDeliver, phase3: phase3,
            floorWouldAdd: floorWouldAdd,
            newPersistedState: V5PersistedState(
                mealHypothesis: newHypothesisState,
                mlMealLikelyNullStreak: nextNullStreak,
                lastCycleScore: scoreResult.score // 2026-07-03: next cycle's scoreReadyStreak input
            )
        )
    }
}

// MARK: - Composed Phase-3 floor (F = 0.25) — shadow first, per-user activatable

/// 2026-07-06/07 composed Phase-3 floor (AAPS e0f18ddd0e + 730b3dcb2c).
///
/// Forensic + 40,180-cycle cohort backtest: on meal-session high cycles (CONFIRMED/COMMITTED/
/// RECOVERING ∧ BG > 160 ∧ eventualBG > target+20 ∧ awake ∧ budget > 0) the composed post-budget
/// multiplier — stateMult × velocityFactor × iobHeadroomBrake × decelerationBrake — has MEDIAN
/// 0.037. Individually-sane brakes multiply into a product that drives the dose below one pump
/// step, so it floor-rounds to ZERO for 30+ minutes mid-meal (Episode B: BG 268–277, six
/// consecutive zero-dose cycles, ended 297 + a manual bolus). A pipeline defect (independent
/// brakes multiplying), not a calibration issue.
///
/// F = 0.25 backtests at +0.76 U/user-day with 16.6% pre-low incidence — the base rate, i.e. no
/// added hypo exposure. SHADOW first: with the toggle OFF, `targetDose` only feeds the
/// `floorWouldAdd` telemetry (what the floor WOULD have added) and delivered dosing is untouched.
/// Activation (`boostV5ComposedFloorActive`, Advanced, default OFF) applies the floor to the
/// delivered dose — PER-USER, and the per-user TBR gate is now ENFORCED in code (2026-07-08, AAPS
/// 9110ef2520 + 8b492a08e7): the floor may only engage while trailing-14d TBR<63 < 2.0% AND
/// TBR<70 < 3.5% (`allowedByTbr`, fail-closed). The host computes those from a throttled 14d BG
/// scan and ANDs the result into `V5Inputs.composedFloorActive`.
enum ComposedFloor {
    /// Floor fraction of the (mlHypoRisk-damped) AggressionBudget the composed multiplier stack may
    /// not push the dose below on a meal-session high cycle.
    static let fraction = 0.25
    /// BG must exceed this (mg/dL) — the "high cycle" condition.
    static let minBgMgdl = 160.0
    /// eventualBG must exceed target by more than this (mg/dL).
    static let minEventualOffsetMgdl = 20.0

    /// Max trailing-14-day time-below-63 mg/dL (3.5 mmol/L — the TING lower bound) for the composed
    /// brake-floor to be ALLOWED to engage. The floor is insulin-ADDING, so it may only alter the
    /// delivered dose for users with low severe-hypo exposure. (2026-07-08, AAPS 9110ef2520.)
    static let maxTbr63Pct = 2.0
    /// Max trailing-14-day time-below-70 mg/dL — the two-test-bar primary gate (added 2026-07-08,
    /// AAPS 8b492a08e7: a <63-only gate wrongly engaged user C, whose <63 was 1.56% but <70 3.95%).
    static let maxTbr70Pct = 3.5

    /// Whether the composed brake-floor may engage, given the user's trailing-14d time-below-63 AND
    /// time-below-70 mg/dL. FAIL-CLOSED: a nil in EITHER (not yet computed, or insufficient CGM
    /// history to trust the fraction) means NOT allowed — an insulin-adding feature never engages
    /// without evidence the user is not hypo-prone. Thresholds are strict (<), so a user exactly at
    /// either limit is blocked. (2026-07-08, AAPS 9110ef2520 + 8b492a08e7.)
    static func allowedByTbr(
        tbr63Pct: Double?,
        tbr70Pct: Double?,
        max63: Double = maxTbr63Pct,
        max70: Double = maxTbr70Pct
    ) -> Bool {
        guard let t63 = tbr63Pct, let t70 = tbr70Pct else { return false }
        return t63 < max63 && t70 < max70
    }

    /// Minimum trailing-14d CGM readings before the TBR fractions are trusted (~3.5 days of 5-min
    /// CGM). Below this the gate fails closed. (AAPS `TBR_GATE_MIN_READINGS` = 1000.)
    static let gateMinReadings = 1000

    /// The complete fail-closed hypo-gate decision from trailing-14d glucose values (mg/dL, already
    /// sanity-filtered by the caller). Fewer than `minReadings` readings → NOT allowed (thin history
    /// can't be trusted for an insulin-adding feature); otherwise computes TBR<63 / TBR<70 over the
    /// SAME window and applies `allowedByTbr`. The host (`BoostComposedFloorGate`) wraps this in a
    /// throttled, thread-safe cache; keeping the decision here puts the safety branches under test.
    static func allowedFromGlucose(valuesMgdl: [Int], minReadings: Int = gateMinReadings) -> Bool {
        let n = valuesMgdl.count
        guard n >= minReadings else { return false }
        let tbr63 = 100.0 * Double(valuesMgdl.filter { $0 < 63 }.count) / Double(n)
        let tbr70 = 100.0 * Double(valuesMgdl.filter { $0 < 70 }.count) / Double(n)
        return allowedByTbr(tbr63Pct: tbr63, tbr70Pct: tbr70)
    }

    /// The composed Phase-3 floor's target dose (U) for this cycle — the single source of truth for
    /// BOTH the shadow field (toggle OFF: `wouldAdd = max(0, target − actualFinalDose)`) and the
    /// delivered floor (toggle ON: `finalDose = max(pipeline, clamped-and-rounded target)`), so the
    /// two can never diverge.
    ///
    /// Returns:
    ///  - **nil** when the floor conditions are unmet. Conditions (ALL required): meal session
    ///    (CONFIRMED/COMMITTED/RECOVERING) ∧ bg > 160 ∧ eventualBg > targetBg + 20 ∧ !asleep ∧
    ///    !postRescueWindow ∧ budget > 0. The budget > 0 condition makes the Episode-A guard hold
    ///    BY CONSTRUCTION: a zero budget can never produce a floored dose.
    ///  - **0.0** when a Phase-3 HARD gate fired (enableSMB pre-checks, minGuardBG, maxDelta): those
    ///    zero the dose regardless of any multiplier floor, so the floor may add nothing.
    ///  - Otherwise the bounded floored dose = min(budget × F, committedCapU) — one routine hold is
    ///    the ceiling — additionally bounded at `v1WouldDoseU` in RECOVERING, a NON-meal state at
    ///    the override seam (capped at V1's would-dose since the 2026-07-04 non-meal-state cap).
    static func targetDose(
        state: MealHypothesis,
        bg: Double,
        eventualBg: Double,
        targetBg: Double,
        asleep: Bool,
        postRescueWindow: Bool,
        budgetU: Double,
        committedCapU: Double,
        v1WouldDoseU: Double?,
        hardGateFired: Bool
    ) -> Double? {
        let mealSession = state == .confirmed || state == .committed || state == .recovering
        let conditionsMet = mealSession &&
            bg > minBgMgdl &&
            eventualBg > targetBg + minEventualOffsetMgdl &&
            !asleep &&
            !postRescueWindow &&
            budgetU > 0.0
        if !conditionsMet { return nil }
        // Hard gates (enableSMB pre-checks, minGuardBG, maxDelta) zero the dose regardless of any
        // multiplier floor — the floored pipeline would deliver 0 too, so the floor adds nothing.
        if hardGateFired { return 0.0 }
        let flooredDose = min(budgetU * fraction, committedCapU)
        // RECOVERING: v1-bound where applicable (non-meal-state cap at the override seam).
        if state == .recovering, let v1 = v1WouldDoseU {
            return min(flooredDose, v1)
        }
        return flooredDose
    }
}
