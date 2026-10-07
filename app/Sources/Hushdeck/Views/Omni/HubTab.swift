import OmniKit
import SwiftUI

/// GG Engine → Settings: power, OLED screen, screen saver, Bluetooth, factory reset.
struct HubTab: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        Form {
            Section("Power") {
                LabeledContent {
                    Picker("Turn headset off after", selection: omni.binding(\.autoOff, fallback: .thirtyMinutes) { .autoOff($0) }) {
                        ForEach(OmniTimeout.allCases, id: \.self) { timeout in
                            timeoutLabel(timeout, zero: "Never").tag(timeout)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "Turn headset off after", feature: .autoOff,
                                 subtitle: "When no audio is playing.")
                }
            }

            Section {
                OmniIssueRow(issues: omni.issues(in: .display))
                OmniSliderRow(title: "Brightness", feature: .oledBrightness,
                              value: omni.sliderBinding(\.oledBrightness, fallback: 10) { .oledBrightness($0) },
                              range: 1...10)
                LabeledContent {
                    Picker("Home screen", selection: omni.binding(\.homeScreenView, fallback: .detailed) { .homeScreenView($0) }) {
                        ForEach(HomeScreenView.allCases, id: \.self) { view in
                            Text(view.localizedName).tag(view)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "Home screen", feature: .homeScreenView)
                }
                LabeledContent {
                    Picker("Home screen shows", selection: omni.binding(\.homeScreenOption, fallback: .stereo) { .homeScreenOption($0) }) {
                        ForEach(HomeScreenOption.allCases, id: \.self) { option in
                            Text(option.localizedName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "Home screen shows", feature: .homeScreenOption)
                }
            } header: {
                Text("Screen")
            }

            Section("Screen saver") {
                LabeledContent {
                    Picker("Start after", selection: omni.binding(\.screensaverTimeout, fallback: .tenMinutes) { .screensaverTimeout($0) }) {
                        ForEach(OmniTimeout.allCases, id: \.self) { timeout in
                            timeoutLabel(timeout, zero: "Off").tag(timeout)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "Start after", feature: .screensaverTimeout)
                }
                LabeledContent {
                    Picker("Screen saver", selection: omni.binding(\.screensaverMode, fallback: .dim) { .screensaverMode($0) }) {
                        ForEach(ScreensaverMode.allCases, id: \.self) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(omni.settings.screensaverTimeout == .never)
                } label: {
                    FeatureLabel(title: "Screen saver", feature: .screensaverMode)
                }
            }

            Section {
                Toggle(isOn: omni.binding(\.bluetoothPowerOnDefault, fallback: false) { .bluetoothPowerOnDefault($0) }) {
                    FeatureLabel(title: "Bluetooth at power on", feature: .bluetoothPowerOnDefault,
                                 subtitle: "Turn Bluetooth on whenever the headset powers on.")
                }
                LabeledContent {
                    Picker("During Bluetooth calls", selection: omni.binding(\.bluetoothCallBehaviour, fallback: .doNothing) { .bluetoothCallBehaviour($0) }) {
                        ForEach(BluetoothCallBehaviour.allCases, id: \.self) { behaviour in
                            Text(behaviour.localizedName).tag(behaviour)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "During Bluetooth calls", feature: .bluetoothCallBehaviour)
                }
                ReadoutRow("Bluetooth", feature: .bluetoothStatus, value: bluetoothStatus)
            } header: {
                Text("Bluetooth")
            }

            Section {
                LabeledContent {
                    Text("Not offered")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Factory reset")
                    Text("GG sends a reset command Hushdeck deliberately never sends: it hasn’t been tested and may unpair the headset. Reset from the GameHub itself: System Settings → Reset.")
                }
            } header: {
                Text("Reset")
            }
        }
        .formStyle(.grouped)
    }

    private var bluetoothStatus: String? {
        guard let mode = omni.readouts.bluetoothMode else { return nil }
        if mode == .linkMode, let link = omni.readouts.bluetoothLink {
            return "\(mode.localizedName) · \(link.localizedName)"
        }
        return mode.localizedName
    }
}
