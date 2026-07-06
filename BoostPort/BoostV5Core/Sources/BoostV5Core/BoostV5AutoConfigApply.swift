import Foundation

/// Pure helpers for applying a `BoostV5AutoConfig.Suggestion` to preferences while respecting any
/// value the user (or an imported preset) has ALREADY tuned. Mirrors AAPS `BoostV5AutoConfigApply`
/// (b2c0705e5e).
///
/// ── Per-knob resolution (2026-07 fix, field evidence: Roman on AAPS) ─────────────────────────
/// The original design used one global "did run" flag (`boostV5AutoConfigDone` in Trio's
/// Preferences). Failure mode: once the flag was consumed (older build, or carried in via a
/// settings import), the whole run — including knobs ADDED to auto-config later — was suppressed
/// for good. The fix: each managed knob is tracked individually as RESOLVED once it has either
/// been applied once or been skipped because the user tuned it; both mark it resolved.
/// Insufficient data resolves nothing, so unresolved knobs genuinely retry on later cycles.
///
/// Trio note vs AAPS: AAPS's second defect — "user tuned" tested by raw key PRESENCE in storage —
/// does not exist here. Trio's caps carry explicit per-knob `…UserSet` flags (set only when the
/// user moves the slider) and the remaining knobs compare value-vs-factory-default, so the host
/// injects its own `isUserTuned` predicate per knob. `isUserTuned(storedValue:defaultValue:)`
/// below is the value-vs-default building block for the knobs without a UserSet flag.
public enum BoostV5AutoConfigApply {
    /// Tolerance for "still at factory default": preference values can round-trip through
    /// Decimal/JSON, so exact Double equality would be fragile. Same epsilon as AAPS (1e-4).
    public static let defaultEps = 1E-4

    /// "User (or preset) has tuned this knob": a stored value exists AND it differs from the
    /// factory default. A value persisted AT the default (settings import, settings-screen visit)
    /// does NOT count as tuned — nobody objected to the default, so a suggestion may still apply.
    public static func isUserTuned(storedValue: Double?, defaultValue: Double) -> Bool {
        guard let storedValue else { return false }
        return abs(storedValue - defaultValue) > defaultEps
    }

    /// Apply the suggestion with per-knob resolution. For each knob, in order:
    ///  - already RESOLVED (applied or skipped in an earlier run) → untouched;
    ///  - user-tuned (`isUserTuned`) → kept, marked resolved (never revisited);
    ///  - otherwise → suggested value written, marked resolved.
    /// Per-knob and independent — tuning one never blocks the others. Returns the knobs actually
    /// written. Pure: the closures inject the preference I/O so all skip/resolve behaviour is
    /// testable without the host.
    ///
    /// NOT called when there is insufficient history (the caller gets no suggestion), so
    /// unresolved knobs remain eligible and genuinely retry on a later cycle.
    public static func applyAutoConfig<Knob: Equatable>(
        knobs: [(knob: Knob, value: Double)],
        isResolved: (Knob) -> Bool,
        isUserTuned: (Knob) -> Bool,
        put: (Knob, Double) -> Void,
        markResolved: (Knob) -> Void
    ) -> [(knob: Knob, value: Double)] {
        var applied: [(knob: Knob, value: Double)] = []
        for (knob, value) in knobs {
            if isResolved(knob) { continue }
            if isUserTuned(knob) {
                markResolved(knob) // user value kept; never revisit
                continue
            }
            put(knob, value)
            markResolved(knob)
            applied.append((knob, value))
        }
        return applied
    }

    /// One-time migration from the legacy global "auto-config done" flag to per-knob resolution.
    /// Called when the legacy flag is found set: marks as resolved ONLY the knobs the host deems
    /// user-tuned / off their factory default (they were plausibly applied by the old run, or
    /// user-set — either way they must not be rewritten). Knobs still AT their factory default
    /// stay UNRESOLVED and become eligible for derivation again — this rescues installs where a
    /// consumed/imported flag wrongly suppressed them; suggestion-only still holds because
    /// value == default means nobody objected. Returns the knobs marked resolved. The caller
    /// clears the legacy flag afterwards (migration is one-shot).
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
