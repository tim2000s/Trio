@testable import BoostV5Core
import XCTest

/// Activity-load source abstraction (Swift port, 2026-06-28). StepSourceResolver selection +
/// ActivityLoadTracker multi-source history, overlap calibration, and scaled bridging. Mirrors the
/// AAPS `StepSourceBridgeTest`. Pure — nothing here doses.
final class StepSourceBridgeTests: XCTestCase {
    private typealias T = ActivityLoadTracker
    private typealias Day = ActivityLoadTracker.DailyStepTotal
    private typealias R = StepSourceResolver

    private func srcHist(_ src: String, _ days: [Int: Int]) -> (String, T.StepHistory) {
        let arr = days.sorted { $0.key < $1.key }.map { Day(dayIndex: $0.key, steps: $0.value, source: src) }
        return (src, T.StepHistory(days: arr))
    }

    private func msh(_ srcDays: (String, T.StepHistory)...) -> T.MultiSourceHistory {
        T.MultiSourceHistory(sources: Dictionary(uniqueKeysWithValues: srcDays))
    }

    // MARK: - Resolver

    func testCanonicalMapsGarminAndHK() {
        XCTAssertEqual(R.canonical("com.garmin.connect.mobile"), "garmin")
        XCTAssertEqual(R.canonical("Apple Watch"), "appleWatch")
        XCTAssertEqual(R.canonical("iPhone"), "iphone")
        XCTAssertEqual(R.canonical("com.withings.wiscale2"), "hk:wiscale2")
    }

    func testTrustOrder() {
        XCTAssertLessThan(R.tier("appleWatch"), R.tier("garmin"))
        XCTAssertLessThan(R.tier("garmin"), R.tier("hk:wiscale2"))
        XCTAssertLessThan(R.tier("hk:wiscale2"), R.tier("iphone"))
    }

    func testResolvePicksHighestTrustFresh() {
        let r = R.resolve([
            R.SourceState(source: "iphone", fresh: true, coverageDays: 20, stepsToday: 5000),
            R.SourceState(source: "appleWatch", fresh: true, coverageDays: 2, stepsToday: 6000),
            R.SourceState(source: "garmin", fresh: false, coverageDays: 20, stepsToday: 9000)
        ])
        XCTAssertEqual(r.active, "appleWatch")
        XCTAssertEqual(r.stepsToday, 6000)
    }

    func testResolveFallsBackWhenNoneFresh() {
        let r = R.resolve([
            R.SourceState(source: "iphone", fresh: false, coverageDays: 20, stepsToday: 5000),
            R.SourceState(source: "garmin", fresh: false, coverageDays: 20, stepsToday: 9000)
        ])
        XCTAssertEqual(r.active, "garmin")
    }

    func testResolveEmpty() {
        XCTAssertNil(R.resolve([]).active)
    }

    // MARK: - Calibration

    func testCalibrationMedianOverOverlap() {
        let active = T.StepHistory(days: (1 ... 5).map { Day(dayIndex: $0, steps: 9000, source: "iphone") })
        let donor = T.StepHistory(days: (1 ... 5).map { Day(dayIndex: $0, steps: 14000, source: "appleWatch") })
        let cal = T.calibration(active: active, donor: donor)
        XCTAssertNotNil(cal)
        XCTAssertEqual(cal!, 9000.0 / 14000.0, accuracy: 1E-6)
    }

    func testCalibrationNilWhenTooLittleOverlap() {
        let active = T.StepHistory(days: [
            Day(dayIndex: 1, steps: 9000, source: "iphone"),
            Day(dayIndex: 2, steps: 9000, source: "iphone")
        ])
        let donor = T.StepHistory(days: (1 ... 5).map { Day(dayIndex: $0, steps: 14000, source: "appleWatch") })
        XCTAssertNil(T.calibration(active: active, donor: donor))
    }

    // MARK: - Bridging (headline guarantee)

    func testWatchDiesPhoneTakesOverScaledBridge() {
        // appleWatch logged 14k/day for days 1..20 then died; iPhone logs 9k and owns today (21).
        let multi = msh(
            srcHist("appleWatch", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 14000) })),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (16 ... 20).map { ($0, 9000) }))
        )
        let bridged = T.bridgedWindow(multi, activeSource: "iphone", todayIndex: 21)
        XCTAssertTrue(bridged.calibrated, "≥3 overlap days (16..20) → calibrated")
        // bridged appleWatch days scaled phone-ward: 14000 * (9000/14000) ≈ 9000
        XCTAssertEqual(bridged.history.steps(forDay: 1)!, 9000, accuracy: 50)
        // baseline ≈ phone units, yesterday (9000) ≈ baseline → ratio ~1, NOT inactivity
        let base = T.baseline(bridged.history, todayIndex: 21)
        XCTAssertNotNil(base)
        XCTAssertEqual(base!, 9000, accuracy: 200)
        let f = T.compute(bridged.history, todayIndex: 21)
        XCTAssertEqual(f.wouldDeltaIsfPct ?? 0, 0, accuracy: 1.0)
    }

    func testBridgingGuaranteesCoverageNoWarmupGap() {
        let multi = msh(
            srcHist("appleWatch", [20: 13000]),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        // appleWatch alone is insufficient-history:
        XCTAssertNil(T.baseline(multi.sources["appleWatch"]!, todayIndex: 21))
        // bridged view has full coverage → baseline forms (no warmup)
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertNotNil(T.baseline(bridged.history, todayIndex: 21))
    }

    func testBridgeWithoutOverlapFlaggedRaw() {
        let multi = msh(
            srcHist("appleWatch", [20: 13000]), // 1 day only → no overlap to calibrate
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertFalse(bridged.calibrated)
        XCTAssertEqual(bridged.history.steps(forDay: 1)!, 9000) // raw iPhone value, no scaling
    }

    func testHighestTrustDonorWinsBridgedDay() {
        let multi = msh(
            srcHist("garmin", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 12000) })),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        // active = appleWatch (no days) → every day bridged; garmin (tier 1) beats iphone (tier 3)
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertEqual(bridged.history.days.first { $0.dayIndex == 5 }?.source, "garmin")
    }

    func testActiveDaysNeverOverwritten() {
        let multi = msh(
            srcHist("appleWatch", [10: 15000]),
            srcHist("iphone", Dictionary(uniqueKeysWithValues: (1 ... 20).map { ($0, 9000) }))
        )
        let bridged = T.bridgedWindow(multi, activeSource: "appleWatch", todayIndex: 21)
        XCTAssertEqual(bridged.history.steps(forDay: 10), 15000)
    }

    // MARK: - mergeSource

    func testMergeSourceAddsDaysAndPrunesEmpty() {
        var multi = T.MultiSourceHistory()
        multi = T.mergeSource(
            multi,
            source: "appleWatch",
            totals: [
                Day(dayIndex: 100, steps: 14000, source: "appleWatch"),
                Day(dayIndex: 101, steps: 15000, source: "appleWatch")
            ],
            todayIndex: 102
        )
        XCTAssertEqual(multi.sources["appleWatch"]?.days.map(\.dayIndex), [100, 101])
        // a source whose only days fall outside the window is pruned
        multi = T.mergeSource(
            multi,
            source: "iphone",
            totals: [Day(dayIndex: 1, steps: 9000, source: "iphone")],
            todayIndex: 102
        )
        XCTAssertNil(multi.sources["iphone"])
    }
}
