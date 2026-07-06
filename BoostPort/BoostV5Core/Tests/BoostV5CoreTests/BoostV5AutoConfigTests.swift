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

    // MARK: - Application of the suggestion (BoostV5AutoConfigApply): per-knob resolution

    //
    // Mirrors AAPS b2c0705e5e / BoostV5AutoConfigTest: tuning one knob must not block the others;
    // each knob resolves (applied once, or skipped-because-user-tuned) exactly once; insufficient
    // data leaves knobs unresolved so they genuinely retry; the legacy global done-flag migrates
    // to per-knob marks (off-default resolved, at-stock re-derivable).

    /// The double knobs the Trio host manages, with their Trio factory defaults.
    private enum Knob: String, CaseIterable {
        case aggression
        case hypoCaution
        case confirmedCapU
        case committedCapU
        case cumulativeSmbCap60Min
        var factoryDefault: Double {
            switch self {
            case .aggression: return 1.0
            case .hypoCaution: return 1.0
            case .confirmedCapU: return 2.5
            case .committedCapU: return 0.5
            case .cumulativeSmbCap60Min: return 10.0
            }
        }
    }

    /// Minimal in-memory stand-in for the host's preference + resolution-mark I/O.
    private final class FakeStore {
        var store: [Knob: Double]
        var resolved = Set<Knob>()
        init(_ preset: [Knob: Double] = [:]) { store = preset }
        func apply(_ knobs: [(knob: Knob, value: Double)]) -> [(knob: Knob, value: Double)] {
            BoostV5AutoConfigApply.applyAutoConfig(
                knobs: knobs,
                isResolved: { self.resolved.contains($0) },
                isUserTuned: { BoostV5AutoConfigApply.isUserTuned(storedValue: self.store[$0], defaultValue: $0.factoryDefault) },
                put: { k, v in self.store[k] = v },
                markResolved: { self.resolved.insert($0) }
            )
        }
    }

    private func knobs(_ s: BoostV5AutoConfig.Suggestion) -> [(knob: Knob, value: Double)] {
        [
            (.aggression, s.aggression), (.hypoCaution, s.hypoCaution),
            (.confirmedCapU, s.confirmedCapU), (.committedCapU, s.committedCapU),
            (.cumulativeSmbCap60Min, s.cumulativeSmbCap60MinU)
        ]
    }

    func testNothingPresetEverythingConfiguredAndResolvedIncludingCumulativeCap() {
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore()
        let applied = f.apply(knobs(s))
        XCTAssertEqual(applied.map(\.knob), knobs(s).map(\.knob))
        XCTAssertEqual(f.resolved, Set(Knob.allCases))
        // The cumulative 60-min SMB cap is derived, WRITTEN, and part of the applied list.
        XCTAssertEqual(f.store[.cumulativeSmbCap60Min], s.cumulativeSmbCap60MinU)
        XCTAssertTrue(applied.contains { $0.knob == .cumulativeSmbCap60Min && $0.value == s.cumulativeSmbCap60MinU })
    }

    func testTuningOneKnobKeepsItAndStillConfiguresTheOthers() {
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore([.cumulativeSmbCap60Min: 2.5]) // user tuned the SMB cap (≠ default 10.0)
        let applied = f.apply(knobs(s))
        let others = Knob.allCases.filter { $0 != .cumulativeSmbCap60Min }
        XCTAssertEqual(Set(applied.map(\.knob)), Set(others))
        XCTAssertTrue(f.resolved.contains(.cumulativeSmbCap60Min)) // tuned → resolved, never revisited
        XCTAssertEqual(f.store[.cumulativeSmbCap60Min], 2.5) // tuned value untouched
        for (k, v) in knobs(s) where k != .cumulativeSmbCap60Min {
            XCTAssertEqual(f.store[k], v)
        }
    }

    func testKnobPersistedAtFactoryDefaultDoesNotBlockSuggestion() {
        // Roman's failure mode with a presence-style test: committedCap existed in storage at the
        // stock 0.5 and was skipped forever. Value == default means nobody objected — the
        // suggestion must still be applied.
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore([.committedCapU: Knob.committedCapU.factoryDefault])
        let applied = f.apply(knobs(s))
        XCTAssertTrue(applied.contains { $0.knob == .committedCapU })
        XCTAssertEqual(f.store[.committedCapU], s.committedCapU)
    }

    func testOnceAppliedKnobIsResolvedAndNeverReapplied() {
        let s = BoostV5AutoConfig.compute(prior())!
        let f = FakeStore()
        _ = f.apply(knobs(s))
        // User later sets a knob back to something — a second (re-derived) run must not touch it.
        f.store[.committedCapU] = 0.33
        let secondKnobs = knobs(s).map { (knob: $0.knob, value: $0.value * 2) }
        let appliedAgain = f.apply(secondKnobs)
        XCTAssertTrue(appliedAgain.isEmpty)
        XCTAssertEqual(f.store[.committedCapU], 0.33)
    }

    func testInsufficientDataResolvesNothingSoKnobsGenuinelyRetry() {
        // The caller gets no suggestion → applyAutoConfig is never invoked → no knob resolves.
        XCTAssertNil(BoostV5AutoConfig.compute(prior(days: 5)))
        let f = FakeStore()
        XCTAssertTrue(f.resolved.isEmpty) // still all eligible
        // Once data accrues, the SAME store applies everything.
        let s = BoostV5AutoConfig.compute(prior())!
        XCTAssertEqual(f.apply(knobs(s)).map(\.knob), knobs(s).map(\.knob))
    }

    // MARK: migration from the legacy global done-flag

    func testLegacyFlagMigrationResolvesOnlyKnobsOffFactoryDefault() {
        let store: [Knob: Double] = [
            .confirmedCapU: 4.0, // user/old-run value ≠ default 2.5
            .committedCapU: Knob.committedCapU.factoryDefault // persisted AT default (Roman)
        ]
        var resolved = Set<Knob>()
        let migrated = BoostV5AutoConfigApply.migrateLegacyDoneFlag(
            knobs: Knob.allCases,
            isUserTuned: { BoostV5AutoConfigApply.isUserTuned(storedValue: store[$0], defaultValue: $0.factoryDefault) },
            markResolved: { resolved.insert($0) }
        )
        XCTAssertEqual(migrated, [.confirmedCapU]) // off-default → left alone forever
        XCTAssertEqual(resolved, [.confirmedCapU])
        XCTAssertFalse(resolved.contains(.committedCapU)) // at-stock stays eligible again
    }

    func testRomanRegressionFlagConsumedKeysAtDefaultsCapsGetApplied() {
        // Roman (AAPS field case): V6-active, months of history, TDD ~50U; committedCap stuck at
        // factory 0.5 although his derived value is 1.24. After migration (nothing resolved
        // because everything is at stock), the next cycle must apply BOTH the committed cap and
        // the cumulative cap.
        let roman = prior(
            tdd: 49.6, // 49.6/40 = 1.24 committed
            manual: [4.0, 5.0, 6.0, 6.0, 6.0], // p90 = 6.0 → confirmedCap 6.0
            smb: [0.5, 0.5, 0.5, 0.5, 0.5] // p75 clipped at the old 0.5 cap
        )
        let s = BoostV5AutoConfig.compute(roman)!
        XCTAssertEqual(s.confirmedCapU, 6.0)
        XCTAssertEqual(s.committedCapU, 1.24)
        // cumulative = clamp(6.0 + 2×1.24, 1.0, max(5.0, 6.0)) = clamp(8.48 → 6.0) = 6.0
        XCTAssertEqual(s.cumulativeSmbCap60MinU, 6.0)

        // Storage as found in the field: managed knobs present at stock after the old run.
        let f = FakeStore([
            .committedCapU: Knob.committedCapU.factoryDefault,
            .cumulativeSmbCap60Min: Knob.cumulativeSmbCap60Min.factoryDefault
        ])
        let migrated = BoostV5AutoConfigApply.migrateLegacyDoneFlag(
            knobs: Knob.allCases,
            isUserTuned: { BoostV5AutoConfigApply.isUserTuned(storedValue: f.store[$0], defaultValue: $0.factoryDefault) },
            markResolved: { f.resolved.insert($0) }
        )
        XCTAssertTrue(migrated.isEmpty) // nothing off-default → all eligible
        let applied = f.apply(knobs(s))
        XCTAssertTrue(applied.contains { $0.knob == .committedCapU })
        XCTAssertTrue(applied.contains { $0.knob == .cumulativeSmbCap60Min })
        XCTAssertEqual(f.store[.committedCapU], 1.24)
        XCTAssertEqual(f.store[.cumulativeSmbCap60Min], 6.0)
        // Invariant: the suggestion never auto-raises Aggression above neutral.
        XCTAssertLessThanOrEqual(s.aggression, 1.0)
    }

    func testUserSetFlagStyleTunedPredicateSkipsAndResolves() {
        // Trio's caps use an explicit UserSet flag rather than value-vs-default; the injected
        // isUserTuned seam must honour it even when the stored value EQUALS the default.
        let s = BoostV5AutoConfig.compute(prior())!
        var resolved = Set<Knob>()
        var written = [Knob: Double]()
        let userSetFlags: Set<Knob> = [.confirmedCapU]
        let applied = BoostV5AutoConfigApply.applyAutoConfig(
            knobs: knobs(s),
            isResolved: { resolved.contains($0) },
            isUserTuned: { userSetFlags.contains($0) }, // flag true although value is at default
            put: { k, v in written[k] = v },
            markResolved: { resolved.insert($0) }
        )
        XCTAssertFalse(applied.contains { $0.knob == .confirmedCapU })
        XCTAssertNil(written[.confirmedCapU])
        XCTAssertTrue(resolved.contains(.confirmedCapU))
        XCTAssertEqual(Set(applied.map(\.knob)), Set(Knob.allCases).subtracting([.confirmedCapU]))
    }
}
