@testable import BoostV5Core
import XCTest

/// Verifies the step + HR activity classification port of AAPS Boost
/// (`HrActivityCalculator` + `OpenAPSBoostPlugin.calculateBoostActivity`).
///
/// Covered: Karvonen zone boundaries (30/40/60/80% HRR); step-only ACTIVE /
/// INACTIVE / normal; HR-fused VIGOROUS / RESISTANCE / STRESS; the resulting
/// profilePercent + targetBg per state; and the `exerciseActive` flag.
final class ActivityClassifierTests: XCTestCase {
    // Default rest=60, max=180 → reserve = 120, so HRR% = (hr - 60) / 120 * 100.
    private let rest = 60
    private let max = 180

    // MARK: - Karvonen zone boundaries

    func testKarvonenZoneBoundaries() {
        // reserve = 120. Boundary BPMs: 30% = 96, 40% = 108, 60% = 132, 80% = 156.
        // Just below boundary → lower zone; at/above boundary → next zone.
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 60, rest: rest, max: max), 1) // 0%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 95, rest: rest, max: max), 1) // <30%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 96, rest: rest, max: max), 2) // ==30%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 107, rest: rest, max: max), 2) // <40%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 108, rest: rest, max: max), 3) // ==40%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 131, rest: rest, max: max), 3) // <60%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 132, rest: rest, max: max), 4) // ==60%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 155, rest: rest, max: max), 4) // <80%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 156, rest: rest, max: max), 5) // ==80%
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 200, rest: rest, max: max), 5) // >80%
    }

    func testKarvonenZoneClampsReserveToAvoidDivideByZero() {
        // rest == max → reserve coerced to 1; any hr ABOVE rest is a huge HRR → zone 5.
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 120, rest: 100, max: 100), 5)
        // hr exactly at rest → HRR 0 → zone 1 (even with the clamp).
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 100, rest: 100, max: 100), 1)
        // At rest exactly with a real reserve, HRR = 0 → zone 1.
        XCTAssertEqual(ActivityClassifier.karvonenZone(hr: 100, rest: 100, max: 200), 1)
    }

    // MARK: - Step-only path (HR integration disabled)

    private func stepOnlyInputs(s5: Int, s15: Int, s30: Int, s60: Int) -> ActivityInputs {
        ActivityInputs(
            steps5: s5, steps15: s15, steps30: s30, steps60: s60,
            avgHeartRate: 0,
            thresholds: ActivityThresholds() // hrIntegrationEnabled defaults false
        )
    }

    func testStepOnlyActiveWhenAnyThresholdExceeded() {
        // steps15 = 900 > default 800 → ACTIVE.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 900, s30: 0, s60: 0))
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80) // activityPct default
        XCTAssertEqual(r.targetBgMgdl, 150)
        XCTAssertTrue(r.exerciseActive)
    }

    func testStepOnlyActiveViaShortWindow() {
        // steps5 = 500 > default 420 → ACTIVE even with low longer windows.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 500, s15: 0, s30: 0, s60: 0))
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80)
        XCTAssertEqual(r.targetBgMgdl, 150)
    }

    func testStepOnlyInactiveWhenBelowInactivitySteps() {
        // Not active and steps60 (100) < inactivitySteps (500) → INACTIVE.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100))
        XCTAssertEqual(r.state, .inactive)
        XCTAssertEqual(r.profilePercent, 130) // inactivityPct default
        XCTAssertNil(r.targetBgMgdl)
        XCTAssertFalse(r.exerciseActive)
    }

    func testStepOnlyNormalBetweenThresholds() {
        // Not active, steps60 (600) >= inactivitySteps (500) → normal.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 600))
        XCTAssertEqual(r.state, .normal)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertNil(r.targetBgMgdl)
        XCTAssertFalse(r.exerciseActive)
    }

    func testStepThresholdIsStrictGreaterThan() {
        // steps15 exactly equal to threshold (800) does NOT trigger ACTIVE.
        let r = ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 800, s30: 0, s60: 800))
        XCTAssertEqual(r.state, .normal)
    }

    // MARK: - HR-fused path (HR integration enabled)

    private func hrThresholds(stress: Bool = false) -> ActivityThresholds {
        var t = ActivityThresholds()
        t.hrIntegrationEnabled = true
        t.hrStressDetection = stress
        return t
    }

    func testHrFusedVigorousAerobic() {
        // Step-active (steps15 = 900) + high HR-fusion steps (≥300) + zone 4 (hr 140) → VIGOROUS.
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 140, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .vigorousAerobic)
        // activityPct (80) - 10 = 70, min 50 → 70.
        XCTAssertEqual(r.profilePercent, 70)
        XCTAssertEqual(r.targetBgMgdl, 150)
        XCTAssertTrue(r.exerciseActive)
    }

    func testVigorousProfileFloorAt50() {
        // Low activityPct so activityPct - 10 < 50 → floor at 50.
        var t = hrThresholds()
        t.activityPct = 55
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 160, thresholds: t // zone 5
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .vigorousAerobic)
        XCTAssertEqual(r.profilePercent, 50)
    }

    func testHrFusedModerateAerobicFallsBackToActiveEffect() {
        // Step-active + moderate fusion steps (100..<300) + zone 2 (hr 100) → MODERATE_AEROBIC,
        // which produces the step-only ACTIVE effect.
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 100, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80)
        XCTAssertEqual(r.targetBgMgdl, 150)
    }

    func testHrFusedResistanceFromStepActiveLowFusionSteps() {
        // Step-active via steps5 (500 > 420) but HR-fusion steps15 low (<30) + zone 3 (hr 120)
        // → RESISTANCE: profile unchanged (100), target 160.
        let inputs = ActivityInputs(
            steps5: 500, steps15: 0, steps30: 0, steps60: 0,
            avgHeartRate: 120, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .resistance)
        XCTAssertEqual(r.profilePercent, 100) // unchanged baseline
        XCTAssertEqual(r.targetBgMgdl, 160)
        XCTAssertTrue(r.exerciseActive)
    }

    func testHrOnlyResistanceWithoutStepActivity() {
        // Not step-active, steps60 (600) >= inactivitySteps, low fusion steps + zone 4 (hr 140)
        // → HR-only RESISTANCE.
        let inputs = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 600,
            avgHeartRate: 140, thresholds: hrThresholds()
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .resistance)
        XCTAssertEqual(r.profilePercent, 100)
        XCTAssertEqual(r.targetBgMgdl, 160)
    }

    func testStressGatedByHrStressDetection() {
        // Low steps + zone 2 (hr 100). Inactive branch (steps60 = 100 < 500).
        let stressInputs = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 100,
            avgHeartRate: 100, thresholds: hrThresholds(stress: true)
        )
        let withStress = ActivityClassifier.classify(stressInputs)
        XCTAssertEqual(withStress.state, .stress)
        XCTAssertEqual(withStress.profilePercent, 100) // profile unchanged
        XCTAssertEqual(withStress.targetBgMgdl, 160)
        XCTAssertTrue(withStress.exerciseActive)

        // Same inputs but stress detection disabled → falls through to INACTIVE.
        let noStressInputs = ActivityInputs(
            steps5: 0, steps15: 0, steps30: 0, steps60: 100,
            avgHeartRate: 100, thresholds: hrThresholds(stress: false)
        )
        let withoutStress = ActivityClassifier.classify(noStressInputs)
        XCTAssertEqual(withoutStress.state, .inactive)
        XCTAssertEqual(withoutStress.profilePercent, 130)
        XCTAssertNil(withoutStress.targetBgMgdl)
    }

    func testHrEnabledButNoHrSignalUsesStepOnly() {
        // HR integration enabled but avgHeartRate 0 → no fusion; step-active → ACTIVE.
        var t = ActivityThresholds()
        t.hrIntegrationEnabled = true
        let inputs = ActivityInputs(
            steps5: 0, steps15: 900, steps30: 0, steps60: 0,
            avgHeartRate: 0, thresholds: t
        )
        let r = ActivityClassifier.classify(inputs)
        XCTAssertEqual(r.state, .active)
        XCTAssertEqual(r.profilePercent, 80)
        XCTAssertEqual(r.targetBgMgdl, 150)
    }

    // MARK: - exerciseActive flag coverage

    func testExerciseActiveFlagPerState() {
        // resting / normal / inactive → false; exercise states → true.
        XCTAssertFalse(ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 600)).exerciseActive) // normal
        XCTAssertFalse(ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 0, s30: 0, s60: 100)).exerciseActive) // inactive
        XCTAssertTrue(ActivityClassifier.classify(stepOnlyInputs(s5: 0, s15: 900, s30: 0, s60: 0)).exerciseActive) // active
    }
}
