import Foundation
import OmniKit

/// Which of the three onboard EQs a preset belongs to.
enum EQKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case wireless
    case bluetooth
    case mic

    var id: String { rawValue }

    var omniKind: OmniEqualizerKind {
        switch self {
        case .wireless: .wireless
        case .bluetooth: .bluetooth
        case .mic: .mic
        }
    }

    var feature: OmniFeature {
        switch self {
        case .wireless: .wirelessEQ
        case .bluetooth: .bluetoothEQ
        case .mic: .micEQ
        }
    }

    var bandFrequencies: [Int] {
        switch self {
        case .wireless: ParametricBand.defaultFrequencies
        case .bluetooth: BluetoothEQPreset.bandFrequencies
        case .mic: MicEQPreset.bandFrequencies
        }
    }
}

/// The band data of a preset, independent of the wire structs so one type covers all three EQs.
enum EQPresetCurve: Codable, Sendable, Hashable {
    case parametric([ParametricBand])
    case graphic(gainsTenths: [Int])
}

/// A preset the user saved locally (GG's library presets stay on the Windows side; Hushdeck
/// keeps its own).
struct CustomEQPreset: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var kind: EQKind
    var name: String
    var curve: EQPresetCurve
    var created: Date

    init(id: UUID = UUID(), kind: EQKind, name: String, curve: EQPresetCurve, created: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.curve = curve
        self.created = created
    }

    /// The 6-character alias the OLED shows: the first six letters, upper-cased.
    var shortName: String {
        String(name.uppercased().unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(OmniEQNames.shortNameLength))
    }
}

/// Factory preset names as GG lists them. The curves are Hushdeck's own: SteelSeries' preset
/// data is not copied. Selecting one sends the slot index the hub already knows the name of.
enum FactoryEQPresets {
    /// 2.4 GHz: slots 0–3 are onboard; 4 is Custom.
    static func wirelessBands(_ preset: WirelessEQPreset) -> [ParametricBand]? {
        func band(_ f: Int, _ gain: Double) -> ParametricBand {
            ParametricBand(frequency: f, filter: .peaking, gainDB: gain, q: 1.414)
        }
        func shelf(_ f: Int, _ type: EQFilterType, _ gain: Double) -> ParametricBand {
            ParametricBand(frequency: f, filter: type, gainDB: gain, q: 0.707)
        }
        switch preset {
        case .flat:
            return ParametricBand.flat
        case .bassBoost:
            var bands = ParametricBand.flat
            bands[0] = shelf(32, .lowShelf, 6)
            bands[1] = band(64, 4)
            bands[2] = band(125, 2)
            return bands
        case .focus:
            var bands = ParametricBand.flat
            bands[2] = band(125, -2)
            bands[5] = band(1000, 1.5)
            bands[6] = band(2000, 3)
            bands[7] = band(4000, 2.5)
            bands[9] = shelf(16000, .highShelf, -2)
            return bands
        case .smiley:
            var bands = ParametricBand.flat
            bands[0] = shelf(32, .lowShelf, 5)
            bands[1] = band(64, 3)
            bands[4] = band(500, -2)
            bands[5] = band(1000, -2.5)
            bands[8] = band(8000, 3)
            bands[9] = shelf(16000, .highShelf, 4)
            return bands
        case .custom, .other:
            return nil
        }
    }

    static func bluetoothGains(_ preset: BluetoothEQPreset) -> [Int]? {
        switch preset {
        case .flat: BluetoothEQ.flatGains
        case .bassBoost: [60, 45, 25, 10, 0, 0, 0, 0, 0, 0]
        case .focus: [0, 0, -20, -10, 0, 15, 30, 25, 0, -15]
        case .smiley: [50, 30, 0, -15, -25, -25, -10, 15, 30, 40]
        case .custom: nil
        }
    }

    static func micGains(_ preset: MicEQPreset) -> [Int]? {
        switch preset {
        case .flat: MicEQ.flatGains
        case .balanced: [-20, -10, 0, 0, 10, 10, 15, 10, 0, -10]
        case .broadcastHighPitch: [-40, -30, -10, 0, 10, 20, 30, 30, 20, 0]
        case .broadcastLowPitch: [-20, 0, 20, 20, 10, 0, 10, 10, 0, -10]
        case .clarityLowPitch: [-30, -20, 0, 0, 0, 10, 25, 35, 25, 10]
        case .clarityHighPitch: [-40, -30, -20, -10, 0, 15, 30, 40, 30, 15]
        case .deepVoice: [10, 30, 30, 20, 0, -10, -10, 0, 0, -10]
        case .lessNasal: [0, 0, 10, 0, -20, -35, -20, 0, 10, 0]
        case .walkieTalkie: [-60, -60, -40, 0, 20, 30, 20, -20, -50, -60]
        case .custom: nil
        }
    }
}

/// Persists custom presets as JSON in UserDefaults.
final class EQPresetStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "omniEQPresets.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [CustomEQPreset] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? OmniProfile.decoder().decode([CustomEQPreset].self, from: data)) ?? []
    }

    func save(_ presets: [CustomEQPreset]) {
        if let data = try? OmniProfile.encoder().encode(presets) { defaults.set(data, forKey: key) }
    }

    func removeAll() {
        defaults.removeObject(forKey: key)
    }
}
