@testable import BoostV5Core
import XCTest

/// Periodic re-derivation of the derived knobs (AAPS 2026-08-03, second revision, with the
/// 2026-08-04 clipped-step fix).
///
/// Movement of each knob's driver is tracked and applied to whatever the knob is currently set to,
/// so a user's own offset is preserved rather than overwritten or frozen.
final class RedriveTests: XCTestCase {
    typealias Apply = BoostV5AutoConfigApply
    typealias Knob = BoostAutoConfigKnob

    /// A mutable store standing in for the host's preferences plus the baseline and pending ledgers.
    private final class Store {
        var value: [Knob: Double] = [
            .aggression: 1.0, .hypoCaution: 1.0, .confirmedCapU: 2.5,
            .committedCapU: 0.5, .cumulativeSmbCap60Min: 10.0, .primerCapU: 0.3
        ]
        var baseline: [Knob: Double] = [:]
        var pending: [Knob: Double] = [:]

        @discardableResult func run(
            _ s: BoostV5AutoConfig.Suggestion,
            tbr70: Double = 2.0,
            sev54: Double = 0.2
        ) -> [Apply.Resolution] {
            Apply.redrive(
                suggestion: s, tbrBelow70Pct: tbr70, timeBelow54Pct: sev54,
                storedValue: { self.value[$0] }, currentDefault: { _ in 0 },
                baselineValue: { self.baseline[$0] }, pendingValue: { self.pending[$0] },
                put: { self.value[$0] = $1 },
                setBaseline: { self.baseline[$0] = $1 },
                setPending: { knob, v in
                    if let v { self.pending[knob] = v } else { self.pending.removeValue(forKey: knob) }
                }
            )
        }
    }

    private func suggestion(
        aggression: Double = 1.0, hypoCaution: Double = 1.0,
        confirmedCapU: Double = 2.5, committedCapU: Double = 0.5, primerCapU: Double = 0.3
    ) -> BoostV5AutoConfig.Suggestion {
        BoostV5AutoConfig.Suggestion(
            aggression: aggression, hypoCaution: hypoCaution,
            confirmedCapU: confirmedCapU, committedCapU: committedCapU,
            cumulativeSmbCap60MinU: BoostV5AutoConfig.cumulativeCap60Min(
                confirmedCapU: confirmedCapU, committedCapU: committedCapU
            ),
            maxIobU: 8, bolusCapU: 10, fastCarbConfirm: true,
            aggressiveEarlyConfirm: false, velocityBudgetFloor: false,
            primerCapU: primerCapU, primerTbrFallback: false, rationale: []
        )
    }

    func testFirstRunRecordsBaselinesAndWritesNoTrackedKnob() {
        let store = Store()
        let out = store.run(suggestion(committedCapU: 2.0))
        for knob in Apply.redriveKnobs {
            XCTAssertNotNil(store.baseline[knob], "\(knob) baseline")
            XCTAssertTrue(out.contains { $0.knob == knob && $0.outcome == .baselineRecorded })
        }
        // The tracked knobs are untouched.
        XCTAssertEqual(store.value[.committedCapU], 0.5)
        XCTAssertEqual(store.value[.aggression], 1.0)
    }

    func testComputedKnobsCanStillBeWrittenOnTheFirstRun() {
        // They are recomputed from the operative caps rather than tracked, so a cumulative cap that
        // has drifted out of step with the caps it bounds is corrected immediately. "The first run
        // changes nothing" is not true, and AAPS says so having shipped that claim.
        let store = Store()
        store.value[.cumulativeSmbCap60Min] = 1.0 // out of step with 2.5 + 2 x 0.5
        store.run(suggestion())
        XCTAssertEqual(store.value[.cumulativeSmbCap60Min]!, 3.5, accuracy: 1E-9)
    }

    func testTheUsersOwnOffsetSurvivesAMoveInTheDriver() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.24)) // baseline recorded
        store.value[.committedCapU] = 1.8 // the user raised it by 45%
        store.run(suggestion(committedCapU: 1.488)) // the derivation moved up 20%
        // 1.8 x 1.2 = 2.16: the driver's movement applied, the offset intact.
        XCTAssertEqual(store.value[.committedCapU]!, 2.16, accuracy: 0.01)
    }

    func testRatioOfCurrentToDerivedIsInvariant() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.0))
        store.value[.committedCapU] = 1.5 // offset of 1.5x
        store.run(suggestion(committedCapU: 1.2))
        XCTAssertEqual(store.value[.committedCapU]! / 1.2, 1.5, accuracy: 0.02)
    }

    func testAMoveInsideTheDeadbandIsNotWrittenAndAccumulates() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.0))
        // A 5% move on a 1.0 cap is 0.05, inside the 0.07 band.
        let first = store.run(suggestion(committedCapU: 1.05))
        XCTAssertEqual(store.value[.committedCapU], 0.5) // unchanged
        XCTAssertTrue(first.contains { $0.knob == .committedCapU && $0.outcome == .insideDeadband })
        // The baseline did not advance, so the movement is still available next time.
        XCTAssertEqual(store.baseline[.committedCapU]!, 1.0, accuracy: 1E-9)
    }

    func testOffsetKnobsMustRepeatBeforeTheyAreWritten() {
        let store = Store()
        store.run(suggestion(aggression: 1.0))
        let held = store.run(suggestion(aggression: 0.92))
        XCTAssertTrue(held.contains { $0.knob == .aggression && $0.outcome == .awaitingConfirmation })
        XCTAssertEqual(store.value[.aggression], 1.0) // not yet written
        let written = store.run(suggestion(aggression: 0.92))
        XCTAssertTrue(written.contains { $0.knob == .aggression && $0.outcome == .redriven })
        XCTAssertEqual(store.value[.aggression]!, 0.92, accuracy: 1E-9)
    }

    func testAFlappingOffsetKnobIsNeverWritten() {
        // The confirmation has to be consecutive, or a knob alternating either side of a threshold
        // accumulates a match across the gap and eventually writes the flap.
        let store = Store()
        store.run(suggestion(aggression: 1.0))
        store.run(suggestion(aggression: 0.92)) // held
        store.run(suggestion(aggression: 1.0)) // back again, clears the pending value
        store.run(suggestion(aggression: 0.92)) // held once more, not written
        XCTAssertEqual(store.value[.aggression], 1.0)
    }

    func testARaiseIsHeldWhileTimeBelowRangeIsHigh() {
        let store = Store()
        store.run(suggestion(committedCapU: 1.0))
        let out = store.run(suggestion(committedCapU: 1.5), tbr70: 9.0)
        XCTAssertTrue(out.contains { $0.knob == .committedCapU && $0.outcome == .suggestedNotAppliedTbr })
        XCTAssertEqual(store.value[.committedCapU], 0.5)
    }

    func testATighteningIsNeverHeldByTheRaiseGuard() {
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.run(suggestion(committedCapU: 1.0))
        store.run(suggestion(committedCapU: 0.6), tbr70: 9.0)
        XCTAssertLessThan(store.value[.committedCapU]!, 1.0)
    }

    func testAClippedStepKeepsItsRemainderAndConverges() {
        // The case that motivated the 2026-08-04 fix: diluting U200 insulin to U100 roughly doubles
        // the dose in units, so the derived cap doubles in a single step. Under the old logic the
        // cap moved a quarter once, advanced its baseline to the doubled value, saw no further
        // movement and sat about 40% below where it belonged.
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.run(suggestion(committedCapU: 1.0))
        var seen: [Double] = []
        for _ in 0 ..< 6 {
            store.run(suggestion(committedCapU: 2.0))
            seen.append(store.value[.committedCapU]!)
        }
        XCTAssertEqual(seen[0], 1.25, accuracy: 0.01)
        XCTAssertEqual(seen[1], 1.56, accuracy: 0.01)
        XCTAssertEqual(seen[2], 1.95, accuracy: 0.01)
        // It settles within the knob's own deadband of the target rather than exactly on it, which
        // is what the design promises: the last step is below the measured noise floor.
        XCTAssertEqual(seen.last!, 2.0, accuracy: Apply.redriveDeadband[.committedCapU]!)
    }

    func testOneStepIsBoundedToAQuarter() {
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.run(suggestion(committedCapU: 1.0))
        store.run(suggestion(committedCapU: 10.0))
        XCTAssertEqual(store.value[.committedCapU]!, 1.25, accuracy: 1E-9)
    }

    func testThePrimerCeilingFollowsTheCommittedCap() {
        let store = Store()
        store.value[.committedCapU] = 1.0
        store.value[.primerCapU] = 0.6
        store.run(suggestion(committedCapU: 1.0, primerCapU: 0.6)) // baselines
        store.run(suggestion(committedCapU: 1.2, primerCapU: 0.72))
        // The cap moved to 1.2, so the ceiling follows at the same fraction of it.
        XCTAssertEqual(store.value[.primerCapU]!, store.value[.committedCapU]! * 0.6, accuracy: 0.01)
    }

    func testTheCumulativeCapFollowsTheOperativeCapsNotTheDerivation() {
        let store = Store()
        store.value[.confirmedCapU] = 2.0 // the user's own, below the derived 4.65
        store.run(suggestion(confirmedCapU: 4.65))
        // 2.0 + 2 x 0.5 = 3.0, sized from what actually governs dosing.
        XCTAssertEqual(store.value[.cumulativeSmbCap60Min]!, 3.0, accuracy: 1E-9)
    }
}
