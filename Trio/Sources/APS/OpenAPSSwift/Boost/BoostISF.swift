import Foundation

/// Boost-flavoured Dynamic ISF (V1), the Trio-side glue over the pure `DynIsf` core
/// (BoostV5Core). It produces the single adjusted `sens` value that threads through the
/// whole determination — predictions, eventualBG, insulinReq — exactly where stock oref
/// uses `sens / sensitivityRatio`. Faithful to AAPS `calculateBoostIsf`:
///   sensNormalTarget (TDD-derived when useTdd, else profile sens)
///   → velocity-blended `variableSens` at current BG (with the soft BG cap)
///   → divided by the autosens/TDD sensitivity ratio (stock-oref convention).
///
/// Only used in `.active` mode (see the call site), so shadow/off keep stock dosing.
/// NOTE: numeric calibration vs a given AAPS config (useTdd, velocity, divisor) must be
/// confirmed by shadow comparison before being trusted as an exact replica.
enum BoostISF {
    static func adjustedSensitivity(
        profileSens: Decimal,
        sensitivityRatio: Decimal,
        currentGlucose: Decimal,
        tdd: Decimal,
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
        let sensProfile = dbl(profileSens)

        let sensNormalTarget: Double
        if preferences.boostUseTdd, tddValue > 0 {
            let tddAdjusted = tddValue * adjFactor / 100.0
            sensNormalTarget = DynIsf.isfTargetV1(
                tdd: tddAdjusted,
                normalTarget: normalTarget,
                insulinDivisor: divisor
            )
        } else {
            sensNormalTarget = sensProfile
        }

        let variableSens = DynIsf.getIsfByProfile(
            bg: bg,
            normalTarget: normalTarget,
            insulinDivisor: divisor,
            sensNormalTarget: sensNormalTarget,
            velocity: velocity,
            bgCap: bgCap,
            useCap: true
        )

        // Apply the autosens/TDD ratio the same way stock oref does (sens / ratio),
        // so it composes with Trio's existing sensitivity-ratio pipeline.
        let ratio = dbl(sensitivityRatio)
        let adjusted = (ratio != 0 && ratio != 1.0) ? variableSens / ratio : variableSens
        return Decimal(adjusted).jsRounded(scale: 1)
    }

    /// Mirror DynamicISF's insulin factor: 120 − custom peak, else curve fallback.
    private static func insulinDivisor(profile: Profile, preferences: Preferences) -> Double {
        if preferences.useCustomPeakTime {
            return 120.0 - dbl(profile.insulinPeakTime)
        }
        switch profile.curve {
        case .ultraRapid: return 120.0 - 50.0
        default: return 120.0 - 65.0 // rapidActing + bilinear
        }
    }

    private static func dbl(_ d: Decimal) -> Double { (d as NSDecimalNumber).doubleValue }
}
