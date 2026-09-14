@testable import BoostV5Core
import XCTest

final class BoostMlFeatureBuilderTests: XCTestCase {
    typealias B = BoostMlFeatureBuilder

    private func snap(_ ts: Double, _ cgm: Double) -> B.CycleSnapshot {
        B.CycleSnapshot(
            ts: ts, cgmMgdl: cgm, iobIob: 1.0, iobActivity: 0.01,
            sugEventualBG: cgm + 10, recentSmbUnits60m: 0.5, sugMinDelta: -1.0
        )
    }

    // MARK: - Ring-buffer staleness (AAPS 2026-08-14)

    private func snapAtMinute(_ minute: Double, _ cgm: Double) -> B.CycleSnapshot {
        snap(minute * 60000, cgm)
    }

    func testRingBufferDropsSnapshotsOlderThanTheLookbackWindow() {
        var ring = B.RingBuffer()
        // Five contiguous cycles on the five-minute grid, then a two-hour break.
        for i in 0 ..< 5 { ring.push(snapAtMinute(Double(i) * 5, 100 + Double(i))) }
        XCTAssertEqual(ring.snapshots.count, 5)
        ring.push(snapAtMinute(140, 200)) // 2 h after the last one

        // Only the new cycle survives: the pre-gap snapshots are not the preceding five cycles.
        XCTAssertEqual(ring.snapshots.count, 1)
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl, 200)
        XCTAssertNil(ring.lagged(1))
    }

    func testRingBufferKeepsHistoryAcrossAnOrdinaryLateReading() {
        var ring = B.RingBuffer()
        for i in 0 ..< 5 { ring.push(snapAtMinute(Double(i) * 5, 100 + Double(i))) }
        // A cycle 8 minutes after the last rather than 5. The slack in the window is there so a
        // late reading does not discard usable history.
        ring.push(snapAtMinute(28, 200))
        XCTAssertEqual(ring.snapshots.count, 6)
        XCTAssertEqual(ring.lagged(5)?.cgmMgdl, 100)
    }

    func testRingBufferBoundaryIsThirtyFiveMinutes() {
        var ring = B.RingBuffer()
        ring.push(snapAtMinute(0, 100))
        ring.push(snapAtMinute(35, 200)) // exactly 35 min: the older entry is not yet stale
        XCTAssertEqual(ring.snapshots.count, 2)

        var ring2 = B.RingBuffer()
        ring2.push(snapAtMinute(0, 100))
        ring2.push(snapAtMinute(35.001, 200)) // just past it
        XCTAssertEqual(ring2.snapshots.count, 1)
    }

    func testRingBufferDropsOnlyTheEntriesOutsideTheWindow() {
        var ring = B.RingBuffer()
        // Two old cycles, a gap, then three recent ones. Only the old pair should go.
        ring.push(snapAtMinute(0, 100))
        ring.push(snapAtMinute(5, 101))
        ring.push(snapAtMinute(50, 102))
        ring.push(snapAtMinute(55, 103))
        ring.push(snapAtMinute(60, 104))
        XCTAssertEqual(ring.snapshots.count, 3)
        XCTAssertEqual(ring.lagged(2)?.cgmMgdl, 102)
        XCTAssertNil(ring.lagged(3))
    }

    func testRingBufferLaggedAndCap() {
        var ring = B.RingBuffer()
        for i in 0 ..< 8 { ring.push(snap(Double(i), 100 + Double(i))) }
        // Capped at 6 entries — oldest dropped.
        XCTAssertEqual(ring.snapshots.count, B.lookback)
        // lag0 = most recent (cgm 107), lag5 = 6th from end (cgm 102).
        XCTAssertEqual(ring.lagged(0)?.cgmMgdl, 107)
        XCTAssertEqual(ring.lagged(5)?.cgmMgdl, 102)
        // Beyond the buffer → nil.
        XCTAssertNil(ring.lagged(6))
    }

    func testBuildStaticAndLagMapping() {
        var ring = B.RingBuffer()
        ring.push(snap(0, 100)) // lag1 after current push
        let current = snap(1, 120)
        ring.push(current) // lag0
        let names = ["cgm_mgdl", "bg_above_target", "cgm_mgdl_lag0", "cgm_mgdl_lag1", "sug_minDelta_lag0"]
        let statics: [String: Double] = ["cgm_mgdl": 120, "bg_above_target": 20]
        let v = B.build(featureNames: names, current: current, ring: ring, staticValues: statics)
        XCTAssertEqual(v[0], 120) // static cgm_mgdl
        XCTAssertEqual(v[1], 20) // static bg_above_target
        XCTAssertEqual(v[2], 120) // lag0 = current
        XCTAssertEqual(v[3], 100) // lag1 = previous
        XCTAssertEqual(v[4], -1.0) // sug_minDelta_lag0
    }

    func testBuildColdStartLagFallsBackToCurrent() {
        var ring = B.RingBuffer()
        let current = snap(0, 90)
        ring.push(current) // only one entry
        let names = ["cgm_mgdl_lag0", "cgm_mgdl_lag3"]
        let v = B.build(featureNames: names, current: current, ring: ring, staticValues: [:])
        XCTAssertEqual(v[0], 90) // lag0 present
        XCTAssertEqual(v[1], 90) // lag3 missing → falls back to current
    }

    func testMissingStaticDefaultsToZero() {
        let v = B.build(
            featureNames: ["not_a_known_feature"], current: snap(0, 100),
            ring: B.RingBuffer(), staticValues: [:]
        )
        XCTAssertEqual(v[0], 0.0)
    }

    func testSerializeRoundTrip() {
        var ring = B.RingBuffer()
        ring.push(snap(10, 110))
        ring.push(snap(20, 120))
        let restored = B.deserialize(B.serialize(ring))
        XCTAssertEqual(restored.snapshots.count, 2)
        XCTAssertEqual(restored.lagged(0)?.cgmMgdl, 120)
        XCTAssertEqual(restored.lagged(1)?.cgmMgdl, 110)
    }

    func testDeserializeEmptyAndCorrupt() {
        XCTAssertEqual(B.deserialize("").snapshots.count, 0)
        XCTAssertEqual(B.deserialize("{not json").snapshots.count, 0)
    }
}
