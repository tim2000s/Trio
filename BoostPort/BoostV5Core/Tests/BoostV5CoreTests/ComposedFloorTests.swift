@testable import BoostV5Core
import XCTest

/// 2026-07-06/07 composed Phase-3 brake floor (AAPS e0f18ddd0e + 730b3dcb2c).
///
/// `ComposedFloor.targetDose` is the single source of truth for BOTH the shadow field (toggle OFF:
/// `floorWouldAdd = max(0, target − pipeline)`) and the delivered floor (toggle ON: `finalDose =
/// max(pipeline, clamped-and-rounded target)`). These tests lock the target's conditions/bounds and
/// the decide() shadow-vs-active integration. Mirrors the AAPS ComposedFloorShadowTest.
final class ComposedFloorTests: XCTestCase {
    // MARK: targetDose — conditions & bounds

    /// Baseline qualifying call: CONFIRMED, bg 270 > 160, eventualBg 200 > target+20, awake, not
    /// post-rescue, budget 0.5 > 0, no hard gate. Floor = min(0.5 × 0.25, committedCap 0.5) = 0.125.
    private func target(
        state: MealHypothesis = .confirmed, bg: Double = 270, eventualBg: Double = 200,
        targetBg: Double = 100, asleep: Bool = false, postRescueWindow: Bool = false,
        budgetU: Double = 0.5, committedCapU: Double = 0.5, v1WouldDoseU: Double? = nil,
        hardGateFired: Bool = false
    ) -> Double? {
        ComposedFloor.targetDose(
            state: state, bg: bg, eventualBg: eventualBg, targetBg: targetBg, asleep: asleep,
            postRescueWindow: postRescueWindow, budgetU: budgetU, committedCapU: committedCapU,
            v1WouldDoseU: v1WouldDoseU, hardGateFired: hardGateFired
        )
    }

    func testQualifyingCycleReturnsBudgetFractionCappedAtCommitted() {
        // min(0.5 × 0.25, 0.5) = 0.125 (budget fraction binds).
        XCTAssertEqual(target()!, 0.125, accuracy: 1E-12)
    }

    func testCommittedCapBoundsTheFlooredDose() {
        // Big budget: min(4.0 × 0.25 = 1.0, committedCap 0.5) = 0.5 (cap binds).
        XCTAssertEqual(target(budgetU: 4.0, committedCapU: 0.5)!, 0.5, accuracy: 1E-12)
    }

    func testEachConditionIndividuallyNullsTheFloor() {
        XCTAssertNil(target(state: .idle)) // not a meal session
        XCTAssertNil(target(state: .observing)) // OBSERVING is not a meal session
        XCTAssertNil(target(bg: 160)) // bg must be strictly > 160
        XCTAssertNil(target(eventualBg: 120)) // eventualBg must be > target+20 (=120)
        XCTAssertNil(target(asleep: true)) // asleep suppresses
        XCTAssertNil(target(postRescueWindow: true)) // post-rescue suppresses
        XCTAssertNil(target(budgetU: 0.0)) // budget>0 — Episode-A guard by construction
    }

    func testFiredHardGateReturnsZeroNotNil() {
        // A hard gate zeroes the dose regardless of any multiplier floor → the floor adds nothing.
        XCTAssertEqual(target(hardGateFired: true), 0.0)
    }

    func testMealSessionStatesAllQualify() {
        for s in [MealHypothesis.confirmed, .committed, .recovering] {
            XCTAssertNotNil(target(state: s), "\(s) should qualify")
        }
    }

    func testRecoveringIsBoundedByV1WouldDose() {
        // RECOVERING is a non-meal state at the override seam (capped at V1's would-dose). Floor
        // would be 0.125, but v1WouldDose 0.05 binds it lower.
        XCTAssertEqual(target(state: .recovering, v1WouldDoseU: 0.05)!, 0.05, accuracy: 1E-12)
        // No v1 bound available → unbounded floor.
        XCTAssertEqual(target(state: .recovering, v1WouldDoseU: nil)!, 0.125, accuracy: 1E-12)
        // v1 bound above the floor → floor unchanged.
        XCTAssertEqual(target(state: .recovering, v1WouldDoseU: 1.0)!, 0.125, accuracy: 1E-12)
    }

    // MARK: decide() — shadow vs active integration

    /// COMMITTED, floor conditions met, decelerating + low velocity so the composed pipeline dose is
    /// driven below the floor while maxIOB headroom stays large (so the floor isn't headroom-clamped).
    private func flooredInputs(composedFloorActive: Bool) -> V5Inputs {
        V5Inputs(
            delta: 1, shortAvgDelta: 1, deltaAccl: -8, bg: 270, eventualBg: 200, targetBg: 100,
            maxDelta: 1, minGuardBg: 200, minGuardThreshold: 80, deltaHistory: [8, 5, 1],
            iob: 0.3, maxIob: 6, baseInsulinReq: 0.8, roundSmbTo: 0.05, enableSmbPreChecks: true,
            mlHypoRisk: nil, mlMealLikely: 0.5, recentLowBg: 200, cumulativeRise30min: 3, hour: 13,
            exerciseActive: false, inPostExerciseWindow: false, asleep: false,
            postRescueWindow: false, v1WouldDoseU: 2.0, composedFloorActive: composedFloorActive
        )
    }

    private func committed() -> MealHypothesisState {
        MealHypothesisState(state: .committed, committedInSession: true)
    }

    func testShadowLeavesDeliveredDoseUntouchedButReportsWouldAdd() {
        let d = BoostV5Engine.decide(
            flooredInputs(composedFloorActive: false),
            persisted: V5PersistedState(mealHypothesis: committed())
        )
        // The decelerating trace settles in a meal-session state (COMMITTED→RECOVERING) — either
        // qualifies for the floor; both drive the pipeline dose low.
        XCTAssertTrue([.committed, .recovering].contains(d.mealHypothesis))
        // The pipeline drove the dose below the floor — this is the defect the floor targets.
        // v1WouldDose (2.0) is well above the floor, so the RECOVERING v1-bound never binds here.
        let floor = min(d.aggressionBudget.budget * ComposedFloor.fraction, 0.5)
        XCTAssertLessThan(d.finalDose, floor, "precondition: pipeline below the floor")
        // Shadow: delivered dose unchanged; floorWouldAdd = target − pipeline (> 0).
        XCTAssertEqual(d.finalDose, d.phase3.finalDose, accuracy: 1E-12)
        XCTAssertNotNil(d.floorWouldAdd)
        XCTAssertEqual(d.floorWouldAdd!, floor - d.phase3.finalDose, accuracy: 1E-9)
    }

    func testActiveRaisesDeliveredDoseToTheRoundedFloor() {
        let shadow = BoostV5Engine.decide(
            flooredInputs(composedFloorActive: false),
            persisted: V5PersistedState(mealHypothesis: committed())
        )
        let active = BoostV5Engine.decide(
            flooredInputs(composedFloorActive: true),
            persisted: V5PersistedState(mealHypothesis: committed())
        )
        // The delivered dose is lifted to the pump-rounded floor and strictly exceeds the shadow's.
        XCTAssertGreaterThan(active.finalDose, shadow.finalDose)
        let floor = min(shadow.aggressionBudget.budget * ComposedFloor.fraction, 0.5)
        let roundedFloor = (floor / 0.05).rounded(.down) * 0.05
        XCTAssertEqual(active.finalDose, roundedFloor, accuracy: 1E-9)
        XCTAssertEqual(active.floorWouldAdd!, active.finalDose - shadow.finalDose, accuracy: 1E-9)
    }

    func testTogglePreservesDeliveredDoseWhenPipelineAlreadyMeetsFloor() {
        // A strong meal cycle whose pipeline dose already exceeds the floor: activation is a no-op
        // for the delivered dose (uplift 0.0), so the toggle is bit-identical here.
        func strong(_ active: Bool) -> V5Inputs {
            V5Inputs(
                delta: 10, shortAvgDelta: 10, deltaAccl: 12, bg: 270, eventualBg: 220, targetBg: 100,
                maxDelta: 10, minGuardBg: 220, minGuardThreshold: 80, deltaHistory: [4, 7, 10],
                iob: 0.3, maxIob: 6, baseInsulinReq: 2.0, roundSmbTo: 0.05, enableSmbPreChecks: true,
                mlHypoRisk: nil, mlMealLikely: 0.7, recentLowBg: 200, cumulativeRise30min: 60, hour: 13,
                exerciseActive: false, inPostExerciseWindow: false, asleep: false,
                postRescueWindow: false, v1WouldDoseU: 2.0, composedFloorActive: active
            )
        }
        let off = BoostV5Engine.decide(strong(false), persisted: V5PersistedState(mealHypothesis: committed()))
        let on = BoostV5Engine.decide(strong(true), persisted: V5PersistedState(mealHypothesis: committed()))
        XCTAssertEqual(off.finalDose, on.finalDose, accuracy: 1E-12)
        XCTAssertEqual(on.floorWouldAdd ?? 0, 0.0, accuracy: 1E-9) // uplift 0 — pipeline already above floor
    }

    func testActiveDeliversZeroWhenBudgetZeroEvenIfConditionsElseMet() {
        // budget>0 is a floor condition, so a zero-budget cycle can never be floored (Episode-A guard).
        var i = flooredInputs(composedFloorActive: true)
        i.baseInsulinReq = 0.0 // → budget 0
        let d = BoostV5Engine.decide(i, persisted: V5PersistedState(mealHypothesis: committed()))
        XCTAssertEqual(d.finalDose, 0.0)
        XCTAssertNil(d.floorWouldAdd)
    }
}
