import Foundation

// The three onboard equalizers (protocol-notes §3.7): the 2.4 GHz 10-band parametric EQ, the
// Bluetooth 10-band graphic EQ and the mic 10-band graphic EQ. Reads use feature reports and are
// always allowed. Writes are SET_FEATURE with an unconfirmed layout and need
// `OmniWritePolicy.experimentalEQWrites`.

/// Parametric filter type. 1–5 are documented; 6 (notch) is accepted but its behaviour is unconfirmed.
public enum EQFilterType: UInt8, Codable, Sendable, CaseIterable {
    case peaking = 1
    case lowPass = 2
    case highPass = 3
    case lowShelf = 4
    case highShelf = 5
    case notch = 6
}

/// One parametric band, stored in wire units so a read/write round trip is exact.
public struct ParametricBand: Codable, Sendable, Hashable {
    /// A band sent with this frequency is disabled.
    public static let disabledFrequency = 20001
    public static let frequencyRange = 20...20000
    /// Tenths of a dB: −12.0…+12.0 dB.
    public static let gainTenthsRange = -120...120
    /// Q × 1000: 0.2…10.0.
    public static let qThousandthsRange = 200...10000
    /// GG's default band centres.
    public static let defaultFrequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Hz (20–20000), or `disabledFrequency`.
    public var frequency: Int
    /// Raw filter type byte; see `filter`.
    public var filterType: UInt8
    public var gainTenths: Int
    public var qThousandths: Int

    public init(frequency: Int, filter: EQFilterType, gainTenths: Int, qThousandths: Int) {
        self.frequency = frequency
        self.filterType = filter.rawValue
        self.gainTenths = gainTenths
        self.qThousandths = qThousandths
    }

    /// Convenience with dB and Q; rounds to the device resolution (0.1 dB, 0.001 Q).
    public init(frequency: Int, filter: EQFilterType = .peaking, gainDB: Double, q: Double) {
        self.init(frequency: frequency, filter: filter,
                  gainTenths: Int((gainDB * 10).rounded()), qThousandths: Int((q * 1000).rounded()))
    }

    public var filter: EQFilterType? {
        get { EQFilterType(rawValue: filterType) }
        set { filterType = newValue?.rawValue ?? 0 }
    }

    public var isEnabled: Bool { frequency != Self.disabledFrequency }
    public var gainDB: Double { Double(gainTenths) / 10 }
    public var q: Double { Double(qThousandths) / 1000 }

    /// GG's default: 10 peaking bands at `defaultFrequencies`, Q 1.414, 0 dB.
    public static var flat: [ParametricBand] {
        defaultFrequencies.map { ParametricBand(frequency: $0, filter: .peaking, gainTenths: 0, qThousandths: 1414) }
    }

    func validate(feature: OmniFeature) throws {
        if !(Self.frequencyRange.contains(frequency) || frequency == Self.disabledFrequency) {
            throw OmniError.valueOutOfRange(feature: feature, value: "\(frequency) Hz", allowed: "20...20000 Hz or 20001 (off)")
        }
        guard filter != nil else {
            throw OmniError.valueOutOfRange(feature: feature, value: "filter \(filterType)", allowed: "1...6")
        }
        guard Self.gainTenthsRange.contains(gainTenths) else {
            throw OmniError.valueOutOfRange(feature: feature, value: "\(gainTenths) tenths dB", allowed: "-120...120")
        }
        guard Self.qThousandthsRange.contains(qThousandths) else {
            throw OmniError.valueOutOfRange(feature: feature, value: "Q×1000 \(qThousandths)", allowed: "200...10000")
        }
    }

    /// 6 bytes: frequency u16 LE, type, gain int8 (tenths), Q×1000 u16 LE.
    var wireBytes: [UInt8] {
        let f = UInt16(frequency), q = UInt16(qThousandths)
        return [UInt8(f & 0xFF), UInt8(f >> 8), filterType, UInt8(bitPattern: Int8(gainTenths)), UInt8(q & 0xFF), UInt8(q >> 8)]
    }

    init(wire b: ArraySlice<UInt8>) {
        let i = b.startIndex
        frequency = Int(b[i]) | Int(b[i + 1]) << 8
        filterType = b[i + 2]
        gainTenths = Int(Int8(bitPattern: b[i + 3]))
        qThousandths = Int(b[i + 4]) | Int(b[i + 5]) << 8
    }
}

/// 2.4 GHz preset slots.
public enum WirelessEQPreset: UInt8, Codable, Sendable, CaseIterable {
    case flat = 0
    case bassBoost = 1
    case focus = 2
    case smiley = 3
    case custom = 4
    /// Any GG library or game preset.
    case other = 5
}

/// Preset kinds of the two graphic EQs.
public protocol GraphicEQPreset: RawRepresentable, CaseIterable, Codable, Sendable, Hashable where RawValue == UInt8 {
    /// Band centres in Hz.
    static var bandFrequencies: [Int] { get }
    static var feature: OmniFeature { get }
    static var readQuery: OmniQuery { get }
    static var writeOpcode: UInt8 { get }
    static var custom: Self { get }
}

public enum BluetoothEQPreset: UInt8, GraphicEQPreset {
    case flat = 0
    case bassBoost = 1
    case focus = 2
    case smiley = 3
    case custom = 4

    public static let bandFrequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static var feature: OmniFeature { .bluetoothEQ }
    public static var readQuery: OmniQuery { .bluetoothEQ }
    public static var writeOpcode: UInt8 { 0x1F }
}

public enum MicEQPreset: UInt8, GraphicEQPreset {
    case flat = 0
    case balanced = 1
    case broadcastHighPitch = 2
    case broadcastLowPitch = 3
    case clarityLowPitch = 4
    case clarityHighPitch = 5
    case deepVoice = 6
    case lessNasal = 7
    case custom = 8
    case walkieTalkie = 9

    public static let bandFrequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static var feature: OmniFeature { .micEQ }
    public static var readQuery: OmniQuery { .micEQ }
    public static var writeOpcode: UInt8 { 0x1D }
}

/// Short and long preset names as stored on the hub (6 and 61 ASCII bytes).
public enum OmniEQNames {
    public static let shortNameLength = 6
    public static let nameLength = 61

    static func encode(_ text: String, length: Int, feature: OmniFeature, field: String) throws -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count <= length, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw OmniError.valueOutOfRange(feature: feature, value: "\(field) \"\(text)\"",
                                            allowed: "up to \(length) printable ASCII characters")
        }
        return bytes + [UInt8](repeating: 0, count: length - bytes.count)
    }

    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        let text = bytes.prefix { $0 != 0 }
        return String(decoding: text.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }
}

/// The 2.4 GHz parametric EQ. Selecting a preset and uploading bands are one operation on the
/// wire: GG always sends the index, both names and all ten bands.
public struct WirelessEQ: Codable, Sendable, Hashable {
    public static let bandCount = 10
    public var presetIndex: UInt8
    public var shortName: String
    public var name: String
    public var bands: [ParametricBand]

    public init(preset: WirelessEQPreset, shortName: String, name: String, bands: [ParametricBand]) {
        self.presetIndex = preset.rawValue
        self.shortName = shortName
        self.name = name
        self.bands = bands
    }

    public var preset: WirelessEQPreset? {
        get { WirelessEQPreset(rawValue: presetIndex) }
        set { presetIndex = newValue?.rawValue ?? presetIndex }
    }

    public func validate() throws {
        guard WirelessEQPreset(rawValue: presetIndex) != nil else {
            throw OmniError.valueOutOfRange(feature: .wirelessEQ, value: "preset \(presetIndex)", allowed: "0...5")
        }
        guard bands.count == Self.bandCount else {
            throw OmniError.valueOutOfRange(feature: .wirelessEQ, value: "\(bands.count) bands", allowed: "exactly 10")
        }
        for band in bands { try band.validate(feature: .wirelessEQ) }
    }

    /// `01 1B <idx> <short 6> <name 61> <10 × 6-byte bands>`, zero-padded to 1036.
    func featureReport(policy: OmniWritePolicy) throws -> OmniFeatureReport {
        guard policy.experimentalEQWrites else { throw OmniError.experimentalEQWritesDisabled }
        try validate()
        var payload = [presetIndex]
        payload += try OmniEQNames.encode(shortName, length: OmniEQNames.shortNameLength, feature: .wirelessEQ, field: "short name")
        payload += try OmniEQNames.encode(name, length: OmniEQNames.nameLength, feature: .wirelessEQ, field: "name")
        payload += bands.flatMap(\.wireBytes)
        return try OmniFeatureReport(opcode: 0x1B, payload: payload, policy: policy)
    }
}

/// A 10-band graphic EQ (Bluetooth or mic). Gains are tenths of a dB.
public struct GraphicEQ<Preset: GraphicEQPreset>: Codable, Sendable, Hashable {
    public static var bandCount: Int { 10 }
    /// What the device field can hold (±12 dB).
    public static var gainTenthsRange: ClosedRange<Int> { -120...120 }
    /// What GG's UI offers (±10 dB in 0.5 dB steps).
    public static var uiGainTenthsRange: ClosedRange<Int> { -100...100 }

    public var presetIndex: UInt8
    public var shortName: String
    public var name: String
    public var gainsTenths: [Int]

    public init(preset: Preset, shortName: String, name: String, gainsTenths: [Int]) {
        self.presetIndex = preset.rawValue
        self.shortName = shortName
        self.name = name
        self.gainsTenths = gainsTenths
    }

    public var preset: Preset? {
        get { Preset(rawValue: presetIndex) }
        set { presetIndex = newValue?.rawValue ?? presetIndex }
    }

    public var gainsDB: [Double] { gainsTenths.map { Double($0) / 10 } }

    public static var flatGains: [Int] { [Int](repeating: 0, count: bandCount) }

    public func validate() throws {
        guard Preset(rawValue: presetIndex) != nil else {
            throw OmniError.valueOutOfRange(feature: Preset.feature, value: "preset \(presetIndex)",
                                            allowed: "0...\(Preset.allCases.count - 1)")
        }
        guard gainsTenths.count == Self.bandCount else {
            throw OmniError.valueOutOfRange(feature: Preset.feature, value: "\(gainsTenths.count) gains", allowed: "exactly 10")
        }
        for gain in gainsTenths where !Self.gainTenthsRange.contains(gain) {
            throw OmniError.valueOutOfRange(feature: Preset.feature, value: "\(gain) tenths dB", allowed: "-120...120")
        }
    }

    /// `01 1F|1D <idx> <short 6> <name 61> <10 × int8 gains>`, zero-padded to 1036.
    func featureReport(policy: OmniWritePolicy) throws -> OmniFeatureReport {
        guard policy.experimentalEQWrites else { throw OmniError.experimentalEQWritesDisabled }
        try validate()
        var payload = [presetIndex]
        payload += try OmniEQNames.encode(shortName, length: OmniEQNames.shortNameLength, feature: Preset.feature, field: "short name")
        payload += try OmniEQNames.encode(name, length: OmniEQNames.nameLength, feature: Preset.feature, field: "name")
        payload += gainsTenths.map { UInt8(bitPattern: Int8($0)) }
        return try OmniFeatureReport(opcode: Preset.writeOpcode, payload: payload, policy: policy)
    }
}

public typealias BluetoothEQ = GraphicEQ<BluetoothEQPreset>
public typealias MicEQ = GraphicEQ<MicEQPreset>

/// A preset name read with `01 18 <slot>`.
public struct OmniPresetName: Codable, Sendable, Hashable {
    public var slot: OmniPresetNameSlot
    /// 0 or 1 (GG's preset "class"; meaning unverified).
    public var presetClass: UInt8
    public var shortName: String
    public var name: String

    public init(slot: OmniPresetNameSlot, presetClass: UInt8, shortName: String, name: String) {
        self.slot = slot
        self.presetClass = presetClass
        self.shortName = shortName
        self.name = name
    }
}
