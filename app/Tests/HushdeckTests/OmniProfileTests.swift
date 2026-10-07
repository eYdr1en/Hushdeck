import Foundation
import OmniKit
import Testing
@testable import Hushdeck

@Suite("Omni profiles")
struct OmniProfileTests {
    static func sampleState() -> OmniState {
        var state = OmniState()
        state.connection = .connected(OmniHubInfo(isSimulated: true))
        state.settings.sidetone = Sidetone(isEnabled: true, level: 7)
        state.settings.ancMode = .activeNoiseCancellation
        state.settings.ancLevel = .medium
        state.settings.autoOff = .tenMinutes
        state.settings.streamMix = StreamMix(main: 80, aux: 60, mic: 40)
        var bands = ParametricBand.flat
        bands[2] = ParametricBand(frequency: 130, filter: .lowShelf, gainDB: 3.5, q: 0.8)
        state.equalizers.wireless = WirelessEQ(preset: .custom, shortName: "WARM", name: "Warm", bands: bands)
        state.equalizers.bluetooth = BluetoothEQ(preset: .bassBoost, shortName: "BASS", name: "Bass Boost", gainsTenths: [60, 40, 20, 0, 0, 0, 0, 0, 0, 0])
        state.equalizers.mic = MicEQ(preset: .flat, shortName: "FLAT", name: "Flat", gainsTenths: MicEQ.flatGains)
        return state
    }

    @Test func snapshotCapturesSettingsAndEqualizers() {
        let state = Self.sampleState()
        let profile = OmniProfile(name: "Gaming", snapshotOf: state)
        #expect(profile.settings == state.settings)
        #expect(profile.wirelessEQ == state.equalizers.wireless)
        #expect(profile.bluetoothEQ == state.equalizers.bluetooth)
        #expect(profile.micEQ == state.equalizers.mic)
        #expect(profile.settingsToApply.count == 5)
        #expect(profile.includesEqualizers)
        #expect(profile.matches(state, includingEqualizers: true))
        var changed = state
        changed.settings.ancLevel = .low
        #expect(!changed.settings.asSettings.contains(.ancLevel(.medium)))
        #expect(!profile.matches(changed, includingEqualizers: false))
    }

    @Test func exportImportRoundTrip() throws {
        let profile = OmniProfile(name: "Streaming", snapshotOf: Self.sampleState())
        let data = try profile.exported()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"format\" : \"hushdeck-omni-profile\""))
        #expect(text.contains("\"version\" : 1"))

        let imported = try OmniProfile.imported(from: data)
        #expect(imported.id != profile.id, "imports never collide with the original")
        #expect(imported.name == profile.name)
        #expect(imported.settings == profile.settings)
        #expect(imported.wirelessEQ == profile.wirelessEQ)
        #expect(imported.bluetoothEQ == profile.bluetoothEQ)
        #expect(imported.micEQ == profile.micEQ)
        #expect(abs(imported.created.timeIntervalSince(profile.created)) < 1)

        // Exporting the import again yields the same document apart from the ID.
        var again = imported
        again.id = profile.id
        #expect(try again.exported() == data)
    }

    @Test func importRejectsForeignJSON() {
        let junk = Data("{\"format\":\"something-else\",\"version\":1,\"profile\":{}}".utf8)
        #expect(throws: (any Error).self) { try OmniProfile.imported(from: junk) }
        #expect(throws: (any Error).self) { try OmniProfile.imported(from: Data("nope".utf8)) }
    }

    @Test func storeRoundTrips() {
        let store = OmniProfileStore(defaults: scratchDefaults())
        #expect(store.load().isEmpty)
        let a = OmniProfile(name: "A", snapshotOf: Self.sampleState())
        let b = OmniProfile(name: "B", snapshotOf: OmniState())
        store.save([a, b])
        let loaded = store.load()
        #expect(loaded.map(\.id) == [a.id, b.id])
        #expect(loaded.map(\.settings) == [a.settings, b.settings])
        #expect(loaded[0].wirelessEQ == a.wirelessEQ)
        // ISO-8601 keeps whole seconds.
        #expect(abs(loaded[0].created.timeIntervalSince(a.created)) < 1)
        store.removeAll()
        #expect(store.load().isEmpty)
    }

    @Test @MainActor func saveDuplicateRenameDeleteKeepNamesUnique() async throws {
        let omni = try await readyController()
        let first = try #require(omni.saveProfile(named: "Desk"))
        #expect(omni.activeProfileID == first.id)
        let second = try #require(omni.saveProfile(named: "Desk"))
        #expect(second.name == "Desk 2")
        let copy = omni.duplicate(first)
        #expect(copy.name == "Desk copy")
        #expect(omni.profiles.map(\.name) == ["Desk", "Desk copy", "Desk 2"])
        omni.rename(copy, to: "Couch")
        #expect(omni.profiles[1].name == "Couch")
        omni.delete(first)
        #expect(omni.activeProfileID == second.id, "the last saved profile stays active")
        omni.delete(second)
        #expect(omni.activeProfileID == nil)
        #expect(omni.profiles.map(\.name) == ["Couch"])
        // Persisted.
        #expect(omni.profileStore.load().map(\.name) == ["Couch"])
        omni.stop()
    }

    @Test @MainActor func applyingAProfileDeploysEverySettingThenSaves() async throws {
        let sim = SimulatedOmniTransport()
        let omni = try await readyController(sim)
        var profile = OmniProfile(name: "Night", snapshotOf: omni.state)
        profile.settings.ancMode = .transparency
        profile.settings.transparencyLevel = 3
        profile.settings.oledBrightness = 2
        profile.settings.autoOff = .never
        _ = try omni.importProfile(from: profile.exported())
        let stored = try #require(omni.profiles.first)

        sim.clearRecordedPackets()
        var messages: [(String, Bool)] = []
        omni.onMessage = { messages.append(($0, $1)) }
        omni.apply(stored)
        try await waitUntil("profile applied") { omni.activeProfileID == stored.id }

        let hub = sim.hub
        #expect(hub.ancMode == ANCMode.transparency.rawValue)
        #expect(hub.transparencyLevel == 3)
        #expect(hub.oledBrightness == 2)
        #expect(hub.autoOffCode == OmniTimeout.never.rawValue)
        #expect(hub.saveCount == 1, "save-to-flash after the settings, like GG")
        #expect(sim.sentPackets.last?.opcode == OmniSafety.saveOpcode)
        #expect(sim.sentPackets.allSatisfy { $0.kind != .setFeature }, "EQ writes stay off by default")
        #expect(messages.contains { !$0.1 && $0.0.contains("Night") })
        // The applied settings are remembered for re-apply on reconnect.
        #expect(omni.remembered.ancMode == .transparency)
        // A manual change clears the active profile.
        omni.set(.oledBrightness(5))
        #expect(omni.activeProfileID == nil)
        omni.stop()
    }

    @Test @MainActor func applyingAProfileWithEQWritesOnUploadsTheEqualizers() async throws {
        let sim = SimulatedOmniTransport()
        let omni = try await readyController(sim, experimentalEQWrites: true)
        var profile = OmniProfile(name: "Bassy", snapshotOf: omni.state)
        var bands = ParametricBand.flat
        bands[0] = ParametricBand(frequency: 40, filter: .lowShelf, gainDB: 5, q: 0.7)
        profile.wirelessEQ = WirelessEQ(preset: .custom, shortName: "BASSY", name: "Bassy", bands: bands)
        profile.micEQ = MicEQ(preset: .deepVoice, shortName: "DEEP", name: "Deep Voice", gainsTenths: FactoryEQPresets.micGains(.deepVoice)!)
        _ = try omni.importProfile(from: profile.exported())
        sim.clearRecordedPackets()
        omni.apply(try #require(omni.profiles.first))
        try await waitUntil("profile applied") { omni.activeProfileID != nil }
        let writes = sim.sentPackets.filter { $0.kind == .setFeature }.map(\.opcode)
        #expect(writes == [0x1B, 0x1F, 0x1D])
        #expect(sim.hub.wirelessEQ.bands[0].frequency == 40)
        #expect(sim.hub.micEQ.presetIndex == MicEQPreset.deepVoice.rawValue)
        omni.stop()
    }
}
