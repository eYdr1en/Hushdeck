import Foundation

// Typed values for every Omni setting and readout. Raw values are the wire encodings from
// protocol-notes §3.1, §3.4 and §3.5.

/// Headset noise control (`01 BD`, status byte 10).
public enum ANCMode: UInt8, Codable, Sendable, CaseIterable {
    case off = 0
    case transparency = 1
    case activeNoiseCancellation = 2
}

/// ANC strength (`01 B8`, status byte 16). GG labels them Low / Medium / High.
public enum ANCLevel: UInt8, Codable, Sendable, CaseIterable {
    case low = 1
    case medium = 2
    case high = 3
}

/// Boom-mic AI noise reduction (`01 3C <en> <lvl>`). Off goes on the wire as `00 01`.
public enum MicNoiseReduction: UInt8, Codable, Sendable, CaseIterable {
    case off = 0
    case low = 1
    case medium = 2
    case high = 3

    var wireArguments: [UInt8] { self == .off ? [0, 1] : [1, rawValue] }

    init?(enabled: UInt8, level: UInt8) {
        if enabled == 0 { self = .off; return }
        guard let value = MicNoiseReduction(rawValue: level), value != .off else { return nil }
        self = value
    }
}

/// Line-out ("Output") mode (`01 43`).
public enum OutputMode: UInt8, Codable, Sendable, CaseIterable {
    case speakers = 1
    case streaming = 2
}

/// The minutes → code table shared by the auto-off timer (`01 C1`) and the OLED screensaver
/// timer (`01 83`). The code, not the minutes, goes on the wire.
public enum OmniTimeout: UInt8, Codable, Sendable, CaseIterable {
    /// "Never" for auto-off, "Off" for the screensaver.
    case never = 0
    case oneMinute = 1
    case fiveMinutes = 2
    case tenMinutes = 3
    case fifteenMinutes = 4
    case thirtyMinutes = 5
    case sixtyMinutes = 6

    public var minutes: Int {
        switch self {
        case .never: 0
        case .oneMinute: 1
        case .fiveMinutes: 5
        case .tenMinutes: 10
        case .fifteenMinutes: 15
        case .thirtyMinutes: 30
        case .sixtyMinutes: 60
        }
    }

    /// `nil` for minute values the hub doesn't offer (e.g. 45).
    public init?(minutes: Int) {
        guard let match = Self.allCases.first(where: { $0.minutes == minutes }) else { return nil }
        self = match
    }
}

/// OLED screensaver mode (`01 88`).
public enum ScreensaverMode: UInt8, Codable, Sendable, CaseIterable {
    case screenOff = 0
    case dim = 1
}

/// OLED home-screen view (`01 89`).
public enum HomeScreenView: UInt8, Codable, Sendable, CaseIterable {
    case detailed = 0
    case simple = 1
}

/// OLED home-screen option (`01 8A`).
public enum HomeScreenOption: UInt8, Codable, Sendable, CaseIterable {
    case stereo = 0
    case preset = 1
    case meters = 2
}

/// What Bluetooth calls do to the other audio (`01 B3`, status byte 3).
public enum BluetoothCallBehaviour: UInt8, Codable, Sendable, CaseIterable {
    case doNothing = 0
    case lowerOtherAudio = 1
    case muteOtherAudio = 2
}

/// Headset charging state (status byte 15, battery event b4).
public enum ChargingState: UInt8, Codable, Sendable, CaseIterable {
    /// Unknown, or the headset isn't connected.
    case unknown = 1
    case charging = 2
    /// Plugged in but not charging (full).
    case pluggedInNotCharging = 4
    /// Running on battery.
    case discharging = 8
}

/// 2.4 GHz link between hub and headset (status byte 14, connection event b4).
public enum HeadsetLinkState: UInt8, Codable, Sendable, CaseIterable {
    case unpaired = 1
    case pairing = 2
    /// Paired but not connected (headset off or out of range).
    case disconnected = 4
    case connected = 8
}

/// Bluetooth radio mode (status byte 4, connection event b2).
public enum BluetoothMode: UInt8, Codable, Sendable, CaseIterable {
    case off = 1
    case pairing = 2
    case linkMode = 4
}

/// Bluetooth link status when the mode is `.linkMode` (status byte 5, connection event b3).
public enum BluetoothLinkStatus: UInt8, Codable, Sendable, CaseIterable {
    case ready = 1
    case lost = 2
    case busy = 4
    case error = 8
}

/// Wireless mode (status byte 13). Read-only; GG has no Omni write for it.
public enum WirelessMode: UInt8, Codable, Sendable, CaseIterable {
    case speed = 0
    case range = 1
}

/// Colour variant (UX settings byte 9).
public enum ColourVariant: UInt8, Codable, Sendable, CaseIterable {
    case black = 0
    case white = 1
    case midnightBlue = 4
    case amazonEdition = 5
}

/// Boom-mic sidetone (`01 38 <on> <lvl>`). GG keeps the level when switching off.
public struct Sidetone: Codable, Sendable, Hashable {
    public var isEnabled: Bool
    /// 1–10.
    public var level: Int

    public init(isEnabled: Bool, level: Int) {
        self.isEnabled = isEnabled
        self.level = level
    }

    public static let levels = 1...10
}

/// Line-out stream mix (`01 47 <main> <main> <aux> <mic>`), each 0–100.
public struct StreamMix: Codable, Sendable, Hashable {
    public var main: Int
    public var aux: Int
    public var mic: Int

    public init(main: Int, aux: Int, mic: Int) {
        self.main = main
        self.aux = aux
        self.mic = mic
    }

    public static let levels = 0...100
    /// GG's UI step.
    public static let uiStep = 5
}

/// Hardware ChatMix dial position (event 0x45, audio settings bytes 152–153), each 0–100.
public struct ChatMix: Codable, Sendable, Hashable {
    public var game: Int
    public var chat: Int

    public init(game: Int, chat: Int) {
        self.game = game
        self.chat = chat
    }
}

/// Ranges for the plain integer settings, from protocol-notes §3.4.
public enum OmniRanges {
    public static let micVolume = 1...10
    public static let mutedMicLEDBrightness = 0...10
    public static let transparencyLevel = 1...10
    public static let oledBrightness = 1...10
    public static let batteryPercent = 0...100
}
