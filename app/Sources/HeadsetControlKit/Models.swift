import Foundation

// Codable models for `headsetcontrol -o json` (api_version 1.5).
// Every field that is not guaranteed by the serializer is optional, and unknown
// enum strings decode to an `.other(String)` case, so a newer CLI never breaks us.

/// Top-level document printed by `headsetcontrol -o json`.
public struct HeadsetControlOutput: Decodable, Sendable, Equatable {
    public var name: String?
    public var version: String?
    public var apiVersion: String?
    public var hidapiVersion: String?
    public var deviceCount: Int
    public var devices: [DeviceInfo]
    /// Results of setter flags. Present only when an action was requested.
    public var actions: [ActionResult]

    enum CodingKeys: String, CodingKey {
        case name, version, devices, actions
        case apiVersion = "api_version"
        case hidapiVersion = "hidapi_version"
        case deviceCount = "device_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion)
        hidapiVersion = try c.decodeIfPresent(String.self, forKey: .hidapiVersion)
        devices = try c.decodeIfPresent([DeviceInfo].self, forKey: .devices) ?? []
        deviceCount = try c.decodeIfPresent(Int.self, forKey: .deviceCount) ?? devices.count
        actions = try c.decodeIfPresent([ActionResult].self, forKey: .actions) ?? []
    }

    /// Decodes CLI output. Use this instead of `JSONDecoder` directly: JSON objects are
    /// unordered for `JSONDecoder`, but the order of `equalizer_presets` is the preset
    /// index that `--equalizer-preset N` expects, so it is recovered from the raw text.
    public static func decode(from data: Data) throws -> HeadsetControlOutput {
        var output = try JSONDecoder().decode(HeadsetControlOutput.self, from: data)
        if let orders = try? OrderedJSON.presetKeyOrder(in: data) {
            for index in output.devices.indices where index < orders.count {
                output.devices[index].reorderPresets(by: orders[index])
            }
        }
        return output
    }
}

/// `"success" | "failure" | "partial"`.
public enum ResultStatus: Sendable, Hashable, Decodable {
    case success, failure, partial
    case other(String)

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "success": self = .success
        case "failure": self = .failure
        case "partial": self = .partial
        default: self = .other(raw)
        }
    }
}

/// USB vendor/product pair; also what `-d VID:PID` takes.
public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var vendorID: UInt16
    public var productID: UInt16

    public init(vendorID: UInt16, productID: UInt16) {
        self.vendorID = vendorID
        self.productID = productID
    }

    /// Parses the CLI's `"0xf00b"` style ids.
    public init?(vendor: String, product: String) {
        guard let v = Self.parseHex(vendor), let p = Self.parseHex(product) else { return nil }
        self.init(vendorID: v, productID: p)
    }

    static func parseHex(_ string: String) -> UInt16? {
        var s = string.lowercased().trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") { s.removeFirst(2) }
        return UInt16(s, radix: 16)
    }

    /// Value for `--device`, e.g. `f00b:a00c`.
    public var filterArgument: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    public var description: String { filterArgument }

    public static let testDevice = DeviceID(vendorID: 0xF00B, productID: 0xA00C)
    public var isTestDevice: Bool { vendorID == Self.testDevice.vendorID }
}

public struct DeviceInfo: Decodable, Sendable, Equatable, Identifiable {
    public var status: ResultStatus
    public var name: String
    public var vendor: String?
    public var product: String?
    public var vendorIDString: String?
    public var productIDString: String?
    public var capabilities: [Capability]
    /// Parallel to `capabilities`: the human-readable names (`capabilities_str`).
    public var capabilityNames: [String]
    public var battery: BatteryInfo?
    public var equalizer: EqualizerInfo?
    public var equalizerPresetsCount: Int?
    /// Presets in device index order (see `HeadsetControlOutput.decode(from:)`).
    public var equalizerPresets: [EqualizerPreset]
    public var parametricEqualizer: ParametricEqualizerInfo?
    /// 0...128; 64 is balanced, lower favours game, higher favours chat.
    public var chatmix: Int?
    public var sidetone: SidetoneInfo?
    /// Per-feature read errors, keyed by capability name (`"battery"`, `"chatmix"`...).
    public var errors: [String: String]

    enum CodingKeys: String, CodingKey {
        case status, device, vendor, product, capabilities, battery, equalizer, chatmix, sidetone, errors
        case vendorIDString = "id_vendor"
        case productIDString = "id_product"
        case capabilityNames = "capabilities_str"
        case equalizerPresetsCount = "equalizer_presets_count"
        case equalizerPresets = "equalizer_presets"
        case parametricEqualizer = "parametric_equalizer"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(ResultStatus.self, forKey: .status) ?? .success
        name = try c.decodeIfPresent(String.self, forKey: .device) ?? "Headset"
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        product = try c.decodeIfPresent(String.self, forKey: .product)
        vendorIDString = try c.decodeIfPresent(String.self, forKey: .vendorIDString)
        productIDString = try c.decodeIfPresent(String.self, forKey: .productIDString)
        capabilities = try c.decodeIfPresent([Capability].self, forKey: .capabilities) ?? []
        capabilityNames = try c.decodeIfPresent([String].self, forKey: .capabilityNames) ?? []
        battery = try c.decodeIfPresent(BatteryInfo.self, forKey: .battery)
        equalizer = try c.decodeIfPresent(EqualizerInfo.self, forKey: .equalizer)
        equalizerPresetsCount = try c.decodeIfPresent(Int.self, forKey: .equalizerPresetsCount)
        let presetMap = try c.decodeIfPresent([String: [Double]].self, forKey: .equalizerPresets) ?? [:]
        // Alphabetical until reordered from the raw JSON.
        equalizerPresets = presetMap.keys.sorted().map { EqualizerPreset(name: $0, bands: presetMap[$0] ?? []) }
        parametricEqualizer = try c.decodeIfPresent(ParametricEqualizerInfo.self, forKey: .parametricEqualizer)
        chatmix = try c.decodeIfPresent(Int.self, forKey: .chatmix)
        sidetone = try c.decodeIfPresent(SidetoneInfo.self, forKey: .sidetone)
        errors = try c.decodeIfPresent([String: String].self, forKey: .errors) ?? [:]
    }

    mutating func reorderPresets(by order: [String]) {
        let byName = Dictionary(equalizerPresets.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = order.compactMap { byName[$0] }
        if ordered.count == equalizerPresets.count { equalizerPresets = ordered }
    }

    public var deviceID: DeviceID? {
        guard let v = vendorIDString, let p = productIDString else { return nil }
        return DeviceID(vendor: v, product: p)
    }

    /// Stable identity used for remembering settings.
    public var id: String { deviceID?.filterArgument ?? name }

    public var isTestDevice: Bool { deviceID?.isTestDevice ?? false }

    public func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }

    /// Human-readable capability name from `capabilities_str`, falling back to the identifier.
    public func displayName(for capability: Capability) -> String {
        if let index = capabilities.firstIndex(of: capability), index < capabilityNames.count {
            return capabilityNames[index]
        }
        return capability.fallbackName
    }

    /// The ANC / transparency capability, if this device reports one under any name.
    public var noiseCancellingCapability: Capability? {
        for (index, capability) in capabilities.enumerated() {
            let human = index < capabilityNames.count ? capabilityNames[index] : nil
            if capability.isNoiseCancelling(humanName: human) { return capability }
        }
        return nil
    }

    /// Capabilities this app has no dedicated UI for (shown as a read-only list).
    public var unrecognisedCapabilities: [Capability] {
        let anc = noiseCancellingCapability
        return capabilities.filter { !$0.isKnown && $0 != anc }
    }

    /// Preset names in index order. Falls back to "Preset N" when the device only reports a count.
    public var presetNames: [String] {
        if !equalizerPresets.isEmpty { return equalizerPresets.map(\.name) }
        guard let count = equalizerPresetsCount, count > 0 else { return [] }
        return (1...count).map { "Preset \($0)" }
    }
}

public struct BatteryInfo: Decodable, Sendable, Equatable {
    public enum Status: Sendable, Hashable, Decodable {
        case available, charging, unavailable, error, timeout
        case other(String)

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "BATTERY_AVAILABLE": self = .available
            case "BATTERY_CHARGING": self = .charging
            case "BATTERY_UNAVAILABLE": self = .unavailable
            case "BATTERY_ERROR", "BATTERY_HIDERROR": self = .error
            case "BATTERY_TIMEOUT": self = .timeout
            default: self = .other(raw)
            }
        }
    }

    public var status: Status
    /// Percent, or -1 when unknown.
    public var level: Int
    public var voltageMillivolts: Int?
    public var minutesToFull: Int?
    public var minutesToEmpty: Int?

    enum CodingKeys: String, CodingKey {
        case status, level
        case voltageMillivolts = "voltage_mv"
        case minutesToFull = "time_to_full_min"
        case minutesToEmpty = "time_to_empty_min"
    }

    public init(status: Status, level: Int, voltageMillivolts: Int? = nil, minutesToFull: Int? = nil, minutesToEmpty: Int? = nil) {
        self.status = status
        self.level = level
        self.voltageMillivolts = voltageMillivolts
        self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .other("missing")
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? -1
        voltageMillivolts = try c.decodeIfPresent(Int.self, forKey: .voltageMillivolts)
        minutesToFull = try c.decodeIfPresent(Int.self, forKey: .minutesToFull)
        minutesToEmpty = try c.decodeIfPresent(Int.self, forKey: .minutesToEmpty)
    }

    /// Level in 0...100, or nil when the headset did not report one.
    public var percent: Int? { (0...100).contains(level) ? level : nil }
    public var isCharging: Bool { status == .charging }
}

public struct EqualizerInfo: Decodable, Sendable, Equatable {
    public var bands: Int
    public var baseline: Double
    public var step: Double
    public var min: Double
    public var max: Double

    public init(bands: Int, baseline: Double, step: Double, min: Double, max: Double) {
        self.bands = bands
        self.baseline = baseline
        self.step = step
        self.min = min
        self.max = max
    }
}

public struct EqualizerPreset: Sendable, Equatable, Hashable {
    public var name: String
    public var bands: [Double]

    public init(name: String, bands: [Double]) {
        self.name = name
        self.bands = bands
    }
}

public struct ParametricEqualizerInfo: Decodable, Sendable, Equatable {
    public struct Gain: Decodable, Sendable, Equatable {
        public var step: Double
        public var min: Double
        public var max: Double
        public var base: Double
    }

    public struct QFactor: Decodable, Sendable, Equatable {
        public var min: Double
        public var max: Double
    }

    public struct Frequency: Decodable, Sendable, Equatable {
        public var min: Int
        public var max: Int
    }

    public var bands: Int
    public var gain: Gain?
    public var qFactor: QFactor?
    public var frequency: Frequency?
    public var filterTypes: [String]

    enum CodingKeys: String, CodingKey {
        case bands, gain, frequency
        case qFactor = "q_factor"
        case filterTypes = "filter_types"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bands = try c.decodeIfPresent(Int.self, forKey: .bands) ?? 0
        gain = try c.decodeIfPresent(Gain.self, forKey: .gain)
        qFactor = try c.decodeIfPresent(QFactor.self, forKey: .qFactor)
        frequency = try c.decodeIfPresent(Frequency.self, forKey: .frequency)
        filterTypes = try c.decodeIfPresent([String].self, forKey: .filterTypes) ?? []
    }
}

public struct SidetoneInfo: Decodable, Sendable, Equatable {
    /// 0...128 on HeadsetControl's normalised scale.
    public var level: Int
    /// The device's native step, if it has discrete levels.
    public var deviceLevel: Int?
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case level, name
        case deviceLevel = "device_level"
    }
}

/// One entry of the top-level `actions` array printed after setter flags.
public struct ActionResult: Decodable, Sendable, Equatable {
    public var capability: Capability
    public var device: String?
    public var status: ResultStatus
    /// Omitted by the CLI when the value is 0.
    public var value: Int?
    public var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case capability, device, status, value
        case errorMessage = "error_message"
    }

    public init(capability: Capability, device: String? = nil, status: ResultStatus, value: Int? = nil, errorMessage: String? = nil) {
        self.capability = capability
        self.device = device
        self.status = status
        self.value = value
        self.errorMessage = errorMessage
    }

    public var succeeded: Bool { status == .success }
}
