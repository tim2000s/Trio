@testable import BoostV5Core
import XCTest

/// Tests for the V5 auto-config calculator (Swift port). Conservative, transparent derivation of V5
/// knobs from a user's last-N-day prior dosing history (oref or Boost-V1). Pure-function tests.
final class BoostV5AutoConfigTests: XCTestCase {
    private func prior(
        days: Int = 14, bg: Int = 3500, tdd: Double = 40,
        manual: [Double] = [3, 4, 5, 6], smb: [Double] = [0.2, 0.3, 0.4, 0.6, 0.8],
        tbr70: Double = 3, sev54: Double = 0.4, meanBg: Double = 130,
        maxIob: Double = 8, maxBolus: Double = 10
    ) -> BoostV5AutoConfig.PriorDosing {
        BoostV5AutoConfig.PriorDosing(
            daysWithData: days, bgReadingCount: bg, tddMedianU: tdd,
            manualBolusesU: manual, smbAmountsU: smb,
            tbrBelow70Pct: tbr70, timeBelow54Pct: sev54, meanGlucoseMgdl: meanBg,
            currentMaxIobU: maxIob, currentMaxBolusU: maxBolus
        )
    }

    func testInsufficientDaysReturnsNil() {
        XCTAssertNil(BoostV5AutoConfig.compute(prior(days: 5)))
    }

    func testInsufficientBgReturnsNil() {
        XCTAssertNil(BoostV5AutoConfig.compute(prior(bg: 800)))
    }

    func testInTargetUserNeutral() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 2.5, sev54: 0.2))!
        XCTAssertEqual(s.aggression, 1.0)
        XCTAssertEqual(s.hypoCaution, 1.0)
        XCTAssertTrue(s.fastCarbConfirm)
    }

    func testHypoProneGetsGentlerAndCautious() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 8, sev54: 2.5))!
        XCTAssertEqual(s.aggression, 0.85)
        XCTAssertGreaterThan(s.hypoCaution, 1.0)
        XCTAssertFalse(s.fastCarbConfirm)
    }

    func testAggressionNeverRaisedAboveNeutral() {
        let s = BoostV5AutoConfig.compute(prior(tbr70: 0.5, sev54: 0.0))!
        XCTAssertLessThanOrEqual(s.aggression, 1.0)
    }

    func testCapsClampToRanges() {
        let s = BoostV5AutoConfig.compute(prior(manual: [2, 3, 4, 5], smb: [0.3, 0.5, 0.7]))!
        XCTAssertGreaterThanOrEqual(s.confirmedCapU, 1.5)
        XCTAssertLessThanOrEqual(s.confirmedCapU, 7.5)
        XCTAssertGreaterThanOrEqual(s.committedCapU, 0.25)
        XCTAssertLessThanOrEqual(s.committedCapU, 2.5)
        XCTAssertGreaterThanOrEqual(s.cumulativeSmbCap60MinU, 1.0)
        XCTAssertLessThanOrEqual(s.cumulativeSmbCap60MinU, 5.0)
        XCTAssertGreaterThanOrEqual(s.cumulativeSmbCap60MinU, s.confirmedCapU - 1E-9)
    }

    func testConfirmedCapCoversBigMealUser() {
        let big = BoostV5AutoConfig.compute(prior(manual: [5, 7, 9, 11]))!
        let small = BoostV5AutoConfig.compute(prior(manual: [1, 1.5, 2]))!
        XCTAssertGreaterThan(big.confirmedCapU, small.confirmedCapU)
    }

    func testCumulativeCapNeverBelowConfirmedForBigMealUser() {
        // Big eater: confirmedCap clamps to its 7.5 ceiling. The hourly cumulative budget must not
        // saturate below that (was clamped to 5.0 before the 2026-06-26 fix).
        let s = BoostV5AutoConfig.compute(prior(manual: [5, 7, 9, 11]))!
        XCTAssertEqual(s.confirmedCapU, 7.5)
        XCTAssertGreaterThanOrEqual(s.cumulativeSmbCap60MinU, s.confirmedCapU - 1E-9)
    }

    func testMaxIobAndBolusCarriedAndClamped() {
        let s = BoostV5AutoConfig.compute(prior(maxIob: 15, maxBolus: 12))!
        XCTAssertEqual(s.maxIobU, 12.0)
        XCTAssertEqual(s.bolusCapU, 10.0)
    }

    func testPercentileInterpolates() {
        let v = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(BoostV5AutoConfig.percentile(v, 0), 1.0)
        XCTAssertEqual(BoostV5AutoConfig.percentile(v, 100), 4.0)
        XCTAssertEqual(BoostV5AutoConfig.percentile(v, 50), 2.5, accuracy: 1E-9)
        XCTAssertEqual(BoostV5AutoConfig.percentile([], 90), 0.0)
    }

    func testRationaleExplainsSettings() {
        let s = BoostV5AutoConfig.compute(prior())!
        XCTAssertFalse(s.rationale.isEmpty)
        XCTAssertTrue(s.rationale.contains { $0.contains("HypoCaution") })
        XCTAssertTrue(s.rationale.contains { $0.contains("Aggression") })
    }
}
