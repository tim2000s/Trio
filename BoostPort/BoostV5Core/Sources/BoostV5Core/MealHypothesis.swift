import Foundation

public enum MealHypothesis: String, Codable, Equatable, Sendable {
    case idle = "IDLE"
    case observing = "OBSERVING"
    case confirmed = "CONFIRMED"
    case committed = "COMMITTED"
    case recovering = "RECOVERING"
}

public struct MealHypothesisState: Codable, Equatable, Sendable {
    public var state: MealHypothesis
    public var ageCycles: Int
    public var maxScoreInObserving: Double
    public var maxEventualBgOffsetInObserving: Double
    public var committedInSession: Bool

    public init(
        state: MealHypothesis = .idle,
        ageCycles: Int = 0,
        maxScoreInObserving: Double = 0.0,
        maxEventualBgOffsetInObserving: Double = 0.0,
        committedInSession: Bool = false
    ) {
        self.state = state
        self.ageCycles = ageCycles
        self.maxScoreInObserving = maxScoreInObserving
        self.maxEventualBgOffsetInObserving = maxEventualBgOffsetInObserving
        self.committedInSession = committedInSession
    }
}

/// Calibrated transition thresholds (HARDCODED — not user knobs). Mirrors the Kotlin constants 1:1.
public enum MealHypothesisConstants {
    public static let enterObservingScore = 0.44
    public static let confirmScore = 0.55
    public static let confirmEventualBgOffsetMgdl = 30.0
    public static let confirmMinObservingAge = 2
    /// 2026-07-03 sustained-score early confirm (AAPS 242a6e179d): OBSERVING → CONFIRMED may fire
    /// ONE cycle before `confirmMinObservingAge` when the INSTANTANEOUS score has been ≥
    /// `confirmScore` on BOTH this cycle and the immediately preceding one (`scoreReadyStreak` —
    /// supplied by the caller, same cross-cycle-input pattern as `deltaDeclining`). All other
    /// confirm conditions (peak eventualBG offset ≥ 30, confirmDoseAdequate, !committedInSession)
    /// are unchanged.
    ///
    /// WHY: replay vs the cohort DB (2026-07-03) showed 53% of confirm latency was purely
    /// mechanical — the score was already ≥ confirmScore for ≥2 cycles before the age gate opened.
    /// Shifting the SAME commit-shot 1 cycle earlier measured 0.0pp additional pre-low exposure,
    /// vs +14–17% for added-insulin levers evaluated in the same sweep. The early path requires
    /// the CURRENT score ≥ threshold (not just the tracked max) because the whole point is a
    /// sustained-ready score, not a transient peak.
    public static let confirmMinObservingAgeScoreReady = confirmMinObservingAge - 1
    /// 2026-07-02 dose-adequacy gate: the confirm floor is committedCapU, clamped to at most this
    /// fraction of confirmedCapU so a manual committedCap ≥ confirmedCap can't make the gate
    /// unsatisfiable (which would silently disable V6's meal response). See BoostV5Engine.decide().
    public static let confirmDoseFloorMaxFracOfConfirmedCap = 0.8
    public static let fallBackToIdleScore = 0.36
    public static let fallBackToIdleAge = 2
    public static let confirmedToCommittedAge = 0
    public static let recoveringDecelThreshold = -5.0
    public static let recoveringToIdleScore = 0.18
    public static let recoveringReengageAccl = 10.0
    public static let recoveringReengageDelta = 3.0
    public static let recoveringReengageOffsetMgdl = 20.0
    public static let recoveringReengageMinAge = 1
    // 2026-07-03 retune (AAPS d2f9a08108; replay sweep over the cohort): Δ 8→6, accl 15→10,
    // score 0.60→0.65. This point catches +21 meals ~9 min earlier while REDUCING false fires
    // 39%→32% — the score raise pays for the physics relaxation. A plain physics relaxation
    // WITHOUT the score raise is worse (40% false); the tighter score gate is what makes the
    // looser Δ/accl thresholds safe. All guards (awake, not exercising, recentLowBg ≥ 80,
    // !committedInSession, pref toggle) unchanged.
    public static let fastConfirmDelta = 6.0 // mg/dL per 5 min — sharp rise (2026-07-03: 8.0 → 6.0)
    public static let fastConfirmAccl = 10.0 // delta_accl % — accelerating (2026-07-03: 15.0 → 10.0)
    public static let fastConfirmScore = 0.65 // meal score must corroborate (2026-07-03: 0.60 → 0.65; > enterObserving 0.44)
    /// 2026-07-02 post-hypo rescue-carb guard: the fast-carb fast-path is suppressed when the 60-min
    /// BG low is below this. A rescue-carb rebound routinely satisfies delta≥8 + accl≥15 + score≥0.60,
    /// and the fast path is EXEMPT from the confirmDoseAdequate gate — so it was the only unguarded
    /// CONFIRMED entry within an hour of a hypo. Replay-calibrated (AAPS 1245d33a9a).
    public static let fastConfirmMinRecentLowMgdl = 80.0
    public static let timeJumpResetMinutes = 30.0
}

public enum MealHypothesisEngine {
    /// Effective fast-carb fast-path enable for this cycle: the user toggle AND the post-hypo
    /// rescue-carb guard (`fastConfirmMinRecentLowMgdl`). Computed by the caller (`decide()`) and
    /// passed to `step` as `fastConfirmEnabled` — same pattern as `confirmDoseAdequate`. (AAPS 1245d33a9a)
    public static func fastConfirmAllowed(_ fastCarbConfirmEnabled: Bool, recentLowBg: Double) -> Bool {
        fastCarbConfirmEnabled && recentLowBg >= MealHypothesisConstants.fastConfirmMinRecentLowMgdl
    }

    /// OBSERVING → CONFIRMED eligibility EXCLUDING the dose-adequacy gate — the exact
    /// sub-conditions `step`'s OBSERVING branch checks (age gate incl. the 2026-07-03
    /// sustained-score early path, peak score, peak eventualBG offset, single-confirm-per-session
    /// lock), minus `confirmDoseAdequate`. `step` calls this SAME function for its dosing
    /// decision, so any caller-side use (e.g. gate diagnostics) can never diverge from what the
    /// state machine doses with. (AAPS 242a6e179d / 6067ec9a6d.)
    public static func confirmEligibleExceptDoseGate(
        current: MealHypothesisState,
        score: Double,
        eventualBg: Double,
        targetBg: Double,
        scoreReadyStreak: Bool = false
    ) -> Bool {
        let C = MealHypothesisConstants.self
        if current.state != .observing || current.committedInSession { return false }
        let newMaxScore = max(current.maxScoreInObserving, score)
        let newMaxOffset = max(current.maxEventualBgOffsetInObserving, eventualBg - targetBg)
        let age = current.ageCycles
        // 2026-07-03: age gate opens one cycle early when the score has been ≥ confirmScore on
        // BOTH this cycle and the previous one (see confirmMinObservingAgeScoreReady). The early
        // path checks the CURRENT score, not the tracked max — a sustained-ready score, not a
        // transient peak, is what justifies shaving the hysteresis.
        let ageEligible = age >= C.confirmMinObservingAge ||
            (age >= C.confirmMinObservingAgeScoreReady && score >= C.confirmScore && scoreReadyStreak)
        return ageEligible && newMaxScore >= C.confirmScore && newMaxOffset >= C.confirmEventualBgOffsetMgdl
    }

    /// Single-step transition. Pure; caller threads state across cycles.
    public static func step(
        current: MealHypothesisState,
        score: Double,
        eventualBg: Double,
        targetBg: Double,
        delta: Double,
        deltaAccl: Double,
        deltaDeclining: Bool,
        asleep: Bool = false,
        exerciseActive: Bool = false,
        fastConfirmEnabled: Bool = false,
        // 2026-07-02: OBSERVING→CONFIRMED dose-adequacy gate. Caller sets it true when the prospective
        // commit-shot (budget × CONFIRMED mult) exceeds one routine COMMITTED hold (committedCapU,
        // clamped < confirmedCapU). Defaults true so the fast-carb path and existing callers/tests are
        // unaffected.
        confirmDoseAdequate: Bool = true,
        // 2026-07-03 (AAPS 242a6e179d): sustained-score early confirm. True when the PREVIOUS
        // cycle's score was already ≥ confirmScore — computed by the caller from last cycle's
        // score (cross-cycle input, same pattern as deltaDeclining). With the CURRENT score also
        // ≥ confirmScore, the age gate opens one cycle early (confirmMinObservingAgeScoreReady).
        // Defaults false = legacy timing for all existing callers/tests.
        scoreReadyStreak: Bool = false
    ) -> MealHypothesisState {
        let C = MealHypothesisConstants.self
        let state = current.state
        let age = current.ageCycles
        let maxScore = current.maxScoreInObserving
        let maxOffset = current.maxEventualBgOffsetInObserving
        let committedInSession = current.committedInSession
        let currentOffset = eventualBg - targetBg

        // 2026-06-16 corroborated fast-carb fast-path.
        let fastConfirm = fastConfirmEnabled && !asleep && !exerciseActive &&
            delta >= C.fastConfirmDelta && deltaAccl >= C.fastConfirmAccl && score >= C.fastConfirmScore

        switch state {
        case .idle:
            if fastConfirm {
                return MealHypothesisState(state: .confirmed, ageCycles: 0, committedInSession: true)
            } else if score >= C.enterObservingScore {
                return MealHypothesisState(
                    state: .observing,
                    ageCycles: 0,
                    maxScoreInObserving: score,
                    maxEventualBgOffsetInObserving: currentOffset,
                    committedInSession: false
                )
            } else {
                return MealHypothesisState(state: state, ageCycles: age + 1)
            }

        case .observing:
            let newMaxScore = max(maxScore, score)
            let newMaxOffset = max(maxOffset, currentOffset)
            // Eligibility sub-conditions (age gate incl. the 2026-07-03 sustained-score early
            // path, peak score, peak offset, session lock) live in confirmEligibleExceptDoseGate —
            // the single shared predicate, so a caller-side eligibility read can never diverge
            // from the dosing decision. (AAPS 242a6e179d.)
            let confirmEligible = confirmEligibleExceptDoseGate(
                current: current, score: score, eventualBg: eventualBg, targetBg: targetBg,
                scoreReadyStreak: scoreReadyStreak
            ) && confirmDoseAdequate // 2026-07-02: don't spend the token on a shot < one COMMITTED hold
            if fastConfirm, !committedInSession {
                return MealHypothesisState(state: .confirmed, ageCycles: 0, committedInSession: true)
            } else if confirmEligible {
                return MealHypothesisState(state: .confirmed, ageCycles: 0, committedInSession: true)
            } else if score < C.fallBackToIdleScore, age >= C.fallBackToIdleAge {
                return MealHypothesisState(state: .idle, ageCycles: 0)
            } else {
                return MealHypothesisState(
                    state: state,
                    ageCycles: age + 1,
                    maxScoreInObserving: newMaxScore,
                    maxEventualBgOffsetInObserving: newMaxOffset,
                    committedInSession: committedInSession
                )
            }

        case .confirmed:
            if age >= C.confirmedToCommittedAge {
                return MealHypothesisState(state: .committed, ageCycles: 0, committedInSession: true)
            } else {
                return MealHypothesisState(state: state, ageCycles: age + 1, committedInSession: true)
            }

        case .committed:
            let backOff = deltaAccl < C.recoveringDecelThreshold && deltaDeclining
            if backOff {
                return MealHypothesisState(state: .recovering, ageCycles: 0, committedInSession: true)
            } else {
                return MealHypothesisState(state: state, ageCycles: age + 1, committedInSession: true)
            }

        case .recovering:
            let reEngage = age >= C.recoveringReengageMinAge &&
                deltaAccl > C.recoveringReengageAccl &&
                delta > C.recoveringReengageDelta &&
                currentOffset > C.recoveringReengageOffsetMgdl
            if reEngage {
                return MealHypothesisState(state: .committed, ageCycles: 0, committedInSession: true)
            } else if delta < 0 || score < C.recoveringToIdleScore {
                return MealHypothesisState(state: .idle, ageCycles: 0)
            } else {
                return MealHypothesisState(state: state, ageCycles: age + 1, committedInSession: true)
            }
        }
    }

    /// Force idle on conditions where prior state must not carry over. Returns (state, didReset).
    public static func resetIfNeeded(
        current: MealHypothesisState,
        profileSwitched: Bool = false,
        pumpDisconnected: Bool = false,
        loopSuspended: Bool = false,
        timeJumpMinutes: Double = 0.0
    ) -> (MealHypothesisState, Bool) {
        if profileSwitched || pumpDisconnected || loopSuspended ||
            timeJumpMinutes > MealHypothesisConstants.timeJumpResetMinutes
        {
            return (MealHypothesisState(state: .idle), true)
        }
        return (current, false)
    }

    /// Whether delta has declined monotonically over the last `windowCycles` cycles.
    public static func deltaDeclining(_ deltaHistory: [Double], windowCycles: Int = 2) -> Bool {
        guard deltaHistory.count >= windowCycles + 1 else { return false }
        let tail = Array(deltaHistory.suffix(windowCycles + 1))
        for i in 0 ..< (tail.count - 1) where tail[i] <= tail[i + 1] { return false }
        return true
    }
}
