import Foundation
import OmniKit

/// A named snapshot of every Omni setting, like a GG "configuration". Applying one deploys the
/// settings through `OmniDevice.apply(_:saveToDevice:)`; the three EQs are included in the
/// snapshot and are written only when experimental EQ writes are on.
struct OmniProfile: Codable, Sendable, Hashable, Identifiable {
    static let formatVersion = 1

    var id: UUID
    var name: String
    var created: Date
    var modified: Date
    var settings: OmniSettings
    var wirelessEQ: WirelessEQ?
    var bluetoothEQ: BluetoothEQ?
    var micEQ: MicEQ?

    init(id: UUID = UUID(), name: String, created: Date = Date(), modified: Date? = nil, settings: OmniSettings,
         wirelessEQ: WirelessEQ? = nil, bluetoothEQ: BluetoothEQ? = nil, micEQ: MicEQ? = nil) {
        self.id = id
        self.name = name
        self.created = created
        self.modified = modified ?? created
        self.settings = settings
        self.wirelessEQ = wirelessEQ
        self.bluetoothEQ = bluetoothEQ
        self.micEQ = micEQ
    }

    /// Snapshot of what the device currently reports.
    init(name: String, snapshotOf state: OmniState, now: Date = Date()) {
        self.init(name: name, created: now, settings: state.settings, wirelessEQ: state.equalizers.wireless,
                  bluetoothEQ: state.equalizers.bluetooth, micEQ: state.equalizers.mic)
    }

    /// The writes that deploy this profile, in the order GG sends them.
    var settingsToApply: [OmniSetting] { settings.asSettings }

    var includesEqualizers: Bool { wirelessEQ != nil || bluetoothEQ != nil || micEQ != nil }

    /// `true` when the device already reports every value in this profile.
    func matches(_ state: OmniState, includingEqualizers: Bool) -> Bool {
        for setting in settingsToApply where !state.settings.asSettings.contains(setting) { return false }
        guard includingEqualizers else { return true }
        if let wirelessEQ, wirelessEQ != state.equalizers.wireless { return false }
        if let bluetoothEQ, bluetoothEQ != state.equalizers.bluetooth { return false }
        if let micEQ, micEQ != state.equalizers.mic { return false }
        return true
    }

    func duplicated(name: String, now: Date = Date()) -> OmniProfile {
        var copy = self
        copy.id = UUID()
        copy.name = name
        copy.created = now
        copy.modified = now
        return copy
    }

    // MARK: JSON export / import

    /// The on-disk document: versioned so a later Hushdeck can still read today's files.
    struct Document: Codable, Sendable, Equatable {
        var format = "hushdeck-omni-profile"
        var version = OmniProfile.formatVersion
        var profile: OmniProfile
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func exported() throws -> Data {
        try Self.encoder().encode(Document(profile: self))
    }

    /// Reads an exported document. The imported profile gets a fresh ID so it never collides
    /// with one already in the library.
    static func imported(from data: Data) throws -> OmniProfile {
        let document = try decoder().decode(Document.self, from: data)
        guard document.format == "hushdeck-omni-profile" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var profile = document.profile
        profile.id = UUID()
        return profile
    }

    static let fileExtension = "hushdeckprofile"
}

/// Persists profiles as JSON in UserDefaults.
final class OmniProfileStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "omniProfiles.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [OmniProfile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? OmniProfile.decoder().decode([OmniProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [OmniProfile]) {
        if let data = try? OmniProfile.encoder().encode(profiles) { defaults.set(data, forKey: key) }
    }

    func removeAll() {
        defaults.removeObject(forKey: key)
    }
}
