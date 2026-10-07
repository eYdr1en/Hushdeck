import Foundation

/// Wire-level state of a fake GameHub. Replies are built byte by byte from protocol-notes §3,
/// independently of OmniKit's decoders, so round-trip tests exercise both sides.
public struct SimulatedGameHub: Sendable, Hashable {
    // Status (01 B0), §3.1. Defaults are GG's defaults with the headset on and connected.
    public var bluetoothPowerOnDefault: UInt8 = 0
    public var bluetoothCall: UInt8 = 0
    public var bluetoothMode: UInt8 = 1
    public var bluetoothLink: UInt8 = 1
    public var headsetBattery: UInt8 = 87
    public var spareBattery: UInt8 = 100
    public var transparencyLevel: UInt8 = 8
    public var micMuted: UInt8 = 0
    public var ancMode: UInt8 = 0
    public var mutedMicLED: UInt8 = 10
    public var autoOffCode: UInt8 = 5
    public var wirelessMode: UInt8 = 0
    public var headsetLink: UInt8 = 8
    public var charging: UInt8 = 8
    public var ancLevel: UInt8 = 3

    // OLED / UX (01 80), §3.5.
    public var screensaverCode: UInt8 = 3
    public var oledBrightness: UInt8 = 10
    public var homeView: UInt8 = 0
    public var colour: UInt8 = 0
    public var screensaverMode: UInt8 = 1
    public var homeOption: UInt8 = 0

    // Audio settings (01 20), §3.6.
    public var audioInput: UInt8 = 0
    public var hubVolume: UInt8 = 24
    public var volumeLimiter: UInt8 = 1
    public var surround: UInt8 = 0
    public var micVolume: UInt8 = 8
    public var sidetoneLevel: UInt8 = 5
    public var sidetoneOn: UInt8 = 1
    public var lineOut: UInt8 = 1
    public var chatMixGame: UInt8 = 100
    public var chatMixChat: UInt8 = 100
    public var streamMain: UInt8 = 100
    public var streamAux: UInt8 = 100
    public var streamMic: UInt8 = 100
    public var micNREnabled: UInt8 = 0
    public var micNRLevel: UInt8 = 1

    // EQ, §3.7.
    public var wirelessEQ = WirelessEQ(preset: .flat, shortName: "FLAT", name: "Flat", bands: ParametricBand.flat)
    public var wirelessCustomBands = ParametricBand.flat
    public var bluetoothEQ = BluetoothEQ(preset: .flat, shortName: "FLAT", name: "Flat", gainsTenths: BluetoothEQ.flatGains)
    public var micEQ = MicEQ(preset: .flat, shortName: "FLAT", name: "Flat", gainsTenths: MicEQ.flatGains)
    public var presetNames: [OmniPresetNameSlot: OmniPresetName] = [
        .wirelessCustom: OmniPresetName(slot: .wirelessCustom, presetClass: 0, shortName: "CUSTOM", name: "Custom"),
        .bluetoothCustom: OmniPresetName(slot: .bluetoothCustom, presetClass: 0, shortName: "CUSTOM", name: "Custom"),
        .wirelessGame: OmniPresetName(slot: .wirelessGame, presetClass: 1, shortName: "GAME", name: "Game preset"),
        .micCustom: OmniPresetName(slot: .micCustom, presetClass: 0, shortName: "CUSTOM", name: "Custom"),
    ]

    // Identity, §3.3.
    public var firmware = OmniFirmwareVersions(hubMCU1: "1.32.0", hubMCU2: "1.32.0", hubDSP: "0.36.0",
                                               headsetMCU: "0.36.0", headsetBluetooth: "0.36.0")
    public var serial = "SIMOMNI000000000042"

    /// Number of save-to-flash commands received, and the state at the last one.
    public var saveCount = 0
    public var lastSavedSnapshot: SimulatedSettingsSnapshot?

    public init() {}

    // MARK: Replies

    public func statusReport() -> [UInt8] {
        Self.pad([0x01, 0xB0, bluetoothPowerOnDefault, bluetoothCall, bluetoothMode, bluetoothLink, headsetBattery,
                  spareBattery, transparencyLevel, micMuted, ancMode, mutedMicLED, autoOffCode, wirelessMode,
                  headsetLink, charging, ancLevel], to: OmniUSB.outputReportLength)
    }

    public func displayReport() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: OmniUSB.outputReportLength)
        r[0] = 0x01; r[1] = 0x80
        r[2] = screensaverCode; r[3] = oledBrightness; r[5] = homeView
        r[9] = colour; r[10] = screensaverMode; r[11] = homeOption
        return r
    }

    public func firmwareReport() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: OmniUSB.outputReportLength)
        r[0] = 0x01; r[1] = 0x10
        let fields = [firmware.hubMCU1, firmware.hubMCU2, firmware.hubDSP, firmware.headsetMCU, firmware.headsetBluetooth]
        for (i, text) in fields.enumerated() {
            for (j, byte) in text.utf8.prefix(12).enumerated() { r[2 + 12 * i + j] = byte }
        }
        return r
    }

    public func serialReport() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: OmniUSB.outputReportLength)
        r[0] = 0x01; r[1] = 0x12
        for (j, byte) in serial.utf8.prefix(19).enumerated() { r[2 + j] = byte }
        return r
    }

    public func audioSettingsFeature() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: OmniUSB.featureReportLength)
        r[0] = 0x01; r[1] = 0x20
        Self.write(bands: wirelessCustomBands, into: &r, at: 2)
        Self.write(bands: wirelessEQ.bands, into: &r, at: 62)
        Self.write(gains: bluetoothEQ.gainsTenths, into: &r, at: 122)
        Self.write(gains: micEQ.gainsTenths, into: &r, at: 132)
        r[142] = audioInput; r[143] = hubVolume; r[144] = volumeLimiter; r[145] = surround
        r[146] = micVolume; r[147] = sidetoneLevel; r[148] = lineOut
        r[149] = wirelessEQ.presetIndex; r[150] = micEQ.presetIndex; r[151] = bluetoothEQ.presetIndex
        r[152] = chatMixGame; r[153] = chatMixChat
        r[156] = streamMain; r[158] = streamAux; r[159] = streamMic
        r[165] = micNREnabled; r[166] = micNRLevel; r[170] = sidetoneOn
        return r
    }

    public func wirelessEQFeature() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: OmniUSB.featureReportLength)
        r[0] = 0x01; r[1] = 0x1A; r[2] = wirelessEQ.presetIndex
        Self.write(text: wirelessEQ.shortName, into: &r, at: 3, length: 6)
        Self.write(text: wirelessEQ.name, into: &r, at: 9, length: 61)
        Self.write(bands: wirelessEQ.bands, into: &r, at: 70)
        return r
    }

    public func graphicEQFeature<P>(_ eq: GraphicEQ<P>) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: OmniUSB.featureReportLength)
        r[0] = 0x01; r[1] = P.readQuery.opcode; r[2] = eq.presetIndex
        Self.write(text: eq.shortName, into: &r, at: 3, length: 6)
        Self.write(text: eq.name, into: &r, at: 9, length: 61)
        Self.write(gains: eq.gainsTenths, into: &r, at: 70)
        return r
    }

    public func presetNameFeature(_ slot: OmniPresetNameSlot) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: OmniUSB.featureReportLength)
        r[0] = 0x01; r[1] = 0x18; r[2] = slot.rawValue
        if let name = presetNames[slot] {
            r[3] = name.presetClass
            Self.write(text: name.shortName, into: &r, at: 4, length: 6)
            Self.write(text: name.name, into: &r, at: 10, length: 61)
        }
        return r
    }

    // MARK: Writes

    /// Applies a 64-byte settings write the way the hub would. Returns `true` if it was a setting.
    @discardableResult
    public mutating func applySettingWrite(_ r: [UInt8]) -> Bool {
        guard r.count >= 6 else { return false }
        switch r[1] {
        case 0x38: sidetoneOn = r[2]; sidetoneLevel = r[3]
        case 0x37: micVolume = r[2]
        case 0x3C: micNREnabled = r[2]; micNRLevel = r[3]
        case 0xBF: mutedMicLED = r[2]
        case 0xBD: ancMode = r[2]
        case 0xB8: ancLevel = r[2]
        case 0xB9: transparencyLevel = r[2]
        case 0xC1: autoOffCode = r[2]
        case 0x27: volumeLimiter = r[2]
        case 0x43: lineOut = r[2]
        case 0x47: streamMain = r[2]; streamAux = r[4]; streamMic = r[5]
        case 0x85: oledBrightness = r[2]
        case 0x83: screensaverCode = r[2]
        case 0x88: screensaverMode = r[2]
        case 0x89: homeView = r[2]
        case 0x8A: homeOption = r[2]
        case 0xB2: bluetoothPowerOnDefault = r[2]
        case 0xB3: bluetoothCall = r[2]
        default: return false
        }
        return true
    }

    /// Applies a 1036-byte EQ upload (0x1B / 0x1D / 0x1F).
    public mutating func applyFeatureWrite(_ r: [UInt8]) {
        guard r.count >= 80 else { return }
        let short = OmniEQNames.decode(r[3..<9]), name = OmniEQNames.decode(r[9..<70])
        switch r[1] {
        case 0x1B:
            let bands = (0..<10).map { ParametricBand(wire: r[(70 + 6 * $0)..<(76 + 6 * $0)]) }
            wirelessEQ = WirelessEQ(preset: .flat, shortName: short, name: name, bands: bands)
            wirelessEQ.presetIndex = r[2]
            if r[2] == WirelessEQPreset.custom.rawValue {
                wirelessCustomBands = bands
                presetNames[.wirelessCustom] = OmniPresetName(slot: .wirelessCustom, presetClass: 0, shortName: short, name: name)
            }
        case 0x1F:
            bluetoothEQ = BluetoothEQ(preset: .flat, shortName: short, name: name, gainsTenths: r[70..<80].map { Int(Int8(bitPattern: $0)) })
            bluetoothEQ.presetIndex = r[2]
        case 0x1D:
            micEQ = MicEQ(preset: .flat, shortName: short, name: name, gainsTenths: r[70..<80].map { Int(Int8(bitPattern: $0)) })
            micEQ.presetIndex = r[2]
        default:
            break
        }
    }

    public var settingsSnapshot: SimulatedSettingsSnapshot {
        SimulatedSettingsSnapshot(statusReport: statusReport(), displayReport: displayReport(), audioSettings: audioSettingsFeature())
    }

    // MARK: Helpers

    static func pad(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count))
    }

    private static func write(bands: [ParametricBand], into r: inout [UInt8], at offset: Int) {
        for (i, band) in bands.prefix(10).enumerated() {
            r.replaceSubrange((offset + 6 * i)..<(offset + 6 * i + 6), with: band.wireBytes)
        }
    }

    private static func write(gains: [Int], into r: inout [UInt8], at offset: Int) {
        for (i, gain) in gains.prefix(10).enumerated() { r[offset + i] = UInt8(bitPattern: Int8(clamping: gain)) }
    }

    private static func write(text: String, into r: inout [UInt8], at offset: Int, length: Int) {
        for (j, byte) in text.utf8.prefix(length).enumerated() { r[offset + j] = byte }
    }
}

/// What the simulated hub had in "flash" at the last save.
public struct SimulatedSettingsSnapshot: Sendable, Hashable {
    public var statusReport: [UInt8]
    public var displayReport: [UInt8]
    public var audioSettings: [UInt8]
}
