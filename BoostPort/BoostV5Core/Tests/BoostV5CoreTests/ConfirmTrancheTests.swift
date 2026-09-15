@testable import BoostV5Core
import XCTest

/// Confirm tranche (AAPS 2026-08-27): part of the commit shot now, the rest ten minutes later if
/// the rise continues.
final class ConfirmTrancheTests: XCTestCase {
    private let t0: Double = 1_700_000_000_000
    private func mins(_ m: Double) -> Double { t0 + m * 60000 }

    func testTheConfirmDeliversTheFractionAndHoldsTheRest() {
        let c = ConfirmTranche(immediateFraction: 0.5)
        XCTAssertEqual(c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0), 1.0, accuracy: 1E-12)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12)
    }

    func testAContinuingRiseReleasesTheRemainder() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.3)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        // Ten minutes on and still climbing hard.
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: 185), 1.0, accuracy: 1E-12)
        XCTAssertEqual(c.heldU, 0)
    }

    func testAnExcursionThatGoesNowhereKeepsTheRemainderWithheld() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.9)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: 151), 0)
        XCTAssertEqual(c.heldU, 0, "the hold is resolved on its cycle either way")
    }

    func testNothingIsReleasedBeforeTheHoldWindow() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.0)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(5), bg: 180), 0)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12, "still pending")
    }

    func testTheSlackAllowsACycleThatLandsJustShortOfTheBoundary() {
        // The reported case: a confirm at 14:52:11 followed by a cycle at 15:02:10, which is 9.991
        // minutes. An exact comparison deferred the decision by a whole cycle, and with five-minute
        // cycles that misses roughly half the time.
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.3)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertGreaterThan(c.onCycle(nowMs: mins(9.991), bg: 185), 0)
    }

    func testAnExpiredHoldIsDroppedRatherThanCarried() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.0)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(31), bg: 200), 0)
        XCTAssertEqual(c.heldU, 0)
    }

    func testANewConfirmReplacesAnOlderHold() {
        let c = ConfirmTranche(immediateFraction: 0.5)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        _ = c.onConfirm(nowMs: mins(5), bg: 170, sizedDose: 1.0)
        XCTAssertEqual(c.heldU, 0.5, accuracy: 1E-12)
    }

    func testItCanOnlyEverDeliverLessThanTheEngineWould() {
        // The bounding property, across thresholds and outcomes: the sum of what is delivered at the
        // confirm and what is later released can never exceed the sized dose.
        for threshold in stride(from: 0.0, through: 1.0, by: 0.1) {
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                for endBg in [140.0, 150.0, 160.0, 200.0, 260.0] {
                    let c = ConfirmTranche(immediateFraction: fraction, releaseThreshold: threshold)
                    let sized = 2.0
                    let now = c.onConfirm(nowMs: t0, bg: 150, sizedDose: sized)
                    let later = c.onCycle(nowMs: mins(10), bg: endBg)
                    XCTAssertLessThanOrEqual(now + later, sized + 1E-9)
                    XCTAssertGreaterThanOrEqual(now + later, 0)
                }
            }
        }
    }

    func testAZeroOrNonFiniteDoseIsPassedThroughUntouched() {
        let c = ConfirmTranche()
        XCTAssertEqual(c.onConfirm(nowMs: t0, bg: 150, sizedDose: 0), 0)
        XCTAssertEqual(c.heldU, 0)
        XCTAssertEqual(c.onConfirm(nowMs: t0, bg: .nan, sizedDose: 1.5), 1.5, accuracy: 1E-12)
    }

    func testAMissingGlucoseReadingDoesNotReleaseOrDropTheHold() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.0)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: nil), 0)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12, "still pending, to be decided on a cycle with data")
    }

    func testResetDropsTheHold() {
        let c = ConfirmTranche(immediateFraction: 0.5)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        c.reset()
        XCTAssertEqual(c.heldU, 0)
        XCTAssertEqual(c.onCycle(nowMs: mins(10), bg: 200), 0)
    }

    func testARaisedThresholdWithholdsMore() {
        func delivered(threshold: Double) -> Double {
            let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: threshold)
            let now = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
            return now + c.onCycle(nowMs: mins(10), bg: 168)
        }
        XCTAssertGreaterThanOrEqual(delivered(threshold: 0.30), delivered(threshold: 0.95))
    }

    func testProbeReportsWithoutActing() {
        let c = ConfirmTranche(immediateFraction: 0.5, releaseThreshold: 0.3)
        _ = c.onConfirm(nowMs: t0, bg: 150, sizedDose: 2.0)
        let p = c.probeProbability(bg: 185)
        XCTAssertNotNil(p)
        XCTAssertGreaterThan(p!, 0)
        XCTAssertLessThan(p!, 1)
        XCTAssertEqual(c.heldU, 1.0, accuracy: 1E-12, "probing must not resolve the hold")
        XCTAssertNil(ConfirmTranche().probeProbability(bg: 185), "nothing pending")
    }
}
