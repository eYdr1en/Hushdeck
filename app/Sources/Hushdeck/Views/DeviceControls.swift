import HeadsetControlKit
import SwiftUI

/// Every control is gated on a capability the device actually reports.
struct DeviceControls: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    @AppStorage("showMoreControls") private var showMore = false

    private let debounce: Duration = .milliseconds(350)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let anc = device.noiseCancellingCapability {
                NoiseCancellingSection(device: device, capability: anc)
            }
            if hasSoundSection {
                SectionTitle("Sound")
                if device.supports(.equalizerPreset) || device.supports(.equalizer) {
                    EqualizerSection(device: device)
                }
                if let chatmix = device.chatmix {
                    ChatMixReadout(level: chatmix)
                }
            }
            if hasMicSection {
                SectionTitle("Microphone")
                if device.supports(.sidetone) {
                    LabeledSlider(
                        title: "Sidetone", symbol: "ear",
                        value: model.binding(\.sidetone, debounce: debounce) { .sidetone(Int($0.rounded())) },
                        range: 0...128, valueText: percentText(128)
                    )
                    .help("How much of your own voice you hear")
                }
                if device.supports(.microphoneVolume) {
                    LabeledSlider(
                        title: "Mic level", symbol: "mic",
                        value: model.binding(\.microphoneVolume, debounce: debounce) { .microphoneVolume(Int($0.rounded())) },
                        range: 0...128, valueText: percentText(128)
                    )
                }
                if device.supports(.noiseFilter) {
                    ControlRow(title: "Noise filter", symbol: "waveform.badge.mic") {
                        Picker("Noise filter", selection: model.binding(\.noiseFilter) { .noiseFilter($0) }) {
                            Text("Off").tag(NoiseFilterLevel.off)
                            Text("Low").tag(NoiseFilterLevel.low)
                            Text("High").tag(NoiseFilterLevel.high)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }
            if hasHeadsetSection {
                SectionTitle("Headset")
                if device.supports(.lights) {
                    ControlRow(title: "Lights", symbol: "lightbulb") {
                        Toggle("Lights", isOn: model.binding(\.lights) { .lights($0) })
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                }
                if device.supports(.inactiveTime) {
                    ControlRow(title: "Turn off after", symbol: "moon.zzz") {
                        Picker("Turn off after", selection: model.binding(\.inactiveTime) { .inactiveTime(minutes: $0 ?? 0) }) {
                            if model.controls.inactiveTime == nil {
                                Text("Not set").tag(Int?.none)
                            }
                            Text("Never").tag(Int?.some(0))
                            ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { minutes in
                                Text("\(minutes) min", comment: "Auto-off delay in minutes").tag(Int?.some(minutes))
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    .help("Power the headset off after this long without audio")
                }
            }
            if hasMoreSection {
                DisclosureGroup(isExpanded: $showMore) {
                    MoreControls(device: device)
                        .padding(.top, 2)
                } label: {
                    Text("More")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { showMore.toggle() } }
                }
                .padding(.top, 8)
            }
        }
        .disabled(!device.connection.isReachable)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var hasSoundSection: Bool {
        device.supports(.equalizerPreset) || device.supports(.equalizer) || device.chatmix != nil
    }

    private var hasMicSection: Bool {
        device.supports(.sidetone) || device.supports(.microphoneVolume) || device.supports(.noiseFilter)
    }

    private var hasHeadsetSection: Bool {
        device.supports(.lights) || device.supports(.inactiveTime)
    }

    private var hasMoreSection: Bool {
        MoreControls.isNonEmpty(for: device)
    }
}

// MARK: - Noise cancelling

/// Appears only when the device reports an ANC/transparency capability (none do yet).
private struct NoiseCancellingSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    let capability: Capability

    var body: some View {
        let control = NoiseCancellingControl(capability: capability, humanName: device.displayName(for: capability))
        SectionTitle("Noise control")
        Picker("Noise control", selection: model.binding(\.noiseCancelling) { .noiseCancelling($0, control) }) {
            Label("Off", systemImage: "person").tag(NoiseCancellingMode.off)
            Label("Cancel", systemImage: "person.wave.2.fill").tag(NoiseCancellingMode.noiseCancelling)
            Label("Transparency", systemImage: "person.wave.2").tag(NoiseCancellingMode.transparency)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Active noise cancellation and transparency")
    }
}

// MARK: - Chat mix

private struct ChatMixReadout: View {
    let level: Int

    private var fraction: Double { min(max(Double(level) / 128, 0), 1) }

    private var summary: String {
        let offset = level - 64
        if abs(offset) <= 4 { return String(localized: "Balanced", comment: "Chat mix dial is centred") }
        return offset < 0
            ? String(localized: "More game", comment: "Chat mix favours game audio")
            : String(localized: "More chat", comment: "Chat mix favours chat audio")
    }

    var body: some View {
        ControlRow(title: "Chat mix", symbol: "dial.low") {
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

// MARK: - More

private struct MoreControls: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo

    static func isNonEmpty(for device: DeviceInfo) -> Bool {
        let caps: [Capability] = [.voicePrompts, .rotateToMute, .volumeLimiter, .microphoneMuteLEDBrightness,
                                  .bluetoothWhenPoweredOn, .bluetoothCallVolume, .notificationSound]
        return caps.contains(where: device.supports) || !device.unrecognisedCapabilities.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if device.supports(.rotateToMute) {
                toggleRow("Mute when mic is raised", "mic.slash", \.rotateToMute) { .rotateToMute($0) }
            }
            if device.supports(.microphoneMuteLEDBrightness) {
                ControlRow(title: "Mute light", symbol: "light.max") {
                    Picker("Mute light", selection: model.binding(\.microphoneMuteLEDBrightness) { .microphoneMuteLEDBrightness($0) }) {
                        Text("Off").tag(0)
                        Text("Low").tag(1)
                        Text("Med").tag(2)
                        Text("High").tag(3)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                }
            }
            if device.supports(.voicePrompts) {
                toggleRow("Voice prompts", "speaker.wave.2", \.voicePrompts) { .voicePrompts($0) }
            }
            if device.supports(.volumeLimiter) {
                toggleRow("Volume limiter", "speaker.badge.exclamationmark", \.volumeLimiter) { .volumeLimiter($0) }
            }
            if device.supports(.bluetoothWhenPoweredOn) {
                toggleRow("Bluetooth at power on", "dot.radiowaves.left.and.right", \.bluetoothWhenPoweredOn) { .bluetoothWhenPoweredOn($0) }
            }
            if device.supports(.bluetoothCallVolume) {
                LabeledSlider(
                    title: "Bluetooth call volume", symbol: "phone",
                    value: model.binding(\.bluetoothCallVolume, debounce: .milliseconds(350)) { .bluetoothCallVolume(Int($0.rounded())) },
                    range: 0...100, valueText: percentText(100)
                )
            }
            if device.supports(.notificationSound) {
                ControlRow(title: "Notification sound", symbol: "bell") {
                    Button("Play") { model.playNotificationSound() }
                        .controlSize(.small)
                }
            }
            if !device.unrecognisedCapabilities.isEmpty {
                let names = device.unrecognisedCapabilities.map { device.displayName(for: $0) }
                Text("Also reported by this headset: \(names.formatted(.list(type: .and))). Hushdeck doesn’t have controls for these yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, _ symbol: String, _ keyPath: WritableKeyPath<AppModel.Controls, Bool>, _ make: @escaping (Bool) -> HeadsetSetting) -> some View {
        ControlRow(title: title, symbol: symbol) {
            Toggle(title, isOn: model.binding(keyPath, make))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}
