import Foundation
import OmniKit

// App-side names for OmniKit's typed values. OmniKit stays free of localisation; the app maps
// its enums to catalog strings here, mirroring Localized.swift for HeadsetControlKit.

extension WirelessEQPreset {
    /// The factory names as GG lists them (and as the hub stores them, in English).
    var displayName: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .focus: "Focus"
        case .smiley: "Smiley"
        case .custom: "Custom"
        case .other: "Game"
        }
    }

    var shortName: String {
        switch self {
        case .flat: "FLAT"
        case .bassBoost: "BASS"
        case .focus: "FOCUS"
        case .smiley: "SMILEY"
        case .custom: "CUSTOM"
        case .other: "GAME"
        }
    }

    var localizedName: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .bassBoost: String(localized: "Bass Boost")
        case .focus: String(localized: "Focus")
        case .smiley: String(localized: "Smiley")
        case .custom: String(localized: "Custom")
        case .other: String(localized: "Game preset", comment: "The 2.4 GHz EQ slot GG uses for game and library presets")
        }
    }

    /// The slots a user can pick; `.other` is filled by GG's library and only shown when active.
    static let selectable: [WirelessEQPreset] = [.flat, .bassBoost, .focus, .smiley, .custom]
}

extension BluetoothEQPreset {
    var displayName: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .focus: "Focus"
        case .smiley: "Smiley"
        case .custom: "Custom"
        }
    }

    var shortName: String {
        switch self {
        case .flat: "FLAT"
        case .bassBoost: "BASS"
        case .focus: "FOCUS"
        case .smiley: "SMILEY"
        case .custom: "CUSTOM"
        }
    }

    var localizedName: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .bassBoost: String(localized: "Bass Boost")
        case .focus: String(localized: "Focus")
        case .smiley: String(localized: "Smiley")
        case .custom: String(localized: "Custom")
        }
    }
}

extension MicEQPreset {
    var displayName: String {
        switch self {
        case .flat: "Flat"
        case .balanced: "Balanced"
        case .broadcastHighPitch: "Broadcast High Pitch"
        case .broadcastLowPitch: "Broadcast Low Pitch"
        case .clarityLowPitch: "Clarity Low Pitch"
        case .clarityHighPitch: "Clarity High Pitch"
        case .deepVoice: "Deep Voice"
        case .lessNasal: "Less Nasal"
        case .custom: "Custom"
        case .walkieTalkie: "Walkie Talkie"
        }
    }

    var shortName: String {
        switch self {
        case .flat: "FLAT"
        case .balanced: "BALANC"
        case .broadcastHighPitch: "BCASTH"
        case .broadcastLowPitch: "BCASTL"
        case .clarityLowPitch: "CLARL"
        case .clarityHighPitch: "CLARH"
        case .deepVoice: "DEEP"
        case .lessNasal: "NASAL"
        case .custom: "CUSTOM"
        case .walkieTalkie: "WALKIE"
        }
    }

    var localizedName: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .balanced: String(localized: "Balanced")
        case .broadcastHighPitch: String(localized: "Broadcast High Pitch")
        case .broadcastLowPitch: String(localized: "Broadcast Low Pitch")
        case .clarityLowPitch: String(localized: "Clarity Low Pitch")
        case .clarityHighPitch: String(localized: "Clarity High Pitch")
        case .deepVoice: String(localized: "Deep Voice")
        case .lessNasal: String(localized: "Less Nasal")
        case .custom: String(localized: "Custom")
        case .walkieTalkie: String(localized: "Walkie Talkie")
        }
    }

    /// GG's order: the factory voices first, Custom last.
    static let displayOrder: [MicEQPreset] = [.flat, .balanced, .broadcastHighPitch, .broadcastLowPitch, .clarityLowPitch,
                                              .clarityHighPitch, .deepVoice, .lessNasal, .walkieTalkie, .custom]
}

extension EQFilterType {
    var localizedName: String {
        switch self {
        case .peaking: String(localized: "Peaking")
        case .lowPass: String(localized: "Low-pass")
        case .highPass: String(localized: "High-pass")
        case .lowShelf: String(localized: "Low shelf")
        case .highShelf: String(localized: "High shelf")
        case .notch: String(localized: "Notch")
        }
    }

    /// Gain has no effect on pass and notch filters (GG greys it out).
    var usesGain: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf: true
        case .lowPass, .highPass, .notch: false
        }
    }
}

extension ANCMode {
    var localizedName: String {
        switch self {
        case .off: String(localized: "Off")
        case .transparency: String(localized: "Transparency")
        case .activeNoiseCancellation: String(localized: "Noise cancelling", comment: "ANC mode")
        }
    }
}

extension ANCLevel {
    var localizedName: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        }
    }
}

extension MicNoiseReduction {
    var localizedName: String {
        switch self {
        case .off: String(localized: "Off")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        }
    }
}

extension OutputMode {
    var localizedName: String {
        switch self {
        case .speakers: String(localized: "Speakers")
        case .streaming: String(localized: "Streaming")
        }
    }
}

extension OmniTimeout {
    /// "Never" / "Off" wording depends on the setting; see the call sites.
    var localizedMinutes: String {
        String(localized: "\(minutes) min", comment: "Auto-off delay in minutes")
    }
}

extension ScreensaverMode {
    var localizedName: String {
        switch self {
        case .screenOff: String(localized: "Screen off")
        case .dim: String(localized: "Dim")
        }
    }
}

extension HomeScreenView {
    var localizedName: String {
        switch self {
        case .detailed: String(localized: "Detailed")
        case .simple: String(localized: "Simple")
        }
    }
}

extension HomeScreenOption {
    var localizedName: String {
        switch self {
        case .stereo: String(localized: "Stereo")
        case .preset: String(localized: "EQ preset", comment: "OLED home screen shows the EQ preset name")
        case .meters: String(localized: "Meters")
        }
    }
}

extension BluetoothCallBehaviour {
    var localizedName: String {
        switch self {
        case .doNothing: String(localized: "Do nothing")
        case .lowerOtherAudio: String(localized: "Lower game volume by 12 dB")
        case .muteOtherAudio: String(localized: "Mute game volume")
        }
    }
}

extension ChargingState {
    var localizedName: String {
        switch self {
        case .unknown: String(localized: "Not connected")
        case .charging: String(localized: "Charging")
        case .pluggedInNotCharging: String(localized: "Plugged in, charged")
        case .discharging: String(localized: "On battery")
        }
    }
}

extension HeadsetLinkState {
    var localizedName: String {
        switch self {
        case .unpaired: String(localized: "Not paired")
        case .pairing: String(localized: "Pairing…")
        case .disconnected: String(localized: "Off or out of range")
        case .connected: String(localized: "Connected")
        }
    }
}

extension BluetoothMode {
    var localizedName: String {
        switch self {
        case .off: String(localized: "Off")
        case .pairing: String(localized: "Pairing…")
        case .linkMode: String(localized: "On")
        }
    }
}

extension BluetoothLinkStatus {
    var localizedName: String {
        switch self {
        case .ready: String(localized: "Ready", comment: "Bluetooth link status")
        case .lost: String(localized: "Link lost")
        case .busy: String(localized: "In a call", comment: "Bluetooth link status: busy")
        case .error: String(localized: "Error")
        }
    }
}

extension WirelessMode {
    var localizedName: String {
        switch self {
        case .speed: String(localized: "Speed", comment: "2.4 GHz wireless mode")
        case .range: String(localized: "Range", comment: "2.4 GHz wireless mode")
        }
    }
}

extension ColourVariant {
    var localizedName: String {
        switch self {
        case .black: String(localized: "Black")
        case .white: String(localized: "White")
        case .midnightBlue: String(localized: "Midnight Blue")
        case .amazonEdition: String(localized: "Amazon edition")
        }
    }
}

extension OmniConfidence {
    /// One line for the tooltip of an "Unverified" marker.
    var localizedExplanation: String {
        switch self {
        case .hardwareConfirmed:
            String(localized: "Confirmed on real hardware.")
        case .documented:
            String(localized: "Not tested on real hardware yet. The command and its values are documented, but no real hub has confirmed them.")
        case .inferred:
            String(localized: "Not tested on real hardware yet, and the byte layout is partly inferred: the value shown may be off until a USB capture confirms it.")
        }
    }
}

extension OmniFeature {
    var localizedName: String {
        switch self {
        case .headsetBattery: String(localized: "Headset battery")
        case .spareBattery: String(localized: "Spare battery")
        case .chargingState: String(localized: "Charging state")
        case .headsetLink: String(localized: "Headset link")
        case .bluetoothStatus: String(localized: "Bluetooth")
        case .micMute: String(localized: "Mic mute")
        case .chatMixDial: String(localized: "Chat mix")
        case .audioInput: String(localized: "Audio source")
        case .firmwareVersions: String(localized: "Firmware")
        case .serialNumber: String(localized: "Serial number")
        case .colourVariant: String(localized: "Colour")
        case .hubVolume: String(localized: "Hub volume")
        case .wirelessMode: String(localized: "Wireless mode")
        case .hubEvents: String(localized: "Live updates")
        case .wirelessEQ: String(localized: "2.4 GHz equalizer")
        case .bluetoothEQ: String(localized: "Bluetooth equalizer")
        case .outputMode: String(localized: "Output")
        case .streamMix: String(localized: "Stream mix")
        case .ancMode: String(localized: "Noise control")
        case .ancLevel: String(localized: "Noise cancelling level")
        case .transparencyLevel: String(localized: "Transparency level")
        case .volumeLimiter: String(localized: "Volume limiter")
        case .micEQ: String(localized: "Microphone equalizer")
        case .micVolume: String(localized: "Mic level")
        case .sidetone: String(localized: "Sidetone")
        case .mutedMicLEDBrightness: String(localized: "Mute light")
        case .micNoiseReduction: String(localized: "Noise reduction")
        case .autoOff: String(localized: "Turn off after")
        case .oledBrightness: String(localized: "Screen brightness")
        case .homeScreenView: String(localized: "Home screen")
        case .homeScreenOption: String(localized: "Home screen shows")
        case .screensaverTimeout: String(localized: "Screen saver after")
        case .screensaverMode: String(localized: "Screen saver")
        case .bluetoothCallBehaviour: String(localized: "Bluetooth calls")
        case .bluetoothPowerOnDefault: String(localized: "Bluetooth at power on")
        case .eqPresetNames: String(localized: "Preset names")
        case .saveToDevice: String(localized: "Save to device")
        }
    }

    /// Tooltip for the "Unverified" marker: why, plus where the value lives on the wire.
    var unverifiedExplanation: String {
        "\(confidence.localizedExplanation) \(String(localized: "Wire: \(wireReference).", comment: "Tooltip suffix naming the USB command"))"
    }

    var isVerified: Bool { confidence == .hardwareConfirmed }
}
