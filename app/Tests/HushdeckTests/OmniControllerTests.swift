import Foundation
import OmniKit
import Testing
@testable import Hushdeck

@Suite("Omni controller")
struct OmniControllerTests {
    @Test @MainActor func settersReachTheSimulatedHubAndShowImmediately() async throws {
        let sim = SimulatedOmniTransport()
        let omni = try await readyController(sim)
        sim.clearRecordedPackets()

        omni.set(.ancMode(.activeNoiseCancellation))
        // Optimistic overlay: the UI sees the new value before the hub confirms it.
        #expect(omni.settings.ancMode == .activeNoiseCancellation)
        try await waitUntil("write sent") { sim.sentOutputReports.count == 1 }
        #expect(sim.sentOutputReports.first?.prefix(3) == [0x01, 0xBD, 2])
        try await waitUntil("overlay cleared") { omni.overlay.isEmpty }
        #expect(omni.state.settings.ancMode == .activeNoiseCancellation)
        #expect(omni.remembered.ancMode == .activeNoiseCancellation)
        omni.stop()
    }

    @Test @MainActor func debouncedSlidersSendOneCommand() async throws {
        let sim = SimulatedOmniTransport()
        let omni = try await readyController(sim)
        sim.clearRecordedPackets()
        for level in 1...9 { omni.set(.micVolume(level), debounce: .milliseconds(80)) }
        #expect(omni.settings.micVolume == 9)
        try await Task.sleep(for: .milliseconds(400))
        #expect(sim.sentOutputReports.map { Array($0.prefix(3)) } == [[0x01, 0x37, 9]])
        omni.stop()
    }

    @Test @MainActor func rememberedSettingsAreRestoredWhenTheHubComesBack() async throws {
        let sim = SimulatedOmniTransport()
        let defaults = scratchDefaults()
        let omni = try await readyController(sim, defaults: defaults)
        omni.shouldReapplyOnConnect = { true }
        omni.set(.oledBrightness(3))
        try await waitUntil("write sent") { omni.overlay.isEmpty }

        // The hub loses power and forgets the brightness.
        sim.simulateHubDisconnect()
        try await waitUntil("searching") { !omni.isPresent }
        sim.updateHub { $0.oledBrightness = 10 }
        sim.clearRecordedPackets()
        sim.simulateHubReconnect()
        try await waitUntil("restored") { sim.hub.oledBrightness == 3 }
        #expect(sim.sentOutputReports.contains { Array($0.prefix(3)) == [0x01, 0x85, 3] })
        #expect(!sim.sentOutputReports.contains { $0[1] == OmniSafety.saveOpcode }, "restore doesn't save to flash")
        omni.stop()
    }

    @Test @MainActor func reapplyIsSkippedWhenTheDeviceAlreadyMatchesOrThePreferenceIsOff() async throws {
        let sim = SimulatedOmniTransport()
        let omni = try await readyController(sim)
        omni.shouldReapplyOnConnect = { false }
        omni.set(.oledBrightness(3))
        try await waitUntil("write sent") { omni.overlay.isEmpty }
        sim.simulateHubDisconnect()
        try await waitUntil("searching") { !omni.isPresent }
        sim.updateHub { $0.oledBrightness = 10 }
        sim.clearRecordedPackets()
        sim.simulateHubReconnect()
        try await waitUntil("refreshed") { omni.isReady && omni.state.lastRefresh != nil }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!sim.sentOutputReports.contains { $0[1] == 0x85 })
        #expect(sim.hub.oledBrightness == 10)
        omni.stop()
    }

    @Test @MainActor func eqEditsStayLocalUntilExperimentalWritesAreOn() async throws {
        let sim = SimulatedOmniTransport()
        let omni = try await readyController(sim)
        var messages: [(String, Bool)] = []
        omni.onMessage = { messages.append(($0, $1)) }

        omni.updateWirelessBand(3) { $0.gainTenths = 45; $0.frequency = 300 }
        #expect(omni.isDirty(.wireless))
        #expect(omni.wirelessEQ.bands[3].gainDB == 4.5)
        #expect(omni.wirelessEQ.preset == .custom)
        #expect(omni.state.equalizers.wireless?.bands[3].gainTenths == 0, "device copy untouched")

        sim.clearRecordedPackets()
        omni.apply(.wireless)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sim.sentPackets.isEmpty)
        #expect(messages.last?.1 == true)
        #expect(omni.isDirty(.wireless), "the draft survives")

        omni.revert(.wireless)
        #expect(!omni.isDirty(.wireless))
        omni.stop()
    }

    @Test @MainActor func eqUploadWorksWithTheFlagOn() async throws {
        let sim = SimulatedOmniTransport()
        let omni = try await readyController(sim, experimentalEQWrites: true)
        omni.updateGraphicGain(.mic, band: 0, gainTenths: -35)
        #expect(omni.micEQ.gainsTenths[0] == -35)
        omni.saveCustomPreset(.mic, name: "Quiet lows")
        #expect(omni.customPresets(for: .mic).count == 1)
        #expect(omni.micEQ.shortName == "QUIET ")
        sim.clearRecordedPackets()
        omni.apply(.mic)
        try await waitUntil("uploaded") { !omni.isDirty(.mic) && sim.sentPackets.contains { $0.kind == .setFeature } }
        #expect(sim.hub.micEQ.gainsTenths[0] == -35)
        #expect(sim.hub.micEQ.name == "Quiet lows")
        // The device copy now matches and the custom preset is selectable by name.
        #expect(omni.state.equalizers.mic?.name == "Quiet lows")
        omni.stop()
    }

    @Test @MainActor func factoryPresetSelectionLoadsHushdecksCurve() async throws {
        let omni = try await readyController()
        omni.selectWirelessPreset(.bassBoost)
        #expect(omni.wirelessEQ.preset == .bassBoost)
        #expect(omni.wirelessEQ.name == "Bass Boost")
        #expect(omni.wirelessEQ.bands[0].filter == .lowShelf)
        #expect(EQCurve.decibels(of: omni.wirelessEQ.bands, at: 30) > 4)
        omni.selectMicPreset(.walkieTalkie)
        #expect(omni.micEQ.gainsTenths == FactoryEQPresets.micGains(.walkieTalkie))
        omni.selectBluetoothPreset(.flat)
        #expect(omni.bluetoothEQ.gainsTenths == BluetoothEQ.flatGains)
        omni.stop()
    }

    @Test @MainActor func readIssuesAreGroupedBySection() async throws {
        let sim = SimulatedOmniTransport(configuration: .init(silentQueryOpcodes: [0x10, 0x1E]))
        let omni = OmniController(transport: sim, configuration: testOmniConfiguration(), defaults: scratchDefaults())
        omni.start()
        try await waitUntil("refresh") { omni.state.lastRefresh != nil }
        #expect(omni.issues.count == 2)
        #expect(omni.issues(in: .firmware).count == 1)
        #expect(omni.issues(in: .bluetoothEQ).count == 1)
        #expect(omni.issues(in: .audio).isEmpty)
        #expect(omni.issues(in: .firmware).first?.message.isEmpty == false)
        omni.stop()
    }

    @Test @MainActor func hubStatesAreExposedForTheUI() async throws {
        let sim = SimulatedOmniTransport(configuration: .init(startsAttached: false))
        let omni = OmniController(transport: sim, configuration: testOmniConfiguration(), defaults: scratchDefaults())
        #expect(!omni.isPresent)
        omni.start()
        try await waitUntil("searching") { omni.state.connection == .searching }
        #expect(!omni.isPresent && !omni.isReady)
        sim.simulateHubReconnect()
        try await waitUntil("ready") { omni.isReady }
        #expect(omni.isPresent && !omni.isSettling)
        #expect(omni.isSimulated)
        sim.simulateHubDisconnect()
        try await waitUntil("gone") { !omni.isPresent }
        #expect(omni.overlay.isEmpty && omni.wirelessDraft == nil)
        omni.stop()
    }
}
