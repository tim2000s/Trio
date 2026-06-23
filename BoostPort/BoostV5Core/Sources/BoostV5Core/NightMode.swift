import Foundation

/// Boost "night mode" decision.
///
/// Faithful port of `OpenAPSBoostPlugin.isNightModeActiveImpl()` from AAPS
/// (`plugins/aps/.../openAPSBoost/OpenAPSBoostPlugin.kt`, ~lines 1476–1523).
///
/// In the Kotlin source the *only* effect of night mode being active is that
/// SMB is suppressed (`isSMBModeEnabled` sets the constraint to `false` when
/// `isNightModeActive()` is true, line 1439). Night mode does **not** lower the
/// glucose target — `profileTargetMgdl` is passed through unchanged. The
/// expression `bg < profileTarget + bgOffset` is the *activation gate*, not a
/// target adjustment (the catalog summary conflates the two). See the porting
/// report for details.
///
/// Gate order, matching the Kotlin source exactly:
///   1. `enabled` (else inactive)
///   2. clock-window OR (sleepActive AND autoBySleep) — else inactive
///   3. if `disableWithCob` and `cob > 0` — inactive
///   4. if `disableWithLowTt` and an active TT is *below* profileTarget — inactive
///   5. active iff `bg < profileTarget + bgOffsetMgdl`
public struct NightModeConfig: Equatable, Sendable {
    public var enabled: Bool
    /// Minute-of-day [0, 1440) of the night-window start.
    public var startMinute: Int
    /// Minute-of-day [0, 1440) of the night-window end.
    public var endMinute: Int
    /// BG offset in mg/dL added to the profile target for the activation gate.
    /// AAPS default: `UnitDoubleKey.ApsBoostNightModeBgOffset` = 27.0 mg/dL.
    public var bgOffsetMgdl: Double
    public var disableWithCob: Bool
    public var disableWithLowTt: Bool
    public var autoBySleep: Bool

    public init(
        enabled: Bool = false,
        startMinute: Int,
        endMinute: Int,
        bgOffsetMgdl: Double = 27,
        disableWithCob: Bool = false,
        disableWithLowTt: Bool = false,
        autoBySleep: Bool = false
    ) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.bgOffsetMgdl = bgOffsetMgdl
        self.disableWithCob = disableWithCob
        self.disableWithLowTt = disableWithLowTt
        self.autoBySleep = autoBySleep
    }
}

public struct NightModeInputs: Equatable, Sendable {
    /// Current local clock as minute-of-day [0, 1440).
    public var nowMinuteOfDay: Int
    /// Current glucose, mg/dL.
    public var bg: Double
    /// Profile target, mg/dL.
    public var profileTargetMgdl: Double
    /// Carbs on board (meal COB).
    public var cob: Double
    /// Active temp-target value in mg/dL, or `nil` when no TT is active.
    public var activeTempTargetMgdl: Double?
    /// Sleep detector reports a non-AWAKE state.
    public var sleepActive: Bool
    public var config: NightModeConfig

    public init(
        nowMinuteOfDay: Int,
        bg: Double,
        profileTargetMgdl: Double,
        cob: Double,
        activeTempTargetMgdl: Double?,
        sleepActive: Bool,
        config: NightModeConfig
    ) {
        self.nowMinuteOfDay = nowMinuteOfDay
        self.bg = bg
        self.profileTargetMgdl = profileTargetMgdl
        self.cob = cob
        self.activeTempTargetMgdl = activeTempTargetMgdl
        self.sleepActive = sleepActive
        self.config = config
    }
}

public struct NightModeResult: Equatable, Sendable {
    /// Whether night mode is active.
    public var active: Bool
    /// Whether SMB should be suppressed (true iff `active` — night mode's only
    /// effect in the AAPS source).
    public var suppressSmb: Bool
    /// The (possibly lowered) target. In the faithful AAPS port night mode does
    /// not change the target, so this equals `profileTargetMgdl`.
    public var targetMgdl: Double
    /// Short tag describing which gate decided the outcome.
    public var reason: String

    public init(active: Bool, suppressSmb: Bool, targetMgdl: Double, reason: String) {
        self.active = active
        self.suppressSmb = suppressSmb
        self.targetMgdl = targetMgdl
        self.reason = reason
    }
}

public enum NightMode {
    /// Pure evaluation of the night-mode decision. No clock or I/O access.
    public static func evaluate(_ inputs: NightModeInputs) -> NightModeResult {
        let cfg = inputs.config
        let target = inputs.profileTargetMgdl

        // Gate 1: master enable.
        guard cfg.enabled else {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "disabled")
        }

        // Gate 2: clock window OR (sleepActive AND autoBySleep).
        // Kotlin: `if (!active && !sleepActive) return false`, where `sleepActive`
        // is itself gated by `autoBySleep`.
        let inWindow = minuteInWindow(
            now: inputs.nowMinuteOfDay,
            start: cfg.startMinute,
            end: cfg.endMinute
        )
        let sleepActive = cfg.autoBySleep && inputs.sleepActive
        guard inWindow || sleepActive else {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "outside-window")
        }

        // Gate 3: disable when COB > 0.
        if cfg.disableWithCob, inputs.cob > 0 {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "cob")
        }

        // Gate 4: disable when an active temp target is below the profile target.
        if cfg.disableWithLowTt, let tt = inputs.activeTempTargetMgdl, tt < target {
            return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "low-tt")
        }

        // Gate 5: BG must be below profileTarget + bgOffset.
        let active = inputs.bg < target + cfg.bgOffsetMgdl
        if active {
            return NightModeResult(active: true, suppressSmb: true, targetMgdl: target, reason: "active")
        }
        return NightModeResult(active: false, suppressSmb: false, targetMgdl: target, reason: "bg-high")
    }

    /// Circular minute-of-day window membership: `[start, end)`.
    ///
    /// Mirrors the Kotlin midnight-wrap logic
    /// (`if (end > start) now in start until end else wrap`). When `end > start`
    /// the window is a simple half-open interval; otherwise it wraps midnight
    /// (e.g. 22:00→07:00). When `start == end` the window is empty, matching the
    /// Kotlin `end > start` branch falling into the wrap form with no coverage.
    static func minuteInWindow(now: Int, start: Int, end: Int) -> Bool {
        if end > start {
            return now >= start && now < end
        } else if end < start {
            // Wraps midnight: [start, 1440) ∪ [0, end).
            return now >= start || now < end
        } else {
            // start == end: empty window.
            return false
        }
    }
}
