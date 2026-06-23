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
                    boostSlider("Confirmed cap (U)", $state.boostV5ConfirmedCapU, in: 0 ... 5, step: 0.05)
                    boostSlider("Committed cap (U)", $state.boostV5CommittedCapU, in: 0 ... 1, step: 0.05)
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
        step: Double
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
                step: step
            )
        }
    }
}
