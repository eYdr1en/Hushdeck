import OmniKit
import SwiftUI

/// GG Engine → Microphone: mic EQ, volume, sidetone, mute light, noise reduction.
struct MicrophoneTab: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        Form {
            if !omni.headsetOnline {
                Section { OmniHeadsetOfflineNotice() }
            }

            Section {
                OmniIssueRow(issues: omni.issues(in: .micEQ))
                GraphicEQEditor(kind: .mic)
                    .padding(.vertical, 4)
            } header: {
                HStack(spacing: 6) {
                    Text("Microphone equalizer")
                    UnverifiedBadge(feature: .micEQ)
                }
            }

            Section("Level") {
                OmniIssueRow(issues: omni.issues(in: .audio))
                LabeledContent {
                    HStack(spacing: 10) {
                        if omni.readouts.micMuted == true {
                            Label("Muted", systemImage: "mic.slash.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .labelStyle(.titleAndIcon)
                                .help("The mute button on the headset is pressed")
                        }
                        Slider(value: omni.sliderBinding(\.micVolume, fallback: 8) { .micVolume($0) }, in: 1...10, step: 1)
                            .frame(minWidth: 140, maxWidth: 220)
                            .accessibilityLabel(Text("Mic level"))
                        Text((omni.settings.micVolume ?? 8).formatted())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 34, alignment: .trailing)
                    }
                } label: {
                    FeatureLabel(title: "Mic level", feature: .micVolume)
                }

                let sidetone = omni.settings.sidetone ?? Sidetone(isEnabled: true, level: 5)
                Toggle(isOn: Binding(
                    get: { omni.settings.sidetone?.isEnabled ?? true },
                    set: { omni.set(.sidetone(Sidetone(isEnabled: $0, level: sidetone.level))) }
                )) {
                    FeatureLabel(title: "Sidetone", feature: .sidetone, subtitle: "Hear your own voice in the headset.")
                }
                OmniSliderRow(
                    title: "Sidetone level", feature: .sidetone,
                    value: Binding(
                        get: { Double(omni.settings.sidetone?.level ?? 5) },
                        set: { omni.set(.sidetone(Sidetone(isEnabled: sidetone.isEnabled, level: Int($0.rounded()))), debounce: .milliseconds(350)) }
                    ),
                    range: 1...10
                )
                .disabled(!sidetone.isEnabled)

                OmniSliderRow(
                    title: "Mute light", feature: .mutedMicLEDBrightness,
                    subtitle: "Brightness of the red light on the boom while muted.",
                    value: omni.sliderBinding(\.mutedMicLEDBrightness, fallback: 10) { .mutedMicLEDBrightness($0) },
                    range: 0...10,
                    valueText: { $0 == 0 ? String(localized: "Off") : Int($0.rounded()).formatted() }
                )
            }

            Section {
                LabeledContent {
                    Picker("Noise reduction", selection: omni.binding(\.micNoiseReduction, fallback: .off) { .micNoiseReduction($0) }) {
                        ForEach(MicNoiseReduction.allCases, id: \.self) { level in
                            Text(level.localizedName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "Noise reduction", feature: .micNoiseReduction,
                                 subtitle: "On-device noise rejection for the boom mic. Works on every platform, unlike Sonar’s software filters.")
                }
            } header: {
                Text("Noise reduction")
            } footer: {
                Text("GG’s “Live Mic Preview” plays your mic back through the headset from the computer. Hushdeck doesn’t offer it yet; sidetone gives a similar check.")
                    .sectionFooterStyle()
            }
        }
        .formStyle(.grouped)
    }
}
