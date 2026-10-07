import HeadsetControlKit
import OmniKit
import SwiftUI

/// The app settings, shared by the popover's Settings pane and the window's Settings tab.
struct SettingsForm: View {
    @Environment(AppModel.self) private var model
    /// The popover shows About as a separate pane; the window shows it inline.
    var showAbout: (() -> Void)?

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Picker("Check headset every", selection: $preferences.pollInterval) {
                    ForEach(Preferences.pollIntervalChoices, id: \.self) { seconds in
                        Text(pollIntervalText(seconds)).tag(seconds)
                    }
                }
                Toggle("Show battery level in menu bar", isOn: $preferences.showBatteryPercentage)
                Toggle(isOn: $preferences.reapplyOnConnect) {
                    Text("Restore settings on reconnect")
                    Text("The base station can forget settings when it loses power. Hushdeck sends your last choices again when the headset comes back.")
                }
                if let device = model.device, !model.remembered.isEmpty {
                    Button("Forget Saved Settings") { model.forgetRememberedSettings() }
                        .help("Forget what Hushdeck remembers for \(device.name)")
                }
                if model.omni.hasRememberedSettings {
                    Button("Forget Saved Omni Settings") { model.omni.forgetRemembered() }
                        .help("Forget the settings Hushdeck would restore on the Arctis Nova Pro Omni")
                }
            }

            NotificationsSection()

            Section("HeadsetControl") {
                LabeledContent("In use") {
                    if let location = model.binaryLocation {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(location.source.localizedName)
                            if let version = model.cliVersion {
                                Text(version).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Not found").foregroundStyle(.red)
                    }
                }
                if let location = model.binaryLocation {
                    Text(location.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                TextField("Custom path", text: $preferences.binaryPathOverride, prompt: Text("Automatic"))
                    .textFieldStyle(.roundedBorder)
                if model.overrideIsInvalid {
                    Label("No executable at that path. Using the automatic location instead.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Choose…") { model.chooseBinary() }
                    if !preferences.binaryPathOverride.isEmpty {
                        Button("Use Automatic") { preferences.binaryPathOverride = "" }
                    }
                }
            }

            DeveloperSection()

            Section {
                if let showAbout {
                    Button(action: showAbout) {
                        HStack {
                            Text("About Hushdeck")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    LabeledContent("Hushdeck") {
                        Text("Version \(AppInfo.version) (\(AppInfo.build))")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("Talks to the Arctis Nova Pro Omni GameHub directly over USB (OmniKit) and to other headsets through HeadsetControl. Open the About pane in the menu bar for licences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Low-battery, fully-charged and spare-battery alerts. Permission is requested the first
/// time any toggle is switched on.
private struct NotificationsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        Section("Notifications") {
            Toggle(isOn: $preferences.lowBatteryAlert) {
                Text("Low battery")
                Text("Once per charge, when the headset drops to the level below.")
            }
            if preferences.lowBatteryAlert {
                Picker("Alert at", selection: $preferences.lowBatteryThreshold) {
                    ForEach(thresholdChoices, id: \.self) { value in
                        if value == BatteryAlertPolicy.ggThreshold {
                            Text("\(percentString(value)) (like SteelSeries GG)", comment: "Low battery threshold that matches GG's own rule").tag(value)
                        } else {
                            Text(percentString(value)).tag(value)
                        }
                    }
                }
            }
            Toggle("Fully charged", isOn: $preferences.fullyChargedAlert)
            Toggle(isOn: $preferences.spareChargedAlert) {
                Text("Spare battery charged")
                Text("When the spare battery in the Omni GameHub reaches 100 %.")
            }

            if preferences.wantsNotifications {
                switch model.notificationPermission {
                case .denied:
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Notifications are turned off for Hushdeck.", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Button("Open Notification Settings…") { SystemNotifier.openSystemSettings() }
                    }
                    .font(.caption)
                case .unavailable:
                    Label("Notifications only work when Hushdeck runs as an app bundle.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .notDetermined, .authorized:
                    EmptyView()
                }
            }
        }
        .task { await model.updateNotificationPermission(requestIfNeeded: false) }
    }

    private var thresholdChoices: [Int] {
        let current = model.preferences.lowBatteryThreshold
        let choices = Preferences.lowBatteryThresholdChoices
        return choices.contains(current) ? choices : (choices + [current]).sorted()
    }
}

/// Test device, experimental EQ uploads, and the simulated GameHub's controls.
private struct DeveloperSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        Section("Developer") {
            Toggle(isOn: $preferences.useTestDevice) {
                Text("Use test device")
                if preferences.environmentForcesTestDevice {
                    Text("On because HUSHDECK_TEST_DEVICE is set.")
                } else {
                    Text("Talk to HeadsetControl’s simulated headset instead of real hardware.")
                }
            }
            .disabled(preferences.environmentForcesTestDevice)
            if preferences.effectiveUseTestDevice {
                Picker("Test profile", selection: $preferences.testProfile) {
                    ForEach(Preferences.testProfileChoices, id: \.self) { profile in
                        Text(testProfileName(profile)).tag(profile)
                    }
                }
                .disabled(preferences.environmentTestProfile != nil)
                .help("Simulate battery and error states. HUSHDECK_TEST_PROFILE overrides this.")
            }

            Toggle(isOn: $preferences.experimentalEQWrites) {
                Text("Allow equalizer uploads to the Omni GameHub")
                Text("Confirmed on the hub: new bands are stored in its Custom slot, and factory presets keep their built-in curves. Turn this off to keep equalizer edits in Hushdeck only.")
            }

            if let simulator = model.omni.simulator {
                SimulatorControls(simulator: simulator)
            }
        }
    }

    private func testProfileName(_ profile: Int) -> String {
        switch profile {
        case 0: String(localized: "Normal battery", comment: "Test profile: battery at 42 percent")
        case 1: String(localized: "Errors", comment: "Test profile: every read fails")
        case 2: String(localized: "Charging", comment: "Test profile: charging at 50 percent")
        case 3: String(localized: "Basic battery", comment: "Test profile: level without time estimates")
        case 4: String(localized: "Headset off", comment: "Test profile: battery unavailable")
        case 5: String(localized: "Timeout", comment: "Test profile: battery read times out")
        case 6: String(localized: "Full battery", comment: "Test profile: 100 percent")
        case 7: String(localized: "Low battery", comment: "Test profile: 10 percent")
        case 10: String(localized: "Limited controls", comment: "Test profile: few capabilities")
        default: profile.formatted()
        }
    }
}

/// Buttons that drive `SimulatedOmniTransport` (HUSHDECK_SIMULATED_OMNI=1).
private struct SimulatorControls: View {
    @Environment(AppModel.self) private var model
    let simulator: SimulatedOmniTransport

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Button("Unplug Hub") { simulator.simulateHubDisconnect() }
                        .disabled(!model.omni.isPresent)
                    Button("Plug In Hub") { simulator.simulateHubReconnect() }
                        .disabled(model.omni.isPresent)
                }
                HStack {
                    Button("Headset Off") { simulator.simulateHeadsetPower(on: false) }
                    Button("Headset On") { simulator.simulateHeadsetPower(on: true) }
                }
                HStack {
                    Button("Drain 10 %") { simulator.simulateBatteryDrain(by: 10) }
                    Button("Hot Swap") { simulator.simulateBatteryHotSwap() }
                    Button("Toggle Mute") { simulator.simulateMicMuteToggle() }
                }
            }
            .controlSize(.small)
            .disabled(!model.omni.isStarted)
        } label: {
            Text("Simulated GameHub")
            Text("HUSHDECK_SIMULATED_OMNI is set, so Hushdeck talks to OmniKit’s fake hub.")
        }
    }
}
