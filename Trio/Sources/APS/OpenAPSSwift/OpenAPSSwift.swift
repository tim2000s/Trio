import Foundation

struct OpenAPSSwift {
    static func makeProfile(
        preferences: JSON,
        pumpSettings: JSON,
        bgTargets: JSON,
        basalProfile: JSON,
        isf: JSON,
        carbRatio: JSON,
        tempTargets: JSON,
        model: JSON,
        trioSettings: JSON,
        clock: Date
    ) -> (OrefFunctionResult) {
        do {
            let preferences = try JSONBridge.preferences(from: preferences)
            let pumpSettings = try JSONBridge.pumpSettings(from: pumpSettings)
            let bgTargets = try JSONBridge.bgTargets(from: bgTargets)
            let basalProfile = try JSONBridge.basalProfile(from: basalProfile)
            let isf = try JSONBridge.insulinSensitivities(from: isf)
            let carbRatio = try JSONBridge.carbRatios(from: carbRatio)
            let tempTargets = try JSONBridge.tempTargets(from: tempTargets)
            let model = JSONBridge.model(from: model)
            let trioSettings = try JSONBridge.trioSettings(from: trioSettings)

            let profile = try ProfileGenerator.generate(
                pumpSettings: pumpSettings,
                bgTargets: bgTargets,
                basalProfile: basalProfile,
                isf: isf,
                preferences: preferences,
                carbRatios: carbRatio,
                tempTargets: tempTargets,
                model: model,
                clock: clock
            )

            return (try .success(JSONBridge.to(profile)))
        } catch {
            return (.failure(error))
        }
    }

    static func determineBasal(
        glucose: JSON,
        currentTemp: JSON,
        iob: JSON,
        profile: JSON,
        autosens: JSON,
        meal: JSON,
        microBolusAllowed: Bool,
        reservoir: JSON,
        pumpHistory: JSON,
        preferences: JSON,
        basalProfile: JSON,
        trioCustomOrefVariables: JSON,
        clock: Date,
        simulation: Bool = false
    ) -> (OrefFunctionResult) {
        do {
            let glucose = try JSONBridge.glucose(from: glucose)
            let currentTemp = try JSONBridge.currentTemp(from: currentTemp)
            let iob = try JSONBridge.iobResult(from: iob)
            let profile = try JSONBridge.profile(from: profile)
            let autosens = try JSONBridge.autosens(from: autosens)
            let meal = try JSONBridge.computedCarbs(from: meal)
            let microBolusAllowed = microBolusAllowed
            let reservoir = Decimal(string: reservoir.rawJSON)
            let pumpHistory = try JSONBridge.pumpHistory(from: pumpHistory)
            let preferences = try JSONBridge.preferences(from: preferences)
            let basalProfile = try JSONBridge.basalProfile(from: basalProfile)
            let trioCustomOrefVariables = try JSONBridge.trioCustomOrefVariables(from: trioCustomOrefVariables)

            guard let mealData = meal, let autosensData = autosens else {
                return .failure(DeterminationError.missingInputs)
            }

            var rawDetermination = try DeterminationGenerator.generate(
                profile: profile,
                preferences: preferences,
                currentTemp: currentTemp,
                iobData: iob,
                mealData: mealData,
                autosensData: autosensData,
                reservoirData: reservoir ?? 100,
                glucose: glucose,
                microBolusAllowed: microBolusAllowed,
                trioCustomOrefVariables: trioCustomOrefVariables,
                currentTime: clock
            )

            // ── Boost V5 second pass (off | shadow | active). Same engine, two wirings:
            // shadow logs what V5 would do; active overrides the SMB (units), exactly as AAPS
            // V5-active overrides Boost-V1's SMB. baseInsulinReq = the stock determination's
            // insulinReq — V5 adds no sensitivity logic of its own. ──
            // Skip the Boost V5 SECOND PASS for what-if simulations (bolus-calculator previews run
            // this repeatedly). The critical reason is state safety: the adapter writes the ML ring
            // buffer, V5 hypothesis state, meal-time history, and lastRunMs — a simulation snapshot
            // would corrupt the next real cycle's lags / state machine. Skipping it also drops the
            // V5 SMB override + night-mode suppression from the preview, which is correct (a what-if
            // shouldn't assume a hypothetical SMB). Note: the FIRST pass (DeterminationGenerator)
            // still applies the user's active Boost sensitivity model — DynISF / future_sens / the
            // V6 pre-meal target — so the preview reflects the model they actually run on; it is NOT
            // a pure stock-oref determination for an active user.
            let boostMode = preferences.boostMode
            if !simulation,
               boostMode != .off,
               var det = rawDetermination,
               let glucoseStatus = try? DeterminationGenerator.getGlucoseStatus(glucoseReadings: glucose)
            {
                // v12 ML features: cumulative SMB volume over the last 60 min and minutes since the
                // last SMB (AAPS recentSmbVolume60Min / timeSinceLastSmbMin — type==SMB, valid; sum
                // amount over 60 min; tSince = min(720, …), default 720 when none).
                let smbEvents = pumpHistory.filter { ($0.isSMB ?? false) && $0.timestamp <= clock }
                let sixtyMinAgo = clock.addingTimeInterval(-3600)
                let recentSmb60 = smbEvents
                    .filter { $0.timestamp >= sixtyMinAgo }
                    .reduce(0.0) { $0 + (($1.amount ?? 0) as NSDecimalNumber).doubleValue }
                let timeSinceSmb = smbEvents.map(\.timestamp).max()
                    .map { min(720.0, clock.timeIntervalSince($0) / 60.0) } ?? 720.0

                let result = BoostV5Adapter.run(
                    determination: det,
                    glucoseStatus: glucoseStatus,
                    glucose: glucose,
                    iobData: iob,
                    maxIob: (preferences.maxIOB as NSDecimalNumber).doubleValue,
                    // Pump bolus increment (AAPS rounds SMB to the pump step); fall back to 0.05.
                    roundSmbTo: preferences.bolusIncrement > 0
                        ? (preferences.bolusIncrement as NSDecimalNumber).doubleValue
                        : 0.05,
                    microBolusAllowed: microBolusAllowed,
                    mode: boostMode,
                    knobs: BoostV5Adapter.V5Knobs(
                        aggression: (preferences.boostV5Aggression as NSDecimalNumber).doubleValue,
                        hypoCaution: (preferences.boostV5HypoCaution as NSDecimalNumber).doubleValue,
                        sensitivity: (preferences.boostV5Sensitivity as NSDecimalNumber).doubleValue,
                        confirmedCapU: (preferences.boostV5ConfirmedCapU as NSDecimalNumber).doubleValue,
                        committedCapU: (preferences.boostV5CommittedCapU as NSDecimalNumber).doubleValue,
                        fastCarbConfirm: preferences.boostV5FastCarbConfirm
                    ),
                    clock: clock,
                    recentSmbUnits60m: recentSmb60,
                    timeSinceLastSmbMin: timeSinceSmb
                )
                det.reason += " " + result.reason
                if boostMode == .active {
                    // Sleep gate — faithful port of Boost-V6 OpenAPSBoostPlugin.kt:1239: V5 drives the
                    // SMB only when a microbolus is allowed AND not SLEEPING. While asleep the override
                    // backs off and the base (V1-equivalent) SMB stands, which night mode then suppresses.
                    // `asleep` = SleepStateDetector SLEEPING via the activity snapshot (staleness-guarded).
                    let asleep = BoostActivityStore.shared.flags(now: clock).asleep
                    if microBolusAllowed, !asleep {
                        det.units = Decimal(result.decision.finalDose)
                    } else if asleep {
                        det.reason += " V6 suppressed (SLEEPING) — base SMB stands;"
                    }
                    // AAPS night mode compares against the BASE profile target (pre-TT) and
                    // disables on an active low temp target clamped to LIMIT_TEMP_TARGET_BG (72–200).
                    let baseTarget = (profile.boostBaseTargetMgdl as NSDecimalNumber?)?.doubleValue
                        ?? (det.current_target as NSDecimalNumber?)?.doubleValue ?? 100
                    let activeTt: Double? = (profile.temptargetSet ?? false)
                        ? (profile.minBg as NSDecimalNumber?).map { min(200, max(72, $0.doubleValue)) }
                        : nil
                    let night = BoostV5Adapter.nightMode(
                        determination: det,
                        preferences: preferences,
                        baseProfileTargetMgdl: baseTarget,
                        activeTempTargetMgdl: activeTt,
                        clock: clock
                    )
                    if night.suppress {
                        det.units = 0
                        det.reason += " nightMode(SMB suppressed)"
                    }
                }
                rawDetermination = det
            }

            return try .success(JSONBridge.to(rawDetermination))

        } catch let determinationError as DeterminationError {
            // if we get a determination error we want to return it as a JSON
            // object that is { "error": "some error" }
            do {
                let response = try JSONBridge.to(DeterminationErrorResponse(error: determinationError.localizedDescription))
                return .success(response)
            } catch {
                return .failure(determinationError)
            }
        } catch {
            return .failure(error)
        }
    }

    static func meal(
        pumphistory: JSON,
        profile: JSON,
        basalProfile: JSON,
        clock: JSON,
        carbs: JSON,
        glucose: JSON
    ) -> (OrefFunctionResult) {
        do {
            let pumpHistory = try JSONBridge.pumpHistory(from: pumphistory)
            let profile = try JSONBridge.profile(from: profile)
            let basalProfile = try JSONBridge.basalProfile(from: basalProfile)
            let clock = try JSONBridge.clock(from: clock)
            let carbs = try JSONBridge.carbs(from: carbs)
            let glucose = try JSONBridge.glucose(from: glucose)

            let mealResult = try MealGenerator.generate(
                pumpHistory: pumpHistory,
                profile: profile,
                basalProfile: basalProfile,
                clock: clock,
                carbHistory: carbs,
                glucoseHistory: glucose
            )

            return try .success(JSONBridge.to(mealResult))
        } catch {
            return .failure(error)
        }
    }

    static func iob(pumphistory: JSON, profile: JSON, clock: JSON, autosens: JSON) -> (OrefFunctionResult) {
        do {
            let pumpHistory = try JSONBridge.pumpHistory(from: pumphistory)
            let profile = try JSONBridge.profile(from: profile)
            let clock = try JSONBridge.clock(from: clock)
            let autosens = try JSONBridge.autosens(from: autosens)

            let iobResult = try IobGenerator.generate(
                history: pumpHistory,
                profile: profile,
                clock: clock,
                autosens: autosens
            )

            return try .success(JSONBridge.to(iobResult))
        } catch {
            return .failure(error)
        }
    }

    static func autosense(
        glucose: JSON,
        pumpHistory: JSON,
        basalProfile: JSON,
        profile: JSON,
        carbs: JSON,
        tempTargets: JSON,
        clock: JSON,
        includeDeviationsForTesting: Bool = false
    ) -> (OrefFunctionResult) {
        do {
            let glucose = try JSONBridge.glucose(from: glucose)
            let pumpHistory = try JSONBridge.pumpHistory(from: pumpHistory)
            let basalProfile = try JSONBridge.basalProfile(from: basalProfile)
            let profile = try JSONBridge.profile(from: profile)
            let carbs = try JSONBridge.carbs(from: carbs)
            let tempTargets = try JSONBridge.tempTargets(from: tempTargets)
            let clock = try JSONBridge.clock(from: clock)

            // this logic is from prepare/autosens.js
            let ratio8h = try AutosensGenerator.generate(
                glucose: glucose,
                pumpHistory: pumpHistory,
                basalProfile: basalProfile,
                profile: profile,
                carbs: carbs,
                tempTargets: tempTargets,
                maxDeviations: 96,
                clock: clock,
                includeDeviationsForTesting: includeDeviationsForTesting
            )

            let ratio24h = try AutosensGenerator.generate(
                glucose: glucose,
                pumpHistory: pumpHistory,
                basalProfile: basalProfile,
                profile: profile,
                carbs: carbs,
                tempTargets: tempTargets,
                maxDeviations: 288,
                clock: clock,
                includeDeviationsForTesting: includeDeviationsForTesting
            )

            let lowestRatio = ratio8h.ratio < ratio24h.ratio ? ratio8h : ratio24h

            return try .success(JSONBridge.to(lowestRatio))
        } catch {
            return .failure(error)
        }
    }
}
