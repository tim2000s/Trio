@testable import BoostV5Core
import Foundation
import XCTest

final class SleepStateDetectorTests: XCTestCase {
    typealias D = SleepStateDetector

    // Night window: 22:00 (1320) → 07:00 (420), preSleepLead 60m → preSleep window [1260, 1320).
    // `avgHeartRate` > 0 synthesises one FRESH reading at nowMs (so avgHr != nil → drought inert,
    // matching the legacy HR-path tests); 0 means no HR samples at all (drives the drought path).
    // Pass `hrReadings` explicitly to drive drought / transmission-resume scenarios directly.
    private func makeInputs(
        avgHeartRate: Double = 60,
        hrReadings: [SleepHrReading]? = nil,
        restingHeartRate: Double = 60,
        steps15min: Int = 0,
        nowMinuteOfDay: Int,
        nightStartMinute: Int = 1320,
        nightEndMinute: Int = 420,
        preSleepLeadMin: Int = 60,
        sleepHysteresisMin: Int = 10,
        wakeHrHysteresisMin: Int = 5,
        droughtThresholdMin: Int = 30,
        freshHrWindowMin: Int = 10,
        mlMealLikely: Double? = nil,
        nowMs: Double,
        autoBySleep: Bool = true
    ) -> SleepDetectorInputs {
        let readings = hrReadings ?? (
            avgHeartRate > 0
                ? [SleepHrReading(timestampMs: nowMs, beatsPerMinute: avgHeartRate, durationMs: 1000)]
                : []
        )
        return SleepDetectorInputs(
            hrReadings: readings,
            hrWindowMinutes: 5,
            restingHeartRate: restingHeartRate,
            steps15min: steps15min,
            nowMinuteOfDay: nowMinuteOfDay,
            nightStartMinute: nightStartMinute,
            nightEndMinute: nightEndMinute,
            preSleepLeadMin: preSleepLeadMin,
            sleepHysteresisMin: sleepHysteresisMin,
            wakeHrHysteresisMin: wakeHrHysteresisMin,
            droughtThresholdMin: droughtThresholdMin,
            freshHrWindowMin: freshHrWindowMin,
            mlMealLikely: mlMealLikely,
            nowMs: nowMs,
            autoBySleep: autoBySleep
        )
    }

    private let minute = 60000.0

    // MARK: AWAKE → PRE_SLEEP

    func testAwakeToPreSleepAtLeadWindow() {
        // 21:00 (1260) is the start of the pre-sleep lead window. HR/steps high so sleep candidacy
        // does NOT fire — pure time transition into PRE_SLEEP must still happen.
        let inputs = makeInputs(avgHeartRate: 90, steps15min: 200, nowMinuteOfDay: 1260, nowMs: 0)
        let out = D.step(inputs, SleepDetectorState())
        XCTAssertEqual(out.state, .preSleep)
    }

    func testNoPreSleepBeforeLeadWindow() {
        // 20:59 (1259) is one minute before the lead window opens → still AWAKE.
        let inputs = makeInputs(avgHeartRate: 90, steps15min: 200, nowMinuteOfDay: 1259, nowMs: 0)
        let out = D.step(inputs, SleepDetectorState())
        XCTAssertEqual(out.state, .awake)
    }

    // MARK: PRE_SLEEP → SLEEPING after hysteresis

    func testPreSleepToSleepingAfterHysteresis() {
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        // In outer window (23:00 = 1380), low HR, no steps, no meal.
        let t0 = makeInputs(avgHeartRate: 65, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.state, .preSleep)
        XCTAssertEqual(state.sleepCandidateSinceMs, 0)

        // 9 minutes later — not yet past the 10m hysteresis.
        let t9 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 9 * minute)
        state = D.step(t9, state)
        XCTAssertEqual(state.state, .preSleep)

        // 10 minutes later — hysteresis met → SLEEPING.
        let t10 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 10 * minute)
        state = D.step(t10, state)
        XCTAssertEqual(state.state, .sleeping)
    }

    func testSleepHrCapBoundary() {
        // resting 60 → cap = 69.0. avgHr 69 qualifies (≤ cap); 70 does not (> cap).
        XCTAssertTrue(D.qualifiesAsSleepCandidate(69.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: nil))
        XCTAssertFalse(D.qualifiesAsSleepCandidate(70.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: nil))
    }

    func testSleepStepCeilingBlocks() {
        // steps 49 ok, 50 blocks.
        XCTAssertTrue(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 49, mlMealLikely: nil))
        XCTAssertFalse(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 50, mlMealLikely: nil))
    }

    // MARK: meal-likelihood blocks SLEEPING

    func testMealLikelihoodBlocksSleeping() {
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        // Meal likely 0.30 → blocks candidacy (>= threshold). Never starts a candidate window.
        let t0 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, mlMealLikely: 0.30, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertNil(state.sleepCandidateSinceMs)

        let t20 = makeInputs(avgHeartRate: 65, steps15min: 0, nowMinuteOfDay: 1380, mlMealLikely: 0.30, nowMs: 20 * minute)
        state = D.step(t20, state)
        XCTAssertEqual(state.state, .preSleep) // still not asleep

        // Just under threshold (0.29) does NOT block.
        XCTAssertTrue(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: 0.29))
        XCTAssertFalse(D.qualifiesAsSleepCandidate(60.0, sleepCap: 69.0, steps15min: 0, mlMealLikely: 0.30))
    }

    func testNoHrDroughtSleepsAfterHysteresis() {
        // No HR samples at all (e.g. no watch) + never saw a fresh sample → fully in drought.
        // In the night window with low steps, the drought qualifier promotes to SLEEPING after
        // hysteresis, matching AAPS's batched-HR / sparse-HR behaviour. Entry reason = "drought".
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        let t0 = makeInputs(avgHeartRate: 0, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.sleepCandidateSinceMs, 0)
        let t10 = makeInputs(avgHeartRate: 0, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 10 * minute)
        state = D.step(t10, state)
        XCTAssertEqual(state.state, .sleeping)
        XCTAssertEqual(state.sleepEntryReason, "drought")
    }

    func testRecentHrGapDoesNotDroughtSleep() {
        // A fresh sample 7 min ago: too old for the 5-min average (avgHr == nil) but recent enough
        // that drought (≥30 min) is NOT established → neither qualifier fires → no sleep.
        let now = 1_000_000.0
        let reading = SleepHrReading(timestampMs: now - 7 * minute, beatsPerMinute: 62, durationMs: 1000)
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: now)
        let t0 = makeInputs(hrReadings: [reading], steps15min: 0, nowMinuteOfDay: 1380, nowMs: now)
        state = D.step(t0, state)
        XCTAssertNil(state.sleepCandidateSinceMs)
        XCTAssertEqual(state.state, .preSleep)
    }

    func testTransmissionResumeWakeFromDrought() {
        // Asleep via drought; then a burst of 3 fresh samples arrives after the drought → AWAKE
        // immediately (no hysteresis), matching AAPS transmission-resume wake.
        var state = SleepDetectorState(
            state: .sleeping, enteredAtMs: 0, lastFreshHrSampleMs: 0, sleepEntryReason: "drought"
        )
        let now = 2_000_000.0 // well past any drought threshold from lastFresh=0
        let burst = [
            SleepHrReading(timestampMs: now - 2 * minute, beatsPerMinute: 70, durationMs: 1000),
            SleepHrReading(timestampMs: now - 1 * minute, beatsPerMinute: 72, durationMs: 1000),
            SleepHrReading(timestampMs: now, beatsPerMinute: 74, durationMs: 1000)
        ]
        // Still inside the outer window (02:00) so the hard morning exit isn't what wakes it.
        let inputs = makeInputs(hrReadings: burst, steps15min: 0, nowMinuteOfDay: 120, nowMs: now)
        state = D.step(inputs, state)
        XCTAssertEqual(state.state, .awake)
    }

    // MARK: SLEEPING → AWAKE on sustained HR + steps

    func testSleepingToAwakeOnHrPlusSteps() {
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        // resting 60 → wakeFloor 75. HR 80 (> 75) and steps 120 (≥ 100), inside outer window (06:00 = 360).
        let t0 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.state, .sleeping)
        XCTAssertEqual(state.wakeCandidateSinceMs, 0)

        // 4m later — not yet past 5m wake hysteresis.
        let t4 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 4 * minute)
        state = D.step(t4, state)
        XCTAssertEqual(state.state, .sleeping)

        // 5m later → AWAKE.
        let t5 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 5 * minute)
        state = D.step(t5, state)
        XCTAssertEqual(state.state, .awake)
    }

    func testSleepingHrAloneDoesNotWake() {
        // HR high but steps low → no wake; counter never starts.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let t0 = makeInputs(avgHeartRate: 90, restingHeartRate: 60, steps15min: 10, nowMinuteOfDay: 360, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertNil(state.wakeCandidateSinceMs)
        let t20 = makeInputs(avgHeartRate: 90, restingHeartRate: 60, steps15min: 10, nowMinuteOfDay: 360, nowMs: 20 * minute)
        state = D.step(t20, state)
        XCTAssertEqual(state.state, .sleeping)
    }

    func testWakeCandidateResetsWhenConditionDrops() {
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let t0 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.wakeCandidateSinceMs, 0)
        // steps drop → candidate resets.
        let t2 = makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 360, nowMs: 2 * minute)
        state = D.step(t2, state)
        XCTAssertNil(state.wakeCandidateSinceMs)
        XCTAssertEqual(state.state, .sleeping)
    }

    // MARK: clock-window exit

    func testSleepingHardExitOnWindowLeave() {
        // 08:00 (480) is past nightEnd (420) → outside outer window → hard AWAKE exit regardless of HR/steps.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let inputs = makeInputs(avgHeartRate: 60, steps15min: 0, nowMinuteOfDay: 480, nowMs: 0)
        state = D.step(inputs, state)
        XCTAssertEqual(state.state, .awake)
    }

    func testPreSleepExitsWhenLeavingWindowWithoutSleeping() {
        // From PRE_SLEEP, jump to mid-morning (480) outside both windows → AWAKE.
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        let inputs = makeInputs(avgHeartRate: 90, steps15min: 0, nowMinuteOfDay: 480, nowMs: 0)
        state = D.step(inputs, state)
        XCTAssertEqual(state.state, .awake)
    }

    // MARK: midnight wrap

    func testMidnightWrapInWindow() {
        // Window 1320→420 wraps midnight. 02:00 (120) is inside; 12:00 (720) is outside.
        XCTAssertTrue(D.minuteInWrappedRange(120, 1320, 420))
        XCTAssertFalse(D.minuteInWrappedRange(720, 1320, 420))
        // Boundaries: start inclusive, end exclusive.
        XCTAssertTrue(D.minuteInWrappedRange(1320, 1320, 420))
        XCTAssertFalse(D.minuteInWrappedRange(420, 1320, 420))
        // Non-wrapping window for comparison.
        XCTAssertTrue(D.minuteInWrappedRange(500, 480, 600))
        XCTAssertFalse(D.minuteInWrappedRange(600, 480, 600))
    }

    func testSleepConfirmedAcrossMidnight() {
        // Candidate starts at 23:55 (1435) and confirms at 00:05 (5) — across the midnight boundary.
        var state = SleepDetectorState(state: .preSleep, enteredAtMs: 0)
        let t0 = makeInputs(avgHeartRate: 62, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1435, nowMs: 0)
        state = D.step(t0, state)
        XCTAssertEqual(state.sleepCandidateSinceMs, 0)
        let t10 = makeInputs(avgHeartRate: 62, restingHeartRate: 60, steps15min: 0, nowMinuteOfDay: 5, nowMs: 10 * minute)
        state = D.step(t10, state)
        XCTAssertEqual(state.state, .sleeping)
    }

    func testPreSleepWindowWrapsMidnight() {
        // nightStart 30 (00:30), lead 60 → preSleepStart = 1410 (23:30). 23:45 (1425) is in pre-sleep.
        let inputs = makeInputs(
            avgHeartRate: 90, steps15min: 200,
            nowMinuteOfDay: 1425, nightStartMinute: 30, nightEndMinute: 420,
            nowMs: 0
        )
        let out = D.step(inputs, SleepDetectorState())
        XCTAssertEqual(out.state, .preSleep)
    }

    // MARK: autoBySleep does NOT gate the detector (matches AAPS — detector always runs;

    // autoBySleep only gates the downstream night-mode extension).

    func testAutoBySleepDisabledStillAdvancesDetector() {
        // Stay-asleep conditions with autoBySleep=false: the detector must HOLD sleeping,
        // not force AWAKE (the old behaviour discarded in-progress state and diverged from AAPS).
        let state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let inputs = makeInputs(avgHeartRate: 60, steps15min: 0, nowMinuteOfDay: 1380, nowMs: 0, autoBySleep: false)
        let out = D.step(inputs, state)
        XCTAssertEqual(out.state, .sleeping)
    }

    // MARK: wake reason (sleep-window collapse fix)

    func testHardExitWakeReasonIsBoundary() {
        // SLEEPING at 12:00 (720), outside the 22:00-07:00 window → hard exit, tagged "boundary"
        // so the learner won't train its wake time on it.
        let state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        let out = D.step(makeInputs(avgHeartRate: 0, steps15min: 0, nowMinuteOfDay: 720, nowMs: 0), state)
        XCTAssertEqual(out.state, .awake)
        XCTAssertEqual(out.wakeReason, "boundary")
    }

    func testGenuineWakeReasonIsHrSteps() {
        // resting 60 → wakeFloor 75; HR 80 + steps 120 in window (06:00) sustained 5m → genuine wake.
        var state = SleepDetectorState(state: .sleeping, enteredAtMs: 0)
        state = D.step(makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 0), state)
        let out = D.step(
            makeInputs(avgHeartRate: 80, restingHeartRate: 60, steps15min: 120, nowMinuteOfDay: 360, nowMs: 5 * minute),
            state
        )
        XCTAssertEqual(out.state, .awake)
        XCTAssertEqual(out.wakeReason, "hr_steps")
    }

    // MARK: serialization round-trip

    func testStateCodableRoundTrip() throws {
        let original = SleepDetectorState(
            state: .sleeping,
            sleepCandidateSinceMs: 12345.0,
            wakeCandidateSinceMs: nil,
            enteredAtMs: 999_999.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SleepDetectorState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testStateCodableRoundTripWithNils() throws {
        let original = SleepDetectorState()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SleepDetectorState.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.state, .awake)
        XCTAssertNil(decoded.sleepCandidateSinceMs)
    }

    func testSleepStateRawValues() {
        XCTAssertEqual(SleepState.awake.rawValue, "awake")
        XCTAssertEqual(SleepState.preSleep.rawValue, "preSleep")
        XCTAssertEqual(SleepState.sleeping.rawValue, "sleeping")
    }
}
