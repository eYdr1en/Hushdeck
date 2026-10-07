import Foundation

// Decoders for query replies. Byte offsets follow protocol-notes §3 and tools/probe.py, with the
// report ID at byte 0 and the opcode echo at byte 1.

/// Status reply (`01 B0`, §3.1).
public struct OmniStatus: Codable, Sendable, Hashable {
    public var bluetoothPowerOnDefault: Bool
    public var bluetoothCallBehaviour: BluetoothCallBehaviour?
    public var bluetoothMode: BluetoothMode?
    public var bluetoothLink: BluetoothLinkStatus?
    public var headsetBattery: Int
    public var spareBattery: Int
    public var transparencyLevel: Int
    public var micMuted: Bool
    public var ancMode: ANCMode?
    public var mutedMicLEDBrightness: Int
    public var autoOff: OmniTimeout?
    public var wirelessMode: WirelessMode?
    public var headsetLink: HeadsetLinkState?
    public var charging: ChargingState?
    public var ancLevel: ANCLevel?

    public init(report r: [UInt8]) throws {
        try OmniReply.expect(r, opcode: 0xB0, minimumLength: 17)
        bluetoothPowerOnDefault = r[2] != 0
        bluetoothCallBehaviour = BluetoothCallBehaviour(rawValue: r[3])
        bluetoothMode = BluetoothMode(rawValue: r[4])
        bluetoothLink = BluetoothLinkStatus(rawValue: r[5])
        headsetBattery = Int(r[6])
        spareBattery = Int(r[7])
        transparencyLevel = Int(r[8])
        micMuted = r[9] != 0
        ancMode = ANCMode(rawValue: r[10])
        mutedMicLEDBrightness = Int(r[11])
        autoOff = OmniTimeout(rawValue: r[12])
        wirelessMode = WirelessMode(rawValue: r[13])
        headsetLink = HeadsetLinkState(rawValue: r[14])
        charging = ChargingState(rawValue: r[15])
        ancLevel = ANCLevel(rawValue: r[16])
    }
}

/// OLED / UX settings reply (`01 80`, §3.5).
public struct OmniDisplaySettings: Codable, Sendable, Hashable {
    public var screensaverTimeout: OmniTimeout?
    public var brightness: Int
    public var homeScreenView: HomeScreenView?
    public var colour: ColourVariant?
    public var screensaverMode: ScreensaverMode?
    public var homeScreenOption: HomeScreenOption?

    public init(report r: [UInt8]) throws {
        try OmniReply.expect(r, opcode: 0x80, minimumLength: 12)
        screensaverTimeout = OmniTimeout(rawValue: r[2])
        brightness = Int(r[3])
        homeScreenView = HomeScreenView(rawValue: r[5])
        colour = ColourVariant(rawValue: r[9])
        screensaverMode = ScreensaverMode(rawValue: r[10])
        homeScreenOption = HomeScreenOption(rawValue: r[11])
    }
}

/// Firmware versions (`01 10`, §3.3): five 12-byte ASCII fields.
public struct OmniFirmwareVersions: Codable, Sendable, Hashable {
    public var hubMCU1: String
    public var hubMCU2: String
    public var hubDSP: String
    public var headsetMCU: String
    public var headsetBluetooth: String

    public init(hubMCU1: String, hubMCU2: String, hubDSP: String, headsetMCU: String, headsetBluetooth: String) {
        self.hubMCU1 = hubMCU1
        self.hubMCU2 = hubMCU2
        self.hubDSP = hubDSP
        self.headsetMCU = headsetMCU
        self.headsetBluetooth = headsetBluetooth
    }

    public init(report r: [UInt8]) throws {
        try OmniReply.expect(r, opcode: 0x10, minimumLength: 62)
        func field(_ i: Int) -> String { OmniEQNames.decode(r[(2 + 12 * i)..<(14 + 12 * i)]) }
        self.init(hubMCU1: field(0), hubMCU2: field(1), hubDSP: field(2), headsetMCU: field(3), headsetBluetooth: field(4))
    }

    /// All-zero headset fields mean no headset is paired (or it hasn't reported yet).
    public var hasHeadsetVersions: Bool { !headsetMCU.isEmpty || !headsetBluetooth.isEmpty }
}

enum OmniSerialReply {
    /// `01 12` reply: 19 ASCII bytes at b2..b20.
    static func decode(_ r: [UInt8]) throws -> String {
        try OmniReply.expect(r, opcode: 0x12, minimumLength: 21)
        return OmniEQNames.decode(r[2..<21])
    }
}

/// Full audio settings (`01 20` then GET_FEATURE, §3.6). Offsets are GG's layout with the report
/// ID at byte 0; if the hub turns out to omit the ID, `OmniReply.alignFeature` fixes it up.
public struct OmniAudioSettings: Codable, Sendable, Hashable {
    public var customWirelessBands: [ParametricBand]
    public var activeWirelessBands: [ParametricBand]
    public var bluetoothGainsTenths: [Int]
    public var micGainsTenths: [Int]
    public var audioInput: Int
    public var hubVolume: Int
    public var volumeLimiter: Bool
    public var surround: Bool
    public var micVolume: Int
    public var sidetoneLevel: Int
    public var outputMode: OutputMode?
    public var wirelessPresetIndex: UInt8
    public var micPresetIndex: UInt8
    public var bluetoothPresetIndex: UInt8
    public var chatMix: ChatMix
    public var streamMix: StreamMix
    public var micNoiseReduction: MicNoiseReduction?
    public var sidetoneEnabled: Bool

    public init(report raw: [UInt8]) throws {
        let r = try OmniReply.alignFeature(raw, opcode: 0x20, minimumLength: 171)
        customWirelessBands = (0..<10).map { ParametricBand(wire: r[(2 + 6 * $0)..<(8 + 6 * $0)]) }
        activeWirelessBands = (0..<10).map { ParametricBand(wire: r[(62 + 6 * $0)..<(68 + 6 * $0)]) }
        bluetoothGainsTenths = r[122..<132].map { Int(Int8(bitPattern: $0)) }
        micGainsTenths = r[132..<142].map { Int(Int8(bitPattern: $0)) }
        audioInput = Int(r[142])
        hubVolume = Int(r[143])
        volumeLimiter = r[144] != 0
        surround = r[145] != 0
        micVolume = Int(r[146])
        sidetoneLevel = Int(r[147])
        outputMode = OutputMode(rawValue: r[148])
        wirelessPresetIndex = r[149]
        micPresetIndex = r[150]
        bluetoothPresetIndex = r[151]
        chatMix = ChatMix(game: Int(r[152]), chat: Int(r[153]))
        streamMix = StreamMix(main: Int(r[156]), aux: Int(r[158]), mic: Int(r[159]))
        micNoiseReduction = MicNoiseReduction(enabled: r[165], level: r[166])
        sidetoneEnabled = r[170] != 0
    }

    public var sidetone: Sidetone { Sidetone(isEnabled: sidetoneEnabled, level: sidetoneLevel) }
}

extension WirelessEQ {
    /// `01 1A` reply: b2 preset, b3–8 short name, b9–69 name, b70–129 bands.
    public init(report raw: [UInt8]) throws {
        let r = try OmniReply.alignFeature(raw, opcode: 0x1A, minimumLength: 130)
        presetIndex = r[2]
        shortName = OmniEQNames.decode(r[3..<9])
        name = OmniEQNames.decode(r[9..<70])
        bands = (0..<10).map { ParametricBand(wire: r[(70 + 6 * $0)..<(76 + 6 * $0)]) }
    }
}

extension GraphicEQ {
    /// `01 1E` / `01 1C` reply: b2 preset, b3–8 short name, b9–69 name, b70–79 gains.
    public init(report raw: [UInt8]) throws {
        let r = try OmniReply.alignFeature(raw, opcode: Preset.readQuery.opcode, minimumLength: 80)
        presetIndex = r[2]
        shortName = OmniEQNames.decode(r[3..<9])
        name = OmniEQNames.decode(r[9..<70])
        gainsTenths = r[70..<80].map { Int(Int8(bitPattern: $0)) }
    }
}

extension OmniPresetName {
    /// `01 18 <slot>` reply: b2 slot, b3 class, b4–9 short name, b10–70 name.
    public init(report raw: [UInt8]) throws {
        let r = try OmniReply.alignFeature(raw, opcode: 0x18, minimumLength: 71)
        guard let slot = OmniPresetNameSlot(rawValue: r[2]) else {
            throw OmniError.malformedReply("preset-name slot \(r[2])")
        }
        self.init(slot: slot, presetClass: r[3], shortName: OmniEQNames.decode(r[4..<10]), name: OmniEQNames.decode(r[10..<71]))
    }
}

enum OmniReply {
    static func expect(_ r: [UInt8], opcode: UInt8, minimumLength: Int) throws {
        guard r.count >= minimumLength else {
            throw OmniError.malformedReply(String(format: "0x%02X reply is %d bytes, need %d", opcode, r.count, minimumLength))
        }
        guard r[0] == OmniUSB.reportID, r[1] == opcode else {
            throw OmniError.malformedReply(String(format: "expected 01 %02X, got %02X %02X", opcode, r[0], r[1]))
        }
    }

    /// Normalises a feature reply so byte 1 is the opcode echo. protocol-notes §6.1: the report
    /// ID may or may not be at byte 0. `01 <echo>` is used as is; a buffer starting with the echo
    /// had its report ID omitted and gets one prepended. The report ID must be checked too: with
    /// the ID omitted, byte 1 is data and can equal the echo by chance (32 Hz = 0x20 = `01 20`).
    static func alignFeature(_ r: [UInt8], opcode: UInt8, minimumLength: Int) throws -> [UInt8] {
        let aligned: [UInt8]
        if r.count > 1, r[0] == OmniUSB.reportID, r[1] == opcode {
            aligned = r
        } else if let first = r.first, first == opcode {
            aligned = [OmniUSB.reportID] + r
        } else {
            let head = r.prefix(2).map { String(format: "%02X", $0) }.joined(separator: " ")
            throw OmniError.malformedReply(String(format: "feature reply for 0x%02X starts with %@", opcode, head))
        }
        guard aligned.count >= minimumLength else {
            throw OmniError.malformedReply(String(format: "0x%02X feature reply is %d bytes, need %d", opcode, aligned.count, minimumLength))
        }
        return aligned
    }
}
