import Foundation

/// Boost step + heart-rate activity classification.
///
/// Faithful port of AAPS Boost's activity detection, fusing two sources:
///
/// 1. `HrActivityCalculator` (`plugins/aps/.../openAPSBoost/HrActivityCalculator.kt`)
///    — Karvonen Heart Rate Reserve (HRR%) zones 1–5.
/// 2. `OpenAPSBoostPlugin.calculateBoostActivity()` (~lines 468–693)
///    — step-threshold ACTIVE / INACTIVE / normal detection plus the
///      HR-fused exercise states and their resulting profile% / target BG.
///
/// ## Karvonen zones (from `classifyZone`)
/// HRR% = (bpm − rest) / max(max − rest, 1) × 100
///   - Zone 1 (very light):  HRR% < 30
///   - Zone 2 (light):       30 ≤ HRR% < 40
///   - Zone 3 (moderate):    40 ≤ HRR% < 60
///   - Zone 4 (hard):        60 ≤ HRR% < 80
///   - Zone 5 (max):         HRR% ≥ 80
///
/// ## HR-fusion step thresholds (15-minute window, from `HrActivityCalculator`)
///   - high steps:     steps15 ≥ 300
///   - moderate steps: steps15 ≥ 100
///   - low steps:      steps15 < 30
///
/// ## Fused state → effect (from `calculateBoostActivity`)
///   - VIGOROUS_AEROBIC: profile → max(activityPct − 10, 50), target 150
///   - MODERATE / LIGHT aerobic (or no HR): step-only ACTIVE → profile activityPct, target 150
///   - RESISTANCE: profile unchanged, target 160
///   - STRESS: profile unchanged, target 160 (only when `hrStressDetection`)
///   - ACTIVE (step-only): profile activityPct, target 150
///   - INACTIVE (step-only): profile inactivityPct, no activity target
///   - normal / resting: no adjustment
///
/// Pure, stateless, Foundation-only.

/// Combined exercise / activity state.
public enum ExerciseState: String, Codable, Sendable {
    case normal
    case active
    case inactive
    case vigorousAerobic
    case moderateAerobic
    case lightAerobic
    case resistance
    case stress
    case resting
}

/// Configurable thresholds. Defaults match the AAPS Boost preference defaults.
public struct ActivityThresholds: Equatable, Sendable {
    /// `ApsBoostActivitySteps5` — steps in last 5 min that trigger ACTIVE.
    public var steps5: Int
    /// `ApsBoostActivitySteps15` — steps in last 15 min that trigger ACTIVE.
    public var steps15: Int
    /// `ApsBoostActivitySteps30` — steps in last 30 min that trigger ACTIVE.
    public var steps30: Int
    /// `ApsBoostActivitySteps60` — steps in last 60 min that trigger ACTIVE.
    public var steps60: Int
    /// `ApsBoostActivityPct` — profile % applied when ACTIVE.
    public var activityPct: Double
    /// `ApsBoostInactivitySteps` — 60-min step count below which INACTIVE applies.
    public var inactivitySteps: Int
    /// `ApsBoostInactivityPct` — profile % applied when INACTIVE.
    public var inactivityPct: Double
    /// `ApsBoostHrMaxBpm` — Karvonen HRmax.
    public var hrMaxBpm: Int
    /// `ApsBoostHrRestingBpm` — Karvonen resting HR.
    public var hrRestingBpm: Int
    /// `ApsBoostHrStressDetection` — opt-in STRESS classification.
    public var hrStressDetection: Bool
    /// `ApsBoostHrIntegrationEnabled` — gate for the HR-fused path.
    public var hrIntegrationEnabled: Bool

    public init(
        steps5: Int = 420,
        steps15: Int = 800,
        steps30: Int = 1200,
        steps60: Int = 1800,
        activityPct: Double = 80,
        inactivitySteps: Int = 500,
        inactivityPct: Double = 130,
        hrMaxBpm: Int = 180,
        hrRestingBpm: Int = 60,
        hrStressDetection: Bool = false,
        hrIntegrationEnabled: Bool = false
    ) {
        self.steps5 = steps5
        self.steps15 = steps15
        self.steps30 = steps30
        self.steps60 = steps60
        self.activityPct = activityPct
        self.inactivitySteps = inactivitySteps
        self.inactivityPct = inactivityPct
        self.hrMaxBpm = hrMaxBpm
        self.hrRestingBpm = hrRestingBpm
        self.hrStressDetection = hrStressDetection
        self.hrIntegrationEnabled = hrIntegrationEnabled
    }
}

/// Inputs to a single classification.
public struct ActivityInputs: Equatable, Sendable {
    public var steps5: Int
    public var steps15: Int
    public var steps30: Int
    public var steps60: Int
    /// Duration-weighted average HR over the HR window. `0` (or any value when
    /// HR integration is disabled) means "no HR signal".
    public var avgHeartRate: Double
    public var thresholds: ActivityThresholds

    public init(
        steps5: Int,
        steps15: Int,
        steps30: Int,
        steps60: Int,
        avgHeartRate: Double,
        thresholds: ActivityThresholds
    ) {
        self.steps5 = steps5
        self.steps15 = steps15
        self.steps30 = steps30
        self.steps60 = steps60
        self.avgHeartRate = avgHeartRate
        self.thresholds = thresholds
    }
}

/// Result of a classification.
public struct ActivityResult: Equatable, Sendable {
    public let state: ExerciseState
    /// Resulting profile percentage (starting from a baseline of 100%).
    public let profilePercent: Double
    /// Target BG in mg/dL, or `nil` when the state imposes no activity target.
    public let targetBgMgdl: Double?
    /// `true` when `state` is one of the exercise states.
    public let exerciseActive: Bool

    public init(
        state: ExerciseState,
        profilePercent: Double,
        targetBgMgdl: Double?,
        exerciseActive: Bool
    ) {
        self.state = state
        self.profilePercent = profilePercent
        self.targetBgMgdl = targetBgMgdl
        self.exerciseActive = exerciseActive
    }
}

public enum ActivityClassifier {
    // MARK: - Constants (from source)

    /// Activity / resistance / stress aerobic target (from `activityBgTarget = 150.0`).
    private static let aerobicTargetBg: Double = 150.0
    /// Resistance & stress target (from `resistanceBgTarget` / `stressBgTarget = 160.0`).
    private static let resistanceStressTargetBg: Double = 160.0
    /// Baseline profile percentage (the source only adjusts when `currentProfileSwitch == 100`).
    private static let baselineProfilePercent: Double = 100.0

    // HR-fusion step thresholds (15-min window), from `HrActivityCalculator`.
    private static let steps15HighThreshold = 300 // brisk walk
    private static let steps15ModerateThreshold = 100 // slow walk
    private static let steps15LowThreshold = 30 // near-stationary

    // MARK: - Karvonen zone

    /// Karvonen HR zone (1–5).
    ///
    /// Mirrors `HrActivityCalculator.classifyZone`. `reserve` is coerced to at
    /// least 1 to avoid division by zero.
    public static func karvonenZone(hr: Double, rest: Int, max: Int) -> Int {
        let reserve = Swift.max(max - rest, 1)
        let hrrPct = ((hr - Double(rest)) / Double(reserve)) * 100.0
        switch hrrPct {
        case ..<30.0: return 1
        case ..<40.0: return 2
        case ..<60.0: return 3
        case ..<80.0: return 4
        default: return 5
        }
    }

    // MARK: - Classification

    public static func classify(_ inputs: ActivityInputs) -> ActivityResult {
        let t = inputs.thresholds

        // Step-only ACTIVE detection (mirrors `isActive` in calculateBoostActivity).
        let isActive =
            (t.steps5 > 0 && inputs.steps5 > t.steps5)
                || (t.steps15 > 0 && inputs.steps15 > t.steps15)
                || (t.steps30 > 0 && inputs.steps30 > t.steps30)
                || (t.steps60 > 0 && inputs.steps60 > t.steps60)

        // HR-fused exercise state (nil when HR integration disabled — step-only path).
        let hrState: ExerciseState? = t.hrIntegrationEnabled
            ? fuseHrState(avgHr: inputs.avgHeartRate, steps15: inputs.steps15, thresholds: t)
            : nil

        if isActive {
            return resolveActive(hrState: hrState, thresholds: t)
        }

        // Not step-active. Inactivity branch (mirrors `currentProfileSwitch == 100
        // && recentSteps60Min < inactivitySteps`).
        if inputs.steps60 < t.inactivitySteps {
            // Stress takes precedence over INACTIVE when detection enabled.
            if t.hrStressDetection, hrState == .stress {
                return result(.stress, profile: baselineProfilePercent, target: resistanceStressTargetBg)
            }
            return result(.inactive, profile: t.inactivityPct, target: nil)
        }

        // HR-only resistance detection (steps don't detect this).
        if t.hrIntegrationEnabled, hrState == .resistance {
            return result(.resistance, profile: baselineProfilePercent, target: resistanceStressTargetBg)
        }

        // HR-only stress detection.
        if t.hrStressDetection, hrState == .stress {
            return result(.stress, profile: baselineProfilePercent, target: resistanceStressTargetBg)
        }

        return result(.normal, profile: baselineProfilePercent, target: nil)
    }

    // MARK: - Helpers

    /// Resolves the effect of a step-only ACTIVE detection, refined by HR.
    private static func resolveActive(hrState: ExerciseState?, thresholds t: ActivityThresholds) -> ActivityResult {
        switch hrState {
        case .vigorousAerobic:
            let profile = Swift.max(t.activityPct - 10.0, 50.0)
            return result(.vigorousAerobic, profile: profile, target: aerobicTargetBg)
        case .resistance:
            // Raise target, do NOT reduce profile.
            return result(.resistance, profile: baselineProfilePercent, target: resistanceStressTargetBg)
        case .lightAerobic,
             .moderateAerobic,
             nil:
            // Step-only ACTIVE behaviour.
            return result(.active, profile: t.activityPct, target: aerobicTargetBg)
        default:
            // HR signal contradicts steps (e.g. resting/stress) — fall back to ACTIVE.
            return result(.active, profile: t.activityPct, target: aerobicTargetBg)
        }
    }

    /// HR + step fusion (mirrors `HrActivityCalculator.classify`).
    private static func fuseHrState(avgHr: Double, steps15: Int, thresholds t: ActivityThresholds) -> ExerciseState? {
        // No HR signal → no fused classification.
        guard avgHr > 0 else { return nil }

        let zone = karvonenZone(hr: avgHr, rest: t.hrRestingBpm, max: t.hrMaxBpm)

        let highSteps = steps15 >= steps15HighThreshold
        let moderateSteps = steps15 >= steps15ModerateThreshold
        let lowSteps = steps15 < steps15LowThreshold

        // Vigorous aerobic: high steps + zone ≥ 3.
        if highSteps, zone >= 3 {
            return .vigorousAerobic
        }
        // Moderate aerobic: moderate steps + zone ≥ 2.
        if moderateSteps, zone >= 2 {
            return .moderateAerobic
        }
        // Light aerobic: above-sedentary steps + zone ≤ 2.
        if !lowSteps, zone <= 2 {
            return .lightAerobic
        }
        // Resistance: low steps + zone 3–4.
        if lowSteps, zone >= 3, zone <= 4 {
            return .resistance
        }
        // STRESS is intentionally NOT classified — it is dead code in AAPS (the classifier only
        // ever tags STRESS with LOW confidence, and the plugin gates it behind `confidence != LOW`,
        // so it never reaches activityState or raises the target). We mirror that: low-steps + zone
        // 2–3 falls through to resting/inactive, never STRESS. (The `hrStressDetection` toggle is
        // kept for parity but, like AAPS, has no effect until STRESS is deliberately enabled.)
        // Inactive: low steps + zone 1.
        if lowSteps, zone == 1 {
            return .inactive
        }
        return .resting
    }

    /// Builds a result, deriving `exerciseActive` from the state.
    private static func result(_ state: ExerciseState, profile: Double, target: Double?) -> ActivityResult {
        ActivityResult(
            state: state,
            profilePercent: profile,
            targetBgMgdl: target,
            exerciseActive: isExerciseState(state)
        )
    }

    /// `true` when the state represents detected exercise (not normal/inactive/resting).
    private static func isExerciseState(_ state: ExerciseState) -> Bool {
        switch state {
        case .active,
             .lightAerobic,
             .moderateAerobic,
             .resistance,
             .vigorousAerobic:
            return true
        case .inactive,
             .normal,
             .resting,
             .stress: // STRESS is inert (AAPS dead code) — never an exercise state
            return false
        }
    }
}
