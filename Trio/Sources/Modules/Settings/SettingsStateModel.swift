import CoreData
import Foundation
import LoopKit
import LoopKitUI
import SwiftUI
import TidepoolServiceKit

extension Settings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var broadcaster: Broadcaster!
        @Injected() private var fileManager: FileManager!
        @Injected() private var nightscoutManager: NightscoutManager!
        @Injected() var pluginManager: PluginManager!
        @Injected() var fetchCgmManager: FetchGlucoseManager!
        @Injected() private var storage: FileStorage!
        @Injected() var overrideStorage: OverrideStorage!

        @Published var units: GlucoseUnits = .mgdL
        @Published var closedLoop = false
        @Published var debugOptions = false
        @Published var boostMode: BoostMode = .off
        @Published var boostV5Aggression: Decimal = 1.0
        @Published var boostV5HypoCaution: Decimal = 1.0
        @Published var boostV5Sensitivity: Decimal = 1.0
        @Published var boostV5ConfirmedCapU: Decimal = 2.5
        @Published var boostV5CommittedCapU: Decimal = 0.5
        @Published var boostCumulativeSmbCap60Min: Decimal = 10.0
        @Published var boostV5FastCarbConfirm: Bool = true
        @Published var boostUseTdd: Bool = false
        @Published var boostEnableCircadianIsf: Bool = false
        @Published var boostDynIsfNormalTarget: Decimal = 99
        @Published var boostDynIsfBgCap: Decimal = 210
        @Published var boostDynIsfVelocity: Decimal = 100
        @Published var boostDynIsfAdjustmentFactor: Decimal = 100
        @Published var boostNightModeEnabled: Bool = false
        @Published var boostNightModeStartHour: Decimal = 22
        @Published var boostNightModeEndHour: Decimal = 7
        @Published var boostNightModeBgOffset: Decimal = 27
        @Published var boostNightModeDisableWithCob: Bool = false
        @Published var boostNightModeDisableWithLowTt: Bool = false
        @Published var boostNightModeAutoBySleep: Bool = false
        @Published var boostV6PreMealEnabled: Bool = false
        @Published var boostV6PreMealTargetMgdl: Decimal = 72
        @Published var boostV6PreMealLeadMin: Decimal = 60
        @Published var boostActivitySteps5: Decimal = 420
        @Published var boostActivitySteps15: Decimal = 800
        @Published var boostActivitySteps30: Decimal = 1200
        @Published var boostActivitySteps60: Decimal = 1800
        @Published var boostActivityPct: Decimal = 80
        @Published var boostInactivitySteps: Decimal = 500
        @Published var boostInactivityPct: Decimal = 130
        @Published var boostHrIntegrationEnabled: Bool = false
        @Published var boostHrMaxBpm: Decimal = 180
        @Published var boostHrRestingBpm: Decimal = 60
        @Published var boostHrStressDetection: Bool = false
        @Published var boostPostExerciseEnabled: Bool = false
        @Published var boostPostExerciseHours: Decimal = 2
        @Published var boostPostExerciseTarget: Decimal = 144
        @Published var boostPostExerciseScale: Decimal = 0.5
        @Published var boostPostExerciseMinDuration: Decimal = 10
        @Published var serviceUIType: ServiceUI.Type?
        @Published var setupTidepool = false

        private(set) var buildNumber = ""
        private(set) var versionNumber = ""
        private(set) var branch = ""
        private(set) var copyrightNotice = ""

        override func subscribe() {
            units = settingsManager.settings.units

            subscribeSetting(\.debugOptions, on: $debugOptions) { debugOptions = $0 }
            subscribeSetting(\.closedLoop, on: $closedLoop) { closedLoop = $0 }
            subscribePreferencesSetting(\.boostMode, on: $boostMode) { boostMode = $0 }
            subscribePreferencesSetting(\.boostV5Aggression, on: $boostV5Aggression) { boostV5Aggression = $0 }
            subscribePreferencesSetting(\.boostV5HypoCaution, on: $boostV5HypoCaution) { boostV5HypoCaution = $0 }
            subscribePreferencesSetting(\.boostV5Sensitivity, on: $boostV5Sensitivity) { boostV5Sensitivity = $0 }
            subscribePreferencesSetting(\.boostV5ConfirmedCapU, on: $boostV5ConfirmedCapU) { boostV5ConfirmedCapU = $0 }
            subscribePreferencesSetting(\.boostV5CommittedCapU, on: $boostV5CommittedCapU) { boostV5CommittedCapU = $0 }
            subscribePreferencesSetting(\.boostCumulativeSmbCap60Min, on: $boostCumulativeSmbCap60Min) {
                boostCumulativeSmbCap60Min = $0 }
            subscribePreferencesSetting(\.boostV5FastCarbConfirm, on: $boostV5FastCarbConfirm) { boostV5FastCarbConfirm = $0 }
            subscribePreferencesSetting(\.boostUseTdd, on: $boostUseTdd) { boostUseTdd = $0 }
            subscribePreferencesSetting(\.boostEnableCircadianIsf, on: $boostEnableCircadianIsf) { boostEnableCircadianIsf = $0 }
            subscribePreferencesSetting(\.boostDynIsfNormalTarget, on: $boostDynIsfNormalTarget) { boostDynIsfNormalTarget = $0 }
            subscribePreferencesSetting(\.boostDynIsfBgCap, on: $boostDynIsfBgCap) { boostDynIsfBgCap = $0 }
            subscribePreferencesSetting(\.boostDynIsfVelocity, on: $boostDynIsfVelocity) { boostDynIsfVelocity = $0 }
            subscribePreferencesSetting(\.boostDynIsfAdjustmentFactor, on: $boostDynIsfAdjustmentFactor) {
                boostDynIsfAdjustmentFactor = $0 }
            subscribePreferencesSetting(\.boostNightModeEnabled, on: $boostNightModeEnabled) { boostNightModeEnabled = $0 }
            subscribePreferencesSetting(\.boostNightModeStartHour, on: $boostNightModeStartHour) { boostNightModeStartHour = $0 }
            subscribePreferencesSetting(\.boostNightModeEndHour, on: $boostNightModeEndHour) { boostNightModeEndHour = $0 }
            subscribePreferencesSetting(\.boostNightModeBgOffset, on: $boostNightModeBgOffset) { boostNightModeBgOffset = $0 }
            subscribePreferencesSetting(\.boostNightModeDisableWithCob, on: $boostNightModeDisableWithCob) {
                boostNightModeDisableWithCob = $0 }
            subscribePreferencesSetting(\.boostNightModeDisableWithLowTt, on: $boostNightModeDisableWithLowTt) {
                boostNightModeDisableWithLowTt = $0 }
            subscribePreferencesSetting(\.boostNightModeAutoBySleep, on: $boostNightModeAutoBySleep) {
                boostNightModeAutoBySleep = $0 }
            subscribePreferencesSetting(\.boostV6PreMealEnabled, on: $boostV6PreMealEnabled) { boostV6PreMealEnabled = $0 }
            subscribePreferencesSetting(\.boostV6PreMealTargetMgdl, on: $boostV6PreMealTargetMgdl) {
                boostV6PreMealTargetMgdl = $0 }
            subscribePreferencesSetting(\.boostV6PreMealLeadMin, on: $boostV6PreMealLeadMin) { boostV6PreMealLeadMin = $0 }
            subscribePreferencesSetting(\.boostActivitySteps5, on: $boostActivitySteps5) { boostActivitySteps5 = $0 }
            subscribePreferencesSetting(\.boostActivitySteps15, on: $boostActivitySteps15) { boostActivitySteps15 = $0 }
            subscribePreferencesSetting(\.boostActivitySteps30, on: $boostActivitySteps30) { boostActivitySteps30 = $0 }
            subscribePreferencesSetting(\.boostActivitySteps60, on: $boostActivitySteps60) { boostActivitySteps60 = $0 }
            subscribePreferencesSetting(\.boostActivityPct, on: $boostActivityPct) { boostActivityPct = $0 }
            subscribePreferencesSetting(\.boostInactivitySteps, on: $boostInactivitySteps) { boostInactivitySteps = $0 }
            subscribePreferencesSetting(\.boostInactivityPct, on: $boostInactivityPct) { boostInactivityPct = $0 }
            subscribePreferencesSetting(\.boostHrIntegrationEnabled, on: $boostHrIntegrationEnabled) {
                boostHrIntegrationEnabled = $0 }
            subscribePreferencesSetting(\.boostHrMaxBpm, on: $boostHrMaxBpm) { boostHrMaxBpm = $0 }
            subscribePreferencesSetting(\.boostHrRestingBpm, on: $boostHrRestingBpm) { boostHrRestingBpm = $0 }
            subscribePreferencesSetting(\.boostHrStressDetection, on: $boostHrStressDetection) { boostHrStressDetection = $0 }
            subscribePreferencesSetting(\.boostPostExerciseEnabled, on: $boostPostExerciseEnabled) {
                boostPostExerciseEnabled = $0 }
            subscribePreferencesSetting(\.boostPostExerciseHours, on: $boostPostExerciseHours) { boostPostExerciseHours = $0 }
            subscribePreferencesSetting(\.boostPostExerciseTarget, on: $boostPostExerciseTarget) { boostPostExerciseTarget = $0 }
            subscribePreferencesSetting(\.boostPostExerciseScale, on: $boostPostExerciseScale) { boostPostExerciseScale = $0 }
            subscribePreferencesSetting(\.boostPostExerciseMinDuration, on: $boostPostExerciseMinDuration) {
                boostPostExerciseMinDuration = $0 }
            broadcaster.register(SettingsObserver.self, observer: self)

            buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"

            versionNumber = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

            branch = BuildDetails.shared.branchAndSha

            copyrightNotice = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""

            serviceUIType = TidepoolService.self as? ServiceUI.Type
        }

        func logItems() -> [URL] {
            var items: [URL] = []

            if fileManager.fileExists(atPath: SimpleLogReporter.logFile) {
                items.append(URL(fileURLWithPath: SimpleLogReporter.logFile))
            }

            if fileManager.fileExists(atPath: SimpleLogReporter.logFilePrev) {
                items.append(URL(fileURLWithPath: SimpleLogReporter.logFilePrev))
            }

            return items
        }

        func hideSettingsModal() {
            hideModal()
        }

        // Commenting this out for now, as not needed and possibly dangerous for users to be able to nuke their pump pairing informations via the debug menu
        // Leaving it in here, as it may be a handy functionality for further testing or developers.
        // See https://github.com/nightscout/Trio/pull/277 for more information
//
//        func resetLoopDocuments() {
//            guard let localDocuments = try? FileManager.default.url(
//                for: .documentDirectory,
//                in: .userDomainMask,
//                appropriateFor: nil,
//                create: true
//            ) else {
//                preconditionFailure("Could not get a documents directory URL.")
//            }
//            let storageURL = localDocuments.appendingPathComponent("PumpManagerState" + ".plist")
//            try? FileManager.default.removeItem(at: storageURL)
//        }
        func hasCgmAndPump() -> Bool {
            let hasCgm = fetchCgmManager.cgmGlucoseSourceType != .none
            let hasPump = provider.deviceManager.pumpManager != nil
            return hasCgm && hasPump
        }

        // The user moved a V5 dosing-cap slider — record it so first-activation auto-config never
        // overrides a deliberately-set cap (Swift parity with Android's getIfExists==null). Called
        // from the slider's onEditingChanged (genuine user interaction only, never programmatic).
        func markBoostV5ConfirmedCapUserSet() { settingsManager.preferences.boostV5ConfirmedCapUUserSet = true }
        func markBoostV5CommittedCapUserSet() { settingsManager.preferences.boostV5CommittedCapUUserSet = true }
        func markBoostCumulativeSmbCap60MinUserSet() { settingsManager.preferences.boostCumulativeSmbCap60MinUserSet = true }
    }
}

extension Settings.StateModel: SettingsObserver {
    func settingsDidChange(_ settings: TrioSettings) {
        closedLoop = settings.closedLoop
        debugOptions = settings.debugOptions
    }
}

extension Settings.StateModel: ServiceOnboardingDelegate {
    func serviceOnboarding(didCreateService service: Service) {
        debug(.nightscout, "Service with identifier \(service.pluginIdentifier) created")
        provider.tidepoolManager.addTidepoolService(service: service)
    }

    func serviceOnboarding(didOnboardService service: Service) {
        precondition(service.isOnboarded)
        debug(.nightscout, "Service with identifier \(service.pluginIdentifier) onboarded")
    }
}

extension Settings.StateModel: CompletionDelegate {
    func completionNotifyingDidComplete(_: CompletionNotifying) {
        setupTidepool = false
        provider.tidepoolManager.forceTidepoolDataUpload()
    }
}
