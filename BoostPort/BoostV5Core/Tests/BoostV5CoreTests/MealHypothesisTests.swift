@testable import BoostV5Core
import XCTest

final class MealHypothesisTests: XCTestCase {
    typealias E = MealHypothesisEngine
    private func obs(age: Int = 0, committed: Bool = false) -> MealHypothesisState {
        MealHypothesisState(
            state: .observing,
            ageCycles: age,
            maxScoreInObserving: 0.5,
            maxEventualBgOffsetInObserving: 10.0,
            committedInSession: committed
        )
    }

    private func idle() -> MealHypothesisState { MealHypothesisState() }

    // strong fast-carb signals
    let D = 12.0, A = 30.0, S = 0.7

    func testFastConfirmFromObservingOneCycle() {
        let r = E.step(
            current: obs(age: 0),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            asleep: false,
            exerciseActive: false,
            fastConfirmEnabled: true
        )
        XCTAssertEqual(r.state, .confirmed)
        XCTAssertTrue(r.committedInSession)
    }

    func testFastConfirmStraightFromIdle() {
        let r = E.step(
            current: idle(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertEqual(r.state, .confirmed)
    }

    func testNoFireWhileAsleep() {
        let r = E.step(
            current: obs(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            asleep: true,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testNoFireWhileExercising() {
        let r = E.step(
            current: obs(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            exerciseActive: true,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testNoFireWhenScoreLow() {
        let r = E.step(
            current: obs(),
            score: 0.45,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testNoFireSlowRise() {
        let r = E.step(
            current: obs(),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: 4.0,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testFix6SingleConfirmGuard() {
        let r = E.step(
            current: obs(age: 1, committed: true),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: true
        )
        XCTAssertNotEqual(r.state, .confirmed)
    }

    func testDisabledToggleYoungObservingStays() {
        let r = E.step(
            current: obs(age: 0),
            score: S,
            eventualBg: 150,
            targetBg: 100,
            delta: D,
            deltaAccl: A,
            deltaDeclining: false,
            fastConfirmEnabled: false
        )
        XCTAssertEqual(r.state, .observing)
    }

    // normal-path transitions
    func testIdleEntersObservingOnScore() {
        let r = E.step(
            current: idle(),
            score: 0.5,
            eventualBg: 150,
            targetBg: 100,
            delta: 5,
            deltaAccl: 5,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .observing)
    }

    func testObservingConfirmsOnAgePlusPeaks() {
        // age 2, score>=0.55, offset (eventualBg-target=50)>=30, not committed → CONFIRMED
        let s = MealHypothesisState(
            state: .observing,
            ageCycles: 2,
            maxScoreInObserving: 0.6,
            maxEventualBgOffsetInObserving: 50.0
        )
        let r = E.step(
            current: s,
            score: 0.6,
            eventualBg: 150,
            targetBg: 100,
            delta: 5,
            deltaAccl: 5,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .confirmed)
        XCTAssertTrue(r.committedInSession)
    }

    func testConfirmedToCommitted() {
        let r = E.step(
            current: MealHypothesisState(state: .confirmed, ageCycles: 0, committedInSession: true),
            score: 0.6,
            eventualBg: 150,
            targetBg: 100,
            delta: 5,
            deltaAccl: 5,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .committed)
    }

    func testCommittedBacksOffToRecovering() {
        let r = E.step(
            current: MealHypothesisState(state: .committed, ageCycles: 1, committedInSession: true),
            score: 0.4,
            eventualBg: 150,
            targetBg: 100,
            delta: -2,
            deltaAccl: -10,
            deltaDeclining: true
        )
        XCTAssertEqual(r.state, .recovering)
    }

    func testRecoveringReengagesOnSecondRise() {
        let s = MealHypothesisState(state: .recovering, ageCycles: 1, committedInSession: true)
        let r = E.step(
            current: s,
            score: 0.5,
            eventualBg: 160,
            targetBg: 100,
            delta: 5,
            deltaAccl: 15,
            deltaDeclining: false
        )
        XCTAssertEqual(r.state, .committed)
    }

    func testRecoveringExitsToIdleOnFall() {
        let s = MealHypothesisState(state: .recovering, ageCycles: 2, committedInSession: true)
        let r = E.step(
            current: s,
            score: 0.1,
            eventualBg: 90,
            targetBg: 100,
            delta: -3,
            deltaAccl: -2,
            deltaDeclining: true
        )
        XCTAssertEqual(r.state, .idle)
        XCTAssertFalse(r.committedInSession)
    }

    func testResetIfNeeded() {
        let (s, did) = E.resetIfNeeded(current: obs(), pumpDisconnected: true)
        XCTAssertTrue(did)
        XCTAssertEqual(s.state, .idle)
    }

    func testDeltaDeclining() {
        XCTAssertTrue(E.deltaDeclining([10, 6, 3]))
        XCTAssertFalse(E.deltaDeclining([3, 6, 10]))
        XCTAssertFalse(E.deltaDeclining([5, 5]))
    }
}
