import Foundation

/// The knobs Boost auto-config manages, each with a per-knob resolution mark persisted by the host
/// (`Preferences.boostV5AutoConfigResolved`, raw values of this enum). Mirrors the AAPS managed-key
/// list (b2c0705e5e) minus maxIOB/maxBolus, which Trio deliberately does NOT manage: the suggestion
/// merely carries the user's own existing values over, so writing them back would be an identity
/// write.
public enum BoostAutoConfigKnob: String, CaseIterable, Sendable {
    case aggression
    case hypoCaution
    case confirmedCapU
    case committedCapU
    case cumulativeSmbCap60Min
    case fastCarbConfirm

    /// The double-valued knobs `applyAutoConfig` resolves (stable order). `fastCarbConfirm` is a
    /// boolean and is handled separately by the host (as in the AAPS plugin).
    public static let doubleKnobs: [BoostAutoConfigKnob] = [
        .aggression, .hypoCaution, .confirmedCapU, .committedCapU, .cumulativeSmbCap60Min
    ]
}

/// Pure helpers for applying a `BoostV5AutoConfig.Suggestion` to preferences while respecting any
/// value the user (or an imported preset) has ALREADY tuned. Mirrors AAPS `BoostV5AutoConfigApply`
/// (b2c0705e5e + the fe9d8a1a13 amendments + the 131923247e versioned re-migration).
///
/// ── Per-knob resolution (2026-07 fix, field evidence: Roman on AAPS) ─────────────────────────
/// The original design used one global "did run" flag (`boostV5AutoConfigDone` in Trio's
/// Preferences). Failure mode: once the flag was consumed (older build, or carried in via a
/// settings import), the whole run — including knobs ADDED to auto-config later — was suppressed
/// for good. The fix: each managed knob is tracked individually as RESOLVED once it has either
/// been applied once or been skipped because the user tuned it; both mark it resolved.
/// Insufficient data resolves nothing, so unresolved knobs genuinely retry on later cycles.
///
/// ── 2026-07-06 amendments (7-user migration-cohort backtest, AAPS fe9d8a1a13) ────────────────
///  - Historical factory defaults: the at-factory test must recognise the defaults of EVERY build
///    era, or a user whose prefs persisted an OLD factory value reads as "user-tuned" and is
///    frozen at the tightest-ever values. This problem EXISTS on Trio for the two per-shot caps
///    (defaults raised in 5cf1abb84, 2026-06-26) — see `historicalFactoryDefaults`.
///  - The cumulative 60-min cap is recomputed in `applyAutoConfig` from the FINAL operative
///    per-shot caps (kept-or-derived), not taken verbatim from the derivation.
///  - TBR raise-guard: a dose-cap RAISE is priced badly for a TBR-heavy user, and value==factory
///    cannot distinguish "never touched" from "deliberately reverted to factory". See
///    `tbrRaiseGuardPct`.
///  - Every knob's classification is returned as a `Resolution` with a human-readable reason, so
///    field diagnosis never needs inference.
///
/// Trio note vs AAPS: AAPS's presence-test defect never existed here — Trio's caps carry explicit
/// per-knob `…UserSet` flags (set only when the user moves the slider), which the host ORs into
/// the injected `isUserTuned` predicate ON TOP of the any-era value-vs-factory test.
public enum BoostV5AutoConfigApply {
    /// Tolerance for "still at factory default": preference values round-trip through
    /// Decimal/JSON, so exact Double equality would be fragile. Same epsilon as AAPS (1e-4).
    public static let defaultEps = 1E-4

    /// Max acceptable 14-day time-below-70 (%) for auto-APPLYING a dose-cap RAISE. At or below
    /// this, raises apply as normal; above it they are only *suggested* (surfaced to the user and
    /// the log) and the knob resolves without being written.
    ///
    /// Backtest evidence (7-user migration cohort, 2026-07-06, AAPS fe9d8a1a13 — cohort user B,
    /// TBR<70 4.26%): the insulin his raised caps would have added priced at 44.7% delivered
    /// within 3 h of a <70 mg/dL reading, vs 32.8% for his baseline dosing — a raise is exactly
    /// the wrong medicine for a TBR-heavy user. LOWERINGS and non-cap tightenings (HypoCaution,
    /// Aggression ≤ 1.0, FastCarbConfirm OFF, the cumulative cap when it tightens) always apply.
    /// 4.0% is the international consensus TBR<70 target the derivation already uses.
    public static let tbrRaiseGuardPct = 4.0

    /// Severe-hypo co-guard on the same raise-guard (2026-07-07, AAPS 13c9bc4d53): a dose-cap RAISE
    /// is also held (suggested-not-applied) when 14-day time-below-54 is at or above this. 1.0% is
    /// the international consensus <54 target the derivation already uses (`sev54Target`). Catches
    /// the user-B pattern the <70-only guard missed: TBR<70 3.83% (under the 4.0% line) but <54
    /// 1.01% (over the severe line) — severe exposure is the stronger contraindication for a raise,
    /// and a user can sit under the <70 gate while over the <54 one. Same suggested-not-applied
    /// path as `tbrRaiseGuardPct`; lowerings and non-cap tightenings still always apply.
    public static let tbr54RaiseGuardPct = 1.0

    /// Every factory default each managed knob has EVER shipped with on Trio, beyond the current
    /// one. Verified from git history of Trio/Sources/Models/Preferences.swift (2026-07-06,
    /// `git log --all -p -G'var boost…'`):
    ///  - boostV5ConfirmedCapU: 1.0 (introduced 01f903a2f, 2026-06-23) → 2.5 (5cf1abb84, 2026-06-26)
    ///  - boostV5CommittedCapU: 0.25 (introduced 01f903a2f) → 0.5 (5cf1abb84)
    ///  - boostCumulativeSmbCap60Min: introduced at 10.0 (724d15cd5) and never changed — no eras.
    /// The other managed knobs (Aggression 1.0, HypoCaution 1.0, FastCarbConfirm true) have never
    /// changed default. A stored value matching ANY of these (±`defaultEps`) is at-factory, i.e.
    /// derivable — without this, a user whose old build persisted an old factory value reads as
    /// "user-tuned" and is frozen at the tightest-ever caps (AAPS cohort users C/D; the same
    /// 06-23→06-26 window exists on Trio). (AAPS fe9d8a1a13 amendment #1.)
    private static let historicalFactoryDefaults: [BoostAutoConfigKnob: [Double]] = [
        .confirmedCapU: [1.0],
        .committedCapU: [0.25]
    ]

    /// Current + historical factory defaults for `knob` (current first). The current default is
    /// injected by the host (it lives in Trio's `Preferences`, which this package cannot see).
    public static func factoryDefaults(_ knob: BoostAutoConfigKnob, currentDefault: Double) -> [Double] {
        [currentDefault] + (historicalFactoryDefaults[knob] ?? [])
    }

    /// "User (or preset) has tuned this knob" (value test): a stored value exists AND it differs
    /// from every factory default the knob has ever shipped with. A value persisted AT any-era
    /// factory default (settings import, settings-screen visit, an old build's default) does NOT
    /// count as tuned — nobody objected to a default, so a suggestion may still apply. The host
    /// ORs the caps' explicit `…UserSet` flags on top of this.
    public static func isUserTuned(storedValue: Double?, factoryDefaults: [Double]) -> Bool {
        guard let storedValue else { return false }
        return !factoryDefaults.contains { abs(storedValue - $0) <= defaultEps }
    }

    /// The dose-cap knobs subject to the `tbrRaiseGuardPct` raise-guard.
    public static let doseCapKnobs: Set<BoostAutoConfigKnob> = [
        .confirmedCapU, .committedCapU, .cumulativeSmbCap60Min
    ]

    /// How a knob was classified by `applyAutoConfig` this run.
    public enum Outcome: String, Equatable, Sendable {
        case applied
        case keptUserTuned
        case suggestedNotAppliedTbr
    }

    /// Per-knob classification record. `suggestedValue` is the final derived value for the knob
    /// (for the cumulative cap: recomputed from the operative per-shot caps); `operativeValue` is
    /// what governs dosing after this run; `reason` is the human-readable classification the host
    /// logs verbatim so field diagnosis never needs inference.
    public struct Resolution: Equatable, Sendable {
        public let knob: BoostAutoConfigKnob
        public let outcome: Outcome
        public let suggestedValue: Double
        public let operativeValue: Double
        public let reason: String
    }

    /// Apply the suggestion with per-knob resolution. For each double knob, in order:
    ///  - already RESOLVED (applied or skipped in an earlier run) → untouched (no `Resolution`);
    ///  - user-tuned (injected predicate: UserSet flag OR off every-era factory) → kept, marked
    ///    resolved (never revisited);
    ///  - a dose-cap (`doseCapKnobs`) whose derived value would RAISE the operative value while
    ///    the 14-day TBR<70 exceeds `tbrRaiseGuardPct` OR the 14-day time-below-54 is ≥
    ///    `tbr54RaiseGuardPct` → NOT written, marked resolved, returned as
    ///    `.suggestedNotAppliedTbr` so the caller can surface the suggestion;
    ///  - otherwise → suggested value written, marked resolved.
    ///
    /// The cumulative 60-min cap is recomputed HERE from the FINAL operative per-shot caps
    /// (kept-or-derived-or-guard-held), via `BoostV5AutoConfig.cumulativeCap60Min` — never taken
    /// verbatim from the derivation, whose caps may not be the ones that apply.
    ///
    /// Per-knob and independent — presetting one never blocks the others. Pure: the closures
    /// inject the preference I/O so all skip/resolve behaviour is testable without the host.
    /// NOT called when there is insufficient history (the caller gets no suggestion), so
    /// unresolved knobs remain eligible and genuinely retry on a later cycle.
    public static func applyAutoConfig(
        suggestion: BoostV5AutoConfig.Suggestion,
        tbrBelow70Pct: Double,
        timeBelow54Pct: Double = 0.0,
        isResolved: (BoostAutoConfigKnob) -> Bool,
        storedValue: (BoostAutoConfigKnob) -> Double?,
        currentDefault: (BoostAutoConfigKnob) -> Double,
        isUserTuned: (BoostAutoConfigKnob) -> Bool,
        put: (BoostAutoConfigKnob, Double) -> Void,
        markResolved: (BoostAutoConfigKnob) -> Void
    ) -> [Resolution] {
        var resolutions: [Resolution] = []
        var operative: [BoostAutoConfigKnob: Double] = [:]
        // Raise-guard trigger: <70 over its line OR <54 at/over the consensus severe line (2026-07-07).
        let raiseGuardTripped = tbrBelow70Pct > Self.tbrRaiseGuardPct || timeBelow54Pct >= Self.tbr54RaiseGuardPct

        func resolve(_ knob: BoostAutoConfigKnob, _ derived: Double) {
            let current = storedValue(knob) ?? currentDefault(knob)
            if isResolved(knob) {
                operative[knob] = current // untouched; feeds the cumulative recompute
                return
            }
            if isUserTuned(knob) {
                markResolved(knob) // user value kept; never revisit
                operative[knob] = current
                resolutions.append(Resolution(
                    knob: knob, outcome: .keptUserTuned, suggestedValue: derived, operativeValue: current,
                    reason: "kept-user-tuned value=\(current) (suggested \(derived))"
                ))
                return
            }
            if doseCapKnobs.contains(knob), derived > current + Self.defaultEps, raiseGuardTripped {
                markResolved(knob) // suggestion surfaced, not written
                operative[knob] = current
                resolutions.append(Resolution(
                    knob: knob, outcome: .suggestedNotAppliedTbr, suggestedValue: derived, operativeValue: current,
                    reason: "suggested-not-applied (TBR): suggested=\(derived) current=\(current) " +
                        "TBR<70=\(tbrBelow70Pct)% (guard >\(Self.tbrRaiseGuardPct)%) " +
                        "<54=\(timeBelow54Pct)% (guard ≥\(Self.tbr54RaiseGuardPct)%)"
                ))
                return
            }
            put(knob, derived)
            markResolved(knob)
            operative[knob] = derived
            resolutions.append(Resolution(
                knob: knob, outcome: .applied, suggestedValue: derived, operativeValue: derived,
                reason: "applied \(derived)"
            ))
        }

        resolve(.aggression, suggestion.aggression)
        resolve(.hypoCaution, suggestion.hypoCaution)
        resolve(.confirmedCapU, suggestion.confirmedCapU)
        resolve(.committedCapU, suggestion.committedCapU)
        // Cumulative cap from the FINAL operative per-shot caps (kept-or-derived), never the
        // derivation's own caps (AAPS cohort user E: budget sized from a derived confirmedCap
        // 4.65 that never applied while his operative cap was 2.0).
        resolve(.cumulativeSmbCap60Min, BoostV5AutoConfig.cumulativeCap60Min(
            confirmedCapU: operative[.confirmedCapU]!,
            committedCapU: operative[.committedCapU]!
        ))
        return resolutions
    }

    /// Auto-config persistence schema version — THE single hook future re-migrations plug into
    /// (extend the `if storedVersion < N` chain in `runSchemaMigrations` and bump this).
    ///
    /// Mirrors AAPS 131923247e (AUTO_CONFIG_SCHEMA_VERSION = 2; version 1 is skipped there so the
    /// number mirrors the amendment generation — Trio keeps the SAME numbering so the platforms'
    /// schema versions stay comparable). Trio judgement (2026-07-06): strictly, no released Trio
    /// build ever persisted era-blind resolved marks — the per-knob resolution and the
    /// historical-factory awareness land together here, so devices upgrading from the released
    /// one-shot-flag era are fully handled by the legacy-flag migration and start at version 2.
    /// The v2 re-audit branch is still implemented because it is free, idempotent, and rescues
    /// anyone who built from source in the brief window where the per-knob resolution existed
    /// WITHOUT historical-factory awareness.
    public static let autoConfigSchemaVersion = 2

    /// Versioned re-migration of persisted per-knob resolution state (see
    /// `autoConfigSchemaVersion`). The pre-amendment persistence shape stores ONLY a resolved mark
    /// per knob with no outcome detail, so applied and kept-user-tuned are indistinguishable — the
    /// audit therefore re-runs the (now historical-factory-aware, UserSet-flag-respecting)
    /// injected `isUserTuned` on every resolved knob and clears the mark when the value is at ANY
    /// era's factory. A knob auto-APPLIED at a factory-coincident value (e.g. Aggression 1.0) gets
    /// re-opened too, which is harmless: re-derivation is suggestion-only and still respects tuned
    /// values.
    ///
    /// Runs at most once per schema bump: no-op (empty result, no version write) when the stored
    /// version is current; otherwise clears + stamps `autoConfigSchemaVersion`. Returns the
    /// re-opened knobs for logging. Pure — the closures inject preference I/O.
    public static func runSchemaMigrations(
        storedVersion: Int,
        knobs: [BoostAutoConfigKnob],
        isResolved: (BoostAutoConfigKnob) -> Bool,
        isUserTuned: (BoostAutoConfigKnob) -> Bool,
        clearResolved: (BoostAutoConfigKnob) -> Void,
        setVersion: (Int) -> Void
    ) -> [BoostAutoConfigKnob] {
        if storedVersion >= autoConfigSchemaVersion { return [] }
        var cleared: [BoostAutoConfigKnob] = []
        if storedVersion < 2 {
            // v2: re-open knobs an era-blind isUserTuned could have mis-resolved at an old
            // factory value.
            let reopened = knobs.filter { isResolved($0) && !isUserTuned($0) }
            reopened.forEach(clearResolved)
            cleared += reopened
        }
        // Future re-migrations: add `if storedVersion < 3 { ... }` here and bump the constant.
        setVersion(autoConfigSchemaVersion)
        return cleared
    }

    /// One-time migration from the legacy global "auto-config done" flag to per-knob resolution.
    /// Called when the legacy flag is found set: marks as resolved ONLY the knobs the host deems
    /// user-tuned (UserSet flag, or off EVERY factory default the knob ever shipped with — they
    /// were plausibly applied by the old run, or user-set; either way they must not be rewritten).
    /// Knobs still AT a factory default (current or any historical era) stay UNRESOLVED and become
    /// eligible for derivation again — this rescues installs where a consumed/imported flag
    /// wrongly suppressed them; suggestion-only still holds because value == default means nobody
    /// objected. Returns the knobs marked resolved. The caller clears the legacy flag afterwards
    /// (migration is one-shot).
    public static func migrateLegacyDoneFlag<Knob>(
        knobs: [Knob],
        isUserTuned: (Knob) -> Bool,
        markResolved: (Knob) -> Void
    ) -> [Knob] {
        let tuned = knobs.filter(isUserTuned)
        tuned.forEach(markResolved)
        return tuned
    }
}
