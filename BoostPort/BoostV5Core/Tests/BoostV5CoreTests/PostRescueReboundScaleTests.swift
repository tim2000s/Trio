@testable import BoostV5Core
import XCTest

/// Graduated post-rescue rebound scale (AAPS `PostRescueReboundScaleTest`, 2026-07-23).
///
/// The curve is 0.3 below 120 mg/dL, linear to 1.0 at 170, and 1.0 above. AAPS applies it to the
/// final microbolus of its V1 tier engine whenever the 45-minute post-rescue window is active,
/// carbs on board are zero and glucose is below 170. Trio has no V1 tier engine, so the curve is
/// defined here and not yet consumed.
final class PostRescueReboundScaleTests: XCTestCase {
    private func scale(_ bg: Double) -> Double {
        SafetyGateConstants.postRescueReboundScale(bg: bg)
    }

    func testFloorBelow120() {
        XCTAssertEqual(scale(80), 0.3, accuracy: 1E-12)
        XCTAssertEqual(scale(97), 0.3, accuracy: 1E-12) // the reported incident's glucose
        XCTAssertEqual(scale(119.99), 0.3, accuracy: 1E-12)
    }

    func testLinearBetween120And170() {
        XCTAssertEqual(scale(120), 0.3, accuracy: 1E-12)
        XCTAssertEqual(scale(145), 0.65, accuracy: 1E-12) // midpoint
        XCTAssertEqual(scale(169.99), 1.0, accuracy: 0.001)
    }

    func testNoSuppressionAtOrAbove170() {
        XCTAssertEqual(scale(170), 1.0, accuracy: 1E-12)
        XCTAssertEqual(scale(250), 1.0, accuracy: 1E-12)
    }

    func testCurveIsMonotonicAndBounded() {
        var previous = 0.0
        for bg in stride(from: 40.0, through: 400.0, by: 1.0) {
            let s = scale(bg)
            XCTAssertGreaterThanOrEqual(s, previous - 1E-12)
            XCTAssertGreaterThanOrEqual(s, 0.3)
            XCTAssertLessThanOrEqual(s, 1.0)
            previous = s
        }
    }

    func testIncidentMagnitude() {
        // The reported incident delivered 3.55 U at 97 mg/dL, 25 minutes after a low of 67.
        // At that glucose the scale is the floor, so the dose would have been about a third.
        XCTAssertEqual(3.55 * scale(97), 1.065, accuracy: 0.001)
    }
}
