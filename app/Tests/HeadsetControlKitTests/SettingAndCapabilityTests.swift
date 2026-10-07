import Foundation
import Testing
@testable import HeadsetControlKit

@Suite("Setter arguments")
struct SettingArgumentTests {
    @Test(arguments: [
        (HeadsetSetting.sidetone(50), "--sidetone=50"),
        (.sidetone(500), "--sidetone=128"),
        (.sidetone(-3), "--sidetone=0"),
        (.equalizerPreset(2), "--equalizer-preset=2"),
        (.equalizer([-2, 0, 1.5, 12, -0.25]), "--equalizer=-2,0,1.5,12,-0.25"),
        (.microphoneVolume(64), "--microphone-volume=64"),
        (.microphoneMuteLEDBrightness(9), "--microphone-mute-led-brightness=3"),
        (.inactiveTime(minutes: 120), "--inactive-time=90"),
        (.lights(true), "--light=1"),
        (.lights(false), "--light=0"),
        (.voicePrompts(false), "--voice-prompt=0"),
        (.rotateToMute(true), "--rotate-to-mute=1"),
        (.noiseFilter(.high), "--noise-filter=2"),
        (.volumeLimiter(true), "--volume-limiter=1"),
        (.bluetoothWhenPoweredOn(true), "--bt-when-powered-on=1"),
        (.bluetoothCallVolume(150), "--bt-call-volume=100"),
        (.notificationSound(1), "--notificate=1"),
        (.parametricEqualizer([.init(frequency: 100, gain: 3, q: 0.7), .init(frequency: 8000, gain: -2, q: 1, filterType: "highshelf")]),
         "--parametric-equalizer=100,3,0.7,peaking;8000,-2,1,highshelf"),
    ])
    func argument(setting: HeadsetSetting, expected: String) {
        #expect(setting.argument == expected)
    }

    @Test func presetAndCustomEqualizerShareADebounceKey() {
        #expect(HeadsetSetting.equalizer([0]).debounceKey == HeadsetSetting.equalizerPreset(1).debounceKey)
        #expect(HeadsetSetting.sidetone(1).debounceKey != HeadsetSetting.microphoneVolume(1).debounceKey)
    }

    @Test func noiseCancellingUsesDiscoveredFlag() {
        let control = NoiseCancellingControl(capability: Capability(rawValue: "CAP_NOISE_CANCELLING"), humanName: "noise cancelling")
        #expect(control.flag == "noise-cancelling")
        #expect(HeadsetSetting.noiseCancelling(.transparency, control).argument == "--noise-cancelling=1")
        #expect(HeadsetSetting.noiseCancelling(.off, control).capability.rawValue == "CAP_NOISE_CANCELLING")

        let anc = NoiseCancellingControl(capability: Capability(rawValue: "CAP_ANC"), humanName: "active noise cancellation")
        #expect(anc.flag == "anc")

        let guessed = NoiseCancellingControl(capability: Capability(rawValue: "CAP_ANC_MODE"), humanName: "anc mode")
        #expect(guessed.flag == "anc-mode")
    }
}

@Suite("Capabilities")
struct CapabilityTests {
    @Test(arguments: [
        ("CAP_ANC", nil as String?),
        ("CAP_ANC_MODE", nil),
        ("CAP_NOISE_CANCELLING", nil),
        ("CAP_NOISE_CANCELLATION", nil),
        ("CAP_ACTIVE_NOISE_CANCELLING", nil),
        ("CAP_TRANSPARENCY", nil),
        ("CAP_AMBIENT_MODE", nil),
        ("CAP_LISTENING_MODE", "noise cancelling"),
        ("CAP_AUDIO_MODE", "anc / transparency"),
    ])
    func detectsNoiseCancelling(raw: String, human: String?) {
        #expect(Capability(rawValue: raw).isNoiseCancelling(humanName: human))
    }

    @Test(arguments: [
        ("CAP_NOISE_FILTER", "microphone noise filter"),
        ("CAP_SIDETONE", "sidetone"),
        ("CAP_CHATMIX_STATUS", "chatmix"),
        ("CAP_BALANCE", "balance"),
        ("CAP_VOLUME_LIMITER", "volume limiter"),
        ("CAP_ENHANCED_MODE", "enhanced mode"),
    ])
    func ignoresOtherCapabilities(raw: String, human: String) {
        #expect(!Capability(rawValue: raw).isNoiseCancelling(humanName: human))
    }

    @Test func unknownCapabilityRoundTrips() throws {
        let data = Data(#"["CAP_SIDETONE","CAP_FROM_THE_FUTURE"]"#.utf8)
        let caps = try JSONDecoder().decode([Capability].self, from: data)
        #expect(caps == [.sidetone, Capability(rawValue: "CAP_FROM_THE_FUTURE")])
        #expect(caps[0].isKnown)
        #expect(!caps[1].isKnown)
        #expect(caps[1].fallbackName == "from the future")
        let encoded = try JSONEncoder().encode(caps)
        #expect(String(decoding: encoded, as: UTF8.self) == #"["CAP_SIDETONE","CAP_FROM_THE_FUTURE"]"#)
    }

    @Test func deviceIDParsing() {
        #expect(DeviceID(vendor: "0x1038", product: "0x12e0") == DeviceID(vendorID: 0x1038, productID: 0x12E0))
        #expect(DeviceID(vendor: "1038", product: "12E0")?.filterArgument == "1038:12e0")
        #expect(DeviceID(vendor: "nope", product: "0x1") == nil)
    }
}
