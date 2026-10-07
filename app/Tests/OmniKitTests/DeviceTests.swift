import Foundation
import Testing
@testable import OmniKit

@Suite("OmniDevice against the simulated hub")
struct DeviceTests {
    @Test func startupReadsEverythingGGReads() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        let state = await device.state

        // Query order mirrors GG's startup sequence (protocol-notes §2).
        let queries = sim.sentOutputReports.map { Array($0.prefix(3)) }
        #expect(queries == [[0x01, 0xB0, 0], [0x01, 0x18, 0], [0x01, 0x18, 2], [0x01, 0x18, 1], [0x01, 0x18, 3], [0x01, 0x20, 0],
                            [0x01, 0x1A, 0], [0x01, 0x1E, 0], [0x01, 0x1C, 0], [0x01, 0x80, 0], [0x01, 0x10, 0], [0x01, 0x12, 0]])
        #expect(sim.sentPackets.filter { $0.kind == .getFeature }.count == 8)
        #expect(sim.sentPackets.allSatisfy { $0.kind != .setFeature })
        #expect(state.issues.isEmpty)

        let hub = sim.hub
        #expect(state.readouts.headsetBattery == Int(hub.headsetBattery))
        #expect(state.readouts.spareBattery == 100)
        #expect(state.readouts.charging == .discharging)
        #expect(state.readouts.headsetLink == .connected)
        #expect(state.readouts.bluetoothMode == .off)
        #expect(state.readouts.micMuted == false)
        #expect(state.readouts.hubVolume == 24)
        #expect(state.readouts.chatMix == ChatMix(game: 100, chat: 100))
        #expect(state.settings.sidetone == Sidetone(isEnabled: true, level: 5))
        #expect(state.settings.micVolume == 8)
        #expect(state.settings.ancMode == .off)
        #expect(state.settings.ancLevel == .high)
        #expect(state.settings.transparencyLevel == 8)
        #expect(state.settings.autoOff == .thirtyMinutes)
        #expect(state.settings.screensaverTimeout == .tenMinutes)
        #expect(state.settings.streamMix == StreamMix(main: 100, aux: 100, mic: 100))
        #expect(state.settings.micNoiseReduction == .off)
        #expect(state.settings.asSettings.count == 18, "every setting is known after a refresh")
        #expect(state.equalizers.wireless == hub.wirelessEQ)
        #expect(state.equalizers.bluetooth == hub.bluetoothEQ)
        #expect(state.equalizers.mic == hub.micEQ)
        #expect(state.equalizers.presetNames.count == 4)
        #expect(state.info.firmware?.hubMCU1 == "1.32.0")
        #expect(state.info.serialNumber == "SIMOMNI000000000042")
        #expect(state.info.colour == .black)
        #expect(state.connection.hub?.isSimulated == true)
        await device.stop()
    }

    /// Every setter: typed call → exact bytes on the wire → simulated hub state → read back.
    @Test func everySetterRoundTrips() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.clearRecordedPackets()

        typealias Step = (call: @Sendable (OmniDevice) async throws -> Void, expected: OmniSetting, bytes: [UInt8])
        let steps: [Step] = [
            ({ try await $0.setSidetone(Sidetone(isEnabled: true, level: 9)) }, .sidetone(Sidetone(isEnabled: true, level: 9)), [0x38, 1, 9]),
            ({ try await $0.setSidetoneEnabled(false) }, .sidetone(Sidetone(isEnabled: false, level: 9)), [0x38, 0, 9]),
            ({ try await $0.setMicVolume(3) }, .micVolume(3), [0x37, 3]),
            ({ try await $0.setMicNoiseReduction(.medium) }, .micNoiseReduction(.medium), [0x3C, 1, 2]),
            ({ try await $0.setMutedMicLEDBrightness(0) }, .mutedMicLEDBrightness(0), [0xBF, 0]),
            ({ try await $0.setANCMode(.activeNoiseCancellation) }, .ancMode(.activeNoiseCancellation), [0xBD, 2]),
            ({ try await $0.setANCLevel(.low) }, .ancLevel(.low), [0xB8, 1]),
            ({ try await $0.setTransparencyLevel(2) }, .transparencyLevel(2), [0xB9, 2]),
            ({ try await $0.setAutoOff(.never) }, .autoOff(.never), [0xC1, 0]),
            ({ try await $0.setVolumeLimiter(false) }, .volumeLimiter(false), [0x27, 0]),
            ({ try await $0.setOutputMode(.streaming) }, .outputMode(.streaming), [0x43, 2]),
            ({ try await $0.setStreamMix(StreamMix(main: 75, aux: 50, mic: 25)) }, .streamMix(StreamMix(main: 75, aux: 50, mic: 25)), [0x47, 75, 75, 50, 25]),
            ({ try await $0.setOLEDBrightness(4) }, .oledBrightness(4), [0x85, 4]),
            ({ try await $0.setScreensaverTimeout(.sixtyMinutes) }, .screensaverTimeout(.sixtyMinutes), [0x83, 6]),
            ({ try await $0.setScreensaverMode(.screenOff) }, .screensaverMode(.screenOff), [0x88, 0]),
            ({ try await $0.setHomeScreenView(.simple) }, .homeScreenView(.simple), [0x89, 1]),
            ({ try await $0.setHomeScreenOption(.meters) }, .homeScreenOption(.meters), [0x8A, 2]),
            ({ try await $0.setBluetoothPowerOnDefault(true) }, .bluetoothPowerOnDefault(true), [0xB2, 1]),
            ({ try await $0.setBluetoothCallBehaviour(.muteOtherAudio) }, .bluetoothCallBehaviour(.muteOtherAudio), [0xB3, 2]),
        ]

        for step in steps {
            try await step.call(device)
            let sent = try #require(sim.sentOutputReports.last)
            #expect(sent == report([0x01] + step.bytes), "\(step.expected)")
            // Optimistic local update.
            let local = await device.state.settings
            #expect(local.asSettings.contains(step.expected), "\(step.expected)")
        }
        #expect(sim.sentOutputReports.count == steps.count)

        // Read everything back from the hub and check the decoded values.
        let state = try await device.refresh()
        let final: [OmniSetting] = [
            .sidetone(Sidetone(isEnabled: false, level: 9)), .micVolume(3), .micNoiseReduction(.medium), .mutedMicLEDBrightness(0),
            .ancMode(.activeNoiseCancellation), .ancLevel(.low), .transparencyLevel(2), .autoOff(.never), .volumeLimiter(false),
            .outputMode(.streaming), .streamMix(StreamMix(main: 75, aux: 50, mic: 25)), .oledBrightness(4),
            .screensaverTimeout(.sixtyMinutes), .screensaverMode(.screenOff), .homeScreenView(.simple), .homeScreenOption(.meters),
            .bluetoothPowerOnDefault(true), .bluetoothCallBehaviour(.muteOtherAudio),
        ]
        #expect(Set(state.settings.asSettings) == Set(final))
        let hub = sim.hub
        #expect(hub.streamMain == 75 && hub.streamAux == 50 && hub.streamMic == 25)
        #expect(hub.sidetoneOn == 0 && hub.sidetoneLevel == 9)
        await device.stop()
    }

    @Test func profileDeployThenSave() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.clearRecordedPackets()
        try await device.apply([.ancMode(.transparency), .transparencyLevel(10), .oledBrightness(3)], saveToDevice: true)
        #expect(sim.sentPackets.map(\.opcode) == [0xBD, 0xB9, 0x85, 0x09])
        let packets = sim.sentPackets
        #expect(packets[2].at.duration(to: packets[3].at) >= .milliseconds(60), "save waits after the last write")
        let hub = sim.hub
        #expect(hub.saveCount == 1)
        #expect(hub.lastSavedSnapshot?.statusReport[10] == ANCMode.transparency.rawValue)
        #expect(hub.lastSavedSnapshot?.displayReport[3] == 3)
        await device.stop()
    }

    @Test func experimentalEQWritesRoundTrip() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim, configuration: testConfiguration(experimentalEQWrites: true))
        #expect(await device.state.experimentalEQWrites)
        sim.clearRecordedPackets()

        var bands = ParametricBand.flat
        bands[0] = ParametricBand(frequency: 45, filter: .lowShelf, gainDB: 4.5, q: 0.707)
        bands[9] = ParametricBand(frequency: ParametricBand.disabledFrequency, filter: .peaking, gainTenths: 0, qThousandths: 1000)
        let wireless = WirelessEQ(preset: .custom, shortName: "BASSY", name: "Bassy but clean", bands: bands)
        try await device.setWirelessEQ(wireless)
        let mic = MicEQ(preset: .custom, shortName: "VOX", name: "Voice", gainsTenths: [-30, -20, -10, 0, 10, 20, 30, 40, 50, 60])
        try await device.setMicEQ(mic)
        let bt = BluetoothEQ(preset: .bassBoost, shortName: "BB", name: "Bass Boost", gainsTenths: [60, 40, 20, 0, 0, 0, 0, 0, 0, 0])
        try await device.setBluetoothEQ(bt)

        let writes = sim.sentPackets.filter { $0.kind == .setFeature }
        #expect(writes.map(\.opcode) == [0x1B, 0x1D, 0x1F])
        #expect(writes.allSatisfy { $0.bytes.count == 1036 })
        // 2.4G layout: 01 1B idx short[6] name[61] bands[60] then zeros.
        let w = writes[0].bytes
        #expect(Array(w[0...2]) == [0x01, 0x1B, 0x04])
        #expect(Array(w[3..<9]) == Array("BASSY".utf8) + [0])
        #expect(Array(w[70..<76]) == [0x2D, 0x00, 0x04, 0x2D, 0xC3, 0x02])
        #expect(w[130...].allSatisfy { $0 == 0 })
        // Mic layout: gains at 70..<80 as int8 tenths.
        #expect(Array(writes[1].bytes[70..<80]) == [0xE2, 0xEC, 0xF6, 0x00, 0x0A, 0x14, 0x1E, 0x28, 0x32, 0x3C])

        let state = try await device.refresh()
        #expect(state.equalizers.wireless == wireless)
        #expect(state.equalizers.mic == mic)
        #expect(state.equalizers.bluetooth == bt)
        #expect(state.equalizers.presetName(.wirelessCustom)?.shortName == "BASSY")
        #expect(state.equalizers.wirelessCustomBands == bands)

        // Turning the flag off at runtime stops further writes.
        await device.setExperimentalEQWrites(false)
        await #expect(throws: OmniError.experimentalEQWritesDisabled) { try await device.setMicEQ(mic) }
        await device.stop()
    }

    @Test func batteryDrainAndHotSwapEvents() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        let start = Int(sim.hub.headsetBattery)
        let events = await device.events()
        sim.simulateBatteryDrain(by: 3)
        try await waitForState(device, "drain") { $0.readouts.headsetBattery == start - 3 }
        sim.simulateBattery(headset: 4, spare: 96, charging: .discharging)
        var state = try await waitForState(device, "low") { $0.readouts.headsetBattery == 4 }
        #expect(state.readouts.isBatteryLow)
        sim.simulateBatteryHotSwap()
        state = try await waitForState(device, "swap") { $0.readouts.headsetBattery == 96 }
        #expect(state.readouts.spareBattery == 4)
        #expect(!state.readouts.isBatteryLow)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .battery(headset: start - 3, spare: 100, charging: .discharging))
        await device.stop()
    }

    @Test func micMuteToggleEvent() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.clearRecordedPackets()
        #expect(sim.simulateMicMuteToggle())
        try await waitForState(device, "muted") { $0.readouts.micMuted == true }
        #expect(!sim.simulateMicMuteToggle())
        try await waitForState(device, "unmuted") { $0.readouts.micMuted == false && $0.lastEvent != nil }
        #expect(sim.sentPackets.isEmpty, "events need no polling")
        await device.stop()
    }

    @Test func hubSideSettingChangesAndDial() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.simulateHubChange(.ancMode(.activeNoiseCancellation))
        sim.simulateHubChange(.streamMix(StreamMix(main: 40, aux: 60, mic: 80)))
        sim.simulateChatMixDial(game: 30, chat: 100)
        sim.simulateAudioInput(2)
        sim.simulateBluetooth(mode: .linkMode, link: .ready)
        let state = try await waitForState(device, "hub changes") {
            $0.settings.ancMode == .activeNoiseCancellation && $0.settings.streamMix == StreamMix(main: 40, aux: 60, mic: 80)
                && $0.readouts.chatMix == ChatMix(game: 30, chat: 100) && $0.readouts.audioInput == 2
                && $0.readouts.bluetoothMode == .linkMode && $0.readouts.bluetoothLink == .ready
        }
        #expect(state.settings.ancMode == .activeNoiseCancellation)
        #expect(sim.hub.ancMode == 2)
        await device.stop()
    }

    @Test func eqPresetChangedOnHubTriggersReRead() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.clearRecordedPackets()
        sim.simulateEQPresetChangeOnHub(.mic, presetIndex: MicEQPreset.walkieTalkie.rawValue)
        let state = try await waitForState(device, "mic EQ re-read") { $0.equalizers.mic?.preset == .walkieTalkie }
        #expect(state.equalizers.mic?.presetIndex == 9)
        #expect(sim.sentOutputReports.map { $0[1] } == [0x1C])
        await device.stop()
    }

    @Test func headsetPowerCycleResyncs() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.simulateHeadsetPower(on: false)
        var state = try await waitForState(device, "headset off") { $0.readouts.headsetLink == .disconnected }
        #expect(state.readouts.trustedHeadsetBattery == nil)
        try await waitForState(device, "charging unknown") { $0.readouts.charging == .unknown }
        sim.clearRecordedPackets()
        sim.updateHub { $0.firmware.headsetMCU = "0.37.0" }
        sim.simulateHeadsetPower(on: true)
        state = try await waitForState(device, "re-sync") { $0.info.firmware?.headsetMCU == "0.37.0" && $0.readouts.isHeadsetOnline }
        #expect(sim.sentOutputReports.first?[1] == 0x10, "firmware is read first after reconnect, like GG")
        await device.stop()
    }

    @Test func hubUnplugAndReplug() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.simulateHubDisconnect()
        let gone = try await waitForState(device, "disconnected") { $0.connection == .searching }
        #expect(gone.readouts.headsetBattery == nil, "no stale readings after unplug")
        await #expect(throws: OmniError.notConnected) { try await device.refreshStatus() }
        sim.updateHub { $0.headsetBattery = 55 }
        sim.simulateHubReconnect()
        let back = try await waitForState(device, "reconnected") { $0.connection.isReady && $0.lastRefresh != nil }
        #expect(back.readouts.headsetBattery == 55)
        await device.stop()
    }

    @Test func pollingFallbackPicksUpSilentChanges() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim, configuration: testConfiguration(pollInterval: .milliseconds(150)))
        sim.updateHub { $0.headsetBattery = 12; $0.charging = ChargingState.pluggedInNotCharging.rawValue } // no event emitted
        let state = try await waitForState(device, "poll") { $0.readouts.headsetBattery == 12 }
        #expect(state.readouts.charging == .pluggedInNotCharging)
        await device.stop()
    }

    @Test func hostWriteEchoesAreHandled() async throws {
        let sim = SimulatedOmniTransport(configuration: .init(echoesHostWrites: true))
        let device = try await connectedDevice(sim)
        let events = await device.events()
        try await device.setOutputMode(.streaming)
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .settingChanged(.outputMode(.streaming)))
        await device.stop()
    }

    @Test func featureRepliesWithoutReportIDStillDecode() async throws {
        let sim = SimulatedOmniTransport(configuration: .init(featureRepliesOmitReportID: true))
        let device = try await connectedDevice(sim)
        let state = await device.state
        #expect(state.issues.isEmpty)
        #expect(state.settings.micVolume == 8)
        #expect(state.equalizers.presetName(.micCustom)?.shortName == "CUSTOM")
        await device.stop()
    }

    @Test func missingRepliesTimeOutAndAreReportedAsIssues() async throws {
        let sim = SimulatedOmniTransport(configuration: .init(silentQueryOpcodes: [0x12]))
        let device = try await connectedDevice(sim)
        let state = await device.state
        #expect(state.info.serialNumber == nil)
        #expect(state.issues.count == 1)
        #expect(state.issues.first?.contains("serial") == true)
        await device.stop()
    }

    @Test func settleDelayIsHonoured() async throws {
        let sim = SimulatedOmniTransport()
        let device = OmniDevice(transport: sim, configuration: OmniDevice.Configuration(startupSettle: .milliseconds(300), pollInterval: nil))
        let clock = ContinuousClock()
        let started = clock.now
        try await device.start()
        try await waitForState(device, "connected") { $0.connection.isReady }
        #expect(started.duration(to: clock.now) >= .milliseconds(300))
        let first = try #require(sim.sentPackets.first)
        #expect(started.duration(to: first.at) >= .milliseconds(300))
        await device.stop()
        #expect(await device.state.connection == .stopped)
    }

    @Test func demoModeProducesActivity() async throws {
        let sim = SimulatedOmniTransport(configuration: .init(autonomousActivityInterval: .milliseconds(40)))
        let device = try await connectedDevice(sim)
        let start = Int(sim.hub.headsetBattery)
        try await waitForState(device, "autonomous drain") { ($0.readouts.headsetBattery ?? 100) < start }
        await device.stop()
        #expect(!sim.isRunning)
    }

    @Test func factorySelectsSimulationFromEnvironment() {
        #expect(OmniTransportFactory.makeDefault(environment: ["HUSHDECK_SIMULATED_OMNI": "1"]) is SimulatedOmniTransport)
        #expect(OmniTransportFactory.makeDefault(environment: [:]) is IOKitOmniTransport)
        #expect(!OmniTransportFactory.isSimulationRequested(environment: ["HUSHDECK_SIMULATED_OMNI": "0"]))
    }
}
