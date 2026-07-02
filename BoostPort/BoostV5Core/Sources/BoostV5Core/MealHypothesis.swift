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
    public static let fastConfirmDelta = 8.0
    public static let fastConfirmAccl = 15.0
    public static let fastConfirmScore = 0.60
    public static let timeJumpResetMinutes = 30.0
}

public enum MealHypothesisEngine {
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
        confirmDoseAdequate: Bool = true
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
            let confirmEligible = age >= C.confirmMinObservingAge &&
                newMaxScore >= C.confirmScore &&
                newMaxOffset >= C.confirmEventualBgOffsetMgdl &&
                confirmDoseAdequate && // 2026-07-02: don't spend the token on a shot < one COMMITTED hold
                !committedInSession
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
