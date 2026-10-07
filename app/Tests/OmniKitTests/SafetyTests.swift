import Foundation
import Testing
@testable import OmniKit

@Suite("Safety model")
struct SafetyTests {
    @Test(arguments: [UInt8(0x01), 0x02, 0xFD])
    func confirmedDangerousOpcodesAreBlocked(opcode: UInt8) {
        #expect(OmniSafety.blockedOpcodes[opcode] != nil)
        #expect(throws: OmniError.self) { try OmniOutputReport(opcode: opcode) }
        #expect(throws: OmniError.self) { try OmniOutputReport(opcode: opcode, arguments: [0x01, 0x01]) }
    }

    @Test func conservativeRangesAreBlocked() {
        for opcode in UInt8(0x00)...0x08 { #expect(OmniSafety.isBlocked(opcode)) }
        for opcode in UInt8(0xF0)...0xFF { #expect(OmniSafety.isBlocked(opcode)) }
        #expect(!OmniSafety.isBlocked(0x09)) // save sits just outside the range
    }

    @Test func noAllowlistedOpcodeIsBlocked() {
        for opcode in OmniSafety.outputOpcodes.union(OmniSafety.featureWriteOpcodes) {
            #expect(!OmniSafety.isBlocked(opcode), "0x\(String(opcode, radix: 16))")
        }
    }

    @Test func allowlistIsExactlyTheTypedCommands() {
        let settings: [OmniSetting] = [
            .sidetone(Sidetone(isEnabled: true, level: 5)), .micVolume(5), .micNoiseReduction(.low), .mutedMicLEDBrightness(5),
            .ancMode(.off), .ancLevel(.low), .transparencyLevel(5), .autoOff(.never), .volumeLimiter(true), .outputMode(.speakers),
            .streamMix(StreamMix(main: 1, aux: 2, mic: 3)), .oledBrightness(5), .screensaverTimeout(.never), .screensaverMode(.dim),
            .homeScreenView(.simple), .homeScreenOption(.meters), .bluetoothPowerOnDefault(true), .bluetoothCallBehaviour(.doNothing),
        ]
        #expect(Set(settings.map(\.opcode)) == OmniSafety.settingOpcodes)
        let queries: [OmniQuery] = [.status, .firmwareVersions, .serialNumber, .displaySettings, .audioSettings, .wirelessEQ,
                                    .bluetoothEQ, .micEQ, .presetName(.micCustom)]
        #expect(Set(queries.map(\.opcode)) == OmniSafety.queryOpcodes)
        #expect(Set([WirelessEQ.writeOpcodeForTests, BluetoothEQPreset.writeOpcode, MicEQPreset.writeOpcode]) == OmniSafety.featureWriteOpcodes)
    }

    @Test func outputValidationRejectsWrongReportIDAndLength() {
        var bytes = report([0x01, 0xB0])
        bytes[0] = 0x06
        #expect(throws: OmniError.self) { try OmniSafety.validateOutput(bytes) }
        #expect(throws: OmniError.self) { try OmniSafety.validateOutput([0x01, 0xB0]) }
        #expect(throws: OmniError.self) { try OmniSafety.validateOutput(report([0x01, 0x01, 0x01])) }
        #expect(throws: OmniError.self) { try OmniSafety.validateOutput(report([0x01, 0x93])) } // OLED bitmap: not allowlisted
        #expect(throws: OmniError.self) { try OmniSafety.validateOutput(report([0x01, 0x49, 0x01])) } // software ChatMix: not allowlisted
    }

    @Test func featureValidationOnlyAllowsEQUploads() {
        let block = { (op: UInt8) in report([0x01, op], length: 1036) }
        #expect(throws: Never.self) { try OmniSafety.validateFeatureWrite(block(0x1B)) }
        #expect(throws: OmniError.self) { try OmniSafety.validateFeatureWrite(block(0x02)) } // firmware "Fizz"
        #expect(throws: OmniError.self) { try OmniSafety.validateFeatureWrite(block(0x93)) } // OLED bitmap
        #expect(throws: OmniError.self) { try OmniSafety.validateFeatureWrite(report([0x01, 0x1B], length: 1037)) }
    }

    @Test func featureReportNeedsTheExperimentalFlag() {
        #expect(throws: OmniError.experimentalEQWritesDisabled) {
            try OmniFeatureReport(opcode: 0x1B, payload: [], policy: OmniWritePolicy())
        }
        #expect(throws: Never.self) {
            try OmniFeatureReport(opcode: 0x1B, payload: [], policy: OmniWritePolicy(experimentalEQWrites: true))
        }
        // Even with the flag on, only the three EQ opcodes pass.
        #expect(throws: OmniError.self) {
            try OmniFeatureReport(opcode: 0x02, payload: [], policy: OmniWritePolicy(experimentalEQWrites: true))
        }
    }

    @Test func refusedProductIDs() {
        for pid in [0x2291, 0x2296, 0x2297] {
            #expect(OmniUSB.isRefused(productID: pid))
            #expect(!OmniUSB.isSupported(vendorID: 0x1038, productID: pid))
        }
        #expect(OmniUSB.isSupported(vendorID: 0x1038, productID: 0x2290))
        #expect(!OmniUSB.isSupported(vendorID: 0x1038, productID: 0x12E0)) // Nova Pro Wireless: not ours
        #expect(!OmniUSB.isSupported(vendorID: 0x046D, productID: 0x2290))
    }

    // MARK: Nothing reaches the transport

    @Test func outOfRangeValuesThrowBeforeTheTransport() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.clearRecordedPackets()

        let invalid: [OmniSetting] = [
            .sidetone(Sidetone(isEnabled: true, level: 0)), .sidetone(Sidetone(isEnabled: false, level: 11)),
            .micVolume(0), .micVolume(11), .mutedMicLEDBrightness(-1), .mutedMicLEDBrightness(11),
            .transparencyLevel(0), .transparencyLevel(11), .oledBrightness(0), .oledBrightness(11),
            .streamMix(StreamMix(main: 101, aux: 0, mic: 0)), .streamMix(StreamMix(main: 0, aux: -1, mic: 0)),
            .streamMix(StreamMix(main: 0, aux: 0, mic: 300)),
        ]
        for setting in invalid {
            await #expect(throws: OmniError.self, "\(setting)") { try await device.apply(setting) }
        }
        await #expect(throws: OmniError.self) { try await device.setMicVolume(42) }
        await #expect(throws: OmniError.self) { try await device.apply([.micVolume(5), .micVolume(99)], saveToDevice: true) }
        #expect(sim.sentPackets.isEmpty, "nothing may reach the transport: \(sim.sentPackets)")
        await device.stop()
    }

    @Test func eqWritesWithTheFlagOffThrowBeforeTheTransport() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.clearRecordedPackets()
        let bands = ParametricBand.flat
        await #expect(throws: OmniError.experimentalEQWritesDisabled) {
            try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "MINE", name: "Mine", bands: bands))
        }
        await #expect(throws: OmniError.experimentalEQWritesDisabled) {
            try await device.setBluetoothEQ(BluetoothEQ(preset: .custom, shortName: "MINE", name: "Mine", gainsTenths: BluetoothEQ.flatGains))
        }
        await #expect(throws: OmniError.experimentalEQWritesDisabled) {
            try await device.setMicEQ(MicEQ(preset: .custom, shortName: "MINE", name: "Mine", gainsTenths: MicEQ.flatGains))
        }
        // The channel enforces it too, independently of OmniDevice.
        let channel = OmniChannel(transport: sim)
        await #expect(throws: OmniError.experimentalEQWritesDisabled) {
            try await channel.writeWirelessEQ(WirelessEQ(preset: .custom, shortName: "MINE", name: "Mine", bands: bands))
        }
        #expect(sim.sentPackets.isEmpty)
        await device.stop()
    }

    @Test func invalidEQValuesThrowBeforeTheTransportEvenWithTheFlagOn() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim, configuration: testConfiguration(experimentalEQWrites: true))
        sim.clearRecordedPackets()
        var bands = ParametricBand.flat
        bands[0].gainTenths = 121
        await #expect(throws: OmniError.self) { try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "X", name: "X", bands: bands)) }
        bands = ParametricBand.flat
        bands[1].frequency = 19
        await #expect(throws: OmniError.self) { try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "X", name: "X", bands: bands)) }
        bands = ParametricBand.flat
        bands[2].qThousandths = 199
        await #expect(throws: OmniError.self) { try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "X", name: "X", bands: bands)) }
        bands = ParametricBand.flat
        bands[3].filterType = 7
        await #expect(throws: OmniError.self) { try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "X", name: "X", bands: bands)) }
        await #expect(throws: OmniError.self) {
            try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "X", name: "X", bands: Array(ParametricBand.flat.prefix(9))))
        }
        await #expect(throws: OmniError.self) {
            try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "TOOLONG", name: "X", bands: ParametricBand.flat))
        }
        await #expect(throws: OmniError.self) {
            try await device.setWirelessEQ(WirelessEQ(preset: .custom, shortName: "ÉQ", name: "X", bands: ParametricBand.flat))
        }
        await #expect(throws: OmniError.self) {
            try await device.setMicEQ(MicEQ(preset: .custom, shortName: "X", name: "X", gainsTenths: [0, 0, 0, 0, 0, 0, 0, 0, 0, -121]))
        }
        var eq = BluetoothEQ(preset: .custom, shortName: "X", name: "X", gainsTenths: BluetoothEQ.flatGains)
        eq.presetIndex = 5 // BT only has 0...4
        await #expect(throws: OmniError.self) { try await device.setBluetoothEQ(eq) }
        #expect(sim.sentPackets.isEmpty)
        await device.stop()
    }

    @Test func writesAreRefusedWhileSettlingOrDisconnected() async throws {
        let sim = SimulatedOmniTransport()
        let device = OmniDevice(transport: sim, configuration: OmniDevice.Configuration(startupSettle: .seconds(30), pollInterval: nil))
        await #expect(throws: OmniError.transportStopped) { try await device.setMicVolume(5) }
        try await device.start()
        try await waitForState(device, "settling") { if case .settling = $0.connection { true } else { false } }
        await #expect(throws: OmniError.hubSettling) { try await device.setMicVolume(5) }
        await #expect(throws: OmniError.hubSettling) { try await device.refresh() }
        sim.simulateHubDisconnect()
        try await waitForState(device, "searching") { $0.connection == .searching }
        await #expect(throws: OmniError.notConnected) { try await device.saveToDevice() }
        #expect(sim.sentPackets.isEmpty, "GG sends nothing for 5 s after enumeration")
        await device.stop()
    }

    @Test func transfersAreSpacedAtLeast50ms() async throws {
        let sim = SimulatedOmniTransport()
        let device = try await connectedDevice(sim)
        sim.clearRecordedPackets()
        // Fire several writes concurrently: the channel must serialise and pace them.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for level in 1...6 { group.addTask { try await device.setMicVolume(level) } }
            try await group.waitForAll()
        }
        let times = sim.sentPackets.map(\.at)
        #expect(times.count == 6)
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(a.duration(to: b) >= .milliseconds(50), "gap \(a.duration(to: b))")
        }
        await device.stop()
    }

    @Test func saveWaitsAfterTheLastWrite() async throws {
        let sim = SimulatedOmniTransport()
        let channel = OmniChannel(transport: sim, saveDelay: .milliseconds(200))
        try await sim.start()
        try await channel.send(.ancMode(.transparency))
        try await channel.saveToFlash()
        let packets = sim.sentPackets
        #expect(packets.map(\.opcode) == [0xBD, 0x09])
        #expect(packets[0].at.duration(to: packets[1].at) >= .milliseconds(200))
        #expect(sim.hub.saveCount == 1)
        // The save delay can't be configured below the 50 ms spacing.
        #expect(OmniChannel(transport: sim, saveDelay: .zero).saveDelay == .milliseconds(50))
        await sim.stop()
    }
}

extension WirelessEQ {
    static var writeOpcodeForTests: UInt8 {
        (try! WirelessEQ(preset: .flat, shortName: "", name: "", bands: ParametricBand.flat)
            .featureReport(policy: OmniWritePolicy(experimentalEQWrites: true))).opcode
    }
}
