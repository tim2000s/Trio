import Foundation

public enum DynIsf {
    /// Magic numbers, matched exactly to AAPS Boost source.
    public enum Const {
        // ---- TDD blend (OpenAPSBoostPlugin.calculateBoostIsf) ----
        /// Weight applied to the last-4h TDD in the weighted-8h estimate. (1.4 * last4h)
        public static let weight4h: Double = 1.4
        /// Weight applied to the 8h..4h TDD in the weighted-8h estimate. (0.6 * last8to4h)
        public static let weight8to4h: Double = 0.6
        /// Scale-up factor turning the 8h window estimate into a daily-equivalent. (… ) * 3
        public static let weighted8hScale: Double = 3.0
        /// Pull-down trigger: weighted8h < 0.75 * tdd7d.
        public static let pullDownThreshold: Double = 0.75

        /// Blend weight on the weighted-8h component.
        public static let blendWeightWeighted8h: Double = 0.33
        /// Blend weight on the 7d component (or the pulled-down adjusted7d in the pull-down branch).
        public static let blendWeight7d: Double = 0.34
        /// Blend weight on the 1d component.
        public static let blendWeight1d: Double = 0.33

        /// Adjustment-factor clamp (percent), from IntKey.ApsBoostDynIsfAdjustmentFactor.coerceIn(1.0, 300.0).
        public static let adjustmentFactorMinPct: Double = 1.0
        public static let adjustmentFactorMaxPct: Double = 300.0

        // ---- ISF target formula ----
        /// V1: ISF = 1800 / (TDD * ln(normalTarget/insulinDivisor + 1)).
        /// Boost uses V1 only; the V2 `2300/(…·TDD²·0.02)` formula is intentionally NOT ported
        /// (known issues, excluded from Boost).
        public static let isfNumeratorV1: Double = 1800.0

        // ---- Soft bg cap (getIsfByProfile / calculateBoostIsf) ----
        /// Above the cap: bgAdj = cap + (bg - cap) / 3.0.
        public static let softCapDivisor: Double = 3.0
    }

    // MARK: - TDD blend

    /// Blended TDD from the four TDD components, matching `calculateBoostIsf`.
    ///
    /// weighted8h = ((1.4 * last4h) + (0.6 * last8to4h)) * 3
    /// If weighted8h < 0.75 * tdd7d:
    ///   adjusted7d = weighted8h + (weighted8h / tdd7d) * (tdd7d - weighted8h)
    ///   blended    = adjusted7d * 0.34 + tdd1d * 0.33 + weighted8h * 0.33
    /// else:
    ///   blended    = weighted8h * 0.33 + tdd7d * 0.34 + tdd1d * 0.33
    /// final = blended * (clampedAdjustmentPct / 100)
    public static func blendedTdd(
        last4h: Double,
        last8to4h: Double,
        tdd7d: Double,
        tdd1d: Double,
        adjustmentFactorPct: Double
    ) -> Double {
        let weighted8h = ((Const.weight4h * last4h) + (Const.weight8to4h * last8to4h)) * Const.weighted8hScale

        let blended: Double
        if weighted8h < (Const.pullDownThreshold * tdd7d) {
            // Recent usage well below 7d average — pull the 7d average toward recent reality.
            let adjusted7d = weighted8h + ((weighted8h / tdd7d) * (tdd7d - weighted8h))
            blended = (adjusted7d * Const.blendWeight7d)
                + (tdd1d * Const.blendWeight1d)
                + (weighted8h * Const.blendWeightWeighted8h)
        } else {
            blended = (weighted8h * Const.blendWeightWeighted8h)
                + (tdd7d * Const.blendWeight7d)
                + (tdd1d * Const.blendWeight1d)
        }

        let clampedPct = min(max(adjustmentFactorPct, Const.adjustmentFactorMinPct), Const.adjustmentFactorMaxPct)
        return blended * (clampedPct / 100.0)
    }

    // MARK: - ISF target

    /// V1 ISF at normal target: 1800 / (TDD * ln(normalTarget/insulinDivisor + 1)).
    public static func isfTargetV1(
        tdd: Double,
        normalTarget: Double,
        insulinDivisor: Double
    ) -> Double {
        let logTerm = log((normalTarget / insulinDivisor) + 1.0)
        return Const.isfNumeratorV1 / (tdd * logTerm)
    }

    // MARK: - Variable sensitivity

    /// variable_sens = sensNormalTarget * (1 - (1 - scaler) * velocity)
    /// where scaler = ln(normalTarget/insulinDivisor + 1) / ln(bgCapped/insulinDivisor + 1).
    ///
    /// `bgCapped` is the (already soft-capped) BG used in the log; pass the raw BG if no cap applies.
    public static func variableSens(
        sensNormalTarget: Double,
        normalTarget: Double,
        bgCapped: Double,
        insulinDivisor: Double,
        velocity: Double
    ) -> Double {
        let sbg = log((bgCapped / insulinDivisor) + 1.0)
        let scaler = log((normalTarget / insulinDivisor) + 1.0) / sbg
        return sensNormalTarget * (1.0 - (1.0 - scaler) * velocity)
    }

    /// Soft-cap variant matching `DetermineBasalBoost.getIsfByProfile(bg, profile, useCap)`.
    ///
    /// If useCap and bg > bgCap: bgAdj = bgCap + (bg - bgCap) / 3.0.
    /// sensBG = ln(bgAdj/insulinDivisor + 1)
    /// scaler = ln(normalTarget/insulinDivisor + 1) / sensBG
    /// return sensNormalTarget * (1 - (1 - scaler) * velocity)
    public static func getIsfByProfile(
        bg: Double,
        normalTarget: Double,
        insulinDivisor: Double,
        sensNormalTarget: Double,
        velocity: Double,
        bgCap: Double,
        useCap: Bool
    ) -> Double {
        var bgAdj = bg
        if useCap, bgAdj > bgCap {
            bgAdj = bgCap + (bgAdj - bgCap) / Const.softCapDivisor
        }
        let sensBG = log((bgAdj / insulinDivisor) + 1.0)
        let scaler = log((normalTarget / insulinDivisor) + 1.0) / sensBG
        return sensNormalTarget * (1.0 - (1.0 - scaler) * velocity)
    }

    // MARK: - delta acceleration

    /// `delta_accl` exactly as AAPS DetermineBasalBoost (~269): guarded so a near-zero shortAvgDelta
    /// yields 0 (not a spurious 50·delta from the /max(|short|,2) floor), then rounded to 2 dp.
    public static func deltaAccl(delta: Double, shortAvgDelta: Double) -> Double {
        guard abs(shortAvgDelta) > 0.001 else { return 0.0 }
        let raw = 100.0 * (delta - shortAvgDelta) / max(abs(shortAvgDelta), 2.0)
        return (raw * 100.0).rounded() / 100.0
    }

    // MARK: - Dosing sensitivity (future_sens)

    /// Boost `future_sens` (DetermineBasalBoost ~750-787): the BG-context-weighted dosing ISF.
    /// `sensBg` = current BG soft-capped /3, `fsensBg` = eventual BG soft-capped /2; the blend BG is
    /// chosen by condition, then ISF = getIsfByProfile(blend, useCap:false), rounded to 0.1.
    public static func futureSens(
        currentBg: Double,
        eventualBg: Double,
        minPredBg: Double,
        delta: Double,
        shortAvgDelta: Double,
        longAvgDelta: Double,
        deltaAccl: Double,
        cob: Double,
        sensNormalTarget: Double,
        normalTarget: Double,
        insulinDivisor: Double,
        velocity: Double,
        bgCap: Double
    ) -> Double {
        let sensBg = currentBg > bgCap ? bgCap + (currentBg - bgCap) / 3.0 : currentBg
        let fsensBg = eventualBg > bgCap ? bgCap + (eventualBg - bgCap) / 2.0 : eventualBg

        func isf(_ bg: Double) -> Double {
            getIsfByProfile(
                bg: bg, normalTarget: normalTarget, insulinDivisor: insulinDivisor,
                sensNormalTarget: sensNormalTarget, velocity: velocity, bgCap: bgCap, useCap: false
            )
        }

        let value: Double
        if cob > 0, deltaAccl > 0 {
            value = isf(fsensBg * 0.75 + sensBg * 0.25)
        } else if delta > 4, deltaAccl > 10, currentBg < 180, eventualBg > currentBg {
            value = isf(fsensBg * 0.5 + sensBg * 0.5)
        } else if currentBg > 180, abs(delta) < 2, abs(shortAvgDelta) < 2, abs(longAvgDelta) < 2 {
            value = isf(minPredBg * 0.25 + sensBg * 0.75)
        } else if (delta > 0 && deltaAccl > 1) || eventualBg > currentBg {
            value = isf(sensBg)
        } else {
            value = isf(max(minPredBg, 1.0))
        }
        return (value * 10.0).rounded() / 10.0
    }

    // MARK: - Sensitivity ratio selection

    /// Which sensitivity-ratio path `calculateBoostIsf` takes.
    /// - tdd:      useTdd && adjustSens — ratio = clamp(tdd24h / tdd7d, autosensMin, autosensMax).
    /// - autosens: !useTdd — fall back to the oref autosens ratio passed in (no clamp here; oref already clamps).
    /// - legacy:   ratio = 1.0.
    public enum SensitivityRatioMode {
        case tdd
        case autosens
        case legacy
    }

    public static func sensitivityRatio(
        mode: SensitivityRatioMode,
        tdd24h: Double,
        tdd7d: Double,
        autosensRatio: Double,
        autosensMin: Double,
        autosensMax: Double
    ) -> Double {
        switch mode {
        case .tdd:
            // ratio = max(min(tddLast24H / tdd7D, autosensMax), autosensMin)
            return max(min(tdd24h / tdd7d, autosensMax), autosensMin)
        case .autosens:
            return autosensRatio
        case .legacy:
            return 1.0
        }
    }
}
