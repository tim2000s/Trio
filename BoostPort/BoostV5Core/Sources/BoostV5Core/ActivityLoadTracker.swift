import Foundation

/// Boost activity-load SHADOW tracker — pure Swift port of
/// `DailyStepHistoryTracker` from AAPS
/// (`plugins/aps/.../openAPSBoost/DailyStepHistoryTracker.kt`, 2026-06-16/19).
///
/// Rolling per-day step history (single-source) → personal baseline (median) →
/// deviation-based shadow factors:
///   - **activity-load** (recent volume ABOVE baseline) → would-RAISE ISF (more
///     sensitive), front-loaded over ~24–48h (yesterday 1.0, day-before 0.5).
///   - **inactivity** (recent volume BELOW baseline) → would-LOWER ISF. Smaller +
///     more conservative because add-insulin is the unsafe direction.
///
/// SHADOW ONLY: nothing here applies a factor to dosing. Constants, caps, weights,
/// the median rule, and the diurnal curve match the Kotlin source exactly.
public enum ActivityLoadTracker {
    /// Constants ported verbatim from `DailyStepHistoryTracker`.
    public enum Const {
        /// Rolling history window in days (`WINDOW_DAYS`).
        public static let windowDays = 28
        /// Cold-start guard — no factor until this many qualifying days exist (`MIN_DAYS_FOR_BASELINE`).
        public static let minDaysForBaseline = 7
        /// Cap on would-raise-ISF at extreme excess (`ACTIVITY_MAX_ISF_PCT`).
        public static let activityMaxIsfPct = 15.0
        /// Cap on would-lower-ISF — smaller, add-insulin (unsafe) direction (`INACTIVITY_MAX_ISF_PCT`).
        public static let inactivityMaxIsfPct = 8.0
        /// Ratio ≥ this saturates the activity factor — 2× baseline (`ACTIVITY_RATIO_FULL`).
        public static let activityRatioFull = 2.0
        /// Ratio ≤ this saturates the inactivity factor — ≤40% baseline; the floor (`INACTIVITY_RATIO_FULL`).
        public static let inactivityRatioFull = 0.4
        /// Days excluded from the most-recent end of the baseline window (`excludeRecent` default).
        public static let baselineExcludeRecent = 2
        /// Decay weight applied to yesterday's completed day in the recent-load blend.
        public static let recentWeightYesterday = 1.0
        /// Decay weight applied to the day-before-yesterday in the recent-load blend.
        public static let recentWeightDayBefore = 0.5

        /// Fraction of a day's steps typically completed by the END of each local
        /// hour (`DIURNAL_FRACTION`, index = hour 0..23). Generic curve; not
        /// personalised in v1. ~0 overnight, rising through the day.
        public static let diurnalFraction: [Double] = [
            0.00, 0.00, 0.00, 0.00, 0.00, 0.01, 0.03, 0.07, 0.13, 0.20, 0.28, 0.36,
            0.44, 0.52, 0.59, 0.66, 0.73, 0.80, 0.86, 0.91, 0.95, 0.98, 0.99, 1.00
        ]
        /// Minimum diurnal fraction floor applied before dividing (Kotlin `coerceAtLeast(0.02)`).
        public static let diurnalFractionFloor = 0.02
    }

    /// One completed local day's step total from the chosen single source.
    /// Mirrors `DailyStepHistoryTracker.DailyTotal`.
    public struct DailyStepTotal: Codable, Equatable, Sendable {
        public var dayIndex: Int
        public var steps: Int
        public var source: String

        public init(dayIndex: Int, steps: Int, source: String) {
            self.dayIndex = dayIndex
            self.steps = steps
            self.source = source
        }
    }

    /// Rolling per-day step history. Mirrors `DailyStepHistoryTracker.History`
    /// (a day-indexed map; here held as a sorted-by-dayIndex array for value semantics).
    public struct StepHistory: Codable, Equatable, Sendable {
        public var days: [DailyStepTotal]

        public init(days: [DailyStepTotal] = []) {
            self.days = days
        }

        /// Steps for a given completed-day index, or nil.
        public func steps(forDay dayIndex: Int) -> Int? {
            days.first { $0.dayIndex == dayIndex }?.steps
        }
    }

    /// Shadow-factor result. Mirrors `DailyStepHistoryTracker.ShadowFactors`
    /// (without the human-readable `note`). All fields nil when cold-start /
    /// insufficient history.
    public struct ActivityLoadResult: Equatable, Sendable {
        /// Median baseline daily steps (nil until `minDaysForBaseline` qualifying days).
        public var baselineSteps: Double?
        /// Decay-weighted recent load (nil if no baseline / no yesterday).
        public var recentLoad: Double?
        /// recentLoad ÷ baseline (nil if no baseline).
        public var ratio: Double?
        /// Signed delta: + = raise ISF (activity), − = lower ISF (inactivity); nil if no data.
        public var wouldDeltaIsfPct: Double?

        public init(
            baselineSteps: Double? = nil,
            recentLoad: Double? = nil,
            ratio: Double? = nil,
            wouldDeltaIsfPct: Double? = nil
        ) {
            self.baselineSteps = baselineSteps
            self.recentLoad = recentLoad
            self.ratio = ratio
            self.wouldDeltaIsfPct = wouldDeltaIsfPct
        }
    }

    // MARK: - Record / trim

    /// Records one completed day's total and trims to the rolling window.
    /// Mirrors `merge(...)` for a single total: a same-`dayIndex` entry is
    /// replaced; entries older than `todayIndex - windowDays` are dropped, where
    /// `todayIndex` is taken as `day.dayIndex + 1` (the recorded day is the most
    /// recent completed day). Returns a new `StepHistory`.
    public static func record(
        _ h: StepHistory,
        day: DailyStepTotal,
        windowDays: Int = Const.windowDays
    ) -> StepHistory {
        var map: [Int: DailyStepTotal] = [:]
        for d in h.days { map[d.dayIndex] = d }
        map[day.dayIndex] = day

        // Trim: keep the most recent `windowDays` completed days. The newest day
        // present (max dayIndex) anchors the window; today = newest + 1.
        let newest = map.keys.max() ?? day.dayIndex
        let todayIndex = newest + 1
        let cutoff = todayIndex - windowDays
        let kept = map.values
            .filter { $0.dayIndex >= cutoff }
            .sorted { $0.dayIndex < $1.dayIndex }
        return StepHistory(days: kept)
    }

    // MARK: - Baseline

    /// Median daily steps over completed days, EXCLUDING the most recent
    /// `excludeRecent` days (default 2). Mirrors Kotlin `baseline(...)`:
    /// filter `dayIndex < todayIndex - excludeRecent`, sort, require
    /// `>= minDaysForBaseline` values, return `vals[vals.count / 2]` (the
    /// lower-of-middle element — NOT an averaged median). Returns nil otherwise.
    public static func baseline(
        _ h: StepHistory,
        todayIndex: Int,
        excludeRecent: Int = Const.baselineExcludeRecent
    ) -> Double? {
        let vals = h.days
            .filter { $0.dayIndex < todayIndex - excludeRecent }
            .map(\.steps)
            .sorted()
        if vals.count < Const.minDaysForBaseline { return nil }
        return Double(vals[vals.count / 2])
    }

    // MARK: - Shadow factor

    /// Shadow factor for `todayIndex` from the completed days before it.
    /// Mirrors Kotlin `shadowFactors(...)`:
    ///   - baseline = median (see `baseline`); if nil/≤0 or yesterday missing → all-nil result.
    ///   - recent load = `(y*1.0 + y2*0.5) / 1.5`, where missing y/y2 fall back to baseline.
    ///   - ratio = recentLoad / baseline.
    ///   - ratio ≥ 1: `+activityMaxIsfPct * clamp((ratio-1)/(2-1), 0, 1)`.
    ///   - ratio < 1: `-inactivityMaxIsfPct * clamp((1-ratio)/(1-0.4), 0, 1)`.
    public static func compute(_ h: StepHistory, todayIndex: Int) -> ActivityLoadResult {
        let base = baseline(h, todayIndex: todayIndex)
        let last = h.steps(forDay: todayIndex - 1)
        guard let base, base > 0, last != nil else {
            // Insufficient history: baseline reported if present, rest nil.
            return ActivityLoadResult(baselineSteps: base)
        }

        let y = Double(h.steps(forDay: todayIndex - 1) ?? Int(base))
        let y2 = Double(h.steps(forDay: todayIndex - 2) ?? Int(base))
        let weightedLoad = (y * Const.recentWeightYesterday + y2 * Const.recentWeightDayBefore)
            / (Const.recentWeightYesterday + Const.recentWeightDayBefore)
        let ratio = weightedLoad / base

        let pct: Double
        if ratio >= 1.0 {
            let f = clamp01((ratio - 1.0) / (Const.activityRatioFull - 1.0))
            pct = Const.activityMaxIsfPct * f
        } else {
            let f = clamp01((1.0 - ratio) / (1.0 - Const.inactivityRatioFull))
            pct = -Const.inactivityMaxIsfPct * f
        }

        return ActivityLoadResult(
            baselineSteps: base,
            recentLoad: weightedLoad,
            ratio: ratio,
            wouldDeltaIsfPct: pct
        )
    }

    // MARK: - Intraday (raise-only)

    /// Intraday "running hot?" factor: today's cumulative `stepsToday` vs
    /// expected-by-now (`baseline × diurnalFraction(hour)`). RAISE-ONLY, capped at
    /// `activityMaxIsfPct`; below-pace returns 0.0 (the next-day factor owns the
    /// lower-activity direction). Nil/≤0 baseline → nil (no factor).
    /// Mirrors Kotlin `intradayFactor(...)`'s `wouldDeltaIsfPct`.
    ///
    /// `diurnalFraction` defaults to the ported `Const.diurnalFraction` curve;
    /// callers may inject an alternative for testing/personalisation.
    public static func intradayLoad(
        stepsToday: Int,
        baseline: Double?,
        hourOfDay: Int,
        diurnalFraction: (Int) -> Double = { Const.diurnalFraction[min(max($0, 0), 23)] }
    ) -> Double? {
        guard let baseline, baseline > 0 else { return nil }
        let frac = max(diurnalFraction(min(max(hourOfDay, 0), 23)), Const.diurnalFractionFloor)
        let expected = baseline * frac
        let ratio = Double(stepsToday) / expected
        let f = clamp01((ratio - 1.0) / (Const.activityRatioFull - 1.0))
        return Const.activityMaxIsfPct * f
    }

    // MARK: - Multi-source history + scaled bridging (2026-06-28)

    // Keeps a SEPARATE daily history per step source so that when the user's primary device changes,
    // the old source's days BRIDGE the new source's empty window — rolling-window coverage is never
    // lost to a device switch (no warmup reset). Cross-source absolute-count differences are
    // reconciled by overlap calibration so the deviation ratio stays honest (an Apple Watch logging
    // ~14k/day and an iPhone logging ~9k/day for the same activity must not read as a 36% drop).
    // `StepSourceResolver` owns today's-count selection. Port of the Kotlin additions.

    /// Days where two sources both recorded, required before an overlap calibration is trusted.
    public static let minOverlapDays = 3

    /// Per-source daily histories, keyed by canonical source id (see `StepSourceResolver.canonical`).
    public struct MultiSourceHistory: Codable, Equatable, Sendable {
        public var sources: [String: StepHistory]
        public init(sources: [String: StepHistory] = [:]) { self.sources = sources }
    }

    /// Merge completed-day `totals` into a source's own history within the window. Today
    /// (`dayIndex >= todayIndex`) is excluded as partial. Mirrors Kotlin `merge(...)`.
    public static func merge(
        _ h: StepHistory,
        totals: [DailyStepTotal],
        todayIndex: Int,
        windowDays: Int = Const.windowDays
    ) -> StepHistory {
        var map: [Int: DailyStepTotal] = [:]
        for d in h.days { map[d.dayIndex] = d }
        for t in totals where t.dayIndex >= (todayIndex - windowDays) && t.dayIndex < todayIndex {
            map[t.dayIndex] = t
        }
        let cutoff = todayIndex - windowDays
        let kept = map.values.filter { $0.dayIndex >= cutoff }.sorted { $0.dayIndex < $1.dayIndex }
        return StepHistory(days: kept)
    }

    /// Merge completed-day `totals` into `source`'s own history within `multi`; prunes empty sources.
    public static func mergeSource(
        _ multi: MultiSourceHistory,
        source: String,
        totals: [DailyStepTotal],
        todayIndex: Int
    ) -> MultiSourceHistory {
        let src = StepSourceResolver.canonical(source)
        var sources = multi.sources
        let canonTotals = totals.map { DailyStepTotal(dayIndex: $0.dayIndex, steps: $0.steps, source: src) }
        sources[src] = merge(sources[src] ?? StepHistory(), totals: canonTotals, todayIndex: todayIndex)
        sources = sources.filter { !$0.value.days.isEmpty }
        return MultiSourceHistory(sources: sources)
    }

    /// Factor to express `donor`'s counts in `active`'s units: median over days where BOTH recorded of
    /// (active.steps / donor.steps). Nil when fewer than `minOverlapDays` overlapping days exist.
    public static func calibration(active: StepHistory, donor: StepHistory) -> Double? {
        var ratios: [Double] = []
        for a in active.days {
            if let d = donor.steps(forDay: a.dayIndex), a.steps > 0, d > 0 {
                ratios.append(Double(a.steps) / Double(d))
            }
        }
        if ratios.count < minOverlapDays { return nil }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    public struct BridgeResult: Equatable, Sendable {
        public var history: StepHistory
        public var calibrated: Bool
        public var donorsUsed: [String]
    }

    /// Build one rolling-window history in `activeSource`'s units for `todayIndex`: use the active
    /// source's value for each day it has, else borrow the highest-trust OTHER source's day scaled
    /// into active units. Guarantees coverage across a device switch. `calibrated` is false if any
    /// borrowed donor lacked enough overlap to scale (those days used raw). Mirrors Kotlin `bridgedWindow`.
    public static func bridgedWindow(
        _ multi: MultiSourceHistory,
        activeSource: String?,
        todayIndex: Int,
        windowDays: Int = Const.windowDays
    ) -> BridgeResult {
        let activeKey = activeSource.map { StepSourceResolver.canonical($0) }
        let active = activeKey.flatMap { multi.sources[$0] } ?? StepHistory()
        let donors = multi.sources
            .filter { $0.key != activeKey }
            .sorted { StepSourceResolver.tier($0.key) < StepSourceResolver.tier($1.key) }

        var out: [Int: DailyStepTotal] = [:]
        for d in active.days { out[d.dayIndex] = d }
        var cals: [String: Double?] = [:]
        var donorsUsed: [String] = []
        var anyUncalibrated = false

        for day in (todayIndex - windowDays) ..< todayIndex where out[day] == nil {
            for donor in donors {
                guard let dt = donor.value.steps(forDay: day) else { continue }
                let cal: Double?
                if cals.keys.contains(donor.key) {
                    cal = cals[donor.key]!
                } else {
                    cal = calibration(active: active, donor: donor.value)
                    cals[donor.key] = cal
                }
                let scaled: Int
                if let cal {
                    scaled = Int(Double(dt) * cal)
                } else {
                    anyUncalibrated = true
                    scaled = dt
                }
                out[day] = DailyStepTotal(dayIndex: day, steps: scaled, source: donor.key)
                if !donorsUsed.contains(donor.key) { donorsUsed.append(donor.key) }
                break
            }
        }

        let hist = StepHistory(days: out.values.sorted { $0.dayIndex < $1.dayIndex })
        return BridgeResult(history: hist, calibrated: !anyUncalibrated, donorsUsed: donorsUsed)
    }

    /// PHONE-ANCHORED rolling window (2026-07-02, mirrors AAPS `phoneAnchoredWindow`) — the correct
    /// frame when watches are SWAPPED, not stacked. `bridgedWindow` calibrated the old source directly
    /// against the new one, but a watch swap means the two never share a day (one ceases as the next
    /// starts) → zero overlap → no scale → raw forever. The iPhone runs continuously across every watch
    /// era, so it is the one source that overlaps them all: it is the calibration frame.
    ///
    /// Per day in the window:
    ///  1. if a worn source (appleWatch > garmin > …) recorded the day AND can be scaled into phone
    ///     units (≥ `minOverlapDays` of phone↔that-source overlap), use the scaled worn value
    ///     (worn-when-carried beats phone-when-pocketed for accuracy);
    ///  2. else use the phone's own value for the day (the phone has every day it was carried);
    ///  3. else (phone lacks the day and the worn source can't be scaled yet — the phone's warmup
    ///     window) fall back to the worn value raw, flagged uncalibrated. Self-heals once the phone
    ///     accrues `minOverlapDays` overlapping days with each worn source.
    ///
    /// No watch-to-watch calibration is ever needed, so a future swap can never re-open the gap.
    public static func phoneAnchoredWindow(
        _ multi: MultiSourceHistory,
        todayIndex: Int,
        windowDays: Int = Const.windowDays
    ) -> BridgeResult {
        let phone = multi.sources[StepSourceResolver.iphone] ?? StepHistory()
        var phoneDays: [Int: DailyStepTotal] = [:]
        for d in phone.days { phoneDays[d.dayIndex] = d }
        let donors = multi.sources
            .filter { $0.key != StepSourceResolver.iphone }
            .sorted { StepSourceResolver.tier($0.key) < StepSourceResolver.tier($1.key) }

        var out: [Int: DailyStepTotal] = [:]
        var cals: [String: Double?] = [:] // phone/donor scale, memoised
        var donorsUsed: [String] = []
        var anyUncalibrated = false

        for day in (todayIndex - windowDays) ..< todayIndex {
            let phoneDay = phoneDays[day]
            // highest-trust worn source that recorded this day (whether or not it scales)
            let worn = donors.first { $0.value.steps(forDay: day) != nil }
            if let worn {
                let raw = worn.value.steps(forDay: day)!
                let cal: Double?
                if cals.keys.contains(worn.key) {
                    cal = cals[worn.key]!
                } else {
                    cal = calibration(active: phone, donor: worn.value) // median(phone/worn)
                    cals[worn.key] = cal
                }
                if let cal {
                    out[day] = DailyStepTotal(dayIndex: day, steps: Int(Double(raw) * cal), source: worn.key)
                    if !donorsUsed.contains(worn.key) { donorsUsed.append(worn.key) }
                } else if let phoneDay {
                    out[day] = phoneDay // can't scale → phone's own day
                } else {
                    out[day] = DailyStepTotal(dayIndex: day, steps: raw, source: worn.key)
                    if !donorsUsed.contains(worn.key) { donorsUsed.append(worn.key) }
                    anyUncalibrated = true
                }
            } else if let phoneDay {
                out[day] = phoneDay
            }
        }

        let hist = StepHistory(days: out.values.sorted { $0.dayIndex < $1.dayIndex })
        return BridgeResult(history: hist, calibrated: !anyUncalibrated, donorsUsed: donorsUsed)
    }

    /// Express `steps` reported by `activeSource` in PHONE-equivalent units, so today's live count
    /// matches the phone-anchored baseline. Phone/unknown/no-overlap → returned unchanged; a worn
    /// source with enough phone overlap → scaled by median(phone/worn). (2026-07-02, AAPS `toPhoneUnits`.)
    public static func toPhoneUnits(steps: Int, activeSource: String?, multi: MultiSourceHistory) -> Int {
        guard let activeSource else { return steps }
        let src = StepSourceResolver.canonical(activeSource)
        if src == StepSourceResolver.iphone { return steps }
        guard let phone = multi.sources[StepSourceResolver.iphone] else { return steps }
        guard let srcHist = multi.sources[src] else { return steps }
        guard let cal = calibration(active: phone, donor: srcHist) else { return steps }
        return Int(Double(steps) * cal)
    }

    // MARK: - Helpers

    /// Matches Kotlin `coerceIn(0.0, 1.0)`.
    private static func clamp01(_ v: Double) -> Double {
        min(max(v, 0.0), 1.0)
    }
}
