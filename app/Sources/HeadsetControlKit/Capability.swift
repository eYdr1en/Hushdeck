import Foundation

/// A HeadsetControl capability identifier, as reported in the `capabilities` array
/// of `headsetcontrol -o json` (for example `"CAP_SIDETONE"`).
///
/// This is deliberately an open struct rather than a closed enum: newer HeadsetControl
/// builds add capabilities (the Arctis Nova Pro Omni work is expected to add a noise
/// cancelling one), and an unknown identifier must decode cleanly instead of failing
/// the whole status payload. Known identifiers are exposed as static constants.
public struct Capability: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    // MARK: Known capabilities (HeadsetControl 4.1, api_version 1.5)

    public static let sidetone = Capability(rawValue: "CAP_SIDETONE")
    public static let batteryStatus = Capability(rawValue: "CAP_BATTERY_STATUS")
    public static let notificationSound = Capability(rawValue: "CAP_NOTIFICATION_SOUND")
    public static let lights = Capability(rawValue: "CAP_LIGHTS")
    public static let inactiveTime = Capability(rawValue: "CAP_INACTIVE_TIME")
    public static let chatmixStatus = Capability(rawValue: "CAP_CHATMIX_STATUS")
    public static let voicePrompts = Capability(rawValue: "CAP_VOICE_PROMPTS")
    public static let rotateToMute = Capability(rawValue: "CAP_ROTATE_TO_MUTE")
    public static let equalizerPreset = Capability(rawValue: "CAP_EQUALIZER_PRESET")
    public static let equalizer = Capability(rawValue: "CAP_EQUALIZER")
    public static let parametricEqualizer = Capability(rawValue: "CAP_PARAMETRIC_EQUALIZER")
    public static let microphoneMuteLEDBrightness = Capability(rawValue: "CAP_MICROPHONE_MUTE_LED_BRIGHTNESS")
    public static let microphoneVolume = Capability(rawValue: "CAP_MICROPHONE_VOLUME")
    public static let volumeLimiter = Capability(rawValue: "CAP_VOLUME_LIMITER")
    public static let bluetoothWhenPoweredOn = Capability(rawValue: "CAP_BT_WHEN_POWERED_ON")
    public static let bluetoothCallVolume = Capability(rawValue: "CAP_BT_CALL_VOLUME")
    public static let noiseFilter = Capability(rawValue: "CAP_NOISE_FILTER")
    public static let sidetoneStatus = Capability(rawValue: "CAP_SIDETONE_STATUS")

    public static let allKnown: [Capability] = [
        .sidetone, .batteryStatus, .notificationSound, .lights, .inactiveTime, .chatmixStatus,
        .voicePrompts, .rotateToMute, .equalizerPreset, .equalizer, .parametricEqualizer,
        .microphoneMuteLEDBrightness, .microphoneVolume, .volumeLimiter, .bluetoothWhenPoweredOn,
        .bluetoothCallVolume, .noiseFilter, .sidetoneStatus,
    ]

    public var isKnown: Bool { Self.allKnown.contains(self) }

    // MARK: Noise cancelling (not in HeadsetControl yet)

    /// Identifier fragments that indicate an active-noise-cancelling / transparency
    /// capability. HeadsetControl has none today; whichever name the Omni work lands
    /// on (`CAP_ANC`, `CAP_NOISE_CANCELLING`, `CAP_NOISE_CANCELLATION`, `CAP_TRANSPARENCY`...)
    /// should light up the ANC control without an app update.
    static let noiseCancellingIdentifierHints = [
        "ANC", "NOISE_CANCEL", "TRANSPARENCY", "AMBIENT", "HEAR_THROUGH",
    ]
    static let noiseCancellingNameHints = [
        "anc", "noise cancel", "noise-cancel", "transparency", "ambient", "hear-through", "hear through",
    ]

    /// Whether this capability looks like ANC / transparency. `humanName` is the
    /// matching entry from `capabilities_str`, if available.
    public func isNoiseCancelling(humanName: String? = nil) -> Bool {
        if self == .noiseFilter { return false } // mic noise filter, not ANC
        let upper = rawValue.uppercased()
        let tokens = upper.split(separator: "_").map(String.init)
        for hint in Self.noiseCancellingIdentifierHints {
            if hint.contains("_") {
                if upper.contains(hint) { return true }
            } else if tokens.contains(where: { $0 == hint || $0.hasPrefix(hint) && hint.count > 3 }) {
                return true
            }
        }
        if let name = humanName?.lowercased() {
            let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            for hint in Self.noiseCancellingNameHints {
                if hint.contains(" ") || hint.contains("-") {
                    if name.contains(hint) { return true }
                } else if words.contains(hint) {
                    return true
                }
            }
        }
        return false
    }

    /// A readable fallback name derived from the identifier: `CAP_BT_CALL_VOLUME` -> "bt call volume".
    public var fallbackName: String {
        var name = rawValue
        if name.hasPrefix("CAP_") { name.removeFirst(4) }
        return name.lowercased().replacingOccurrences(of: "_", with: " ")
    }
}
