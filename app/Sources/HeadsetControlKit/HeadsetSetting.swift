import Foundation

/// Noise cancelling mode. HeadsetControl has no ANC capability yet; the value mapping
/// (0 = off, 1 = ANC, 2 = transparency) mirrors `--noise-filter <0|1|2>` and is
/// provisional until the Omni support lands.
public enum NoiseCancellingMode: Int, Codable, Sendable, CaseIterable, Identifiable {
    // Matches the Omni's own encoding (`01 BD <v>`, protocol-notes.md §3.4).
    case off = 0
    case transparency = 1
    case noiseCancelling = 2

    public var id: Int { rawValue }
}

/// Microphone noise filter levels for `--noise-filter`.
public enum NoiseFilterLevel: Int, Codable, Sendable, CaseIterable, Identifiable {
    case off = 0, low = 1, high = 2
    public var id: Int { rawValue }
}

/// How to drive a device's ANC capability from the CLI.
public struct NoiseCancellingControl: Sendable, Hashable, Codable {
    public var capability: Capability
    /// Long flag without dashes, e.g. `"noise-cancelling"`.
    public var flag: String

    public init(capability: Capability, flag: String) {
        self.capability = capability
        self.flag = flag
    }

    /// Best guess at the CLI flag, following HeadsetControl's convention that a
    /// capability's long flag is its `capabilities_str` name in kebab case
    /// (`"microphone noise filter"` is the exception, which is why known names are listed first).
    public init(capability: Capability, humanName: String?) {
        let known: [String: String] = [
            "CAP_ANC": "anc",
            "CAP_NOISE_CANCELLING": "noise-cancelling",
            "CAP_NOISE_CANCELLATION": "noise-cancellation",
            "CAP_ACTIVE_NOISE_CANCELLING": "active-noise-cancelling",
            "CAP_TRANSPARENCY": "transparency",
        ]
        let flag: String
        if let mapped = known[capability.rawValue] {
            flag = mapped
        } else if let humanName, !humanName.isEmpty {
            flag = humanName.lowercased().split(separator: " ").joined(separator: "-")
        } else {
            flag = capability.fallbackName.split(separator: " ").joined(separator: "-")
        }
        self.init(capability: capability, flag: flag)
    }
}

/// A single setter the CLI understands. Values are clamped to the ranges declared in
/// HeadsetControl's `capability_descriptors.hpp`, and every flag is emitted in the
/// `--long=value` form so negative numbers and optional-argument flags parse safely.
public enum HeadsetSetting: Sendable, Hashable {
    case sidetone(Int)
    case equalizerPreset(Int)
    case equalizer([Double])
    case parametricEqualizer([ParametricBand])
    case microphoneVolume(Int)
    case microphoneMuteLEDBrightness(Int)
    case inactiveTime(minutes: Int)
    case lights(Bool)
    case voicePrompts(Bool)
    case rotateToMute(Bool)
    case noiseFilter(NoiseFilterLevel)
    case volumeLimiter(Bool)
    case bluetoothWhenPoweredOn(Bool)
    case bluetoothCallVolume(Int)
    case notificationSound(Int)
    case noiseCancelling(NoiseCancellingMode, NoiseCancellingControl)

    public var capability: Capability {
        switch self {
        case .sidetone: .sidetone
        case .equalizerPreset: .equalizerPreset
        case .equalizer: .equalizer
        case .parametricEqualizer: .parametricEqualizer
        case .microphoneVolume: .microphoneVolume
        case .microphoneMuteLEDBrightness: .microphoneMuteLEDBrightness
        case .inactiveTime: .inactiveTime
        case .lights: .lights
        case .voicePrompts: .voicePrompts
        case .rotateToMute: .rotateToMute
        case .noiseFilter: .noiseFilter
        case .volumeLimiter: .volumeLimiter
        case .bluetoothWhenPoweredOn: .bluetoothWhenPoweredOn
        case .bluetoothCallVolume: .bluetoothCallVolume
        case .notificationSound: .notificationSound
        case .noiseCancelling(_, let control): control.capability
        }
    }

    /// Stable key for debouncing and bookkeeping. Preset and custom EQ share a key
    /// because they overwrite the same device state.
    public var debounceKey: String {
        switch self {
        case .equalizer, .equalizerPreset: "equalizer"
        default: capability.rawValue
        }
    }

    public var argument: String {
        switch self {
        case .sidetone(let v): "--sidetone=\(v.clamped(0, 128))"
        case .equalizerPreset(let v): "--equalizer-preset=\(v.clamped(0, 255))"
        case .equalizer(let bands): "--equalizer=\(bands.map(Self.format).joined(separator: ","))"
        case .parametricEqualizer(let bands): "--parametric-equalizer=\(bands.map(\.argument).joined(separator: ";"))"
        case .microphoneVolume(let v): "--microphone-volume=\(v.clamped(0, 128))"
        case .microphoneMuteLEDBrightness(let v): "--microphone-mute-led-brightness=\(v.clamped(0, 3))"
        case .inactiveTime(let v): "--inactive-time=\(v.clamped(0, 90))"
        case .lights(let on): "--light=\(on ? 1 : 0)"
        case .voicePrompts(let on): "--voice-prompt=\(on ? 1 : 0)"
        case .rotateToMute(let on): "--rotate-to-mute=\(on ? 1 : 0)"
        case .noiseFilter(let level): "--noise-filter=\(level.rawValue)"
        case .volumeLimiter(let on): "--volume-limiter=\(on ? 1 : 0)"
        case .bluetoothWhenPoweredOn(let on): "--bt-when-powered-on=\(on ? 1 : 0)"
        case .bluetoothCallVolume(let v): "--bt-call-volume=\(v.clamped(0, 100))"
        case .notificationSound(let v): "--notificate=\(v.clamped(0, 1))"
        case .noiseCancelling(let mode, let control): "--\(control.flag)=\(mode.rawValue)"
        }
    }

    /// `1.5`, `-2`, `0` — never `2.0` or scientific notation.
    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

public struct ParametricBand: Sendable, Hashable, Codable {
    public var frequency: Double
    public var gain: Double
    public var q: Double
    public var filterType: String

    public init(frequency: Double, gain: Double, q: Double, filterType: String = "peaking") {
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.filterType = filterType
    }

    var argument: String {
        [HeadsetSetting.format(frequency), HeadsetSetting.format(gain), HeadsetSetting.format(q), filterType]
            .joined(separator: ",")
    }
}

extension Int {
    func clamped(_ lower: Int, _ upper: Int) -> Int { Swift.min(Swift.max(self, lower), upper) }
}
