import Foundation

struct Preferences: JSON, Equatable {
    var maxIOB: Decimal = 0
    var maxDailySafetyMultiplier: Decimal = 3
    var currentBasalSafetyMultiplier: Decimal = 4
    var autosensMax: Decimal = 1.2
    var autosensMin: Decimal = 0.7
    var smbDeliveryRatio: Decimal = 0.5
    var rewindResetsAutosens: Bool = true
    var highTemptargetRaisesSensitivity: Bool = false
    var lowTemptargetLowersSensitivity: Bool = false
    var sensitivityRaisesTarget: Bool = false
    var resistanceLowersTarget: Bool = false
    var advTargetAdjustments: Bool = false
    var exerciseMode: Bool = false
    var halfBasalExerciseTarget: Decimal = 160
    var maxCOB: Decimal = 120
    var maxMealAbsorptionTime: Decimal = 6
    var wideBGTargetRange: Bool = false
    var skipNeutralTemps: Bool = false
    var unsuspendIfNoTemp: Bool = false
    var min5mCarbimpact: Decimal = 8
    var remainingCarbsFraction: Decimal = 1.0
    var remainingCarbsCap: Decimal = 90
    var enableUAM: Bool = false
    var a52RiskEnable: Bool = false
    var enableSMBWithCOB: Bool = false
    var enableSMBWithTemptarget: Bool = false
    var enableSMBAlways: Bool = false
    var enableSMBAfterCarbs: Bool = false
    var allowSMBWithHighTemptarget: Bool = false
    var maxSMBBasalMinutes: Decimal = 30
    var maxUAMSMBBasalMinutes: Decimal = 30
    var smbInterval: Decimal = 3
    var bolusIncrement: Decimal = 0.1
    var curve: InsulinCurve = .rapidActing
    var useCustomPeakTime: Bool = false
    var insulinPeakTime: Decimal = 75
    var carbsReqThreshold: Decimal = 1.0
    var noisyCGMTargetMultiplier: Decimal = 1.3
    var suspendZerosIOB: Bool = true
    var timestamp: Date?
    var maxDeltaBGthreshold: Decimal = 0.2
    var adjustmentFactor: Decimal = 0.8
    var adjustmentFactorSigmoid: Decimal = 0.5
    var sigmoid: Bool = false
    var useNewFormula: Bool = false
    var useWeightedAverage: Bool = false
    var weightPercentage: Decimal = 0.35
    var tddAdjBasal: Bool = false
    var enableSMB_high_bg: Bool = false
    var enableSMB_high_bg_target: Decimal = 110
    var threshold_setting: Decimal = 60
    var updateInterval: Decimal = 20
    var boostMode: BoostMode = .off
    // Boost DynISF (V1) — used to compute a Boost-flavoured ISF in active mode. Defaults match AAPS.
    var boostUseTdd: Bool = false
    var boostDynIsfNormalTarget: Decimal = 99
    var boostDynIsfBgCap: Decimal = 210
    var boostDynIsfVelocity: Decimal = 100 // percent
    var boostDynIsfAdjustmentFactor: Decimal = 100 // percent
    var boostEnableCircadianIsf: Bool = false
    // V5 tuning knobs (ranges match AAPS).
    var boostV5Aggression: Decimal = 1.0 // 0.7…1.3 — scales CONFIRMED dose
    var boostV5HypoCaution: Decimal = 1.0 // 1.0…2.0 — deepens ML hypo damping
    var boostV5Sensitivity: Decimal = 1.0 // 0.8…1.2 — budget lever
    var boostV5ConfirmedCapU: Decimal = 2.5 // 0…7.5 U
    var boostV5CommittedCapU: Decimal = 0.5 // 0…2.5 U
    var boostV5FastCarbConfirm: Bool = true
    // Internal one-shot flag: set true once the V5 knobs have been auto-configured from the user's
    // prior (oref) dosing history on first switch to boostMode == .active. Not user-facing.
    var boostV5AutoConfigDone: Bool = false
    // Night mode (suppresses SMB overnight). Defaults match AAPS.
    var boostNightModeEnabled: Bool = false
    var boostNightModeStartHour: Decimal = 22
    var boostNightModeEndHour: Decimal = 7
    var boostNightModeBgOffset: Decimal = 27 // mg/dL
    var boostNightModeDisableWithCob: Bool = false
    var boostNightModeDisableWithLowTt: Bool = false
    var boostNightModeAutoBySleep: Bool = false
    // V6 anticipatory pre-meal target.
    var boostV6PreMealEnabled: Bool = false
    var boostV6PreMealTargetMgdl: Decimal = 72
    var boostV6PreMealLeadMin: Decimal = 60
    // Activity / HR / post-exercise (feed BoostActivityMonitor). Defaults match AAPS.
    var boostActivitySteps5: Decimal = 420
    var boostActivitySteps15: Decimal = 800
    var boostActivitySteps30: Decimal = 1200
    var boostActivitySteps60: Decimal = 1800
    var boostActivityPct: Decimal = 80
    var boostInactivitySteps: Decimal = 500
    var boostInactivityPct: Decimal = 130
    var boostHrIntegrationEnabled: Bool = false
    var boostHrMaxBpm: Decimal = 180
    var boostHrRestingBpm: Decimal = 60
    var boostHrStressDetection: Bool = false
    var boostPostExerciseEnabled: Bool = false
    var boostPostExerciseHours: Decimal = 2
    var boostPostExerciseTarget: Decimal = 144
    var boostPostExerciseScale: Decimal = 0.5
    var boostPostExerciseMinDuration: Decimal = 10
}

extension Preferences {
    private enum CodingKeys: String, CodingKey {
        case maxIOB = "max_iob"
        case maxDailySafetyMultiplier = "max_daily_safety_multiplier"
        case currentBasalSafetyMultiplier = "current_basal_safety_multiplier"
        case autosensMax = "autosens_max"
        case autosensMin = "autosens_min"
        case smbDeliveryRatio = "smb_delivery_ratio"
        case rewindResetsAutosens = "rewind_resets_autosens"
        case highTemptargetRaisesSensitivity = "high_temptarget_raises_sensitivity"
        case lowTemptargetLowersSensitivity = "low_temptarget_lowers_sensitivity"
        case sensitivityRaisesTarget = "sensitivity_raises_target"
        case resistanceLowersTarget = "resistance_lowers_target"
        case advTargetAdjustments = "adv_target_adjustments"
        case exerciseMode = "exercise_mode"
        case halfBasalExerciseTarget = "half_basal_exercise_target"
        case maxCOB
        case maxMealAbsorptionTime
        case wideBGTargetRange = "wide_bg_target_range"
        case skipNeutralTemps = "skip_neutral_temps"
        case unsuspendIfNoTemp = "unsuspend_if_no_temp"
        case min5mCarbimpact = "min_5m_carbimpact"
        case remainingCarbsFraction
        case remainingCarbsCap
        case enableUAM
        case a52RiskEnable = "A52_risk_enable"
        case enableSMBWithCOB = "enableSMB_with_COB"
        case enableSMBWithTemptarget = "enableSMB_with_temptarget"
        case enableSMBAlways = "enableSMB_always"
        case enableSMBAfterCarbs = "enableSMB_after_carbs"
        case allowSMBWithHighTemptarget = "allowSMB_with_high_temptarget"
        case maxSMBBasalMinutes
        case maxUAMSMBBasalMinutes
        case smbInterval = "SMBInterval"
        case bolusIncrement = "bolus_increment"
        case curve
        case useCustomPeakTime
        case insulinPeakTime
        case carbsReqThreshold
        case noisyCGMTargetMultiplier
        case suspendZerosIOB = "suspend_zeros_iob"
        case maxDeltaBGthreshold = "maxDelta_bg_threshold"
        case adjustmentFactor
        case adjustmentFactorSigmoid
        case sigmoid
        case useNewFormula
        case useWeightedAverage
        case weightPercentage
        case tddAdjBasal
        case enableSMB_high_bg
        case enableSMB_high_bg_target
        case threshold_setting
        case updateInterval
        case boostMode
        case boostUseTdd
        case boostDynIsfNormalTarget
        case boostDynIsfBgCap
        case boostDynIsfVelocity
        case boostDynIsfAdjustmentFactor
        case boostEnableCircadianIsf
        case boostV5Aggression
        case boostV5HypoCaution
        case boostV5Sensitivity
        case boostV5ConfirmedCapU
        case boostV5CommittedCapU
        case boostV5FastCarbConfirm
        case boostV5AutoConfigDone
        case boostNightModeEnabled
        case boostNightModeStartHour
        case boostNightModeEndHour
        case boostNightModeBgOffset
        case boostNightModeDisableWithCob
        case boostNightModeDisableWithLowTt
        case boostNightModeAutoBySleep
        case boostV6PreMealEnabled
        case boostV6PreMealTargetMgdl
        case boostV6PreMealLeadMin
        case boostActivitySteps5
        case boostActivitySteps15
        case boostActivitySteps30
        case boostActivitySteps60
        case boostActivityPct
        case boostInactivitySteps
        case boostInactivityPct
        case boostHrIntegrationEnabled
        case boostHrMaxBpm
        case boostHrRestingBpm
        case boostHrStressDetection
        case boostPostExerciseEnabled
        case boostPostExerciseHours
        case boostPostExerciseTarget
        case boostPostExerciseScale
        case boostPostExerciseMinDuration
    }
}

enum InsulinCurve: String, JSON, Identifiable, CaseIterable {
    case rapidActing = "rapid-acting"
    case ultraRapid = "ultra-rapid"
    case bilinear

    var id: InsulinCurve { self }
}

extension Preferences: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var preferences = Preferences()

        if let maxIOB = try? container.decode(Decimal.self, forKey: .maxIOB) {
            preferences.maxIOB = maxIOB
        }

        if let maxDailySafetyMultiplier = try? container.decode(Decimal.self, forKey: .maxDailySafetyMultiplier) {
            preferences.maxDailySafetyMultiplier = maxDailySafetyMultiplier
        }

        if let currentBasalSafetyMultiplier = try? container.decode(Decimal.self, forKey: .currentBasalSafetyMultiplier) {
            preferences.currentBasalSafetyMultiplier = currentBasalSafetyMultiplier
        }

        if let autosensMax = try? container.decode(Decimal.self, forKey: .autosensMax) {
            preferences.autosensMax = autosensMax
        }

        if let autosensMin = try? container.decode(Decimal.self, forKey: .autosensMin) {
            preferences.autosensMin = autosensMin
        }

        if let smbDeliveryRatio = try? container.decode(Decimal.self, forKey: .smbDeliveryRatio) {
            preferences.smbDeliveryRatio = smbDeliveryRatio
        }

        if let rewindResetsAutosens = try? container.decode(Bool.self, forKey: .rewindResetsAutosens) {
            preferences.rewindResetsAutosens = rewindResetsAutosens
        }

        if let highTemptargetRaisesSensitivity = try? container.decode(Bool.self, forKey: .highTemptargetRaisesSensitivity) {
            preferences.highTemptargetRaisesSensitivity = highTemptargetRaisesSensitivity
        }

        if let lowTemptargetLowersSensitivity = try? container.decode(Bool.self, forKey: .lowTemptargetLowersSensitivity) {
            preferences.lowTemptargetLowersSensitivity = lowTemptargetLowersSensitivity
        }

        if let sensitivityRaisesTarget = try? container.decode(Bool.self, forKey: .sensitivityRaisesTarget) {
            preferences.sensitivityRaisesTarget = sensitivityRaisesTarget
        }

        if let resistanceLowersTarget = try? container.decode(Bool.self, forKey: .resistanceLowersTarget) {
            preferences.resistanceLowersTarget = resistanceLowersTarget
        }

        if let advTargetAdjustments = try? container.decode(Bool.self, forKey: .advTargetAdjustments) {
            preferences.advTargetAdjustments = advTargetAdjustments
        }

        if let exerciseMode = try? container.decode(Bool.self, forKey: .exerciseMode) {
            preferences.exerciseMode = exerciseMode
        }

        if let halfBasalExerciseTarget = try? container.decode(Decimal.self, forKey: .halfBasalExerciseTarget) {
            preferences.halfBasalExerciseTarget = halfBasalExerciseTarget
        }

        if let maxCOB = try? container.decode(Decimal.self, forKey: .maxCOB) {
            preferences.maxCOB = maxCOB
        }

        if let maxMealAbsorptionTime = try? container.decode(Decimal.self, forKey: .maxMealAbsorptionTime) {
            preferences.maxMealAbsorptionTime = maxMealAbsorptionTime
        }

        if let wideBGTargetRange = try? container.decode(Bool.self, forKey: .wideBGTargetRange) {
            preferences.wideBGTargetRange = wideBGTargetRange
        }

        if let skipNeutralTemps = try? container.decode(Bool.self, forKey: .skipNeutralTemps) {
            preferences.skipNeutralTemps = skipNeutralTemps
        }

        if let unsuspendIfNoTemp = try? container.decode(Bool.self, forKey: .unsuspendIfNoTemp) {
            preferences.unsuspendIfNoTemp = unsuspendIfNoTemp
        }

        if let min5mCarbimpact = try? container.decode(Decimal.self, forKey: .min5mCarbimpact) {
            preferences.min5mCarbimpact = min5mCarbimpact
        }

        if let remainingCarbsFraction = try? container.decode(Decimal.self, forKey: .remainingCarbsFraction) {
            preferences.remainingCarbsFraction = remainingCarbsFraction
        }

        if let remainingCarbsCap = try? container.decode(Decimal.self, forKey: .remainingCarbsCap) {
            preferences.remainingCarbsCap = remainingCarbsCap
        }

        if let enableUAM = try? container.decode(Bool.self, forKey: .enableUAM) {
            preferences.enableUAM = enableUAM
        }

        if let a52RiskEnable = try? container.decode(Bool.self, forKey: .a52RiskEnable) {
            preferences.a52RiskEnable = a52RiskEnable
        }

        if let enableSMBWithCOB = try? container.decode(Bool.self, forKey: .enableSMBWithCOB) {
            preferences.enableSMBWithCOB = enableSMBWithCOB
        }

        if let enableSMBWithTemptarget = try? container.decode(Bool.self, forKey: .enableSMBWithTemptarget) {
            preferences.enableSMBWithTemptarget = enableSMBWithTemptarget
        }

        if let enableSMBAlways = try? container.decode(Bool.self, forKey: .enableSMBAlways) {
            preferences.enableSMBAlways = enableSMBAlways
        }

        if let enableSMBAfterCarbs = try? container.decode(Bool.self, forKey: .enableSMBAfterCarbs) {
            preferences.enableSMBAfterCarbs = enableSMBAfterCarbs
        }

        if let allowSMBWithHighTemptarget = try? container.decode(Bool.self, forKey: .allowSMBWithHighTemptarget) {
            preferences.allowSMBWithHighTemptarget = allowSMBWithHighTemptarget
        }

        if let maxSMBBasalMinutes = try? container.decode(Decimal.self, forKey: .maxSMBBasalMinutes) {
            preferences.maxSMBBasalMinutes = maxSMBBasalMinutes
        }

        if let maxUAMSMBBasalMinutes = try? container.decode(Decimal.self, forKey: .maxUAMSMBBasalMinutes) {
            preferences.maxUAMSMBBasalMinutes = maxUAMSMBBasalMinutes
        }

        if let smbInterval = try? container.decode(Decimal.self, forKey: .smbInterval) {
            preferences.smbInterval = smbInterval
        }

        if let bolusIncrement = try? container.decode(Decimal.self, forKey: .bolusIncrement) {
            preferences.bolusIncrement = bolusIncrement > 0 ? bolusIncrement : 0.1
        }

        if let curve = try? container.decode(InsulinCurve.self, forKey: .curve) {
            preferences.curve = curve
        }

        if let useCustomPeakTime = try? container.decode(Bool.self, forKey: .useCustomPeakTime) {
            preferences.useCustomPeakTime = useCustomPeakTime
        }

        if let insulinPeakTime = try? container.decode(Decimal.self, forKey: .insulinPeakTime) {
            preferences.insulinPeakTime = insulinPeakTime
        }

        if let carbsReqThreshold = try? container.decode(Decimal.self, forKey: .carbsReqThreshold) {
            preferences.carbsReqThreshold = carbsReqThreshold
        }

        if let noisyCGMTargetMultiplier = try? container.decode(Decimal.self, forKey: .noisyCGMTargetMultiplier) {
            preferences.noisyCGMTargetMultiplier = noisyCGMTargetMultiplier
        }

        if let suspendZerosIOB = try? container.decode(Bool.self, forKey: .suspendZerosIOB) {
            preferences.suspendZerosIOB = suspendZerosIOB
        }

        if let maxDeltaBGthreshold = try? container.decode(Decimal.self, forKey: .maxDeltaBGthreshold) {
            preferences.maxDeltaBGthreshold = maxDeltaBGthreshold
        }

        if let adjustmentFactor = try? container.decode(Decimal.self, forKey: .adjustmentFactor) {
            preferences.adjustmentFactor = adjustmentFactor
        }

        if let adjustmentFactorSigmoid = try? container.decode(Decimal.self, forKey: .adjustmentFactorSigmoid) {
            preferences.adjustmentFactorSigmoid = adjustmentFactorSigmoid
        }

        if let sigmoid = try? container.decode(Bool.self, forKey: .sigmoid) {
            preferences.sigmoid = sigmoid
        }

        if let useNewFormula = try? container.decode(Bool.self, forKey: .useNewFormula) {
            preferences.useNewFormula = useNewFormula
        }

        if let useWeightedAverage = try? container.decode(Bool.self, forKey: .useWeightedAverage) {
            preferences.useWeightedAverage = useWeightedAverage
        }

        if let weightPercentage = try? container.decode(Decimal.self, forKey: .weightPercentage) {
            preferences.weightPercentage = weightPercentage
        }

        if let tddAdjBasal = try? container.decode(Bool.self, forKey: .tddAdjBasal) {
            preferences.tddAdjBasal = tddAdjBasal
        }

        if let enableSMB_high_bg = try? container.decode(Bool.self, forKey: .enableSMB_high_bg) {
            preferences.enableSMB_high_bg = enableSMB_high_bg
        }

        if let enableSMB_high_bg_target = try? container.decode(Decimal.self, forKey: .enableSMB_high_bg_target) {
            preferences.enableSMB_high_bg_target = enableSMB_high_bg_target
        }

        if let threshold_setting = try? container.decode(Decimal.self, forKey: .threshold_setting) {
            preferences.threshold_setting = threshold_setting
        }

        if let updateInterval = try? container.decode(Decimal.self, forKey: .updateInterval) {
            preferences.updateInterval = updateInterval
        }

        if let boostMode = try? container.decode(BoostMode.self, forKey: .boostMode) {
            preferences.boostMode = boostMode
        }

        if let boostUseTdd = try? container.decode(Bool.self, forKey: .boostUseTdd) {
            preferences.boostUseTdd = boostUseTdd
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfNormalTarget) {
            preferences.boostDynIsfNormalTarget = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfBgCap) {
            preferences.boostDynIsfBgCap = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfVelocity) {
            preferences.boostDynIsfVelocity = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostDynIsfAdjustmentFactor) {
            preferences.boostDynIsfAdjustmentFactor = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostEnableCircadianIsf) {
            preferences.boostEnableCircadianIsf = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5Aggression) {
            preferences.boostV5Aggression = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5HypoCaution) {
            preferences.boostV5HypoCaution = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5Sensitivity) {
            preferences.boostV5Sensitivity = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5ConfirmedCapU) {
            preferences.boostV5ConfirmedCapU = v
        }

        if let v = try? container.decode(Decimal.self, forKey: .boostV5CommittedCapU) {
            preferences.boostV5CommittedCapU = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostV5FastCarbConfirm) {
            preferences.boostV5FastCarbConfirm = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostV5AutoConfigDone) {
            preferences.boostV5AutoConfigDone = v
        }

        if let v = try? container.decode(Bool.self, forKey: .boostNightModeEnabled) {
            preferences.boostNightModeEnabled = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostNightModeStartHour) {
            preferences.boostNightModeStartHour = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostNightModeEndHour) {
            preferences.boostNightModeEndHour = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostNightModeBgOffset) {
            preferences.boostNightModeBgOffset = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostNightModeDisableWithCob) {
            preferences.boostNightModeDisableWithCob = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostNightModeDisableWithLowTt) {
            preferences.boostNightModeDisableWithLowTt = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostNightModeAutoBySleep) {
            preferences.boostNightModeAutoBySleep = v
        }
        if let v = try? container.decode(Bool.self, forKey: .boostV6PreMealEnabled) {
            preferences.boostV6PreMealEnabled = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostV6PreMealTargetMgdl) {
            preferences.boostV6PreMealTargetMgdl = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostV6PreMealLeadMin) {
            preferences.boostV6PreMealLeadMin = v
        }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps5) { preferences.boostActivitySteps5 = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps15) { preferences.boostActivitySteps15 = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps30) { preferences.boostActivitySteps30 = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivitySteps60) { preferences.boostActivitySteps60 = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostActivityPct) { preferences.boostActivityPct = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostInactivitySteps) { preferences.boostInactivitySteps = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostInactivityPct) { preferences.boostInactivityPct = v }
        if let v = try? container
            .decode(Bool.self, forKey: .boostHrIntegrationEnabled) { preferences.boostHrIntegrationEnabled = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostHrMaxBpm) { preferences.boostHrMaxBpm = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostHrRestingBpm) { preferences.boostHrRestingBpm = v }
        if let v = try? container.decode(Bool.self, forKey: .boostHrStressDetection) { preferences.boostHrStressDetection = v }
        if let v = try? container
            .decode(Bool.self, forKey: .boostPostExerciseEnabled) { preferences.boostPostExerciseEnabled = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostPostExerciseHours) { preferences.boostPostExerciseHours = v }
        if let v = try? container
            .decode(Decimal.self, forKey: .boostPostExerciseTarget) { preferences.boostPostExerciseTarget = v }
        if let v = try? container.decode(Decimal.self, forKey: .boostPostExerciseScale) { preferences.boostPostExerciseScale = v }
        if let v = try? container
            .decode(Decimal.self, forKey: .boostPostExerciseMinDuration) { preferences.boostPostExerciseMinDuration = v }

        self = preferences
    }
}
