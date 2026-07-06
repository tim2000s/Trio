@testable import BoostV5Core
import XCTest

/// 2026-07-03 — sustained-score early confirm (`confirmMinObservingAgeScoreReady`, AAPS 242a6e179d).
///
/// OBSERVING → CONFIRMED may fire ONE cycle before the standard age gate when the instantaneous
/// score has been ≥ confirmScore on BOTH the current and the immediately preceding cycle
/// (`scoreReadyStreak` — computed by the caller from last cycle's score, cross-cycle-input pattern
/// shared with `deltaDeclining`). Replay-validated 2026-07-03: 53% of confirm latency was
/// mechanical (score ready ≥2 cycles pre-confirm); shifting the same shot 1 cycle earlier measured
/// 0.0pp additional pre-low exposure. All other confirm conditions unchanged; pure-function tests
/// on step(). Mirrors the AAPS MealHypothesisEarlyConfirmTest 1:1.
final class MealHypothesisEarlyConfirmTests: XCTestCase {
    typealias E = MealHypothesisEngine
    typealias C = MealHypothesisConstants

    // OBSERVING one cycle BEFORE the standard age gate (age = confirmMinObservingAge - 1),
    // score + eventualBG-offset peaks already satisfied.
    private func observingOneCycleEarly(committed: Bool = false) -> MealHypothesisState {
        MealHypothesisState(
            state: .observing,
            ageCycles: C.confirmMinObservingAge - 1,
            maxScoreInObserving: 0.60,
            maxEventualBgOffsetInObserving: 40.0,
            committedInSession: committed
        )
    }

    private let readyScore = 0.60 // ≥ confirmScore (0.55)
    private let eventualBg = 150.0
    private let targetBg = 100.0

    func testScoreReadyTwoConsecutiveCyclesConfirmsOneCycleEarlier() {
        let r = E.step(
            current: observingOneCycleEarly(), score: readyScore, eventualBg: eventualBg,
            targetBg: targetBg, delta: 6.0, deltaAccl: 2.0, deltaDeclining: false,
            scoreReadyStreak: true
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    func testScoreReadyOnlyOnCurrentCycleKeepsOldTiming() {
        // Same cycle, same score, but the PREVIOUS cycle wasn't ready → the early path must not
        // open; it holds in OBSERVING and confirms on the next cycle via the standard age gate.
        let held = E.step(
            current: observingOneCycleEarly(), score: readyScore, eventualBg: eventualBg,
            targetBg: targetBg, delta: 6.0, deltaAccl: 2.0, deltaDeclining: false,
            scoreReadyStreak: false
        )
        XCTAssertEqual(held.state, .observing)
        XCTAssertEqual(held.ageCycles, C.confirmMinObservingAge)

        let confirmedNextCycle = E.step(
            current: held, score: readyScore, eventualBg: eventualBg, targetBg: targetBg,
            delta: 6.0, deltaAccl: 2.0, deltaDeclining: false, scoreReadyStreak: false
        )
        XCTAssertEqual(confirmedNextCycle.state, .confirmed)
    }

    func testStreakWithCurrentScoreBelowThresholdDoesNotOpenEarlyPath() {
        // Peak-tracked max (0.60) is ready but the CURRENT score dipped below confirmScore —
        // the early path requires a sustained-ready CURRENT score, not just the tracked max.
        let r = E.step(
            current: observingOneCycleEarly(), score: 0.50, eventualBg: eventualBg,
            targetBg: targetBg, delta: 6.0, deltaAccl: 2.0, deltaDeclining: false,
            scoreReadyStreak: true
        )
        XCTAssertEqual(r.state, .observing)
    }

    func testEarlyPathStillBlockedByDoseAdequacyGate() {
        let r = E.step(
            current: observingOneCycleEarly(), score: readyScore, eventualBg: eventualBg,
            targetBg: targetBg, delta: 6.0, deltaAccl: 2.0, deltaDeclining: false,
            confirmDoseAdequate: false, scoreReadyStreak: true
        )
        XCTAssertEqual(r.state, .observing)
    }

    func testEarlyPathStillBlockedBySingleConfirmPerSessionGuard() {
        let r = E.step(
            current: observingOneCycleEarly(committed: true), score: readyScore,
            eventualBg: eventualBg, targetBg: targetBg, delta: 6.0, deltaAccl: 2.0,
            deltaDeclining: false, scoreReadyStreak: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testDefaultScoreReadyStreakFalseKeepsLegacyBehaviour() {
        let r = E.step(
            current: observingOneCycleEarly(), score: readyScore, eventualBg: eventualBg,
            targetBg: targetBg, delta: 6.0, deltaAccl: 2.0, deltaDeclining: false
        )
        XCTAssertEqual(r.state, .observing)
    }

    func testConfirmEligibleExceptDoseGateMatchesStepSemantics() {
        // The shared predicate must agree with what step() doses with, on both sides of the gate.
        XCTAssertTrue(E.confirmEligibleExceptDoseGate(
            current: observingOneCycleEarly(), score: readyScore, eventualBg: eventualBg,
            targetBg: targetBg, scoreReadyStreak: true
        ))
        XCTAssertFalse(E.confirmEligibleExceptDoseGate(
            current: observingOneCycleEarly(), score: readyScore, eventualBg: eventualBg,
            targetBg: targetBg, scoreReadyStreak: false
        ))
        XCTAssertFalse(E.confirmEligibleExceptDoseGate(
            current: observingOneCycleEarly(committed: true), score: readyScore,
            eventualBg: eventualBg, targetBg: targetBg, scoreReadyStreak: true
        ))
    }
}
