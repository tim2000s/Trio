@testable import BoostV5Core
import XCTest

final class MealTimeLearnerTests: XCTestCase {
    // All tests use localOffsetMs = 0 so a UTC instant's hour:minute maps
    // directly to local minute-of-day. Day index then advances per UTC day.

    private let msPerDay: Double = 24.0 * 60.0 * 60.0 * 1000.0
    private let msPerHour: Double = 60.0 * 60.0 * 1000.0
    private let msPerMin: Double = 60.0 * 1000.0

    /// Epoch-ms for `day` days after epoch, at `hour:minute` UTC.
    private func ts(day: Int, hour: Int, minute: Int = 0) -> Double {
        Double(day) * msPerDay + Double(hour) * msPerHour + Double(minute) * msPerMin
    }

    // MARK: - record / trim

    func testRecordTrimsBeyondWindow() {
        var h = MealTimeHistory()
        // An old event well outside a 60-day window, plus a recent one.
        let old = ts(day: 0, hour: 12)
        let recent = ts(day: 100, hour: 12) // 100 days after epoch

        h = MealTimeLearner.record(h, tsMs: old)
        h = MealTimeLearner.record(h, tsMs: recent, windowDays: 60)

        // old is > 60 days before recent → trimmed; recent stays.
        XCTAssertEqual(h.events, [recent])
    }

    func testRecordKeepsEventsInsideWindow() {
        var h = MealTimeLearner.record(MealTimeHistory(), tsMs: ts(day: 100, hour: 8))
        h = MealTimeLearner.record(h, tsMs: ts(day: 150, hour: 8)) // 50 days later, inside 60
        XCTAssertEqual(h.events.count, 2)
    }

    func testRecordTrimRelativeToInsertedTimestamp() {
        // Cutoff is computed from the just-inserted tsMs, not "now".
        var h = MealTimeLearner.record(MealTimeHistory(), tsMs: ts(day: 0, hour: 12))
        h = MealTimeLearner.record(h, tsMs: ts(day: 59, hour: 12)) // 59 days → inside
        XCTAssertEqual(h.events.count, 2)
        h = MealTimeLearner.record(h, tsMs: ts(day: 61, hour: 12)) // now day0 is 61 days old → trimmed
        XCTAssertEqual(h.events.count, 2)
        XCTAssertEqual(h.events.first, ts(day: 59, hour: 12))
    }

    // MARK: - modes: trusted cluster

    func testClusterAt1300EmitsModeAround780Min() {
        var h = MealTimeHistory()
        // 6 events over 6 distinct days, all near 13:00 (780 min), within ±45.
        h = MealTimeLearner.record(h, tsMs: ts(day: 1, hour: 13, minute: 0))
        h = MealTimeLearner.record(h, tsMs: ts(day: 2, hour: 12, minute: 50))
        h = MealTimeLearner.record(h, tsMs: ts(day: 3, hour: 13, minute: 10))
        h = MealTimeLearner.record(h, tsMs: ts(day: 4, hour: 13, minute: 5))
        h = MealTimeLearner.record(h, tsMs: ts(day: 5, hour: 12, minute: 55))
        h = MealTimeLearner.record(h, tsMs: ts(day: 6, hour: 13, minute: 0))

        let modes = MealTimeLearner.modes(h, localOffsetMs: 0)
        XCTAssertEqual(modes.count, 1)
        let mode = modes[0]
        XCTAssertTrue(abs(mode.centreMin - 780) <= 5, "centre ~13:00 (780 min), got \(mode.centreMin)")
        XCTAssertEqual(mode.eventCount, 6)
        XCTAssertEqual(mode.distinctDays, 6)
    }

    func testTooFewEventsYieldsNoMode() {
        var h = MealTimeHistory()
        // Only 5 events near 13:00 → below MIN_SESSIONS (6).
        for day in 1 ... 5 {
            h = MealTimeLearner.record(h, tsMs: ts(day: day, hour: 13))
        }
        XCTAssertTrue(MealTimeLearner.modes(h, localOffsetMs: 0).isEmpty)
    }

    func testTooFewDistinctDaysYieldsNoMode() {
        var h = MealTimeHistory()
        // 6 events near 13:00 but spread over only 3 distinct days → below MIN_DISTINCT_DAYS (4).
        h = MealTimeLearner.record(h, tsMs: ts(day: 1, hour: 13, minute: 0))
        h = MealTimeLearner.record(h, tsMs: ts(day: 1, hour: 13, minute: 20))
        h = MealTimeLearner.record(h, tsMs: ts(day: 2, hour: 12, minute: 50))
        h = MealTimeLearner.record(h, tsMs: ts(day: 2, hour: 13, minute: 5))
        h = MealTimeLearner.record(h, tsMs: ts(day: 3, hour: 13, minute: 10))
        h = MealTimeLearner.record(h, tsMs: ts(day: 3, hour: 12, minute: 55))
        XCTAssertTrue(MealTimeLearner.modes(h, localOffsetMs: 0).isEmpty)
    }

    // MARK: - circular mean across midnight

    func testCircularMeanHandlesMidnightWrap() {
        var h = MealTimeHistory()
        // Cluster straddling midnight, all within the ±45-min half-width of ~00:00, over 6 days →
        // one mode centred near midnight (≈0/1440), NOT ~06:00. (A wider 22:00–01:00 spread would
        // exceed the ±45 half-width and faithfully NOT form a single cluster — that's by design.)
        h = MealTimeLearner.record(h, tsMs: ts(day: 1, hour: 23, minute: 45))
        h = MealTimeLearner.record(h, tsMs: ts(day: 2, hour: 23, minute: 55))
        h = MealTimeLearner.record(h, tsMs: ts(day: 3, hour: 0, minute: 5))
        h = MealTimeLearner.record(h, tsMs: ts(day: 4, hour: 0, minute: 15))
        h = MealTimeLearner.record(h, tsMs: ts(day: 5, hour: 23, minute: 50))
        h = MealTimeLearner.record(h, tsMs: ts(day: 6, hour: 0, minute: 10))

        let modes = MealTimeLearner.modes(h, localOffsetMs: 0)
        XCTAssertEqual(modes.count, 1)
        guard let centre = modes.first?.centreMin else { return XCTFail("expected one mode") }
        // Should be near 23:00 (1380), within the late-evening/early-night arc, not midday.
        let nearLateNight = centre >= 1320 || centre <= 120
        XCTAssertTrue(nearLateNight, "centre \(centre) should be near 23:00, not ~06:00")
        XCTAssertFalse(centre > 300 && centre < 1200, "centre \(centre) must not land in daytime")
    }

    // MARK: - preMealWindow

    private func make1300History() -> MealTimeHistory {
        var h = MealTimeHistory()
        for day in 1 ... 6 {
            h = MealTimeLearner.record(h, tsMs: ts(day: day, hour: 13))
        }
        return h
    }

    func testPreMealWindowHitAbout50MinBefore() {
        let h = make1300History()
        // Mode centre ~780 (13:00). 50 min before = 730 min (12:10).
        let hit = MealTimeLearner.preMealWindow(h, nowMin: 730, localOffsetMs: 0, leadMaxMin: 60)
        XCTAssertNotNil(hit)
        XCTAssertTrue(abs((hit?.minutesBeforeMeal ?? -1) - 50) <= 2, "got \(String(describing: hit?.minutesBeforeMeal))")
        XCTAssertTrue(abs((hit?.mode.centreMin ?? -1) - 780) <= 2, "got \(String(describing: hit?.mode.centreMin))")
    }

    func testPreMealWindowNilInsideFloor() {
        let h = make1300History()
        // 30 min before (750 min) is inside the 45-min floor → window closed → nil.
        XCTAssertNil(MealTimeLearner.preMealWindow(h, nowMin: 750, localOffsetMs: 0, leadMaxMin: 60))
    }

    func testPreMealWindowNilFarFromMeal() {
        let h = make1300History()
        // Mid-morning, hours before the meal → nil.
        XCTAssertNil(MealTimeLearner.preMealWindow(h, nowMin: 8 * 60, localOffsetMs: 0, leadMaxMin: 60))
    }

    func testPreMealWindowNilWithNoModes() {
        // Empty history → no modes → never fires.
        XCTAssertNil(MealTimeLearner.preMealWindow(MealTimeHistory(), nowMin: 730, localOffsetMs: 0, leadMaxMin: 60))
    }

    func testPreMealWindowLowLeadMaxStillHasMinimumSpan() {
        let h = make1300History()
        // leadMaxMin below floor+span: open is held at 45+10 = 55. 50 min before is within [45,55].
        let hit = MealTimeLearner.preMealWindow(h, nowMin: 730, localOffsetMs: 0, leadMaxMin: 5)
        XCTAssertNotNil(hit, "low leadMax must not collapse the window below the minimum span")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = MealTimeHistory(events: [1000.0, 2000.5, 3_600_000.0])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MealTimeHistory.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableJSONShapeUsesEventsKey() throws {
        let h = MealTimeHistory(events: [42.0])
        let data = try JSONEncoder().encode(h)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"events\""), "JSON should contain the events key: \(json)")
    }
}
