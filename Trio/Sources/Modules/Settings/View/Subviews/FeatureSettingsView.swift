//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import SwiftUI
import Swinject

struct FeatureSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Trio Features"),
                content: {
                    Text("Treatments").navigationLink(to: .treatmentsSettings, from: self)
                    Text("Shortcuts").navigationLink(to: .shortcutsConfig, from: self)
                    Text("Remote Control").navigationLink(to: .remoteControlConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Trio Personalization"),
                content: {
                    Text("User Interface").navigationLink(to: .userInterfaceSettings, from: self)
                    Text("App Icons").navigationLink(to: .iconConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Anonymized Data Sharing"),
                content: {
                    Text("App Diagnostics").navigationLink(to: .appDiagnostics, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Boost (V5)"),
                footer: Text(
                    "Off: stock Trio only. Shadow: runs the Boost V5 engine and logs what it would dose (in the determination reason) without changing dosing. Active: Boost V5 drives the SMB."
                ),
                content: {
                    Picker("Boost Mode", selection: $state.boostMode) {
                        ForEach(BoostMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            )
            .listRowBackground(Color.chart)

            if state.boostMode != .off {
                Section(header: Text("Boost V5 Tuning")) {
                    boostSlider("Aggression", $state.boostV5Aggression, in: 0.7 ... 1.3, step: 0.05)
                    boostSlider("Hypo Caution", $state.boostV5HypoCaution, in: 1.0 ... 2.0, step: 0.05)
                    boostSlider("Sensitivity", $state.boostV5Sensitivity, in: 0.8 ... 1.2, step: 0.05)
                    boostSlider("Confirmed cap (U)", $state.boostV5ConfirmedCapU, in: 0 ... 7.5, step: 0.05) {
                        state.markBoostV5ConfirmedCapUserSet()
                    }
                    boostSlider("Committed cap (U)", $state.boostV5CommittedCapU, in: 0 ... 2.5, step: 0.05) {
                        state.markBoostV5CommittedCapUserSet()
                    }
                    Toggle("Fast-carb confirm", isOn: $state.boostV5FastCarbConfirm)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Boost Dynamic ISF"),
                    footer: Text(
                        "Applies only in Active mode. Use TDD derives ISF from total daily dose; Circadian ISF applies a time-of-day sensitivity curve."
                    )
                ) {
                    Toggle("Use TDD", isOn: $state.boostUseTdd)
                    Toggle("Circadian ISF", isOn: $state.boostEnableCircadianIsf)
                    boostGlucoseSlider("Normal target", $state.boostDynIsfNormalTarget, inMgdl: 70 ... 120)
                    boostGlucoseSlider("BG cap", $state.boostDynIsfBgCap, inMgdl: 100 ... 300)
                    boostSlider("Velocity %", $state.boostDynIsfVelocity, in: 0 ... 100, step: 5)
                    boostSlider("Adjustment factor %", $state.boostDynIsfAdjustmentFactor, in: 1 ... 300, step: 1)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Boost Night Mode"),
                    footer: Text(
                        "Suppresses SMB overnight (Active mode). Disable-with-COB/low-TT and auto-by-sleep optionally gate it."
                    )
                ) {
                    Toggle("Enabled", isOn: $state.boostNightModeEnabled)
                    if state.boostNightModeEnabled {
                        boostSlider("Start hour", $state.boostNightModeStartHour, in: 0 ... 23, step: 1)
                        boostSlider("End hour", $state.boostNightModeEndHour, in: 0 ... 23, step: 1)
                        boostGlucoseSlider("BG offset", $state.boostNightModeBgOffset, inMgdl: 0 ... 90)
                        Toggle("Disable with COB", isOn: $state.boostNightModeDisableWithCob)
                        Toggle("Disable with low TT", isOn: $state.boostNightModeDisableWithLowTt)
                        Toggle("Auto by sleep", isOn: $state.boostNightModeAutoBySleep)
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Boost V6 Pre-Meal"),
                    footer: Text(
                        "Active mode: fires an anticipatory low target before learned meal times so insulin rises before carbs land (lower-only; suppressed during exercise)."
                    )
                ) {
                    Toggle("Enabled", isOn: $state.boostV6PreMealEnabled)
                    if state.boostV6PreMealEnabled {
                        boostGlucoseSlider("Pre-meal target", $state.boostV6PreMealTargetMgdl, inMgdl: 65 ... 90)
                        boostSlider("Lead time (min)", $state.boostV6PreMealLeadMin, in: 30 ... 90, step: 5)
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Boost Exercise — Steps"),
                    footer: Text(
                        "Step thresholds (per window) that flag activity, and the profile % applied when active / inactive."
                    )
                ) {
                    boostSlider("Active steps / 5 min", $state.boostActivitySteps5, in: 0 ... 2000, step: 10)
                    boostSlider("Active steps / 15 min", $state.boostActivitySteps15, in: 0 ... 4000, step: 25)
                    boostSlider("Active steps / 30 min", $state.boostActivitySteps30, in: 0 ... 6000, step: 50)
                    boostSlider("Active steps / 60 min", $state.boostActivitySteps60, in: 0 ... 10000, step: 50)
                    boostSlider("Activity profile %", $state.boostActivityPct, in: 30 ... 150, step: 5)
                    boostSlider("Inactive steps / 60 min", $state.boostInactivitySteps, in: 0 ... 1000, step: 25)
                    boostSlider("Inactivity profile %", $state.boostInactivityPct, in: 100 ... 200, step: 5)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Boost Exercise — Heart Rate"),
                    footer: Text(
                        "When enabled, heart-rate zones refine activity classification (aerobic vs resistance vs stress)."
                    )
                ) {
                    Toggle("HR integration", isOn: $state.boostHrIntegrationEnabled)
                    if state.boostHrIntegrationEnabled {
                        boostSlider("Max HR (bpm)", $state.boostHrMaxBpm, in: 150 ... 220, step: 1)
                        boostSlider("Resting HR (bpm)", $state.boostHrRestingBpm, in: 30 ... 100, step: 1)
                        Toggle("Stress detection", isOn: $state.boostHrStressDetection)
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Boost Post-Exercise"),
                    footer: Text("After exercise, eases dosing for a recovery window (Active mode).")
                ) {
                    Toggle("Enabled", isOn: $state.boostPostExerciseEnabled)
                    if state.boostPostExerciseEnabled {
                        boostSlider("Recovery window (h)", $state.boostPostExerciseHours, in: 0.5 ... 8, step: 0.5)
                        boostGlucoseSlider("Recovery target", $state.boostPostExerciseTarget, inMgdl: 90 ... 200)
                        boostSlider("SMB scale", $state.boostPostExerciseScale, in: 0 ... 1, step: 0.05)
                        boostSlider("Min duration (min)", $state.boostPostExerciseMinDuration, in: 1 ... 120, step: 1)
                    }
                }
                .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Feature Settings")
        .navigationBarTitleDisplayMode(.automatic)
    }

    @ViewBuilder private func boostSlider(
        _ title: String,
        _ value: Binding<Decimal>,
        in range: ClosedRange<Double>,
        step: Double,
        onUserEdit: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", (value.wrappedValue as NSDecimalNumber).doubleValue))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { (value.wrappedValue as NSDecimalNumber).doubleValue },
                    set: { value.wrappedValue = Decimal($0) }
                ),
                in: range,
                step: step,
                onEditingChanged: { editing in
                    // Fires only on genuine user interaction (drag start/end), never programmatically —
                    // the right place to flag a knob as user-set. Mark on release.
                    if !editing { onUserEdit?() }
                }
            )
        }
    }

    /// Glucose-valued slider: stored in mg/dL, displayed + adjusted in the user's units.
    /// (mmol/L users see/drag mmol; the value persists as mg/dL via Trio's native asMgdL.)
    @ViewBuilder private func boostGlucoseSlider(
        _ title: String,
        _ valueMgdl: Binding<Decimal>,
        inMgdl rangeMgdl: ClosedRange<Double>
    ) -> some View {
        let mmol = state.units == .mmolL
        let unit = mmol ? "mmol/L" : "mg/dL"
        let range: ClosedRange<Double> = mmol
            ? (Decimal(rangeMgdl.lowerBound).asMmolL as NSDecimalNumber)
            .doubleValue ... (Decimal(rangeMgdl.upperBound).asMmolL as NSDecimalNumber).doubleValue
            : rangeMgdl
        let step: Double = mmol ? 0.1 : 1
        let shown = mmol
            ? String(format: "%.1f", (valueMgdl.wrappedValue.asMmolL as NSDecimalNumber).doubleValue)
            : String(format: "%.0f", (valueMgdl.wrappedValue as NSDecimalNumber).doubleValue)
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("\(shown) \(unit)").foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: {
                        mmol
                            ? (valueMgdl.wrappedValue.asMmolL as NSDecimalNumber).doubleValue
                            : (valueMgdl.wrappedValue as NSDecimalNumber).doubleValue
                    },
                    set: { newValue in
                        valueMgdl.wrappedValue = mmol ? Decimal(newValue).asMgdL : Decimal(newValue)
                    }
                ),
                in: range,
                step: step
            )
        }
    }
}
