import Foundation

enum BoostV5Adapter {
    private static func dbl(_ d: Decimal?) -> Double? { d.map { ($0 as NSDecimalNumber).doubleValue } }

    /// Minimum sgv over the last 60 min (mg/dL); high default when no recent data (≈ no recent low).
    private static func recentLowBg(_ glucose: [BloodGlucose], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-3600)
        let recent = glucose.filter { $0.dateString >= cutoff }.compactMap(\.sgv)
        return Double(recent.min() ?? 120)
    }

    /// Run the V5 engine for this cycle against the stock determination + glucose status.
    /// Returns the decision; the caller decides whether to act on it (mode-gated).
    /// ML `direction_num` feature, EXACTLY matching AAPS DetermineBasalBoost (bucketing of
    /// `shortAvgDelta` at ±5/±10/±15 mg/dL per 5-min — the training-time NS-arrow encoding).
    private static func directionNum(shortAvgDelta: Double) -> Double {
        switch shortAvgDelta {
        case let d where d > 15: return 2.0
        case let d where d > 10: return 1.5
        case let d where d > 5: return 1.0
        case let d where d > -5: return 0.0
        case let d where d > -10: return -1.0
        case let d where d > -15: return -1.5
        default: return -2.0
        }
    }

    /// Short-horizon (first 6 prediction points ≈ 30 min) min across the IOB/COB/UAM/ZT series,
    /// matching AAPS `shortHorizonMinGuard`. The full-horizon `minGuardBG` over-fires the
    /// min_guard_bg hard gate (~50% of cycles in AAPS testing). Returns nil if no predictions.
    private static func shortHorizonMinGuard(_ predictions: Predictions?) -> Double? {
        guard let predictions else { return nil }
        let series = [predictions.iob, predictions.cob, predictions.uam, predictions.zt]
        let firstSix = series.compactMap { $0 }.flatMap { $0.prefix(6) }
        guard let minValue = firstSix.min() else { return nil }
        return Double(minValue)
    }

    /// User-tunable V5 knobs (from Preferences). Ranges match AAPS.
    struct V5Knobs {
        var aggression: Double = 1.0
        var hypoCaution: Double = 1.0
        var sensitivity: Double = 1.0
        var confirmedCapU: Double = 2.5 // fallback; host normally passes preferences.boostV5ConfirmedCapU
        var committedCapU: Double = 0.5 // fallback; host normally passes preferences.boostV5CommittedCapU
        var fastCarbConfirm: Bool = true
    }

    static func run(
        determination: Determination,
        glucoseStatus: GlucoseStatus,
        glucose: [BloodGlucose],
        iobData: [IobResult],
        maxIob: Double,
        roundSmbTo: Double,
        microBolusAllowed: Bool,
        mode: BoostMode,
        knobs: V5Knobs,
        clock: Date,
        // Cumulative SMB volume in the last 60 min and minutes since the last SMB — v12 ML
        // features (AAPS recentSmbVolume60Min / timeSinceLastSmbMin). Defaults match AAPS
        // (0 U / 720 min) for the legacy 8-feature model where they are unused.
        recentSmbUnits60m: Double = 0.0,
        timeSinceLastSmbMin: Double = 720.0,
        store: BoostV5Store = .shared
    ) -> Result {
        let delta = (glucoseStatus.delta as NSDecimalNumber).doubleValue
        let shortAvg = (glucoseStatus.shortAvgDelta as NSDecimalNumber).doubleValue
        let longAvg = (glucoseStatus.longAvgDelta as NSDecimalNumber).doubleValue
        let bg = (glucoseStatus.glucose as NSDecimalNumber).doubleValue
        let maxDelta = abs(delta) // AAPS: maxDelta = abs(gs.delta) (NOT glucoseStatus.maxDelta)
        let deltaAccl = DynIsf.deltaAccl(delta: delta, shortAvgDelta: shortAvg)

        let eventualBg = determination.eventualBG.map(Double.init) ?? bg
        let targetBg = dbl(determination.current_target) ?? 100
        // Budget base is floored at 0 (AAPS coerceAtLeast(0)); the ML feature stays SIGNED.
        let signedInsulinReq = dbl(determination.insulinReq) ?? 0.0
        let baseInsulinReq = max(0.0, signedInsulinReq)
        let iob = dbl(determination.iob) ?? 0.0
        // 30-min short-horizon min (AAPS shortHorizonMinGuard); fall back to full-horizon, then bg.
        let minGuardBg = shortHorizonMinGuard(determination.predictions)
            ?? dbl(determination.minGuardBG) ?? bg
        let minGuardThreshold = dbl(determination.threshold) ?? 80.0
        let hour = Calendar.current.component(.hour, from: clock)

        // ── ML scores (Layer-A retrofit): pure-Swift LightGBM inference on 8 features. ──
        // basaliob / activity come from the current IOB sample; the rest from the
        // determination + glucose status. nil if the bundled model didn't load.
        let current = iobData.first
        let iobTotal = current.map { ($0.iob as NSDecimalNumber).doubleValue } ?? iob
        let iobBasal = current.map { ($0.basaliob as NSDecimalNumber).doubleValue } ?? 0.0
        let iobActivity = current.map { ($0.activity as NSDecimalNumber).doubleValue } ?? 0.0
        let iobNetBasal = current.map { ($0.netbasalinsulin as NSDecimalNumber).doubleValue } ?? 0.0
        let directionNumValue = directionNum(shortAvgDelta: shortAvg)
        let minDelta = dbl(determination.minDelta) ?? 0.0
        let mlFeatures = BoostMLModels.Features(
            cgmMgdl: bg,
            iobTotal: iobTotal,
            iobBasal: iobBasal,
            bgAboveTarget: bg - targetBg,
            directionNum: directionNumValue,
            hour: Double(hour),
            iobActivity: iobActivity,
            insulinReq: signedInsulinReq
        )
        // Hypo risk: route on the LOADED model's feature count. 8 → legacy v9 path; otherwise the
        // v12 53-feature windowed-lookback path (BoostMlFeatureBuilder + persisted 6-cycle ring
        // buffer), matching AAPS DetermineBasalBoost's getFeatureNames() dispatch. The current
        // snapshot is pushed to the ring each cycle and persisted across restarts.
        let rawHypoRisk: Double?
        if let names = BoostMLModels.hypoFeatureNames(), names.count != 8 {
            let statics: [String: Double] = [
                "cgm_mgdl": bg,
                "iob_iob": iobTotal,
                "iob_basaliob": iobBasal,
                "bg_above_target": bg - targetBg,
                "direction_num": directionNumValue,
                "hour": Double(hour),
                "iob_activity": iobActivity,
                "sug_insulinReq": signedInsulinReq,
                "sug_COB": dbl(determination.cob) ?? 0.0,
                "sug_eventualBG": eventualBg,
                "sug_expectedDelta": dbl(determination.expectedDelta) ?? 0.0,
                "sug_minDelta": minDelta,
                "sug_TDD": max(0.0, dbl(determination.tdd) ?? 0.0),
                // AAPS feeds iob_bolusiob as max(0, iob − basaliob) at runtime (training-time semantics).
                "iob_bolusiob": max(0.0, iobTotal - iobBasal),
                "iob_netbasalinsulin": iobNetBasal,
                "recent_smb_units_60m": recentSmbUnits60m,
                "time_since_last_smb_min": timeSinceLastSmbMin
            ]
            let snapshot = BoostMlFeatureBuilder.CycleSnapshot(
                ts: clock.timeIntervalSince1970 * 1000.0,
                cgmMgdl: bg,
                iobIob: iobTotal,
                iobActivity: iobActivity,
                sugEventualBG: eventualBg,
                recentSmbUnits60m: recentSmbUnits60m,
                sugMinDelta: minDelta
            )
            var ring = BoostMlRingBufferStore.load()
            ring.push(snapshot)
            let vector = BoostMlFeatureBuilder.build(
                featureNames: names, current: snapshot, ring: ring, staticValues: statics
            )
            BoostMlRingBufferStore.save(ring)
            rawHypoRisk = BoostMLModels.hypoRisk(vector: vector)
        } else {
            rawHypoRisk = BoostMLModels.hypoRisk(mlFeatures)
        }
        // AAPS rounds both ML outputs to 3 dp before the engine consumes them.
        let mlHypoRisk = rawHypoRisk.map { ($0 * 1000).rounded() / 1000 }
        let mlMealLikely = BoostMLModels.mealLikely(mlFeatures).map { ($0 * 1000).rounded() / 1000 }
        // NOTE: Phase-3 postActionRiskCheck (riskAtProjectedIob) is intentionally left nil — AAPS V5
        // disables it in V0 (OpenAPSBoostV5Plugin: `riskAtProjectedIob = null`). Wiring it would
        // diverge from the reference; kept inert for exact parity. mlHypoRisk still damps the budget.

        // ── HealthKit activity (steps + HR) → V5 exercise modifiers. Snapshot is kept fresh
        // by BoostActivityMonitor; flags() guards on staleness. Inert until Health read is granted. ──
        let activity = BoostActivityStore.shared.flags(now: clock)

        // Time-jump / long-gap reset: minutes since the last decide(). A normal ~5-min cycle is
        // <30 (no reset); a clock jump, timezone change, long loop/pump gap, or app restart (state
        // persisted in UserDefaults) yields a large value → MealHypothesis.resetIfNeeded clears the
        // hypothesis (TIME_JUMP_RESET_MINUTES = 30). This is the wired reset signal in Trio;
        // profileSwitched/pumpDisconnected/loopSuspended aren't exposed at this layer (left false),
        // but any >30-min interruption from those is caught by the gap.
        let nowMs = clock.timeIntervalSince1970 * 1000.0
        // Atomic load→decide→save under one lock: timeJumpMinutes, the state passed to decide(), and
        // the state written back must all come from the SAME locked snapshot. Otherwise a scheduled
        // loop overlapping a post-bolus determineBasalSync can lose an update (last-writer-wins) —
        // e.g. erase a CONFIRMED hypothesis so the next cycle re-fires its SMB for the same meal.
        let decision = store.mutateState { state -> V5Decision in
            let timeJumpMinutes = state.lastRunMs.map { abs((nowMs - $0) / 60000.0) } ?? 0.0

            let inputs = V5Inputs(
                delta: delta,
                shortAvgDelta: shortAvg,
                deltaAccl: deltaAccl,
                bg: bg,
                eventualBg: eventualBg,
                targetBg: targetBg,
                maxDelta: maxDelta,
                minGuardBg: minGuardBg,
                minGuardThreshold: minGuardThreshold,
                deltaHistory: [longAvg, shortAvg, delta],
                iob: iob,
                maxIob: maxIob,
                baseInsulinReq: baseInsulinReq,
                roundSmbTo: roundSmbTo,
                // AAPS: enableSmbPreChecks = activeMode ? microBolusAllowed : true. In shadow it stays
                // permissive so the logged would-be dose isn't hard-gated to 0 (active dosing unaffected).
                enableSmbPreChecks: mode == .active ? microBolusAllowed : true,
                mlHypoRisk: mlHypoRisk, // bundled LightGBM; nil → score renormalize path
                mlMealLikely: mlMealLikely, // bundled LightGBM; nil → score renormalize path
                recentLowBg: recentLowBg(glucose, now: clock),
                cumulativeRise30min: max(0.0, shortAvg * 6.0),
                hour: hour,
                // AAPS parity: V5 ignores exercise/post-exercise (v5_exerciseActive/v5_inPostExerciseWindow
                // are hardcoded false in AAPS — the deferred "V0" stubs). The observed flags are still
                // logged in the reason tag for shadow analysis; the exercise feature gets switched on
                // (here) once that analysis is in. `asleep` IS live in AAPS (sleepState == SLEEPING), so kept.
                exerciseActive: false,
                inPostExerciseWindow: false,
                asleep: activity.asleep,
                fastCarbConfirmEnabled: knobs.fastCarbConfirm,
                timeJumpMinutes: timeJumpMinutes,
                aggressionUserKnob: knobs.aggression,
                hypoCautionUserKnob: knobs.hypoCaution,
                sensitivityUserKnob: knobs.sensitivity,
                confirmedCapU: knobs.confirmedCapU,
                committedCapU: knobs.committedCapU
            )

            let decision = BoostV5Engine.decide(inputs, persisted: state)
            state = decision.newPersistedState
            state.lastRunMs = nowMs
            return decision
        }
        // V6 learning: record a fresh CONFIRMED commit (meal-time history → pre-meal target).
        if decision.mealHypothesis == .confirmed, decision.mealHypothesisAge == 0 {
            BoostMealTimeStore.shared.recordConfirmed(at: clock)
        }
        let reason = reasonTag(
            decision,
            mode: mode,
            mlHypoRisk: mlHypoRisk,
            mlMealLikely: mlMealLikely,
            activity: activity
        )
        return Result(decision: decision, reason: reason)
    }

    /// What the harness consumes: the engine decision plus the telemetry string to append.
    struct Result {
        let decision: V5Decision
        let reason: String
    }

    /// Night-mode evaluation: suppresses SMB overnight (AAPS night mode). Uses the
    /// determination's bg/cob + the monitor's asleep flag + the user's config.
    ///
    /// AAPS `isNightModeActiveImpl` compares against the BASE profile target
    /// (`profile.getTargetMgdl()`) for both the low-TT disable gate and the final
    /// bg-vs-target gate — not the TT-adjusted target. `baseProfileTargetMgdl` is that
    /// base target; `activeTempTargetMgdl` is the active temp-target value (clamped to
    /// AAPS `LIMIT_TEMP_TARGET_BG` = 72–200 mg/dL) or nil when no TT is active.
    /// Returns whether to suppress and a short reason tag.
    static func nightMode(
        determination: Determination,
        preferences: Preferences,
        baseProfileTargetMgdl: Double,
        activeTempTargetMgdl: Double?,
        clock: Date
    ) -> (suppress: Bool, reason: String) {
        guard preferences.boostNightModeEnabled else { return (false, "") }
        // AAPS night-mode sleepActive = autoBySleep && sleepState != AWAKE, so PRE_SLEEP also
        // enables/extends night mode (the proactive pre-warm). This is distinct from the V5
        // dose-suppression gate, which uses == SLEEPING. Stale snapshot (>30 min) → not active.
        let sleepActive = BoostActivityStore.shared.snapshot
            .map { clock.timeIntervalSince($0.updatedAt) <= 1800 && ($0.sleepState?.state ?? .awake) != .awake } ?? false
        let config = NightModeConfig(
            enabled: true,
            startMinute: Int((dbl(preferences.boostNightModeStartHour) ?? 22) * 60),
            endMinute: Int((dbl(preferences.boostNightModeEndHour) ?? 7) * 60),
            bgOffsetMgdl: dbl(preferences.boostNightModeBgOffset) ?? 27,
            disableWithCob: preferences.boostNightModeDisableWithCob,
            disableWithLowTt: preferences.boostNightModeDisableWithLowTt,
            autoBySleep: preferences.boostNightModeAutoBySleep
        )
        let nowMin = Calendar.current.component(.hour, from: clock) * 60
            + Calendar.current.component(.minute, from: clock)
        let result = NightMode.evaluate(NightModeInputs(
            nowMinuteOfDay: nowMin,
            bg: dbl(determination.bg) ?? 0,
            profileTargetMgdl: baseProfileTargetMgdl,
            cob: dbl(determination.cob) ?? 0,
            activeTempTargetMgdl: activeTempTargetMgdl,
            sleepActive: sleepActive,
            config: config
        ))
        return (result.suppressSmb, result.reason)
    }

    /// Compact telemetry string appended to the determination reason (shadow + active).
    static func reasonTag(
        _ d: V5Decision,
        mode: BoostMode,
        mlHypoRisk: Double?,
        mlMealLikely: Double?,
        activity: (exerciseActive: Bool, inPostExerciseWindow: Bool, asleep: Bool)
    ) -> String {
        let st = d.mealHypothesis.rawValue
        let smb = String(format: "%.2f", d.finalDose)
        func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
        let ml = " ml(hypo=\(fmt(mlHypoRisk)) meal=\(fmt(mlMealLikely)))"
        var ctx = ""
        if activity.exerciseActive { ctx += " exercise" }
        else if activity.inPostExerciseWindow { ctx += " postEx" }
        if activity.asleep { ctx += " asleep" }
        return "boostV5[\(mode.rawValue)]: state=\(st) score=\(String(format: "%.2f", d.score)) wouldSMB=\(smb)U;\(ml)\(ctx)"
    }
}
