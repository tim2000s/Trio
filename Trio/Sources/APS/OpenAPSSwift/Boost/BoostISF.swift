import Foundation

/// Boost-flavoured Dynamic ISF (V1), the Trio-side glue over the pure `DynIsf` core
/// (BoostV5Core). Produces the single adjusted `sens` value that threads through the
/// determination — predictions, eventualBG, insulinReq — where stock oref uses
/// `sens / sensitivityRatio`. Faithful to AAPS `calculateBoostIsf` (V1 only; V2 excluded):
///   sensNormalTarget = useTdd ? 1800/(TDD·ln(normalTarget/divisor+1)) : profileSens
///   sensNormalTarget *= 100/profilePercent          (profile-% inverse ISF scaling)
///   variableSens = sensNormalTarget·(1 − (1−scaler)·velocity)  at current BG (soft cap)
///   × circadian (optional)
///
/// IMPORTANT: oref autosens is intentionally NOT applied here — Boost DynISF replaces
/// autosens. (AAPS Boost applies no oref autosens to ISF; it uses its own TDD model.)
///
/// FLAGGED: the exact Boost weighted-8h TDD blend (1.4·4h + 0.6·8-4h …, pull-down) is NOT
/// reproduced — Trio exposes only a single blended TDD (weightedAverage/currentTDD), not the
/// 4h/8-4h/7d/1d splits. `tdd` here is Trio's blended TDD × the adjustment factor. Exact-blend
/// fidelity needs new TDD-window plumbing (see DynIsf.blendedTdd, currently unused).
enum BoostISF {
    /// `profilePercent` = the activity profile % (100 = none); applied as 100/profilePercent.
    static func adjustedSensitivity(
        profileSens: Decimal,
        currentGlucose: Decimal,
        tdd: Decimal,
        profilePercent: Double,
        hourOfDay: Int,
        profile: Profile,
        preferences: Preferences
    ) -> Decimal {
        let divisor = insulinDivisor(profile: profile, preferences: preferences)
        let normalTarget = dbl(preferences.boostDynIsfNormalTarget)
        let bgCap = dbl(preferences.boostDynIsfBgCap)
        let velocity = dbl(preferences.boostDynIsfVelocity) / 100.0
        let adjFactor = dbl(preferences.boostDynIsfAdjustmentFactor) // percent
        let bg = dbl(currentGlucose)
        let tddValue = dbl(tdd)
        let globalScale = profilePercent > 0 ? 100.0 / profilePercent : 1.0

        var sensNormalTarget: Double
        if preferences.boostUseTdd, tddValue > 0 {
            let tddAdjusted = tddValue * adjFactor / 100.0
            sensNormalTarget = DynIsf.isfTargetV1(
                tdd: tddAdjusted,
                normalTarget: normalTarget,
                insulinDivisor: divisor
            )
        } else {
            sensNormalTarget = dbl(profileSens)
        }
        // Profile-% inverse scaling (AAPS globalScale): active 80% → ISF ×1.25 (more sensitive).
        sensNormalTarget *= globalScale

        var variableSens = DynIsf.getIsfByProfile(
            bg: bg,
            normalTarget: normalTarget,
            insulinDivisor: divisor,
            sensNormalTarget: sensNormalTarget,
            velocity: velocity,
            bgCap: bgCap,
            useCap: true
        )

        // Circadian ISF overlay (AAPS applies it to variable_sens when enabled).
        if preferences.boostEnableCircadianIsf {
            variableSens *= CircadianISF.sensitivity(hourOfDay: hourOfDay)
        }

        // No autosens division — Boost DynISF replaces oref autosens.
        return Decimal(variableSens).jsRounded(scale: 1)
    }

    /// Per-BG ISF for the prediction loops, faithful to AAPS `getIsfByProfile(bg, profile, true)`.
    /// Recomputes the velocity-blended ISF at the given predicted BG (with the soft cap).
    static func isfByProfile(
        bg: Double,
        sensNormalTarget: Double,
        profile: Profile,
        preferences: Preferences,
        useCap: Bool
    ) -> Double {
        DynIsf.getIsfByProfile(
            bg: bg,
            normalTarget: dbl(preferences.boostDynIsfNormalTarget),
            insulinDivisor: insulinDivisor(profile: profile, preferences: preferences),
            sensNormalTarget: sensNormalTarget,
            velocity: dbl(preferences.boostDynIsfVelocity) / 100.0,
            bgCap: dbl(preferences.boostDynIsfBgCap),
            useCap: useCap
        )
    }

    /// `sensNormalTarget` (ISF at normal target) for a given context — needed by the prediction
    /// loops so they can recompute per-BG ISF without re-deriving it each tick.
    static func sensNormalTarget(
        profileSens: Decimal,
        tdd: Decimal,
        profilePercent: Double,
        profile: Profile,
        preferences: Preferences
    ) -> Double {
        let divisor = insulinDivisor(profile: profile, preferences: preferences)
        let globalScale = profilePercent > 0 ? 100.0 / profilePercent : 1.0
        let tddValue = dbl(tdd)
        var sens: Double
        if preferences.boostUseTdd, tddValue > 0 {
            let tddAdjusted = tddValue * dbl(preferences.boostDynIsfAdjustmentFactor) / 100.0
            sens = DynIsf.isfTargetV1(
                tdd: tddAdjusted,
                normalTarget: dbl(preferences.boostDynIsfNormalTarget),
                insulinDivisor: divisor
            )
        } else {
            sens = dbl(profileSens)
        }
        return sens * globalScale
    }

    /// AAPS Boost insulin divisor: peak (coerced 30–75) → (90−peak)+30 if peak<60 else +40.
    static func insulinDivisor(profile: Profile, preferences: Preferences) -> Double {
        let peakRaw = preferences.useCustomPeakTime ? dbl(profile.insulinPeakTime) : curveDefaultPeak(profile.curve)
        let peak = min(max(peakRaw, 30.0), 75.0)
        return peak < 60.0 ? (90.0 - peak) + 30.0 : (90.0 - peak) + 40.0
    }

    private static func curveDefaultPeak(_ curve: InsulinCurve) -> Double {
        switch curve {
        case .ultraRapid: return 55.0
        case .rapidActing: return 75.0
        default: return 75.0 // bilinear
        }
    }

    private static func dbl(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }
}
