import OmniKit
import SwiftUI

/// A 10-band graphic EQ (Bluetooth or mic): fixed band centres, gain only, ±10 dB in 0.5 dB
/// steps as in GG. The graph draws each band as a peaking filter so the curve is real maths.
struct GraphicEQEditor: View {
    @Environment(OmniController.self) private var omni
    let kind: EQKind
    @State private var selection: Int?

    private var gainsTenths: [Int] {
        switch kind {
        case .bluetooth: omni.bluetoothEQ.gainsTenths
        case .mic: omni.micEQ.gainsTenths
        case .wireless: []
        }
    }

    private var presetIndex: UInt8 {
        switch kind {
        case .bluetooth: omni.bluetoothEQ.presetIndex
        case .mic: omni.micEQ.presetIndex
        case .wireless: 0
        }
    }

    private var presetName: String {
        switch kind {
        case .bluetooth: omni.bluetoothEQ.name
        case .mic: omni.micEQ.name
        case .wireless: ""
        }
    }

    private var factory: [(index: UInt8, name: String)] {
        switch kind {
        case .bluetooth: BluetoothEQPreset.allCases.map { ($0.rawValue, $0.localizedName) }
        case .mic: MicEQPreset.displayOrder.map { ($0.rawValue, $0.localizedName) }
        case .wireless: []
        }
    }

    var body: some View {
        let frequencies = kind.bandFrequencies
        let gains = gainsTenths.map { Double($0) / 10 }
        VStack(alignment: .leading, spacing: 10) {
            EQPresetBar(kind: kind, factory: factory, currentIndex: presetIndex, currentName: presetName) { index in
                switch kind {
                case .bluetooth: if let preset = BluetoothEQPreset(rawValue: index) { omni.selectBluetoothPreset(preset) }
                case .mic: if let preset = MicEQPreset(rawValue: index) { omni.selectMicPreset(preset) }
                case .wireless: break
                }
            }
            EQGraph(
                composite: { EQCurve.decibels(graphicGainsDB: gains, frequencies: frequencies, at: $0) },
                bandResponses: zip(gains, frequencies).map { gain, frequency in
                    { EQCurve.biquad(type: .peaking, frequency: Double(frequency), gainDB: gain, q: EQCurve.graphicBandQ).decibels(at: $0) }
                },
                nodes: zip(gains, frequencies).enumerated().map { index, band in
                    EQNode(id: index, frequency: Double(band.1), gainDB: band.0, isEnabled: true)
                },
                selection: $selection,
                gainRange: -12...12,
                gainStep: 0.5,
                allowsFrequencyDrag: false,
                onDrag: { index, _, gain in omni.updateGraphicGain(kind, band: index, gainTenths: Int((gain * 10).rounded())) },
                onReset: { index in omni.updateGraphicGain(kind, band: index, gainTenths: 0) }
            )
            .frame(height: 190)

            HStack(spacing: 6) {
                ForEach(frequencies.indices, id: \.self) { index in
                    VStack(spacing: 3) {
                        TextField("Gain", value: gainBinding(index), format: .number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
                            .labelsHidden()
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .monospacedDigit()
                        Text(verbatim: frequencyLabel(Double(frequencies[index])))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .background(selection == index ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .onTapGesture { selection = index }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Band \(index + 1)"))
                }
            }
            EQActionBar(kind: kind)
        }
    }

    private func gainBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { Double(gainsTenths.indices.contains(index) ? gainsTenths[index] : 0) / 10 },
            set: { value in
                let snapped = (value * 2).rounded() / 2
                omni.updateGraphicGain(kind, band: index, gainTenths: Int((snapped * 10).rounded()))
            }
        )
    }
}
