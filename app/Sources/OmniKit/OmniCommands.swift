import Foundation

/// The allowlisted settings writes (protocol-notes §3.4), one case per command. Encodings match
/// `tools/probe.py`'s ALLOWLIST byte for byte (see the golden tests). Values are range-checked
/// when the packet is built, so an invalid value throws before anything reaches a transport.
public enum OmniSetting: Sendable, Hashable, Codable {
    case sidetone(Sidetone)
    case micVolume(Int)
    case micNoiseReduction(MicNoiseReduction)
    case mutedMicLEDBrightness(Int)
    case ancMode(ANCMode)
    case ancLevel(ANCLevel)
    case transparencyLevel(Int)
    case autoOff(OmniTimeout)
    /// `true` = limiter on (GG "On/Low" gain), `false` = off ("Off/High").
    case volumeLimiter(Bool)
    case outputMode(OutputMode)
    case streamMix(StreamMix)
    case oledBrightness(Int)
    case screensaverTimeout(OmniTimeout)
    case screensaverMode(ScreensaverMode)
    case homeScreenView(HomeScreenView)
    case homeScreenOption(HomeScreenOption)
    case bluetoothPowerOnDefault(Bool)
    case bluetoothCallBehaviour(BluetoothCallBehaviour)

    public var feature: OmniFeature {
        switch self {
        case .sidetone: .sidetone
        case .micVolume: .micVolume
        case .micNoiseReduction: .micNoiseReduction
        case .mutedMicLEDBrightness: .mutedMicLEDBrightness
        case .ancMode: .ancMode
        case .ancLevel: .ancLevel
        case .transparencyLevel: .transparencyLevel
        case .autoOff: .autoOff
        case .volumeLimiter: .volumeLimiter
        case .outputMode: .outputMode
        case .streamMix: .streamMix
        case .oledBrightness: .oledBrightness
        case .screensaverTimeout: .screensaverTimeout
        case .screensaverMode: .screensaverMode
        case .homeScreenView: .homeScreenView
        case .homeScreenOption: .homeScreenOption
        case .bluetoothPowerOnDefault: .bluetoothPowerOnDefault
        case .bluetoothCallBehaviour: .bluetoothCallBehaviour
        }
    }

    public var opcode: UInt8 {
        switch self {
        case .sidetone: 0x38
        case .micVolume: 0x37
        case .micNoiseReduction: 0x3C
        case .mutedMicLEDBrightness: 0xBF
        case .ancMode: 0xBD
        case .ancLevel: 0xB8
        case .transparencyLevel: 0xB9
        case .autoOff: 0xC1
        case .volumeLimiter: 0x27
        case .outputMode: 0x43
        case .streamMix: 0x47
        case .oledBrightness: 0x85
        case .screensaverTimeout: 0x83
        case .screensaverMode: 0x88
        case .homeScreenView: 0x89
        case .homeScreenOption: 0x8A
        case .bluetoothPowerOnDefault: 0xB2
        case .bluetoothCallBehaviour: 0xB3
        }
    }

    /// Throws `OmniError.valueOutOfRange` for values outside protocol-notes §3.4.
    public func validate() throws {
        switch self {
        case .sidetone(let s):
            try Self.check(s.level, in: Sidetone.levels, feature: .sidetone)
        case .micVolume(let v):
            try Self.check(v, in: OmniRanges.micVolume, feature: .micVolume)
        case .mutedMicLEDBrightness(let v):
            try Self.check(v, in: OmniRanges.mutedMicLEDBrightness, feature: .mutedMicLEDBrightness)
        case .transparencyLevel(let v):
            try Self.check(v, in: OmniRanges.transparencyLevel, feature: .transparencyLevel)
        case .oledBrightness(let v):
            try Self.check(v, in: OmniRanges.oledBrightness, feature: .oledBrightness)
        case .streamMix(let mix):
            for level in [mix.main, mix.aux, mix.mic] {
                try Self.check(level, in: StreamMix.levels, feature: .streamMix)
            }
        case .micNoiseReduction, .ancMode, .ancLevel, .autoOff, .volumeLimiter, .outputMode,
             .screensaverTimeout, .screensaverMode, .homeScreenView, .homeScreenOption,
             .bluetoothPowerOnDefault, .bluetoothCallBehaviour:
            break // Enums: every case is a valid wire value.
        }
    }

    /// Argument bytes after the opcode. Only call after `validate()`.
    var arguments: [UInt8] {
        switch self {
        case .sidetone(let s): [s.isEnabled ? 1 : 0, UInt8(s.level)]
        case .micVolume(let v): [UInt8(v)]
        case .micNoiseReduction(let nr): nr.wireArguments
        case .mutedMicLEDBrightness(let v): [UInt8(v)]
        case .ancMode(let m): [m.rawValue]
        case .ancLevel(let l): [l.rawValue]
        case .transparencyLevel(let v): [UInt8(v)]
        case .autoOff(let t): [t.rawValue]
        case .volumeLimiter(let on): [on ? 1 : 0]
        case .outputMode(let m): [m.rawValue]
        // GG sends the main level twice.
        case .streamMix(let mix): [UInt8(mix.main), UInt8(mix.main), UInt8(mix.aux), UInt8(mix.mic)]
        case .oledBrightness(let v): [UInt8(v)]
        case .screensaverTimeout(let t): [t.rawValue]
        case .screensaverMode(let m): [m.rawValue]
        case .homeScreenView(let v): [v.rawValue]
        case .homeScreenOption(let o): [o.rawValue]
        case .bluetoothPowerOnDefault(let on): [on ? 1 : 0]
        case .bluetoothCallBehaviour(let b): [b.rawValue]
        }
    }

    /// Validates, then builds the 64-byte output report (which also runs the DO NOT SEND check).
    public func outputReport() throws -> OmniOutputReport {
        try validate()
        return try OmniOutputReport(opcode: opcode, arguments: arguments)
    }

    private static func check(_ value: Int, in range: ClosedRange<Int>, feature: OmniFeature) throws {
        guard range.contains(value) else {
            throw OmniError.valueOutOfRange(feature: feature, value: "\(value)",
                                            allowed: "\(range.lowerBound)...\(range.upperBound)")
        }
    }
}

/// EQ preset-name slots readable with `01 18 <slot>` (protocol-notes §3.7).
public enum OmniPresetNameSlot: UInt8, Codable, Sendable, CaseIterable {
    case wirelessCustom = 0
    case bluetoothCustom = 1
    /// The 2.4 GHz "game / other" slot (preset index 5).
    case wirelessGame = 2
    case micCustom = 3
}

/// Read queries. Input queries get a 64-byte input-report reply on the command collection;
/// feature queries are followed by GET_FEATURE(0x01, 1036).
public enum OmniQuery: Sendable, Hashable, CustomStringConvertible {
    case status
    case firmwareVersions
    case serialNumber
    case displaySettings
    case audioSettings
    case wirelessEQ
    case bluetoothEQ
    case micEQ
    case presetName(OmniPresetNameSlot)

    public enum ReplyKind: Sendable { case inputReport, featureReport }

    public var opcode: UInt8 {
        switch self {
        case .status: 0xB0
        case .firmwareVersions: 0x10
        case .serialNumber: 0x12
        case .displaySettings: 0x80
        case .audioSettings: 0x20
        case .wirelessEQ: 0x1A
        case .bluetoothEQ: 0x1E
        case .micEQ: 0x1C
        case .presetName: 0x18
        }
    }

    var arguments: [UInt8] {
        if case .presetName(let slot) = self { return [slot.rawValue] }
        return []
    }

    public var replyKind: ReplyKind {
        switch self {
        case .status, .firmwareVersions, .serialNumber, .displaySettings: .inputReport
        case .audioSettings, .wirelessEQ, .bluetoothEQ, .micEQ, .presetName: .featureReport
        }
    }

    public func outputReport() throws -> OmniOutputReport {
        try OmniOutputReport(opcode: opcode, arguments: arguments)
    }

    public var description: String {
        switch self {
        case .status: "status"
        case .firmwareVersions: "firmware"
        case .serialNumber: "serial"
        case .displaySettings: "OLED settings"
        case .audioSettings: "audio settings"
        case .wirelessEQ: "2.4 GHz EQ"
        case .bluetoothEQ: "Bluetooth EQ"
        case .micEQ: "mic EQ"
        case .presetName(let slot): "preset name \(slot.rawValue)"
        }
    }
}
