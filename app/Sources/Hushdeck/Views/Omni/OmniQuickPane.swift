import AppKit
import OmniKit
import SwiftUI

/// The popover when a GameHub is attached: battery and status, the quick controls, and a
/// button to the full window.
struct OmniQuickPane: View {
    @Environment(AppModel.self) private var model
    @Environment(OmniController.self) private var omni
    @State private var contentHeight: CGFloat = 0

    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 180
    }

    var body: some View {
        VStack(spacing: 0) {
            OmniHeader()
            Divider().padding(.horizontal, 12)
            if omni.isReady {
                ScrollView {
                    OmniQuickControls()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(contentHeight, 40), maxScrollHeight))
            } else {
                OmniSettlingView(compact: true)
            }
        }
    }
}

private struct OmniHeader: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        let readouts = omni.readouts
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "headset")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(omni.headsetOnline ? .primary : .tertiary)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: OmniController.deviceName)
                        .font(.headline)
                        .lineLimit(1)
                    if readouts.micMuted == true {
                        Label("Muted", systemImage: "mic.slash.fill")
                            .font(.caption2.weight(.medium))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.12), in: Capsule())
                            .help("The mute button on the headset is pressed")
                    }
                }
                headsetLine
                if omni.isReady, let spare = readouts.spareBattery {
                    spareLine(spare)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var headsetLine: some View {
        let readouts = omni.readouts
        HStack(spacing: 5) {
            if !omni.isReady {
                Text("Connecting…").foregroundStyle(.secondary)
            } else if !omni.headsetOnline {
                Text(readouts.headsetLink?.localizedName ?? String(localized: "Off or out of range"))
                    .foregroundStyle(.secondary)
                UnverifiedBadge(feature: .headsetLink, style: .dot)
            } else if let level = readouts.trustedHeadsetBattery {
                let charging = readouts.charging == .charging
                Image(systemName: batterySymbol(level: level, charging: charging))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(readouts.isBatteryLow || (level <= 15 && !charging) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Text(percentString(level)).monospacedDigit()
                if let charging = readouts.charging {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(charging.localizedName).foregroundStyle(.secondary)
                }
            } else {
                Text("Connected").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func spareLine(_ spare: Int) -> some View {
        let headset = omni.readouts.trustedHeadsetBattery ?? 100
        let swapReady = omni.headsetOnline && headset <= 20 && spare >= 80
        return HStack(spacing: 5) {
            Image(systemName: spare >= 100 ? "battery.100percent" : "battery.100percent.bolt")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Spare \(percentString(spare))").monospacedDigit()
            Text(verbatim: "·").foregroundStyle(.tertiary)
            if swapReady {
                Text("Ready to swap")
                    .foregroundStyle(Color.accentColor)
                    .help("Swap batteries within 8 seconds and the headset powers back on by itself.")
            } else {
                Text(spare >= 100 ? "Charged" : "Charging").foregroundStyle(.secondary)
            }
            UnverifiedBadge(feature: .spareBattery, style: .dot)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func batterySymbol(level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct OmniQuickControls: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !omni.headsetOnline {
                OmniHeadsetOfflineNotice(compact: true)
                    .padding(.top, 8)
            }
            if !omni.profiles.isEmpty {
                ProfileQuickSwitch()
            }

            SectionTitle("Noise control", feature: .ancMode)
            NoiseControlRows(compact: true)
                .disabled(!omni.headsetOnline)

            SectionTitle("Sound")
            EQPresetQuickRow()
            if let mix = omni.readouts.chatMix {
                ChatMixRow(mix: mix)
            }

            SectionTitle("Microphone")
            let sidetone = omni.settings.sidetone ?? Sidetone(isEnabled: true, level: 5)
            ControlRow(title: "Sidetone", symbol: "ear", feature: .sidetone) {
                HStack(spacing: 6) {
                    Toggle("Sidetone", isOn: Binding(
                        get: { omni.settings.sidetone?.isEnabled ?? true },
                        set: { omni.set(.sidetone(Sidetone(isEnabled: $0, level: sidetone.level))) }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            .help("How much of your own voice you hear")
            Slider(value: Binding(
                get: { Double(omni.settings.sidetone?.level ?? 5) },
                set: { omni.set(.sidetone(Sidetone(isEnabled: sidetone.isEnabled, level: Int($0.rounded()))), debounce: .milliseconds(350)) }
            ), in: 1...10, step: 1)
            .controlSize(.small)
            .padding(.leading, 26)
            .disabled(!sidetone.isEnabled)
            .accessibilityLabel(Text("Sidetone level"))

            LabeledSlider(
                title: "Mic level", symbol: omni.readouts.micMuted == true ? "mic.slash" : "mic",
                value: omni.sliderBinding(\.micVolume, fallback: 8) { .micVolume($0) },
                range: 1...10,
                feature: .micVolume
            )
        }
        .disabled(!omni.isReady)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

/// Preset picker when uploads are allowed; the hub's own preset name otherwise.
private struct EQPresetQuickRow: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        let eq = omni.wirelessEQ
        ControlRow(title: "Equalizer", symbol: "slider.vertical.3", feature: .wirelessEQ) {
            HStack(spacing: 6) {
                if omni.experimentalEQWrites {
                    Picker("Equalizer preset", selection: Binding(
                        get: { eq.presetIndex },
                        set: { if let preset = WirelessEQPreset(rawValue: $0) { omni.selectWirelessPreset(preset) } }
                    )) {
                        ForEach(WirelessEQPreset.selectable, id: \.rawValue) { preset in
                            Text(preset.localizedName).tag(preset.rawValue)
                        }
                        if !WirelessEQPreset.selectable.contains(where: { $0.rawValue == eq.presetIndex }) {
                            Text(verbatim: eq.name).tag(eq.presetIndex)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Text(verbatim: presetLabel(eq))
                        .foregroundStyle(.secondary)
                        .help("The 2.4 GHz preset the GameHub reports. Changing it needs EQ writes, which are off until the byte layout is confirmed (Settings → Developer).")
                }
            }
        }
    }

    private func presetLabel(_ eq: WirelessEQ) -> String {
        if let preset = eq.preset, preset != .custom, preset != .other { return preset.localizedName }
        return eq.name.isEmpty ? String(localized: "Custom") : eq.name
    }
}

/// Game 0–100 / chat 0–100 from the hub's dial, drawn as one balance line.
private struct ChatMixRow: View {
    let mix: ChatMix

    /// 0 = all game, 1 = all chat.
    private var fraction: Double {
        let total = Double(mix.game + mix.chat)
        guard total > 0 else { return 0.5 }
        return Double(mix.chat) / total
    }

    private var summary: String {
        if abs(mix.game - mix.chat) <= 5 { return String(localized: "Balanced", comment: "Chat mix dial is centred") }
        return mix.game > mix.chat
            ? String(localized: "More game", comment: "Chat mix favours game audio")
            : String(localized: "More chat", comment: "Chat mix favours chat audio")
    }

    var body: some View {
        ControlRow(title: "Chat mix", symbol: "dial.low", feature: .chatMixDial) {
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller").font(.caption).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 4)
                        Rectangle().fill(.tertiary).frame(width: 1, height: 8)
                            .offset(x: geo.size.width / 2 - 0.5)
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            .offset(x: fraction * (geo.size.width - 8))
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(width: 72, height: 12)
                Image(systemName: "bubble.left").font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("\(summary). Turn the chat mix dial on the headset to change it.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chat mix")
        .accessibilityValue(summary)
    }
}

/// Switch profiles from the menu bar, like GG's tray menu.
private struct ProfileQuickSwitch: View {
    @Environment(OmniController.self) private var omni

    var body: some View {
        ControlRow(title: "Profile", symbol: "person.crop.rectangle.stack") {
            Picker("Profile", selection: Binding<UUID?>(
                get: { omni.activeProfileID },
                set: { id in if let profile = omni.profiles.first(where: { $0.id == id }) { omni.apply(profile) } }
            )) {
                if omni.activeProfileID == nil {
                    Text("Custom").tag(UUID?.none)
                }
                ForEach(omni.profiles) { profile in
                    Text(verbatim: profile.name).tag(UUID?.some(profile.id))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.top, 6)
    }
}
