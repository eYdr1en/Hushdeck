import Foundation

/// How sure we are that a feature works as modelled. Ordered weakest to strongest so the UI can
/// badge anything below `.hardwareConfirmed` (or below `.documented`, for a stricter badge).
public enum OmniConfidence: Int, Codable, Sendable, CaseIterable, Comparable {
    /// My reasoning: an unconfirmed byte offset (feature-report ±1), an unconfirmed write layout,
    /// or a field whose meaning on the Omni is a guess.
    case inferred = 0
    /// Documented in protocol-notes.md, not yet seen on hardware.
    case documented = 1
    /// Seen working on a real GameHub (OmniKit's live tests or HeadsetControl PR #584).
    case hardwareConfirmed = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Every device-side feature OmniKit exposes, with its confidence. Source: protocol-notes.md.
public enum OmniFeature: String, Codable, Sendable, CaseIterable {
    // Device card and live status (readouts).
    case headsetBattery
    case spareBattery
    case chargingState
    case headsetLink
    case bluetoothStatus
    case micMute
    case chatMixDial
    case audioInput
    case firmwareVersions
    case serialNumber
    case colourVariant
    case hubVolume
    case wirelessMode
    case hubEvents

    // Audio tab.
    case wirelessEQ
    case bluetoothEQ
    case outputMode
    case streamMix
    case ancMode
    case ancLevel
    case transparencyLevel
    case volumeLimiter

    // Microphone tab.
    case micEQ
    case micVolume
    case sidetone
    case mutedMicLEDBrightness
    case micNoiseReduction

    // Settings tab.
    case autoOff
    case oledBrightness
    case homeScreenView
    case homeScreenOption
    case screensaverTimeout
    case screensaverMode
    case bluetoothCallBehaviour
    case bluetoothPowerOnDefault

    // EQ preset names stored on the hub, and persistence.
    case eqPresetNames
    case saveToDevice

    /// Confidence of the read path, or `nil` if OmniKit can't read it back.
    public var readConfidence: OmniConfidence? {
        switch self {
        // Confirmed on a real GameHub (hub fw 1.28.0, headset 0.33.0): every setting round-tripped
        // through write + re-read (LiveHubWriteTests), and the EQ/firmware/serial reads decoded to
        // the hub's actual presets and strings. Feature replies arrive without the report ID on macOS.
        case .headsetBattery, .chargingState, .firmwareVersions, .serialNumber,
             .ancMode, .ancLevel, .transparencyLevel, .mutedMicLEDBrightness, .autoOff,
             .oledBrightness, .homeScreenView, .homeScreenOption, .screensaverTimeout,
             .screensaverMode, .bluetoothCallBehaviour, .bluetoothPowerOnDefault,
             .wirelessEQ, .bluetoothEQ, .outputMode, .streamMix, .volumeLimiter,
             .micEQ, .micVolume, .sidetone, .micNoiseReduction, .eqPresetNames,
             // Hub events seen live (report ID 0x07): mute toggles, ANC button, volume knob (0x25).
             .micMute, .hubEvents, .hubVolume:
            .hardwareConfirmed
        // Decoded plausibly on hardware but not yet checked against the hub (OLED, dial, mute button).
        case .spareBattery, .headsetLink, .bluetoothStatus, .chatMixDial, .audioInput,
             .colourVariant, .wirelessMode:
            .documented
        case .saveToDevice:
            nil
        }
    }

    /// Confidence of the write path, or `nil` for read-only features.
    public var writeConfidence: OmniConfidence? {
        switch self {
        case .headsetBattery, .spareBattery, .chargingState, .headsetLink, .bluetoothStatus, .micMute,
             .chatMixDial, .audioInput, .firmwareVersions, .serialNumber, .colourVariant, .hubVolume,
             .wirelessMode, .hubEvents, .eqPresetNames:
            nil
        // All round-tripped on a real GameHub (LiveHubWriteTests).
        case .sidetone, .outputMode, .streamMix, .ancMode, .ancLevel, .transparencyLevel, .volumeLimiter,
             .micVolume, .mutedMicLEDBrightness, .micNoiseReduction, .autoOff, .oledBrightness,
             .homeScreenView, .homeScreenOption, .screensaverTimeout, .screensaverMode,
             .bluetoothCallBehaviour, .bluetoothPowerOnDefault:
            .hardwareConfirmed
        case .saveToDevice:
            .documented
        // Feature-report writes, round-tripped on hardware on the Custom slots (LiveHubEQTests).
        // Factory slots accept the preset index but keep the hub's own curve.
        case .wirelessEQ, .bluetoothEQ, .micEQ:
            .hardwareConfirmed
        }
    }

    /// The weaker of read and write: what a UI badge should show.
    public var confidence: OmniConfidence {
        [readConfidence, writeConfidence].compactMap { $0 }.min() ?? .inferred
    }

    public var isWritable: Bool { writeConfidence != nil }

    /// Writes need `OmniWritePolicy.experimentalEQWrites`.
    public var requiresExperimentalEQWrites: Bool {
        self == .wirelessEQ || self == .bluetoothEQ || self == .micEQ
    }

    /// Where it lives on the wire, for tooltips and debugging.
    public var wireReference: String {
        switch self {
        case .headsetBattery: "status 01 B0 byte 6; event B7 b2"
        case .spareBattery: "status byte 7; event B7 b3"
        case .chargingState: "status byte 15; event B7 b4"
        case .headsetLink: "status byte 14; event B5 b4"
        case .bluetoothStatus: "status bytes 4-5; event B5 b2-b3"
        case .micMute: "status byte 9; event BB"
        case .chatMixDial: "event 45; audio settings bytes 152-153"
        case .audioInput: "event 23; audio settings byte 142"
        case .firmwareVersions: "01 10"
        case .serialNumber: "01 12"
        case .colourVariant: "UX 01 80 byte 9"
        case .hubVolume: "audio settings byte 143"
        case .wirelessMode: "status byte 13"
        case .hubEvents: "usage page 0xFF00 input reports"
        case .wirelessEQ: "read 01 1A (feature); write 01 1B (feature)"
        case .bluetoothEQ: "read 01 1E (feature); write 01 1F (feature)"
        case .outputMode: "01 43; audio settings byte 148"
        case .streamMix: "01 47 main main aux mic; audio settings bytes 156/158/159"
        case .ancMode: "01 BD; status byte 10"
        case .ancLevel: "01 B8; status byte 16"
        case .transparencyLevel: "01 B9; status byte 8"
        case .volumeLimiter: "01 27; audio settings byte 144"
        case .micEQ: "read 01 1C (feature); write 01 1D (feature)"
        case .micVolume: "01 37; audio settings byte 146"
        case .sidetone: "01 38 on level; audio settings bytes 147/170"
        case .mutedMicLEDBrightness: "01 BF; status byte 11"
        case .micNoiseReduction: "01 3C en level; audio settings bytes 165-166"
        case .autoOff: "01 C1 code; status byte 12"
        case .oledBrightness: "01 85; UX byte 3"
        case .homeScreenView: "01 89; UX byte 5"
        case .homeScreenOption: "01 8A; UX byte 11"
        case .screensaverTimeout: "01 83 code; UX byte 2"
        case .screensaverMode: "01 88; UX byte 10"
        case .bluetoothCallBehaviour: "01 B3; status byte 3"
        case .bluetoothPowerOnDefault: "01 B2; status byte 2"
        case .eqPresetNames: "01 18 slot (feature)"
        case .saveToDevice: "01 09"
        }
    }
}
