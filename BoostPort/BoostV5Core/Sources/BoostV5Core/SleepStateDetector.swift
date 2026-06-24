import Foundation

/// SleepStateDetector — HR + step + clock-driven sleep state estimator for Boost night mode.
///
/// Pure 1:1 port of AAPS `SleepStateDetector` (openAPSBoost). No Android / persistence
/// dependencies: `step` takes the per-cycle inputs and prior state, returns the new state.
///
/// Three-state machine: AWAKE → PRE_SLEEP → SLEEPING → AWAKE.
///
/// Enter PRE_SLEEP (from AWAKE) when clock ∈ [nightStart − preSleepLeadMin, nightStart).
/// Time-only pre-warm window (no HR/step gating).
///
/// Enter SLEEPING (from PRE_SLEEP or AWAKE if already in night window) when ALL hold for
/// ≥ sleepHysteresisMin:
///   - avgHr ≤ restingHr × 1.15
///   - steps15min < 50
///   - clock ∈ [nightStart, nightEnd]   (broad outer night window)
///   - mlMealLikely < 0.30 or nil
///
/// Exit SLEEPING (to AWAKE) requires BOTH simultaneously, sustained ≥ wakeHrHysteresisMin:
///   - avgHr > restingHr × 1.25
///   - steps15min ≥ 100
///   OR clock exits the outer night window (hard morning exit).
///
/// PRE_SLEEP → AWAKE when clock leaves both the pre-sleep and outer night windows.
///
/// Failsafe: if avgHeartRate ≤ 0 (no HR data), sleep cannot be confirmed — state stays
/// AWAKE (or PRE_SLEEP if in the time window).
public enum SleepState: String, Codable, Sendable {
    case awake
    case preSleep
    case sleeping
}

/// Constants matched exactly to the AAPS Kotlin source.
public enum SleepStateConstants {
    /// avgHr ≤ restingHr × this → HR low enough for sleep. (Kotlin: `hrResting * 1.15`)
    public static let sleepHrMultiplier = 1.15
    /// avgHr > restingHr × this → HR high enough to be a wake candidate. (Kotlin: `hrResting * 1.25`)
    public static let wakeHrMultiplier = 1.25
    /// steps15min ≥ this blocks sleep candidacy. (Kotlin: `stepsLast15Min >= 50`)
    public static let sleepStepCeiling = 50
    /// steps15min ≥ this is required to confirm wake. (Kotlin: `stepsLast15Min >= 100`)
    public static let wakeStepFloor = 100
    /// mlMealLikely ≥ this blocks sleep candidacy. (Kotlin: `mlMealLikely >= 0.30`)
    public static let mealLikelyThreshold = 0.30
    /// Minutes in a day, for circular clock math.
    public static let minutesPerDay = 1440
    /// ms per minute, for hysteresis hold computation.
    public static let msPerMinute = 60000.0
}

/// Persisted state carried across cycles. Mirrors the Kotlin `State` serialized fields.
public struct SleepDetectorState: Codable, Equatable, Sendable {
    public var state: SleepState
    /// When the current PRE_SLEEP→SLEEPING qualification window started (nil = none in progress).
    public var sleepCandidateSinceMs: Double?
    /// When the current SLEEPING→AWAKE qualification window started (nil = none in progress).
    public var wakeCandidateSinceMs: Double?
    /// When the current state was entered (epoch-ms).
    public var enteredAtMs: Double

    public init(
        state: SleepState = .awake,
        sleepCandidateSinceMs: Double? = nil,
        wakeCandidateSinceMs: Double? = nil,
        enteredAtMs: Double = 0
    ) {
        self.state = state
        self.sleepCandidateSinceMs = sleepCandidateSinceMs
        self.wakeCandidateSinceMs = wakeCandidateSinceMs
        self.enteredAtMs = enteredAtMs
    }
}

/// Per-cycle inputs from the host.
public struct SleepDetectorInputs {
    /// Average HR over the recent window, bpm. 0 (or ≤0) means "no HR data" → cannot confirm sleep.
    public var avgHeartRate: Double
    /// User's resting HR, bpm.
    public var restingHeartRate: Double
    /// Steps in the last 15 minutes.
    public var steps15min: Int
    /// Local minute-of-day (0..1439).
    public var nowMinuteOfDay: Int
    /// Night-mode start minute-of-day (e.g. 22:00 → 1320).
    public var nightStartMinute: Int
    /// Night-mode end minute-of-day (e.g. 07:00 → 420).
    public var nightEndMinute: Int
    /// How early before nightStart to enter PRE_SLEEP.
    public var preSleepLeadMin: Int
    /// Minutes sleep conditions must hold before SLEEPING.
    public var sleepHysteresisMin: Int
    /// Minutes HR+steps wake conditions must hold before AWAKE.
    public var wakeHrHysteresisMin: Int
    /// Optional meal-likelihood score (nil if model unavailable).
    public var mlMealLikely: Double?
    /// Current system time, epoch-ms.
    public var nowMs: Double
    /// Whether automatic sleep detection is enabled (gate; false → state held AWAKE).
    public var autoBySleep: Bool

    public init(
        avgHeartRate: Double,
        restingHeartRate: Double,
        steps15min: Int,
        nowMinuteOfDay: Int,
        nightStartMinute: Int,
        nightEndMinute: Int,
        preSleepLeadMin: Int,
        sleepHysteresisMin: Int,
        wakeHrHysteresisMin: Int,
        mlMealLikely: Double?,
        nowMs: Double,
        autoBySleep: Bool
    ) {
        self.avgHeartRate = avgHeartRate
        self.restingHeartRate = restingHeartRate
        self.steps15min = steps15min
        self.nowMinuteOfDay = nowMinuteOfDay
        self.nightStartMinute = nightStartMinute
        self.nightEndMinute = nightEndMinute
        self.preSleepLeadMin = preSleepLeadMin
        self.sleepHysteresisMin = sleepHysteresisMin
        self.wakeHrHysteresisMin = wakeHrHysteresisMin
        self.mlMealLikely = mlMealLikely
        self.nowMs = nowMs
        self.autoBySleep = autoBySleep
    }
}

public enum SleepStateDetector {
    /// Pure transition. Returns the new persisted state. Caller stores it and passes it back next cycle.
    public static func step(_ inputs: SleepDetectorInputs, _ state: SleepDetectorState) -> SleepDetectorState {
        // NOTE: the detector always advances its state machine (matching AAPS, which runs the
        // detector every cycle). `autoBySleep` is NOT gated here — it gates only the downstream
        // night-mode extension (see NightMode). Resetting to AWAKE here would discard in-progress
        // hysteresis and diverge from AAPS, so it is intentionally not done.
        let C = SleepStateConstants.self
        let avgHr: Double? = inputs.avgHeartRate > 0 ? inputs.avgHeartRate : nil
        let sleepCap = inputs.restingHeartRate * C.sleepHrMultiplier
        let wakeFloor = inputs.restingHeartRate * C.wakeHrMultiplier

        let inOuterWindow = minuteInWrappedRange(inputs.nowMinuteOfDay, inputs.nightStartMinute, inputs.nightEndMinute)
        let preSleepStart = (inputs.nightStartMinute - inputs.preSleepLeadMin + C.minutesPerDay) % C.minutesPerDay
        let inPreSleep = minuteInWrappedRange(inputs.nowMinuteOfDay, preSleepStart, inputs.nightStartMinute)

        var newState = state
        var transitioned = false

        switch state.state {
        case .awake:
            // Sleep candidacy possible from AWAKE when in outer window OR in pre-sleep window.
            if inOuterWindow || inPreSleep,
               qualifiesAsSleepCandidate(
                   avgHr,
                   sleepCap: sleepCap,
                   steps15min: inputs.steps15min,
                   mlMealLikely: inputs.mlMealLikely
               )
            {
                if newState.sleepCandidateSinceMs == nil {
                    newState.sleepCandidateSinceMs = inputs.nowMs
                } else {
                    let heldMin = Int((inputs.nowMs - newState.sleepCandidateSinceMs!) / C.msPerMinute)
                    if heldMin >= inputs.sleepHysteresisMin {
                        newState = SleepDetectorState(state: .sleeping, enteredAtMs: inputs.nowMs)
                        transitioned = true
                    }
                }
            } else {
                newState.sleepCandidateSinceMs = nil
            }

            if !transitioned, inPreSleep {
                newState = SleepDetectorState(state: .preSleep, enteredAtMs: inputs.nowMs)
                transitioned = true
            }

        case .preSleep:
            // Exit if we've left both the outer night window and the pre-sleep window (morning exit).
            if !inOuterWindow, !inPreSleep {
                newState = SleepDetectorState(state: .awake, enteredAtMs: inputs.nowMs)
                transitioned = true
            } else if qualifiesAsSleepCandidate(
                avgHr,
                sleepCap: sleepCap,
                steps15min: inputs.steps15min,
                mlMealLikely: inputs.mlMealLikely
            ) {
                if newState.sleepCandidateSinceMs == nil {
                    newState.sleepCandidateSinceMs = inputs.nowMs
                } else {
                    let heldMin = Int((inputs.nowMs - newState.sleepCandidateSinceMs!) / C.msPerMinute)
                    if heldMin >= inputs.sleepHysteresisMin {
                        newState = SleepDetectorState(state: .sleeping, enteredAtMs: inputs.nowMs)
                        transitioned = true
                    }
                }
            } else {
                newState.sleepCandidateSinceMs = nil
            }

        case .sleeping:
            // Hard morning exit.
            if !inOuterWindow {
                newState = SleepDetectorState(state: .awake, enteredAtMs: inputs.nowMs)
                transitioned = true
            } else {
                // Wake requires BOTH steps AND HR — BG trend alone is not sufficient.
                let stepsConfirmWake = inputs.steps15min >= C.wakeStepFloor
                let hrAboveWakeFloor = avgHr != nil && avgHr! > wakeFloor
                if stepsConfirmWake, hrAboveWakeFloor {
                    if newState.wakeCandidateSinceMs == nil {
                        newState.wakeCandidateSinceMs = inputs.nowMs
                    } else {
                        let heldMin = Int((inputs.nowMs - newState.wakeCandidateSinceMs!) / C.msPerMinute)
                        if heldMin >= inputs.wakeHrHysteresisMin {
                            newState = SleepDetectorState(state: .awake, enteredAtMs: inputs.nowMs)
                            transitioned = true
                        }
                    }
                } else {
                    newState.wakeCandidateSinceMs = nil
                }
            }
        }

        _ = transitioned
        return newState
    }

    /// True if `minute` lies within [start, end) on a 24-hour clock, handling wrap-around
    /// (e.g. start=1320 (22:00), end=420 (07:00)). Matches Kotlin `minuteInWrappedRange`.
    static func minuteInWrappedRange(_ minute: Int, _ start: Int, _ end: Int) -> Bool {
        if start == end { return false }
        if end > start {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    /// Matches Kotlin `qualifiesAsSleepCandidate`.
    static func qualifiesAsSleepCandidate(_ avgHr: Double?, sleepCap: Double, steps15min: Int, mlMealLikely: Double?) -> Bool {
        guard let avgHr else { return false } // no HR → can't confirm
        if avgHr > sleepCap { return false } // HR too high
        if steps15min >= SleepStateConstants.sleepStepCeiling { return false } // recent activity
        if let meal = mlMealLikely, meal >= SleepStateConstants.mealLikelyThreshold { return false } // about to eat
        return true
    }
}
