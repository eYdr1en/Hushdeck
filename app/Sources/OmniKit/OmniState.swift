import Foundation

/// Identity of a matched GameHub, from the HID layer.
public struct OmniHubInfo: Codable, Sendable, Hashable {
    public var vendorID: Int
    public var productID: Int
    public var productName: String?
    /// USB serial string (not the `01 12` unique ID).
    public var usbSerialNumber: String?
    /// bcdDevice, e.g. 0x0132 for MCU 1.32.
    public var releaseNumber: Int?
    public var locationID: Int?
    public var isSimulated: Bool

    public init(vendorID: Int = OmniUSB.vendorID, productID: Int = OmniUSB.gameHubProductID, productName: String? = nil,
                usbSerialNumber: String? = nil, releaseNumber: Int? = nil, locationID: Int? = nil, isSimulated: Bool = false) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.usbSerialNumber = usbSerialNumber
        self.releaseNumber = releaseNumber
        self.locationID = locationID
        self.isSimulated = isSimulated
    }
}

/// USB-level connection to the GameHub. The headset's own link is `OmniReadouts.headsetLink`.
public enum OmniConnectionState: Codable, Sendable, Hashable {
    /// `OmniDevice.start()` hasn't been called, or `stop()` was.
    case stopped
    /// Watching for the hub; none attached.
    case searching
    /// The hub enumerated; waiting the 5 s GG waits before talking to it.
    case settling(OmniHubInfo)
    /// Ready: reads and writes are allowed.
    case connected(OmniHubInfo)

    public var isReady: Bool {
        if case .connected = self { return true }
        return false
    }

    public var hub: OmniHubInfo? {
        switch self {
        case .settling(let info), .connected(let info): info
        case .stopped, .searching: nil
        }
    }
}

/// Read-only values (GG's device card and live status). `nil` = not read yet.
public struct OmniReadouts: Codable, Sendable, Hashable {
    /// Headset battery %, as reported. Only meaningful while `headsetLink == .connected`
    /// (GG ignores it otherwise); see `trustedHeadsetBattery`.
    public var headsetBattery: Int?
    /// Spare battery in the hub's charging slot (status byte 7, "charger battery").
    public var spareBattery: Int?
    public var charging: ChargingState?
    public var headsetLink: HeadsetLinkState?
    public var bluetoothMode: BluetoothMode?
    public var bluetoothLink: BluetoothLinkStatus?
    public var micMuted: Bool?
    public var wirelessMode: WirelessMode?
    /// 0–38, read-only.
    public var hubVolume: Int?
    public var audioInput: Int?
    public var chatMix: ChatMix?
    public var surround: Bool?

    public init() {}

    public var isHeadsetOnline: Bool { headsetLink == .connected }
    /// Battery % only when GG would trust it (2.4 GHz link connected).
    public var trustedHeadsetBattery: Int? { isHeadsetOnline ? headsetBattery : nil }
    /// GG's low-battery rule: 0 < battery ≤ 5 %.
    public var isBatteryLow: Bool {
        guard let battery = trustedHeadsetBattery else { return false }
        return battery > 0 && battery <= 5
    }
}

/// Every writable setting. `nil` = not read yet.
public struct OmniSettings: Codable, Sendable, Hashable {
    public var sidetone: Sidetone?
    public var micVolume: Int?
    public var micNoiseReduction: MicNoiseReduction?
    public var mutedMicLEDBrightness: Int?
    public var ancMode: ANCMode?
    public var ancLevel: ANCLevel?
    public var transparencyLevel: Int?
    public var autoOff: OmniTimeout?
    public var volumeLimiter: Bool?
    public var outputMode: OutputMode?
    public var streamMix: StreamMix?
    public var oledBrightness: Int?
    public var screensaverTimeout: OmniTimeout?
    public var screensaverMode: ScreensaverMode?
    public var homeScreenView: HomeScreenView?
    public var homeScreenOption: HomeScreenOption?
    public var bluetoothPowerOnDefault: Bool?
    public var bluetoothCallBehaviour: BluetoothCallBehaviour?

    public init() {}

    public mutating func apply(_ setting: OmniSetting) {
        switch setting {
        case .sidetone(let v): sidetone = v
        case .micVolume(let v): micVolume = v
        case .micNoiseReduction(let v): micNoiseReduction = v
        case .mutedMicLEDBrightness(let v): mutedMicLEDBrightness = v
        case .ancMode(let v): ancMode = v
        case .ancLevel(let v): ancLevel = v
        case .transparencyLevel(let v): transparencyLevel = v
        case .autoOff(let v): autoOff = v
        case .volumeLimiter(let v): volumeLimiter = v
        case .outputMode(let v): outputMode = v
        case .streamMix(let v): streamMix = v
        case .oledBrightness(let v): oledBrightness = v
        case .screensaverTimeout(let v): screensaverTimeout = v
        case .screensaverMode(let v): screensaverMode = v
        case .homeScreenView(let v): homeScreenView = v
        case .homeScreenOption(let v): homeScreenOption = v
        case .bluetoothPowerOnDefault(let v): bluetoothPowerOnDefault = v
        case .bluetoothCallBehaviour(let v): bluetoothCallBehaviour = v
        }
    }

    /// The known settings as a list of writes, e.g. to save a profile and re-apply it later.
    public var asSettings: [OmniSetting] {
        var out: [OmniSetting] = []
        if let v = sidetone { out.append(.sidetone(v)) }
        if let v = micVolume { out.append(.micVolume(v)) }
        if let v = micNoiseReduction { out.append(.micNoiseReduction(v)) }
        if let v = mutedMicLEDBrightness { out.append(.mutedMicLEDBrightness(v)) }
        if let v = ancMode { out.append(.ancMode(v)) }
        if let v = ancLevel { out.append(.ancLevel(v)) }
        if let v = transparencyLevel { out.append(.transparencyLevel(v)) }
        if let v = autoOff { out.append(.autoOff(v)) }
        if let v = volumeLimiter { out.append(.volumeLimiter(v)) }
        if let v = outputMode { out.append(.outputMode(v)) }
        if let v = streamMix { out.append(.streamMix(v)) }
        if let v = oledBrightness { out.append(.oledBrightness(v)) }
        if let v = screensaverTimeout { out.append(.screensaverTimeout(v)) }
        if let v = screensaverMode { out.append(.screensaverMode(v)) }
        if let v = homeScreenView { out.append(.homeScreenView(v)) }
        if let v = homeScreenOption { out.append(.homeScreenOption(v)) }
        if let v = bluetoothPowerOnDefault { out.append(.bluetoothPowerOnDefault(v)) }
        if let v = bluetoothCallBehaviour { out.append(.bluetoothCallBehaviour(v)) }
        return out
    }
}

/// The three EQs and the hub's stored preset names.
public struct OmniEqualizers: Codable, Sendable, Hashable {
    /// From `01 1A` (preferred) or the audio-settings "active" bands.
    public var wireless: WirelessEQ?
    /// The stored 2.4 GHz Custom bands (audio settings bytes 2–61).
    public var wirelessCustomBands: [ParametricBand]?
    public var bluetooth: BluetoothEQ?
    public var mic: MicEQ?
    public var presetNames: [OmniPresetName] = []

    public init() {}

    public func presetName(_ slot: OmniPresetNameSlot) -> OmniPresetName? {
        presetNames.first { $0.slot == slot }
    }

    mutating func store(_ name: OmniPresetName) {
        presetNames.removeAll { $0.slot == name.slot }
        presetNames.append(name)
        presetNames.sort { $0.slot.rawValue < $1.slot.rawValue }
    }
}

/// Identity and versions.
public struct OmniDeviceInfo: Codable, Sendable, Hashable {
    public var firmware: OmniFirmwareVersions?
    /// Unique ID from `01 12`.
    public var serialNumber: String?
    public var colour: ColourVariant?

    public init() {}
}

/// Everything OmniKit knows about the hub and headset. Published by `OmniDevice.updates()`.
public struct OmniState: Codable, Sendable, Hashable {
    public var connection: OmniConnectionState = .stopped
    public var readouts = OmniReadouts()
    public var settings = OmniSettings()
    public var equalizers = OmniEqualizers()
    public var info = OmniDeviceInfo()
    /// Experimental EQ writes are allowed (mirrors the device configuration).
    public var experimentalEQWrites = false
    public var lastRefresh: Date?
    public var lastEvent: Date?
    /// Non-fatal problems from the most recent refresh (a section that couldn't be read).
    public var issues: [String] = []

    public init() {}

    public mutating func apply(_ status: OmniStatus) {
        readouts.bluetoothMode = status.bluetoothMode
        readouts.bluetoothLink = status.bluetoothLink
        readouts.headsetBattery = status.headsetBattery
        readouts.spareBattery = status.spareBattery
        readouts.micMuted = status.micMuted
        readouts.wirelessMode = status.wirelessMode
        readouts.headsetLink = status.headsetLink
        readouts.charging = status.charging
        settings.bluetoothPowerOnDefault = status.bluetoothPowerOnDefault
        settings.bluetoothCallBehaviour = status.bluetoothCallBehaviour ?? settings.bluetoothCallBehaviour
        settings.transparencyLevel = status.transparencyLevel
        settings.ancMode = status.ancMode ?? settings.ancMode
        settings.mutedMicLEDBrightness = status.mutedMicLEDBrightness
        settings.autoOff = status.autoOff ?? settings.autoOff
        settings.ancLevel = status.ancLevel ?? settings.ancLevel
    }

    public mutating func apply(_ display: OmniDisplaySettings) {
        settings.screensaverTimeout = display.screensaverTimeout ?? settings.screensaverTimeout
        settings.oledBrightness = display.brightness
        settings.homeScreenView = display.homeScreenView ?? settings.homeScreenView
        settings.screensaverMode = display.screensaverMode ?? settings.screensaverMode
        settings.homeScreenOption = display.homeScreenOption ?? settings.homeScreenOption
        info.colour = display.colour
    }

    public mutating func apply(_ audio: OmniAudioSettings) {
        readouts.audioInput = audio.audioInput
        readouts.hubVolume = audio.hubVolume
        readouts.surround = audio.surround
        readouts.chatMix = audio.chatMix
        settings.volumeLimiter = audio.volumeLimiter
        settings.micVolume = audio.micVolume
        settings.sidetone = audio.sidetone
        settings.outputMode = audio.outputMode ?? settings.outputMode
        settings.streamMix = audio.streamMix
        settings.micNoiseReduction = audio.micNoiseReduction ?? settings.micNoiseReduction
        equalizers.wirelessCustomBands = audio.customWirelessBands
        // The dedicated EQ reads carry names too; only fill gaps from here.
        if equalizers.wireless == nil {
            equalizers.wireless = WirelessEQ(preset: .flat, shortName: "", name: "", bands: audio.activeWirelessBands)
            equalizers.wireless?.presetIndex = audio.wirelessPresetIndex
        }
        if equalizers.bluetooth == nil {
            equalizers.bluetooth = BluetoothEQ(preset: .flat, shortName: "", name: "", gainsTenths: audio.bluetoothGainsTenths)
            equalizers.bluetooth?.presetIndex = audio.bluetoothPresetIndex
        }
        if equalizers.mic == nil {
            equalizers.mic = MicEQ(preset: .flat, shortName: "", name: "", gainsTenths: audio.micGainsTenths)
            equalizers.mic?.presetIndex = audio.micPresetIndex
        }
    }

    /// Applies a hub event. Returns `true` if the state changed.
    @discardableResult
    public mutating func apply(_ event: OmniEvent) -> Bool {
        let before = self
        switch event {
        case .connection(let btMode, let btLink, let link):
            readouts.bluetoothMode = btMode ?? readouts.bluetoothMode
            readouts.bluetoothLink = btLink ?? readouts.bluetoothLink
            readouts.headsetLink = link ?? readouts.headsetLink
        case .battery(let headset, let spare, let charging):
            readouts.headsetBattery = headset
            readouts.spareBattery = spare
            readouts.charging = charging ?? readouts.charging
        case .micMute(let muted):
            readouts.micMuted = muted
        case .chatMix(let mix):
            readouts.chatMix = mix
        case .audioInput(let input):
            readouts.audioInput = input
        case .hubVolume(let volume):
            readouts.hubVolume = volume
        case .settingChanged(let setting):
            settings.apply(setting)
        case .equalizerChanged:
            break // OmniDevice re-reads the EQ.
        }
        return self != before
    }
}
