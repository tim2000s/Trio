# Boost-in-Trio

A faithful functional port of the AndroidAPS **"Boost"** algorithm into [Trio](https://github.com/nightscout/Trio) (iOS). It runs as an optional, mode-gated second pass over Trio's existing oref determination — so stock Trio behaviour is preserved unless you explicitly turn Boost **Active**.

> **Branch:** `Boost-in-Trio-v0.1`
> **Source of truth:** the AndroidAPS branch `Boost-V6-mealtime-alpha` (a V5‑dosing build) — the port is verified line‑by‑line against it, not against upstream AndroidAPS.

---

## ⚠️ Safety / disclaimer

This is **experimental, do‑it‑yourself, open‑source software for an automated insulin‑delivery system**. It is **not** a medical device, is **not** approved by any regulator, and carries **no warranty**. It is not affiliated with or endorsed by the Trio or Nightscout projects.

Automated insulin dosing can cause serious harm, including severe hypoglycaemia. **You are solely responsible** for any device you build and run. Do not use this unless you fully understand the algorithm, can read the code, and accept the risk. Start in **Shadow** mode and review the logs before considering **Active**.

---

## What Boost is

Boost is an SMB‑centric dosing layer originally built for AndroidAPS. The port brings three pieces of that algorithm into Trio:

- **Dynamic ISF (V1)** — a TDD/BG‑context sensitivity model (`sensNormalTarget = 1800 / (TDD·ln(normalTarget/divisor+1))`, velocity‑blended `variable_sens`, soft BG caps, optional circadian curve), replacing oref autosens for the dosing path. A separate **`future_sens`** computes a BG‑context‑weighted dosing ISF used only for the insulin‑requirement maths.
- **V5 meal engine** — a meal‑hypothesis **state machine** (IDLE → OBSERVING → CONFIRMED → COMMITTED → RECOVERING) driven by a continuous meal‑likelihood **signal score**, an **aggression budget**, per‑state **action multipliers**, and an ordered **Phase‑3 safety‑gate** stack. Two LightGBM models (hypo‑risk + meal‑likelihood) feed the score and damping.
- **V6 + environment** — anticipatory pre‑meal target, learned night window / sleep detection, and the activity/HR plumbing that shapes the inputs.

When Active, V5's computed SMB **overrides** the stock determination's SMB on cycles where a microbolus is allowed — exactly as the AndroidAPS build does.

## Modes (the safety gate)

Set under **Settings → Features → Boost (V5)**:

| Mode | Behaviour |
|------|-----------|
| **Off** | Stock Trio only. The entire Boost pass is skipped. |
| **Shadow (log only)** | Runs the full Boost engine and appends *what it would do* to the determination reason. **Does not change dosing** — output is byte‑identical to stock Trio. |
| **Active (doses)** | Boost's DynISF shapes the determination and V5 drives the SMB. |

**Shadow‑safety contract:** with mode `Off` or `Shadow`, the dosing output (units, rate, insulinReq, forecasts) is **byte‑identical to stock Trio** — every dosing‑affecting change is gated on `== .active`. This is verified by audit and is the foundation for evaluating Boost safely before enabling it.

## Architecture

```
BoostPort/BoostV5Core/            ← pure SwiftPM package (no Trio/HealthKit deps), unit-tested
  DynIsf, CircadianISF            ← DynISF V1 + future_sens maths
  BoostV5Engine, MealHypothesis,  ← V5 state machine + score + budget + gates
  MealSignalScore, AggressionBudget, SafetyGates
  BoostTreeModel, BoostMlFeatureBuilder  ← LightGBM inference + v12 feature/ring-buffer builder
  SleepStateDetector, SleepHistoryTracker, NightMode, ActivityClassifier
  …

Trio/Sources/APS/OpenAPSSwift/Boost/   ← Trio-side glue
  BoostISF                        ← DynISF wiring into the determination
  BoostV5Adapter                  ← assembles V5 inputs, runs the engine, ML features, night mode
  BoostMLModels                   ← loads the bundled models + ring-buffer persistence
  BoostActivityStore / BoostMealTimeStore   ← UserDefaults-backed snapshots/history

Trio/Sources/Services/HealthKit/BoostActivityMonitor.swift  ← steps + HR → sleep/activity state
```

`BoostV5Core` is a pure package compiled **into** the Trio target (deterministic, unit‑testable in isolation). The glue layer adapts Trio's models and HealthKit to the core, and the second pass lives in `OpenAPSSwift.determineBasal`.

## Enabling it

1. **Settings → Features → Boost (V5)** → pick **Shadow** first.
2. Review the determination `reason` (and Nightscout devicestatus) — Boost logs its hypothesis state, score, and would‑be SMB each cycle.
3. Tune the V5 knobs and DynISF if needed (see below).
4. Only switch to **Active** once you understand the shadow behaviour and accept the risk.

For sleep/night features to work, grant **Health** read access (steps + heart rate) when prompted; until then they are silently inert.

## Settings

Under **Settings → Features**, the Boost sections are:

- **Boost (V5)** — mode (Off / Shadow / Active).
- **Boost V5 Tuning** — Aggression, Hypo Caution, Sensitivity, Confirmed/Committed dose caps, fast‑carb confirm.
- **Boost Dynamic ISF** — Use TDD, Circadian ISF, normal target, BG cap, velocity %, adjustment factor %.
- **Boost Night Mode** — overnight SMB suppression: window, BG offset, disable‑with‑COB / low‑TT, auto‑by‑sleep.
- **Boost V6 Pre‑Meal** — anticipatory lower‑only target before learned meal times.
- **Boost Exercise — Steps / Heart Rate / Post‑Exercise** — activity classification inputs (see *Deferred* below).

Glucose‑valued settings respect your mmol/L vs mg/dL display unit.

## Overnight behaviour

This mirrors the running AndroidAPS build:

1. A **drought‑based sleep detector** (HR + steps + clock, with HR‑drought and transmission‑resume handling) decides SLEEPING — robust to the sparse overnight HR HealthKit typically provides.
2. While asleep, **V5 stops overriding the SMB** and the de‑aggressed base dose stands.
3. **Night mode** suppresses SMB on top of that within the night window.
4. A **SleepHistoryTracker** learns your habitual night window and resting HR over ~28 days (≥7 sessions) and feeds them to the detector; below that threshold it uses the configured values.

The sleep detector is advanced on the loop cadence (not only on HealthKit callbacks) so it cannot go stale overnight.

## Faithfulness, and what is intentionally different

**Verified faithful to `Boost-V6-mealtime-alpha`:** the V5 engine (every state‑machine threshold, signal‑score weight, aggression budget, and safety gate), the DynISF/`future_sens` maths, the **v12 hypo‑risk model** (53‑feature vector + 6‑cycle lag ring buffer; model JSON byte‑identical) and the 8‑feature meal model, the drought sleep detector, SleepHistoryTracker, and night mode.

**Intentionally different / deferred:**
- **Activity‑load (festival) telemetry** — ported but **not wired** (shadow‑only logging; zero dosing effect). Deferred.
- **Exercise / post‑exercise** modifiers — inputs are collected but not yet fed to the dose path; deferred pending shadow analysis.
- **Flat‑CGM (`sensorQualityOk`) gate** — AndroidAPS only ever engages this for Libre 1; Trio's glucose layer carries no sensor‑type, so it is inert (matches non‑Libre‑1 behaviour).
- **Boost time‑window, Use‑TDD + Adjust‑Sensitivity, TT‑sensitivity** — present in AndroidAPS but **disabled** in the reference build, so they are not ported (Trio matches at defaults). `future_sens` therefore runs as always‑in‑window.
- **TDD blend** — Trio uses its single blended TDD; the AndroidAPS weighted‑8h pull‑down blend is not reproduced.

## Testing

Two layers: deterministic **unit tests** of the pure core, and **backtests** that replay the port
over large volumes of real captured data and golden‑master it against the AndroidAPS reference.

### Unit tests

`BoostV5Core` ships ~190 unit tests (state machine, gates, DynISF, ML feature builder + ring buffer, sleep detector, history tracker, night mode). Run them with:

```sh
cd BoostPort/BoostV5Core && swift test
```

The full app is built with `xcodebuild` against the Trio workspace as usual.

### Backtests against real captured data

The port is replayed locally over real device data and checked, cycle‑by‑cycle, against what the
AndroidAPS Boost reference actually computed. Volume matters here — these run over **hundreds of
thousands of real cycles across multiple users**, not synthetic fixtures. All run via `swift test`;
fixtures are gitignored (real glucose/insulin data) and the suites `XCTSkip` cleanly without them.
Full method, results and limits: [`BoostPort/docs/REPLAY.md`](BoostPort/docs/REPLAY.md).

**1. DynISF golden master** (`Tests/BoostV5CoreTests/Replay/DynIsfReplayTests.swift`) — replays the
DynISF/`future_sens` maths over **266,323 cycles across 7 users** (Feb–Jun 2026) captured from the
AndroidAPS **Boost v4.1.5** reference (`boost_decisions` in the local TimescaleDB, exported by
[`BoostPort/sim/export_boost_decisions.sh`](BoostPort/sim/export_boost_decisions.sh)). Per‑profile
divisor fit; out‑of‑scope variants (v4.2–v4.4.2, v3) detected and excluded:

| check | rows | match |
|------|------|-------|
| `variableSens` (end‑to‑end ISF) | 129,063 | **99.97%** |
| `isfTargetV1 × globalScale` | 135,147 | **99.97%** |
| `blendedTdd` / `finalTdd` | 136,947 | **99.78%** |
| `deltaAccl` | 38,021 | **100.0%** |

**2. Engine robustness** (`BoostEngineReplayTests.swift`) — drives the full V5 state machine over the
same **266,323 real glucose trajectories** (per‑user timelines): **0 violations** — no NaN/inf, no
negative dose, none over maxIOB.

**3. Dosing‑delivery golden master** (`V5ShadowReplayTests.swift`) — the dosing‑path check. Replays
the **on‑device V5 shadow** (`openaps.suggested.boostV5_*` in Nightscout deviceStatus, produced by
the AndroidAPS Kotlin V5) through the Swift port's dose‑cap + Phase‑3 safety‑gate stages over
**19,196 cycles across 5 users** (rolling last 10 days; fixture built by
[`BoostPort/sim/fetch_v5shadow.py`](BoostPort/sim/fetch_v5shadow.py)):

Reproducibility note: a few V5 inputs aren't in the telemetry (the velocity 30‑min rise; the
on‑device ML risk model), so the figures below are *as close as the logged data allows* — the
test reports exactly which residuals are missing‑input vs a genuine difference, rather than a bare
"match %". The one stage needing no reconstruction (action multiplier) is exact.

| dosing stage | rows | reproduced | residual is… |
|------|------|------|------|
| action multiplier (per state) | 19,196 | **100.0%** | — (nothing to reconstruct) |
| iobHeadroom safety brake | 19,196 | **98.4%** | logged `maxIOB` ≠ the gate's input on a few cycles |
| deceleration safety brake | 5,691 | **96.5%** | `deltaAccl` logged at 1–2 dp (formula itself exact) |
| final SMB dose (uncapped states) | 12,314 | **97.0%** | see decomposition below |

The dose row decomposes — and the genuine‑difference count is the number that matters:

| | share | meaning |
|---|---|---|
| exact (velocity factor 1.0) | 71.8% | reproduced outright |
| velocity‑reconciled | 25.2% | a velocity factor ∈ [0.4, 1.0] reproduces it — the 30‑min rise that sets it **isn't logged** |
| ML hypo‑risk brake | 3.0% | device dosed **less**; the post‑action brake needs the on‑device ML model (all such cycles carry ML risk) |
| **genuine port‑vs‑reference difference** | **0.0%** | — |

**What dosing delivery this confirms:** **97.0%** of uncapped doses reproduce within the inputs we
have, and **0%** are a genuine port difference — every residual is an input the offline replay
can't supply (velocity rise, ML risk model), and all of them make the *device* dose less, never the
port more. The soft safety‑brakes and per‑state action multiplier reproduce the on‑device AndroidAPS
V5 directly, and the engine emits no out‑of‑bounds dose across 266k trajectories.

**What it does not (honest limits, see REPLAY.md):** the **HARD min‑guard hypo‑gate** (~25% of
cycles) can't be telemetry‑validated — the gate's sanitised input isn't logged (the recorded
`minGuardBG` is oref's raw, unbounded value); and **CONFIRMED/COMMITTED dose caps** are a
configurable Trio setting the shadow doesn't apply, so the capped value isn't reproduced. Closing
both needs a few extra fields in the on‑device shadow log, or Trio's own Shadow mode to emit
`boostV5_*` for a like‑for‑like compare.

**Records:**
- [`BoostPort/docs/REPLAY.md`](BoostPort/docs/REPLAY.md) — backtest method, results, and scope/limits.
- [`BoostPort/docs/TESTS.md`](BoostPort/docs/TESTS.md) — per-suite unit-test results (193 tests, 0 failures).
- [`BoostPort/docs/AUDIT.md`](BoostPort/docs/AUDIT.md) — the adversarial audit passes, findings by severity, and the final verdict.

## Credits & licence

Boost is the work of [@tim2000s](https://github.com/tim2000s). Trio is © the Trio/Nightscout contributors and is licensed under its own terms (see the root `LICENSE`/`README.md`); this port inherits that licence. Built on the work of the OpenAPS, AndroidAPS, Loop, and Trio communities.
