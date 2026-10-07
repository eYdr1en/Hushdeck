import Foundation
import HeadsetControlKit

// App-side translations for text that originates in HeadsetControlKit. The kit keeps
// plain English (it's also used from tests and scripts); the app maps its values to
// catalog strings here so HeadsetControlKit needs no localisation of its own.

extension BinaryLocation.Source {
    var localizedName: String {
        switch self {
        case .userOverride: String(localized: "Custom path")
        case .bundled: String(localized: "Bundled with Hushdeck")
        case .homebrew: String(localized: "Homebrew")
        case .usrLocal: "/usr/local"
        case .developmentBuild: String(localized: "Development build")
        }
    }
}

extension Capability {
    /// Name used in error messages. Known capabilities reuse the control labels.
    var localizedName: String {
        switch self {
        case .sidetone, .sidetoneStatus: String(localized: "Sidetone")
        case .lights: String(localized: "Lights")
        case .inactiveTime: String(localized: "Turn off after")
        case .voicePrompts: String(localized: "Voice prompts")
        case .rotateToMute: String(localized: "Mute when mic is raised")
        case .equalizerPreset, .equalizer, .parametricEqualizer: String(localized: "Equalizer")
        case .microphoneMuteLEDBrightness: String(localized: "Mute light")
        case .microphoneVolume: String(localized: "Mic level")
        case .volumeLimiter: String(localized: "Volume limiter")
        case .bluetoothWhenPoweredOn: String(localized: "Bluetooth at power on")
        case .bluetoothCallVolume: String(localized: "Bluetooth call volume")
        case .noiseFilter: String(localized: "Noise filter")
        case .notificationSound: String(localized: "Notification sound")
        case .chatmixStatus: String(localized: "Chat mix")
        case .batteryStatus: String(localized: "Battery")
        default: fallbackName.prefix(1).uppercased() + fallbackName.dropFirst()
        }
    }
}

enum ErrorText {
    /// A user-facing, localised message for errors from HeadsetControlKit.
    /// Text that comes from the CLI itself (stderr, per-action errors) is passed through.
    static func message(for error: any Error) -> String {
        guard let error = error as? HeadsetControlError else { return error.localizedDescription }
        switch error {
        case .binaryNotFound:
            return String(localized: "HeadsetControl isn’t installed.")
        case .launchFailed(let reason):
            return String(localized: "Couldn’t start HeadsetControl: \(reason)")
        case .timedOut(let seconds):
            return String(localized: "HeadsetControl didn’t respond within \(Int(seconds)) s.")
        case .commandFailed(_, let message):
            return message.isEmpty ? String(localized: "HeadsetControl reported an error.") : message
        case .invalidOutput:
            return String(localized: "HeadsetControl returned output Hushdeck can’t read.")
        case .noDevice:
            return String(localized: "No supported headset is connected.")
        case .actionsFailed(let failures):
            return failures.map { failure in
                let reason = failure.errorMessage ?? String(localized: "the headset rejected the change")
                return String(localized: "\(failure.capability.localizedName): \(reason).")
            }.joined(separator: " ")
        }
    }
}

/// "42%" in English, "42 %" in German.
func percentString(_ value: Int) -> String {
    value.formatted(.percent)
}
