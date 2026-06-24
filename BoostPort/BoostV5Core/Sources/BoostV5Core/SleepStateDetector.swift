import Foundation

/// SleepStateDetector — HR + step + clock-driven sleep state estimator for Boost night mode.
///
/// Pure 1:1 port of AAPS `SleepStateDetector` (openAPSBoost, Boost-V6-mealtime-alpha). No
/// Android / persistence dependencies: `step` takes the per-cycle inputs and prior state,
/// returns the new state.
///
/// Three-state machine: AWAKE → PRE_SLEEP → SLEEPING → AWAKE.
///
/// Enter PRE_SLEEP (from AWAKE) when clock ∈ [nightStart − preSleepLeadMin, nightStart).
/// Time-only pre-warm window (no HR/step gating).
///
/// Enter SLEEPING (from PRE_SLEEP or AWAKE if already in night window) when ALL hold for
/// ≥ sleepHysteresisMin (the HR-value qualifier), OR the drought qualifier holds:
///   HR qualifier: avgHr ≤ restingHr × 1.15, steps15min < 50, clock ∈ outer window, meal < 0.30/nil
///   Drought qualifier (batched-HR platforms / sparse HealthKit overnight HR): avgHr == nil AND
///     no fresh HR sample for ≥ droughtThresholdMin AND steps15min < 50 AND meal < 0.30/nil.
///
/// Exit SLEEPING (to AWAKE):
///   - clock exits the outer night window (hard morning exit), OR
///   - transmission-resume wake: ≥3 fresh HR samples arrive after a ≥droughtThresholdMin drought
///     (no hysteresis), OR
///   - avgHr > restingHr × 1.25 AND steps15min ≥ 100, sustained ≥ wakeHrHysteresisMin.
///
/// PRE_SLEEP → AWAKE when clock leaves both the pre-sleep and outer night windows.
public enum SleepState: String, Codable, Sendable {
    case awake
    case preSleep
    case sleeping
}

/// One HR sample. Mirrors AAPS `HR` (timestamp, beatsPerMinute, duration, isValid). The
/// detector computes its own duration-weighted average and freshness/drought from these, so
/// the host must pass raw samples (not a pre-averaged value).
public struct SleepHrReading: Codable, Equatable, Sendable {
    /// Sample timestamp, epoch-ms.
    public var timestampMs: Double
    public var beatsPerMinute: Double
    /// Sample duration, ms. HealthKit HR samples are typically instantaneous; the host should
    /// supply a nominal positive duration so the duration-weighted average degrades to a mean.
    public var durationMs: Double
    public var isValid: Bool

    public init(timestampMs: Double, beatsPerMinute: Double, durationMs: Double, isValid: Bool = true) {
        self.timestampMs = timestampMs
        self.beatsPerMinute = beatsPerMinute
        self.durationMs = durationMs
        self.isValid = isValid
    }
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
    /// ≥ this many fresh samples after a drought → transmission-resume wake. (Kotlin: `>= 3`)
    public static let transmissionResumeSampleCount = 3
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
    /// Most recent fresh HR-sample timestamp seen (epoch-ms). 0 until the first fresh sample;
    /// persists across cycles so drought duration survives gaps between `step` calls. (2026-06-05)
    public var lastFreshHrSampleMs: Double
    /// Which qualifier promoted the current SLEEPING entry: "hr" or "drought"; nil when not
    /// SLEEPING. Telemetry only. (2026-06-06)
    public var sleepEntryReason: String?

    public init(
        state: SleepState = .awake,
        sleepCandidateSinceMs: Double? = nil,
        wakeCandidateSinceMs: Double? = nil,
        enteredAtMs: Double = 0,
        lastFreshHrSampleMs: Double = 0,
        sleepEntryReason: String? = nil
    ) {
        self.state = state
        self.sleepCandidateSinceMs = sleepCandidateSinceMs
        self.wakeCandidateSinceMs = wakeCandidateSinceMs
        self.enteredAtMs = enteredAtMs
        self.lastFreshHrSampleMs = lastFreshHrSampleMs
        self.sleepEntryReason = sleepEntryReason
    }
}

/// Per-cycle inputs from the host.
public struct SleepDetectorInputs {
    /// Recent HR samples; the detector filters by window and computes its own average + drought.
    public var hrReadings: [SleepHrReading]
    /// Minutes of HR history to average for state evaluation. (Kotlin default 5)
    public var hrWindowMinutes: Int
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
    /// Minutes without a fresh HR sample before drought-based sleep qualification applies.
    /// (Kotlin default 30; set very high to disable drought promotion.)
    public var droughtThresholdMin: Int
    /// How recent (relative to nowMs) an HR sample must be to count as "fresh"/live. (Kotlin default 10)
    public var freshHrWindowMin: Int
    /// Optional meal-likelihood score (nil if model unavailable).
    public var mlMealLikely: Double?
    /// Current system time, epoch-ms.
    public var nowMs: Double
    /// Whether automatic sleep detection is enabled (gates only downstream night-mode, not `step`).
    public var autoBySleep: Bool

    public init(
        hrReadings: [SleepHrReading],
        hrWindowMinutes: Int = 5,
        restingHeartRate: Double,
        steps15min: Int,
        nowMinuteOfDay: Int,
        nightStartMinute: Int,
        nightEndMinute: Int,
        preSleepLeadMin: Int,
        sleepHysteresisMin: Int,
        wakeHrHysteresisMin: Int,
        droughtThresholdMin: Int = 30,
        freshHrWindowMin: Int = 10,
        mlMealLikely: Double?,
        nowMs: Double,
        autoBySleep: Bool
    ) {
        self.hrReadings = hrReadings
        self.hrWindowMinutes = hrWindowMinutes
        self.restingHeartRate = restingHeartRate
        self.steps15min = steps15min
        self.nowMinuteOfDay = nowMinuteOfDay
        self.nightStartMinute = nightStartMinute
        self.nightEndMinute = nightEndMinute
        self.preSleepLeadMin = preSleepLeadMin
        self.sleepHysteresisMin = sleepHysteresisMin
        self.wakeHrHysteresisMin = wakeHrHysteresisMin
        self.droughtThresholdMin = droughtThresholdMin
        self.freshHrWindowMin = freshHrWindowMin
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
        let avgHr = averageHr(inputs.hrReadings, nowMs: inputs.nowMs, windowMinutes: inputs.hrWindowMinutes)
        let sleepCap = inputs.restingHeartRate * C.sleepHrMultiplier
        let wakeFloor = inputs.restingHeartRate * C.wakeHrMultiplier

        let inOuterWindow = minuteInWrappedRange(inputs.nowMinuteOfDay, inputs.nightStartMinute, inputs.nightEndMinute)
        let preSleepStart = (inputs.nightStartMinute - inputs.preSleepLeadMin + C.minutesPerDay) % C.minutesPerDay
        let inPreSleep = minuteInWrappedRange(inputs.nowMinuteOfDay, preSleepStart, inputs.nightStartMinute)

        var newState = state

        // Drought-based sleep + transmission-resume wake (2026-06-05). The most recent FRESH HR
        // sample (timestamp within freshHrWindowMin of now — distinguishes live transmission from
        // backfilled sync) drives drought duration; persists in `lastFreshHrSampleMs`.
        let freshCutoff = inputs.nowMs - Double(inputs.freshHrWindowMin) * C.msPerMinute
        let freshReadings = inputs.hrReadings
            .filter { $0.isValid && $0.timestampMs > freshCutoff && $0.timestampMs <= inputs.nowMs }
        let mostRecentFreshTs = freshReadings.map(\.timestampMs).max() ?? 0
        if mostRecentFreshTs > newState.lastFreshHrSampleMs {
            newState.lastFreshHrSampleMs = mostRecentFreshTs
        }
        let droughtMinutes = newState.lastFreshHrSampleMs > 0
            ? Int((inputs.nowMs - newState.lastFreshHrSampleMs) / C.msPerMinute)
            : Int.max
        let droughtEstablished = droughtMinutes >= inputs.droughtThresholdMin
        let fifteenMinCutoff = inputs.nowMs - 15 * C.msPerMinute
        let freshSamplesInLast15Min = freshReadings.filter { $0.timestampMs >= fifteenMinCutoff }.count

        // Drought-qualified candidacy: no HR + established drought + step/meal gates pass.
        let droughtQualifies = avgHr == nil && droughtEstablished &&
            inputs.steps15min < C.sleepStepCeiling &&
            (inputs.mlMealLikely == nil || inputs.mlMealLikely! < C.mealLikelyThreshold)
        let hrQualifies = qualifiesAsSleepCandidate(
            avgHr, sleepCap: sleepCap, steps15min: inputs.steps15min, mlMealLikely: inputs.mlMealLikely
        )
        let anyQualifies = hrQualifies || droughtQualifies

        // Transmission-resume wake: a burst of fresh samples following an actual drought.
        let priorDroughtMinutes = state.lastFreshHrSampleMs > 0
            ? Int((inputs.nowMs - state.lastFreshHrSampleMs) / C.msPerMinute)
            : Int.max
        let transmissionResumeWake = freshSamplesInLast15Min >= C.transmissionResumeSampleCount &&
            priorDroughtMinutes >= inputs.droughtThresholdMin

        var transitioned = false

        switch state.state {
        case .awake:
            // Sleep candidacy possible from AWAKE when in outer window OR in pre-sleep window.
            if inOuterWindow || inPreSleep, anyQualifies {
                if newState.sleepCandidateSinceMs == nil {
                    newState.sleepCandidateSinceMs = inputs.nowMs
                } else {
                    let heldMin = Int((inputs.nowMs - newState.sleepCandidateSinceMs!) / C.msPerMinute)
                    if heldMin >= inputs.sleepHysteresisMin {
                        newState = SleepDetectorState(
                            state: .sleeping, enteredAtMs: inputs.nowMs,
                            lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                            sleepEntryReason: hrQualifies ? "hr" : "drought"
                        )
                        transitioned = true
                    }
                }
            } else {
                newState.sleepCandidateSinceMs = nil
            }

            if !transitioned, inPreSleep {
                newState = SleepDetectorState(
                    state: .preSleep, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs
                )
                transitioned = true
            }

        case .preSleep:
            // Exit if we've left both the outer night window and the pre-sleep window (morning exit).
            if !inOuterWindow, !inPreSleep {
                newState = SleepDetectorState(
                    state: .awake, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs
                )
                transitioned = true
            } else if anyQualifies {
                if newState.sleepCandidateSinceMs == nil {
                    newState.sleepCandidateSinceMs = inputs.nowMs
                } else {
                    let heldMin = Int((inputs.nowMs - newState.sleepCandidateSinceMs!) / C.msPerMinute)
                    if heldMin >= inputs.sleepHysteresisMin {
                        newState = SleepDetectorState(
                            state: .sleeping, enteredAtMs: inputs.nowMs,
                            lastFreshHrSampleMs: newState.lastFreshHrSampleMs,
                            sleepEntryReason: hrQualifies ? "hr" : "drought"
                        )
                        transitioned = true
                    }
                }
            } else {
                newState.sleepCandidateSinceMs = nil
            }

        case .sleeping:
            // Hard morning exit.
            if !inOuterWindow {
                newState = SleepDetectorState(
                    state: .awake, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs
                )
                transitioned = true
            } else if transmissionResumeWake {
                // Sync burst after a drought → user resumed interaction. No hysteresis.
                newState = SleepDetectorState(
                    state: .awake, enteredAtMs: inputs.nowMs,
                    lastFreshHrSampleMs: newState.lastFreshHrSampleMs
                )
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
                            newState = SleepDetectorState(
                                state: .awake, enteredAtMs: inputs.nowMs,
                                lastFreshHrSampleMs: newState.lastFreshHrSampleMs
                            )
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

    /// Duration-weighted average HR over the window; nil if no readings or zero total duration.
    /// Matches Kotlin `averageHr`.
    static func averageHr(_ readings: [SleepHrReading], nowMs: Double, windowMinutes: Int) -> Double? {
        let cutoff = nowMs - Double(windowMinutes) * SleepStateConstants.msPerMinute
        let inWindow = readings.filter { $0.isValid && $0.timestampMs > cutoff && $0.timestampMs <= nowMs }
        if inWindow.isEmpty { return nil }
        let totalDur = inWindow.reduce(0.0) { $0 + $1.durationMs }
        if totalDur <= 0 { return nil }
        return inWindow.reduce(0.0) { $0 + $1.beatsPerMinute * $1.durationMs } / totalDur
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

    /// Matches Kotlin `qualifiesAsSleepCandidate` (HR-value qualifier).
    static func qualifiesAsSleepCandidate(_ avgHr: Double?, sleepCap: Double, steps15min: Int, mlMealLikely: Double?) -> Bool {
        guard let avgHr else { return false } // no HR → can't confirm
        if avgHr > sleepCap { return false } // HR too high
        if steps15min >= SleepStateConstants.sleepStepCeiling { return false } // recent activity
        if let meal = mlMealLikely, meal >= SleepStateConstants.mealLikelyThreshold { return false } // about to eat
        return true
    }
}
