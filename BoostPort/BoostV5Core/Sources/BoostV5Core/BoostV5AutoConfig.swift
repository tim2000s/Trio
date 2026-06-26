import Foundation

/// Boost V5 auto-configuration — derive sensible initial V5 knobs from the user's own recent dosing
/// history (default: last 14 days) the first time they switch to Boost V5.
///
/// Faithful Swift port of the AAPS `BoostV5AutoConfig` (Kotlin). Algorithm-agnostic: it reads dosing
/// + glycaemia (TDD, bolus/SMB sizes, TBR, maxIOB/maxBolus), so it works equally for a Boost-V1 user
/// (AAPS) or a **standard oref** user (Trio) — the prior engine doesn't matter. PURE: the host
/// gathers the inputs and applies + logs the result. Suggestion-only — the caller writes a knob only
/// if the user hasn't already set it, and surfaces what it set.
///
/// Conservative by design: never auto-RAISE aggression above neutral; safety knobs (HypoCaution,
/// caps) bound rather than embolden; proven maxIOB/bolus carried over; aggression refines once shadow
/// data exists.
public enum BoostV5AutoConfig {
    public static let minDays = 7
    public static let minBgReadings = 1500 // ~7 days of 5-min CGM minus gaps
    private static let tbr70Target = 4.0 // % time <70 mg/dL
    private static let sev54Target = 1.0 // % time <54 mg/dL

    /// What the host gathers from the user's last-N-day history (any prior engine).
    public struct PriorDosing: Sendable {
        public let daysWithData: Int
        public let bgReadingCount: Int
        public let tddMedianU: Double
        public let manualBolusesU: [Double] // NORMAL (meal/manual) boluses
        public let smbAmountsU: [Double] // SMB micro-boluses
        public let tbrBelow70Pct: Double
        public let timeBelow54Pct: Double
        public let meanGlucoseMgdl: Double
        public let currentMaxIobU: Double
        public let currentMaxBolusU: Double

        public init(
            daysWithData: Int, bgReadingCount: Int, tddMedianU: Double,
            manualBolusesU: [Double], smbAmountsU: [Double],
            tbrBelow70Pct: Double, timeBelow54Pct: Double, meanGlucoseMgdl: Double,
            currentMaxIobU: Double, currentMaxBolusU: Double
        ) {
            self.daysWithData = daysWithData
            self.bgReadingCount = bgReadingCount
            self.tddMedianU = tddMedianU
            self.manualBolusesU = manualBolusesU
            self.smbAmountsU = smbAmountsU
            self.tbrBelow70Pct = tbrBelow70Pct
            self.timeBelow54Pct = timeBelow54Pct
            self.meanGlucoseMgdl = meanGlucoseMgdl
            self.currentMaxIobU = currentMaxIobU
            self.currentMaxBolusU = currentMaxBolusU
        }
    }

    /// Suggested V5 knobs (each clamped to its preference range) + human-readable reasons.
    public struct Suggestion: Sendable, Equatable {
        public let aggression: Double
        public let hypoCaution: Double
        public let confirmedCapU: Double
        public let committedCapU: Double
        public let maxIobU: Double
        public let bolusCapU: Double
        public let fastCarbConfirm: Bool
        public let rationale: [String]
    }

    /// Returns nil when there isn't enough data to responsibly auto-configure.
    public static func compute(_ p: PriorDosing) -> Suggestion? {
        guard p.daysWithData >= minDays, p.bgReadingCount >= minBgReadings else { return nil }

        var reasons: [String] = []
        let hypoProne = p.timeBelow54Pct > 1.5 || p.tbrBelow70Pct > 6.0

        // HypoCaution [1.0..2.0]
        let cautionRaw = 1.0
            + max(0.0, p.tbrBelow70Pct - tbr70Target) / 4.0
            + max(0.0, p.timeBelow54Pct - sev54Target) * 0.5
        let hypoCaution = round1(min(max(cautionRaw, 1.0), 2.0))
        reasons
            .append("HypoCaution \(hypoCaution) (TBR<70 \(pct(p.tbrBelow70Pct)), <54 \(pct(p.timeBelow54Pct)) vs targets 4%/1%)")

        // Aggression [0.7..1.3] — never auto-raised above 1.0
        let aggression = round2(
            (p.timeBelow54Pct > 1.5 || p.tbrBelow70Pct > 6.0) ? 0.85
                : (p.tbrBelow70Pct > tbr70Target) ? 0.92
                : 1.0
        )
        reasons
            .append(
                "Aggression \(aggression) (\(aggression < 1.0 ? "gentle — hypo history" : "neutral"); refines after shadow period)"
            )

        // Confirmed cap [1.5..7.5]
        let confirmedCapU = round2(min(max(max(percentile(p.manualBolusesU, 90), percentile(p.smbAmountsU, 95)), 1.5), 7.5))
        reasons.append("Confirmed cap \(confirmedCapU)U (≈ your biggest typical single dose)")

        // Committed cap [0.25..2.5]
        let committedCapU = round2(min(max(max(percentile(p.smbAmountsU, 75), p.tddMedianU / 40.0), 0.25), 2.5))
        reasons.append("Committed cap \(committedCapU)U (≈ your routine SMB size)")

        let maxIobU = round1(min(max(p.currentMaxIobU, 0.1), 12.0))
        let bolusCapU = round1(min(max(p.currentMaxBolusU, 0.1), 10.0))
        reasons.append("maxIOB \(maxIobU)U / bolus cap \(bolusCapU)U carried from your settings")

        let fastCarbConfirm = !hypoProne
        if hypoProne { reasons.append("Fast-carb confirm OFF (cautious start — notable hypo history)") }

        return Suggestion(
            aggression: aggression, hypoCaution: hypoCaution,
            confirmedCapU: confirmedCapU, committedCapU: committedCapU,
            maxIobU: maxIobU, bolusCapU: bolusCapU,
            fastCarbConfirm: fastCarbConfirm, rationale: reasons
        )
    }

    /// Linear-interpolated percentile (0..100) of positive values; 0.0 if empty.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        let v = values.filter { $0.isFinite && $0 > 0 }.sorted()
        if v.isEmpty { return 0.0 }
        if v.count == 1 { return v[0] }
        let rank = (p / 100.0) * Double(v.count - 1)
        let lo = Int(rank)
        let hi = min(lo + 1, v.count - 1)
        return v[lo] + (v[hi] - v[lo]) * (rank - Double(lo))
    }

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
    private static func pct(_ x: Double) -> String { "\((x * 10).rounded() / 10)%" }
}
