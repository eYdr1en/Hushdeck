import OmniKit
import SwiftUI

/// The 2.4 GHz 10-band parametric EQ: graph with draggable nodes plus a table for exact values.
struct ParametricEQEditor: View {
    @Environment(OmniController.self) private var omni
    @State private var selection: Int?

    private var eq: WirelessEQ { omni.wirelessEQ }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EQPresetBar(
                kind: .wireless,
                factory: WirelessEQPreset.selectable.map { ($0.rawValue, $0.localizedName) },
                currentIndex: eq.presetIndex,
                currentName: eq.name,
                onSelectFactory: { index in
                    if let preset = WirelessEQPreset(rawValue: index) { omni.selectWirelessPreset(preset) }
                }
            )
            let bands = eq.bands
            EQGraph(
                composite: { EQCurve.decibels(of: bands, at: $0) },
                bandResponses: bands.map { band in { EQCurve.decibels(of: band, at: $0) } },
                nodes: bands.enumerated().map { index, band in
                    EQNode(id: index, frequency: Double(band.isEnabled ? band.frequency : ParametricBand.defaultFrequencies[index]),
                           gainDB: band.gainDB, isEnabled: band.isEnabled, usesGain: band.filter?.usesGain ?? true)
                },
                selection: $selection,
                gainRange: -12...12,
                gainStep: 0.1,
                allowsFrequencyDrag: true,
                onDrag: { index, frequency, gain in
                    omni.updateWirelessBand(index) { band in
                        if !band.isEnabled { band.frequency = ParametricBand.defaultFrequencies[index] }
                        if let frequency { band.frequency = Int(frequency) }
                        band.gainTenths = Int((gain * 10).rounded())
                    }
                },
                onReset: { index in
                    omni.updateWirelessBand(index) { band in
                        band.frequency = ParametricBand.defaultFrequencies[index]
                        band.gainTenths = 0
                    }
                }
            )
            .frame(height: 230)

            BandTable(selection: $selection)
            EQActionBar(kind: .wireless)
        }
    }
}

/// One row per band with the exact wire values: on/off, frequency, filter type, gain, Q.
private struct BandTable: View {
    @Environment(OmniController.self) private var omni
    @Binding var selection: Int?

    private var bands: [ParametricBand] { omni.wirelessEQ.bands }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("Band").gridColumnAlignment(.center)
                Text("Frequency")
                Text("Type")
                Text("Gain")
                Text("Q")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)

            ForEach(bands.indices, id: \.self) { index in
                let band = bands[index]
                GridRow {
                    Toggle(isOn: enabledBinding(index)) {
                        Text(index + 1, format: .number)
                            .monospacedDigit()
                            .frame(width: 16, alignment: .trailing)
                    }
                    .toggleStyle(.checkbox)
                    .help(band.isEnabled ? "Turn this band off" : "Turn this band on")

                    HStack(spacing: 3) {
                        TextField("Frequency", value: frequencyBinding(index), format: .number.grouping(.never))
                            .labelsHidden()
                            .frame(width: 58)
                            .multilineTextAlignment(.trailing)
                        Text(verbatim: "Hz").foregroundStyle(.secondary)
                    }
                    .disabled(!band.isEnabled)

                    Picker("Type", selection: filterBinding(index)) {
                        ForEach(EQFilterType.allCases, id: \.self) { type in
                            Text(type.localizedName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 112)
                    .disabled(!band.isEnabled)

                    HStack(spacing: 3) {
                        TextField("Gain", value: gainBinding(index), format: .number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
                            .labelsHidden()
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                        Text(verbatim: "dB").foregroundStyle(.secondary)
                    }
                    .disabled(!band.isEnabled || !(band.filter?.usesGain ?? true))

                    HStack(spacing: 3) {
                        TextField("Q", value: qBinding(index), format: .number.precision(.fractionLength(1...3)))
                            .labelsHidden()
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                    }
                    .disabled(!band.isEnabled)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(selection == index ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { selection = index }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Band \(index + 1)"))
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .monospacedDigit()
    }

    private func enabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { bands[index].isEnabled },
            set: { on in
                omni.updateWirelessBand(index) { band in
                    band.frequency = on ? ParametricBand.defaultFrequencies[index] : ParametricBand.disabledFrequency
                }
            }
        )
    }

    private func frequencyBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { bands[index].isEnabled ? bands[index].frequency : ParametricBand.defaultFrequencies[index] },
            set: { value in omni.updateWirelessBand(index) { $0.frequency = value } }
        )
    }

    private func filterBinding(_ index: Int) -> Binding<EQFilterType> {
        Binding(
            get: { bands[index].filter ?? .peaking },
            set: { value in omni.updateWirelessBand(index) { $0.filter = value } }
        )
    }

    private func gainBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { bands[index].gainDB },
            set: { value in omni.updateWirelessBand(index) { $0.gainTenths = Int((value * 10).rounded()) } }
        )
    }

    private func qBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { bands[index].q },
            set: { value in omni.updateWirelessBand(index) { $0.qThousandths = Int((value * 1000).rounded()) } }
        )
    }
}
