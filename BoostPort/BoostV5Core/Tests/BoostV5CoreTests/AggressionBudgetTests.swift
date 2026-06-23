@testable import BoostV5Core
import XCTest

final class AggressionBudgetTests: XCTestCase {
    typealias B = AggressionBudgetEngine

    func testNoRiskNoModifierIsBaseReq() {
        let r = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.1, inPostExerciseWindow: false)
        XCTAssertEqual(r.budget, 1.0, accuracy: 1E-9)
        XCTAssertEqual(r.mlHypoRiskScale, 1.0, accuracy: 1E-9)
    }

    func testHardFloorAt30Percent() {
        // high risk + high caution knob drives mlScale to its 0.25 floor (raw 0.25 < 0.30) → 30% floor binds.
        let r = B.aggressionBudget(baseInsulinReq: 2.0, mlHypoRisk: 1.0, inPostExerciseWindow: false, hypoCautionUserKnob: 2.0)
        XCTAssertEqual(r.budget, 0.30 * 2.0, accuracy: 1E-9)
    }

    func testMlScaleFloorsAtHalfWithDefaultKnob() {
        // risk 1.0, knob 1.0 → mlScale floors at 0.50 (not 0); raw 1.0 beats the 0.6 floor.
        let r = B.aggressionBudget(baseInsulinReq: 2.0, mlHypoRisk: 1.0, inPostExerciseWindow: false)
        XCTAssertEqual(r.mlHypoRiskScale, 0.50, accuracy: 1E-9)
        XCTAssertEqual(r.budget, 1.0, accuracy: 1E-9)
    }

    func testHypoCautionHigherKnobGivesLessInsulin() {
        // The 2026-06-15 direction fix: raising Hypo Caution must REDUCE the scale at a mid risk.
        let lo = B.mlHypoRiskScale(0.6, hypoCautionKnob: 1.0)
        let hi = B.mlHypoRiskScale(0.6, hypoCautionKnob: 2.0)
        XCTAssertLessThan(hi, lo)
    }

    func testPostExerciseHalvesBeforeFloor() {
        let r = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.0, inPostExerciseWindow: true)
        // 1.0 * 1.0(ml) * 0.5(postEx) * 1.0(sens) = 0.5, above the 0.30 floor
        XCTAssertEqual(r.budget, 0.5, accuracy: 1E-9)
    }

    func testSensitivityKnobBounded() {
        let hi = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.0, inPostExerciseWindow: false, sensitivityUserKnob: 5.0)
        XCTAssertEqual(hi.budget, 1.2, accuracy: 1E-9) // clamped to 1.2
        let lo = B.aggressionBudget(baseInsulinReq: 1.0, mlHypoRisk: 0.0, inPostExerciseWindow: false, sensitivityUserKnob: 0.1)
        XCTAssertEqual(lo.budget, 0.8, accuracy: 1E-9) // clamped to 0.8
    }

    func testNilRiskIsNeutral() {
        XCTAssertEqual(B.mlHypoRiskScale(nil), 1.0, accuracy: 1E-9)
    }
}
