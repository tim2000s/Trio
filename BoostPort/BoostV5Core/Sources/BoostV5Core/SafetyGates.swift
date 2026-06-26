import Foundation

public enum SafetyGateConstants {
    public static let maxDeltaBgRatioDisable = 0.30
    public static let iobHeadroomThreshold0 = 0.50
    public static let iobHeadroomThreshold1 = 0.70
    public static let iobHeadroomThreshold2 = 0.85
    public static let iobHeadroomScale1 = 0.85
    public static let iobHeadroomScale2 = 0.60
    public static let iobHeadroomScale3 = 0.40
    public static let decelBrakeAcclFull = -15.0
    public static let decelBrakeFloor = 0.30
    public static let decelBrakeVelocityFallback = 8.0
    public static let postActionRiskThreshold = 0.40
    public static let postActionRiskDeltaThreshold = 0.15
    public static let postActionRiskFloor = 0.30
    public static let sensorQualityBadScale = 0.7
    public static let dynamicSpikeCapMultiplier = 2.5
    // Dose-cap fallbacks (only used if the host preference is unset; the Trio adapter normally
    // passes the user's boostV5ConfirmedCapU/CommittedCapU through). 2026-06-26: aligned to the
    // AAPS defaults (2.5 / 0.5) so an unset-preference path can't revert to the old conservative caps.
    public static let maxConfirmedCommitDoseU = 2.5
    public static let maxCommittedDoseU = 0.5
    public static let velocityRiseLoMgdl = 25.0
    public static let velocityRiseHiMgdl = 50.0
    public static let velocityScaleFloor = 0.40
}

public struct Phase3Inputs {
    public var insulinToDeliver: Double
    public var enableSmbPreChecks: Bool
    public var minGuardBg: Double
    public var minGuardThreshold: Double
    public var maxDelta: Double
    public var bg: Double
    public var iob: Double
    public var maxIob: Double
    public var deltaAccl: Double
    public var delta: Double
    public var baseInsulinReq: Double
    public var roundSmbTo: Double
    public var sensorQualityOk: Bool
    public var riskAtProjectedIob: ((Double) -> Double)?
    public var mlHypoRisk: Double?

    public init(
        insulinToDeliver: Double,
        enableSmbPreChecks: Bool,
        minGuardBg: Double,
        minGuardThreshold: Double,
        maxDelta: Double,
        bg: Double,
        iob: Double,
        maxIob: Double,
        deltaAccl: Double,
        delta: Double = 0.0,
        baseInsulinReq: Double,
        roundSmbTo: Double,
        sensorQualityOk: Bool = true,
        riskAtProjectedIob: ((Double) -> Double)? = nil,
        mlHypoRisk: Double? = nil
    ) {
        self.insulinToDeliver = insulinToDeliver
        self.enableSmbPreChecks = enableSmbPreChecks
        self.minGuardBg = minGuardBg
        self.minGuardThreshold = minGuardThreshold
        self.maxDelta = maxDelta
        self.bg = bg
        self.iob = iob
        self.maxIob = maxIob
        self.deltaAccl = deltaAccl
        self.delta = delta
        self.baseInsulinReq = baseInsulinReq
        self.roundSmbTo = roundSmbTo
        self.sensorQualityOk = sensorQualityOk
        self.riskAtProjectedIob = riskAtProjectedIob
        self.mlHypoRisk = mlHypoRisk
    }
}

public struct GateReductions: Equatable, Sendable {
    public var hardGateFired: String?
    public var maxIobClampApplied: Bool
    public var iobHeadroomBrake: Double
    public var postActionRiskCheck: Double
    public var decelerationBrake: Double
    public var sensorQualityCheck: Double
    public var dynamicSpikeCapped: Bool
    public init(
        hardGateFired: String? = nil,
        maxIobClampApplied: Bool = false,
        iobHeadroomBrake: Double = 1.0,
        postActionRiskCheck: Double = 1.0,
        decelerationBrake: Double = 1.0,
        sensorQualityCheck: Double = 1.0,
        dynamicSpikeCapped: Bool = false
    ) {
        self.hardGateFired = hardGateFired
        self.maxIobClampApplied = maxIobClampApplied
        self.iobHeadroomBrake = iobHeadroomBrake
        self.postActionRiskCheck = postActionRiskCheck
        self.decelerationBrake = decelerationBrake
        self.sensorQualityCheck = sensorQualityCheck
        self.dynamicSpikeCapped = dynamicSpikeCapped
    }
}

public struct Phase3Result: Equatable, Sendable {
    public let finalDose: Double
    public let reductions: GateReductions
}

public enum SafetyGates {
    private typealias C = SafetyGateConstants

    public static func applyPhase3(_ input: Phase3Inputs) -> Phase3Result {
        var dose = input.insulinToDeliver

        // HARD gates (binary disable)
        if !input
            .enableSmbPreChecks
        {
            return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "enable_smb_pre_checks")) }
        if input.minGuardBg < input
            .minGuardThreshold { return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "min_guard_bg")) }
        if input.maxDelta > C.maxDeltaBgRatioDisable * input
            .bg { return Phase3Result(finalDose: 0.0, reductions: GateReductions(hardGateFired: "max_delta")) }

        let headroom = max(0.0, input.maxIob - input.iob)
        var maxIobClampApplied = false
        if dose > headroom { dose = headroom
            maxIobClampApplied = true }

        // SOFT gates (ordered)
        let iobBrake = iobHeadroomBrake(input.iob, input.maxIob)
        dose *= iobBrake
        let parScale = postActionRiskCheck(
            dose: dose,
            currentMlHypoRisk: input.mlHypoRisk,
            currentIob: input.iob,
            riskAtProjectedIob: input.riskAtProjectedIob
        )
        dose *= parScale
        let decelScale = decelerationBrake(input.deltaAccl, input.delta)
        dose *= decelScale
        let sensorScale = sensorQualityCheck(input.sensorQualityOk)
        dose *= sensorScale

        // FINAL clamp
        if input.roundSmbTo > 0.0 { dose = floor(dose / input.roundSmbTo + 1E-9) * input.roundSmbTo }
        let spikeCap = dynamicSpikeCap(input.baseInsulinReq)
        var spikeCapped = false
        if dose > spikeCap { dose = spikeCap
            spikeCapped = true }
        dose = max(0.0, dose)

        return Phase3Result(finalDose: dose, reductions: GateReductions(
            hardGateFired: nil, maxIobClampApplied: maxIobClampApplied, iobHeadroomBrake: iobBrake,
            postActionRiskCheck: parScale, decelerationBrake: decelScale, sensorQualityCheck: sensorScale,
            dynamicSpikeCapped: spikeCapped
        ))
    }

    static func iobHeadroomBrake(_ iob: Double, _ maxIob: Double) -> Double {
        if maxIob <= 0.0 { return 1.0 }
        let f = iob / maxIob
        if f < C.iobHeadroomThreshold0 { return 1.0 }
        if f < C.iobHeadroomThreshold1 { return C.iobHeadroomScale1 }
        if f < C.iobHeadroomThreshold2 { return C.iobHeadroomScale2 }
        return C.iobHeadroomScale3
    }

    static func decelerationBrake(_ deltaAccl: Double, _ delta: Double) -> Double {
        if delta > C.decelBrakeVelocityFallback { return 1.0 }
        if deltaAccl >= 0.0 { return 1.0 }
        let frac = min(max((deltaAccl - C.decelBrakeAcclFull) / (0.0 - C.decelBrakeAcclFull), 0.0), 1.0)
        return C.decelBrakeFloor + (1.0 - C.decelBrakeFloor) * frac
    }

    static func postActionRiskCheck(
        dose: Double,
        currentMlHypoRisk: Double?,
        currentIob: Double,
        riskAtProjectedIob: ((Double) -> Double)?
    ) -> Double {
        guard let riskFn = riskAtProjectedIob, let current = currentMlHypoRisk else { return 1.0 }
        let projected = riskFn(currentIob + dose)
        if projected > current + C.postActionRiskDeltaThreshold, projected > C.postActionRiskThreshold {
            let raw = 1.0 - (projected - C.postActionRiskThreshold) / (1.0 - C.postActionRiskThreshold)
            return max(C.postActionRiskFloor, raw)
        }
        return 1.0
    }

    static func sensorQualityCheck(_ ok: Bool) -> Double { ok ? 1.0 : C.sensorQualityBadScale }
    static func dynamicSpikeCap(_ baseInsulinReq: Double) -> Double { C.dynamicSpikeCapMultiplier * baseInsulinReq }

    // Fix-6 velocity scaling + state dose cap
    public static func velocityScaledDoseFactor(_ cumulativeRise30min: Double) -> Double {
        if cumulativeRise30min >= C.velocityRiseHiMgdl { return 1.0 }
        if cumulativeRise30min <= C.velocityRiseLoMgdl { return C.velocityScaleFloor }
        let span = C.velocityRiseHiMgdl - C.velocityRiseLoMgdl
        let frac = (cumulativeRise30min - C.velocityRiseLoMgdl) / span
        return C.velocityScaleFloor + (1.0 - C.velocityScaleFloor) * frac
    }

    public static func applyStateDoseCap(
        _ state: MealHypothesis,
        _ dose: Double,
        confirmedCapU: Double = SafetyGateConstants.maxConfirmedCommitDoseU,
        committedCapU: Double = SafetyGateConstants.maxCommittedDoseU
    ) -> Double {
        switch state {
        case .confirmed: return min(dose, confirmedCapU)
        case .committed: return min(dose, committedCapU)
        default: return dose
        }
    }
}
