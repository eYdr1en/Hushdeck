import Foundation

/// The last value the user successfully applied for each setting on one device.
///
/// This doubles as the source of truth for write-only settings: HeadsetControl can
/// set lights, auto-off, mic volume etc. but cannot read them back, so the app shows
/// what it last applied. It is also what gets re-applied when the headset reconnects,
/// since the dock may lose settings across power loss.
public struct RememberedSettings: Codable, Sendable, Equatable {
    public enum Equalizer: Codable, Sendable, Equatable {
        case preset(Int)
        case custom([Double])
    }

    public var sidetone: Int?
    public var equalizer: Equalizer?
    public var microphoneVolume: Int?
    public var microphoneMuteLEDBrightness: Int?
    public var inactiveTime: Int?
    public var lights: Bool?
    public var voicePrompts: Bool?
    public var rotateToMute: Bool?
    public var noiseFilter: NoiseFilterLevel?
    public var volumeLimiter: Bool?
    public var bluetoothWhenPoweredOn: Bool?
    public var bluetoothCallVolume: Int?
    public var noiseCancelling: NoiseCancellingMode?

    public init() {}

    public var isEmpty: Bool { self == RememberedSettings() }

    public mutating func record(_ setting: HeadsetSetting) {
        switch setting {
        case .sidetone(let v): sidetone = v
        case .equalizerPreset(let v): equalizer = .preset(v)
        case .equalizer(let bands): equalizer = .custom(bands)
        case .parametricEqualizer: break // no UI yet; not persisted
        case .microphoneVolume(let v): microphoneVolume = v
        case .microphoneMuteLEDBrightness(let v): microphoneMuteLEDBrightness = v
        case .inactiveTime(let v): inactiveTime = v
        case .lights(let v): lights = v
        case .voicePrompts(let v): voicePrompts = v
        case .rotateToMute(let v): rotateToMute = v
        case .noiseFilter(let v): noiseFilter = v
        case .volumeLimiter(let v): volumeLimiter = v
        case .bluetoothWhenPoweredOn(let v): bluetoothWhenPoweredOn = v
        case .bluetoothCallVolume(let v): bluetoothCallVolume = v
        case .notificationSound: break // momentary, not a setting
        case .noiseCancelling(let mode, _): noiseCancelling = mode
        }
    }

    /// Setters that restore these settings, limited to what `device` supports.
    public func settingsToReapply(on device: DeviceInfo) -> [HeadsetSetting] {
        var result: [HeadsetSetting] = []
        func add(_ capability: Capability, _ setting: HeadsetSetting?) {
            if let setting, device.supports(capability) { result.append(setting) }
        }
        add(.sidetone, sidetone.map(HeadsetSetting.sidetone))
        switch equalizer {
        case .preset(let index)?: add(.equalizerPreset, .equalizerPreset(index))
        case .custom(let bands)?: add(.equalizer, .equalizer(bands))
        case nil: break
        }
        add(.microphoneVolume, microphoneVolume.map(HeadsetSetting.microphoneVolume))
        add(.microphoneMuteLEDBrightness, microphoneMuteLEDBrightness.map(HeadsetSetting.microphoneMuteLEDBrightness))
        add(.inactiveTime, inactiveTime.map { HeadsetSetting.inactiveTime(minutes: $0) })
        add(.lights, lights.map(HeadsetSetting.lights))
        add(.voicePrompts, voicePrompts.map(HeadsetSetting.voicePrompts))
        add(.rotateToMute, rotateToMute.map(HeadsetSetting.rotateToMute))
        add(.noiseFilter, noiseFilter.map(HeadsetSetting.noiseFilter))
        add(.volumeLimiter, volumeLimiter.map(HeadsetSetting.volumeLimiter))
        add(.bluetoothWhenPoweredOn, bluetoothWhenPoweredOn.map(HeadsetSetting.bluetoothWhenPoweredOn))
        add(.bluetoothCallVolume, bluetoothCallVolume.map(HeadsetSetting.bluetoothCallVolume))
        if let mode = noiseCancelling, let capability = device.noiseCancellingCapability {
            let control = NoiseCancellingControl(capability: capability, humanName: device.displayName(for: capability))
            result.append(.noiseCancelling(mode, control))
        }
        return result
    }
}

/// Persists `RememberedSettings` per device (keyed by `VID:PID`) as JSON in UserDefaults.
public final class RememberedSettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "rememberedSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    private var all: [String: RememberedSettings] {
        get {
            guard let data = defaults.data(forKey: key) else { return [:] }
            return (try? JSONDecoder().decode([String: RememberedSettings].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
        }
    }

    public func settings(for deviceKey: String) -> RememberedSettings {
        all[deviceKey] ?? RememberedSettings()
    }

    public func save(_ settings: RememberedSettings, for deviceKey: String) {
        var current = all
        current[deviceKey] = settings
        all = current
    }

    public func forget(_ deviceKey: String) {
        var current = all
        current[deviceKey] = nil
        all = current
    }
}
