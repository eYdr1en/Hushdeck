import HeadsetControlKit
import SwiftUI

struct EqualizerSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    @State private var activeBand: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if device.supports(.equalizerPreset), !device.presetNames.isEmpty {
                ControlRow(title: "Equalizer", symbol: "slider.vertical.3") {
                    Picker("Equalizer preset", selection: presetBinding) {
                        if model.controls.presetIndex == nil {
                            Text(model.remembered.equalizer == nil ? "Choose…" : "Custom").tag(Int?.none)
                        }
                        ForEach(Array(device.presetNames.enumerated()), id: \.offset) { index, name in
                            Text(presetLabel(index, name)).tag(Int?.some(index))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            if device.supports(.equalizer), let info = device.equalizer, !model.controls.equalizerBands.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        if !device.supports(.equalizerPreset) {
                            Label("Equalizer", systemImage: "slider.vertical.3")
                        }
                        Spacer()
                        Text(readout(info))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .animation(nil, value: activeBand)
                    }
                    BandSliders(
                        info: info,
                        bands: model.controls.equalizerBands,
                        activeBand: $activeBand,
                        onChange: { model.setBand($0, to: $1) }
                    )
                    .frame(height: 104)
                    HStack(spacing: 8) {
                        Button("Flat") { model.flattenEqualizer() }
                            .help("Set every band to \(format(info.baseline)) dB")
                        Spacer()
                        if model.equalizerIsDirty {
                            Button("Revert") { model.revertEqualizer() }
                            Button("Apply") { model.applyCustomEqualizer() }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Device-reported names as they are; a numbered fallback when it only reports a count.
    private func presetLabel(_ index: Int, _ name: String) -> String {
        device.equalizerPresets.isEmpty
            ? String(localized: "Preset \(index + 1)", comment: "Equalizer preset without a name")
            : name.localizedCapitalized
    }

    private var presetBinding: Binding<Int?> {
        Binding(
            get: { model.controls.presetIndex },
            set: { if let index = $0 { model.selectPreset(index) } }
        )
    }

    private func readout(_ info: EqualizerInfo) -> String {
        if let band = activeBand, band < model.controls.equalizerBands.count {
            return String(localized: "Band \(band + 1)  \(format(model.controls.equalizerBands[band])) dB")
        }
        if model.equalizerIsDirty { return String(localized: "Not applied") }
        return String(localized: "\(format(info.min)) to \(format(info.max)) dB", comment: "Equalizer range, e.g. -12 to +12 dB")
    }
}

/// Signed decibels with at most one decimal, in the user's number format ("+1.5", "+1,5").
func format(_ db: Double) -> String {
    db.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always(includingZero: false)))
}

/// A row of compact vertical sliders, one per band, drawn from the baseline so
/// boosts rise and cuts fall.
private struct BandSliders: View {
    let info: EqualizerInfo
    let bands: [Double]
    @Binding var activeBand: Int?
    let onChange: (Int, Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(bands.indices, id: \.self) { index in
                VStack(spacing: 3) {
                    BandSlider(
                        value: bands[index],
                        info: info,
                        isActive: activeBand == index,
                        onEditing: { activeBand = $0 ? index : nil },
                        onChange: { onChange(index, $0) }
                    )
                    .accessibilityLabel("Band \(index + 1)")
                    Text(index + 1, format: .number)
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct BandSlider: View {
    let value: Double
    let info: EqualizerInfo
    let isActive: Bool
    let onEditing: (Bool) -> Void
    let onChange: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    private let knob: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.height - knob
            let y = { (v: Double) -> CGFloat in
                knob / 2 + usable * CGFloat(1 - (v - info.min) / max(info.max - info.min, 0.001))
            }
            let knobY = y(value)
            let baseY = y(info.baseline)
            let midX = geo.size.width / 2

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 4, height: usable)
                    .position(x: midX, y: geo.size.height / 2)
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 10, height: 1)
                    .position(x: midX, y: baseY)
                Capsule()
                    .fill(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 4, height: abs(knobY - baseY))
                    .position(x: midX, y: (knobY + baseY) / 2)
                Circle()
                    .fill(.white.opacity(isEnabled ? 1 : 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(isActive ? 0.25 : 0.1), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .position(x: midX, y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onEditing(true)
                        let fraction = 1 - Double((drag.location.y - knob / 2) / max(usable, 1))
                        onChange(snap(info.min + fraction * (info.max - info.min)))
                    }
                    .onEnded { _ in onEditing(false) }
            )
            .onTapGesture(count: 2) { onChange(info.baseline) }
        }
        .accessibilityElement()
        .accessibilityValue("\(format(value)) decibels")
        .accessibilityAdjustableAction { direction in
            let step = max(info.step, 0.5)
            switch direction {
            case .increment: onChange(snap(value + step))
            case .decrement: onChange(snap(value - step))
            @unknown default: break
            }
        }
        .help("Drag to adjust, double-click to reset")
    }

    private func snap(_ raw: Double) -> Double {
        let step = info.step > 0 ? info.step : 0.5
        let snapped = (raw / step).rounded() * step
        return min(max(snapped, info.min), info.max)
    }
}
