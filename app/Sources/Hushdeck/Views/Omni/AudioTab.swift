import OmniKit
import SwiftUI

/// GG Engine → Audio: the two EQs, Output and stream mix, Noise Control, Volume Limiter.
struct AudioTab: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        Form {
            if !omni.headsetOnline {
                Section { OmniHeadsetOfflineNotice() }
            }

            Section {
                OmniIssueRow(issues: omni.issues(in: .wirelessEQ))
                ParametricEQEditor()
                    .padding(.vertical, 4)
            } header: {
                HStack(spacing: 6) {
                    Text("2.4 GHz wireless equalizer")
                    UnverifiedBadge(feature: .wirelessEQ)
                }
            } footer: {
                Text("Ten parametric bands, each with a frequency, filter type, gain in 0.1 dB steps and Q. The 2.4 GHz link uses this equalizer; Bluetooth has its own below.")
                    .sectionFooterStyle()
            }

            Section {
                OmniIssueRow(issues: omni.issues(in: .bluetoothEQ))
                GraphicEQEditor(kind: .bluetooth)
                    .padding(.vertical, 4)
            } header: {
                HStack(spacing: 6) {
                    Text("Bluetooth equalizer")
                    UnverifiedBadge(feature: .bluetoothEQ)
                }
            }

            Section("Output") {
                OmniIssueRow(issues: omni.issues(in: .audio))
                LabeledContent {
                    Picker("Line out", selection: omni.binding(\.outputMode, fallback: .speakers) { .outputMode($0) }) {
                        ForEach(OutputMode.allCases, id: \.self) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "Line out", feature: .outputMode,
                                 subtitle: "Streaming sends a separate mix to the line-out jack, for a second PC or a capture card.")
                }

                let mix = omni.settings.streamMix ?? StreamMix(main: 100, aux: 100, mic: 100)
                let streaming = omni.settings.outputMode == .streaming
                Group {
                    OmniSliderRow(title: "Main", feature: .streamMix, value: streamBinding(\.main, mix), range: 0...100, step: 5, valueText: percentText(100))
                    OmniSliderRow(title: "Aux", feature: .streamMix, value: streamBinding(\.aux, mix), range: 0...100, step: 5, valueText: percentText(100))
                    OmniSliderRow(title: "Microphone", feature: .streamMix, value: streamBinding(\.mic, mix), range: 0...100, step: 5, valueText: percentText(100))
                }
                .disabled(!streaming)
                .help("Stream mix levels apply in Streaming mode")
            }

            Section {
                NoiseControlRows()
                    .disabled(!omni.headsetOnline)
            } header: {
                Text("Noise control")
            } footer: {
                Text("The headset’s power button also toggles noise cancelling (single press) and transparency (double press). Changes made there show up here.")
                    .sectionFooterStyle()
            }

            Section("Volume") {
                Toggle(isOn: omni.binding(\.volumeLimiter, fallback: true) { .volumeLimiter($0) }) {
                    FeatureLabel(title: "Volume limiter", feature: .volumeLimiter,
                                 subtitle: "On keeps the output gain low; the GameHub’s screen calls this “Gain: Low”.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func streamBinding(_ keyPath: WritableKeyPath<StreamMix, Int>, _ current: StreamMix) -> Binding<Double> {
        Binding(
            get: { Double((omni.settings.streamMix ?? current)[keyPath: keyPath]) },
            set: { value in
                var mix = omni.settings.streamMix ?? current
                mix[keyPath: keyPath] = Int(value.rounded())
                omni.set(.streamMix(mix), debounce: .milliseconds(350))
            }
        )
    }
}

/// Mode segmented control with the level for the chosen mode beneath. Shared by the popover.
struct NoiseControlRows: View {
    @Environment(OmniController.self) private var omni
    var compact = false

    var body: some View {
        let mode = omni.settings.ancMode ?? .off
        if compact {
            modePicker
                .pickerStyle(.segmented)
                .labelsHidden()
            levelControl(mode)
        } else {
            LabeledContent {
                Picker("Mode", selection: omni.binding(\.ancMode, fallback: .off) { .ancMode($0) }) {
                    modeOptions
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                FeatureLabel(title: "Mode", feature: .ancMode)
            }
            levelControl(mode)
        }
    }

    private var modePicker: some View {
        Picker("Noise control", selection: omni.binding(\.ancMode, fallback: .off) { .ancMode($0) }) {
            modeOptions
        }
    }

    @ViewBuilder
    private var modeOptions: some View {
        Text("Off").tag(ANCMode.off)
        Text("Transparency").tag(ANCMode.transparency)
        Text("Noise cancelling", comment: "ANC mode").tag(ANCMode.activeNoiseCancellation)
    }

    @ViewBuilder
    private func levelControl(_ mode: ANCMode) -> some View {
        switch mode {
        case .activeNoiseCancellation:
            if compact {
                ControlRow(title: "Strength", symbol: "person.wave.2.fill", feature: .ancLevel) {
                    ancLevelPicker
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                }
            } else {
                LabeledContent {
                    Picker("Strength", selection: omni.binding(\.ancLevel, fallback: .high) { .ancLevel($0) }) {
                        ForEach(ANCLevel.allCases, id: \.self) { level in
                            Text(level.localizedName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    FeatureLabel(title: "Strength", feature: .ancLevel)
                }
            }
        case .transparency:
            if compact {
                LabeledSlider(title: "Transparency level", symbol: "person.wave.2",
                              value: omni.sliderBinding(\.transparencyLevel, fallback: 8) { .transparencyLevel($0) },
                              range: 1...10, feature: .transparencyLevel)
            } else {
                OmniSliderRow(title: "Transparency level", feature: .transparencyLevel,
                              value: omni.sliderBinding(\.transparencyLevel, fallback: 8) { .transparencyLevel($0) },
                              range: 1...10)
            }
        case .off:
            EmptyView()
        }
    }

    private var ancLevelPicker: some View {
        Picker("Strength", selection: omni.binding(\.ancLevel, fallback: .high) { .ancLevel($0) }) {
            ForEach(ANCLevel.allCases, id: \.self) { level in
                Text(level.localizedName).tag(level)
            }
        }
    }
}
