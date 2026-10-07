import Foundation
import Testing
@testable import OmniKit

@Suite("Reply and event decoding")
struct DecodingTests {
    // Hand-built from protocol-notes §3.1, not from the simulator.
    static let statusBytes = report([
        0x01, 0xB0,
        0x01, // 2 BT auto-power-on: on
        0x02, // 3 BT call: mute others
        0x04, // 4 BT mode: link
        0x02, // 5 BT link: lost
        0x3F, // 6 headset battery 63 %
        0x5A, // 7 spare battery 90 %
        0x07, // 8 transparency 7
        0x01, // 9 mic muted
        0x01, // 10 ANC mode: transparency
        0x04, // 11 muted-mic LED 4
        0x06, // 12 auto-off 60 min
        0x01, // 13 wireless mode: range
        0x08, // 14 2.4G link: connected
        0x02, // 15 charging: cable charging
        0x02, // 16 ANC level: medium
    ])

    @Test func statusReplyDecodesEveryField() throws {
        let s = try OmniStatus(report: Self.statusBytes)
        #expect(s.bluetoothPowerOnDefault)
        #expect(s.bluetoothCallBehaviour == .muteOtherAudio)
        #expect(s.bluetoothMode == .linkMode)
        #expect(s.bluetoothLink == .lost)
        #expect(s.headsetBattery == 63)
        #expect(s.spareBattery == 90)
        #expect(s.transparencyLevel == 7)
        #expect(s.micMuted)
        #expect(s.ancMode == .transparency)
        #expect(s.mutedMicLEDBrightness == 4)
        #expect(s.autoOff == .sixtyMinutes)
        #expect(s.wirelessMode == .range)
        #expect(s.headsetLink == .connected)
        #expect(s.charging == .charging)
        #expect(s.ancLevel == .medium)
    }

    @Test(arguments: [(UInt8(1), ChargingState.unknown), (2, .charging), (4, .pluggedInNotCharging), (8, .discharging)])
    func chargingCodes(code: UInt8, expected: ChargingState) throws {
        var bytes = Self.statusBytes
        bytes[15] = code
        #expect(try OmniStatus(report: bytes).charging == expected)
    }

    @Test(arguments: [(UInt8(1), HeadsetLinkState.unpaired), (2, .pairing), (4, .disconnected), (8, .connected)])
    func linkCodes(code: UInt8, expected: HeadsetLinkState) throws {
        var bytes = Self.statusBytes
        bytes[14] = code
        let status = try OmniStatus(report: bytes)
        #expect(status.headsetLink == expected)
        var state = OmniState()
        state.apply(status)
        // GG only trusts the battery while the link is connected.
        #expect(state.readouts.trustedHeadsetBattery == (expected == .connected ? 63 : nil))
    }

    @Test func ancFieldsAcrossModes() throws {
        for (mode, level) in [(UInt8(0), UInt8(1)), (1, 3), (2, 2)] {
            var bytes = Self.statusBytes
            bytes[10] = mode
            bytes[16] = level
            let s = try OmniStatus(report: bytes)
            #expect(s.ancMode?.rawValue == mode)
            #expect(s.ancLevel?.rawValue == level)
        }
    }

    @Test func unknownCodesDecodeAsNilNotGarbage() throws {
        var bytes = Self.statusBytes
        bytes[15] = 3
        bytes[14] = 0
        bytes[10] = 9
        let s = try OmniStatus(report: bytes)
        #expect(s.charging == nil)
        #expect(s.headsetLink == nil)
        #expect(s.ancMode == nil)
    }

    @Test func statusRejectsWrongEchoOrShortReply() {
        #expect(throws: OmniError.self) { try OmniStatus(report: report([0x01, 0x80])) }
        #expect(throws: OmniError.self) { try OmniStatus(report: [0x01, 0xB0, 0x00]) }
    }

    @Test func lowBatteryRule() {
        var r = OmniReadouts()
        r.headsetLink = .connected
        r.headsetBattery = 5
        #expect(r.isBatteryLow)
        r.headsetBattery = 6
        #expect(!r.isBatteryLow)
        r.headsetBattery = 0
        #expect(!r.isBatteryLow)
    }

    @Test func displaySettings() throws {
        var bytes = report([0x01, 0x80])
        bytes[2] = 2; bytes[3] = 7; bytes[5] = 1; bytes[9] = 4; bytes[10] = 0; bytes[11] = 2
        let d = try OmniDisplaySettings(report: bytes)
        #expect(d.screensaverTimeout == .fiveMinutes)
        #expect(d.brightness == 7)
        #expect(d.homeScreenView == .simple)
        #expect(d.colour == .midnightBlue)
        #expect(d.screensaverMode == .screenOff)
        #expect(d.homeScreenOption == .meters)
    }

    @Test func firmwareAndSerial() throws {
        var bytes = report([0x01, 0x10])
        for (i, text) in ["1.32.0", "1.32.1", "0.36.0", "", ""].enumerated() {
            for (j, b) in text.utf8.enumerated() { bytes[2 + 12 * i + j] = b }
        }
        let fw = try OmniFirmwareVersions(report: bytes)
        #expect(fw.hubMCU1 == "1.32.0")
        #expect(fw.hubMCU2 == "1.32.1")
        #expect(fw.hubDSP == "0.36.0")
        #expect(!fw.hasHeadsetVersions)

        var serial = report([0x01, 0x12])
        for (j, b) in "ABCDEFGHIJKLMNOPQRS".utf8.enumerated() { serial[2 + j] = b }
        #expect(try OmniSerialReply.decode(serial) == "ABCDEFGHIJKLMNOPQRS")
    }

    @Test func audioSettingsFeatureLayout() throws {
        var r = report([0x01, 0x20], length: 1036)
        // One custom band and one active band, hand-encoded: 1000 Hz, low-shelf, -3.5 dB, Q 0.707.
        r.replaceSubrange(2..<8, with: [0xE8, 0x03, 0x04, 0xDD, 0xC3, 0x02])
        r.replaceSubrange(62..<68, with: [0x21, 0x4E, 0x01, 0x78, 0x10, 0x27]) // 20001 (off), +12.0 dB, Q 10
        r[122] = 0x88 // BT band 1: -12.0 dB
        r[141] = 0x05 // mic band 10: +0.5 dB
        r[142] = 3; r[143] = 38; r[144] = 1; r[145] = 0; r[146] = 9; r[147] = 4; r[148] = 2
        r[149] = 4; r[150] = 8; r[151] = 1; r[152] = 70; r[153] = 30
        r[156] = 90; r[157] = 0xEE; r[158] = 40; r[159] = 20
        r[165] = 1; r[166] = 2; r[170] = 0
        let a = try OmniAudioSettings(report: r)
        #expect(a.customWirelessBands[0] == ParametricBand(frequency: 1000, filter: .lowShelf, gainTenths: -35, qThousandths: 707))
        #expect(!a.activeWirelessBands[0].isEnabled)
        #expect(a.activeWirelessBands[0].gainDB == 12.0)
        #expect(a.activeWirelessBands[0].q == 10.0)
        #expect(a.bluetoothGainsTenths[0] == -120)
        #expect(a.micGainsTenths[9] == 5)
        #expect(a.audioInput == 3)
        #expect(a.hubVolume == 38)
        #expect(a.volumeLimiter)
        #expect(a.micVolume == 9)
        #expect(a.sidetone == Sidetone(isEnabled: false, level: 4))
        #expect(a.outputMode == .streaming)
        #expect(a.wirelessPresetIndex == 4)
        #expect(a.micPresetIndex == 8)
        #expect(a.bluetoothPresetIndex == 1)
        #expect(a.chatMix == ChatMix(game: 70, chat: 30))
        #expect(a.streamMix == StreamMix(main: 90, aux: 40, mic: 20))
        #expect(a.micNoiseReduction == .medium)
    }

    @Test func featureRepliesWithoutReportIDAreRealigned() throws {
        let hub = SimulatedGameHub()
        let withID = hub.audioSettingsFeature()
        let withoutID = Array(withID.dropFirst())
        #expect(try OmniAudioSettings(report: withID) == OmniAudioSettings(report: withoutID))
        #expect(try WirelessEQ(report: Array(hub.wirelessEQFeature().dropFirst())) == hub.wirelessEQ)
        #expect(throws: OmniError.self) { try OmniAudioSettings(report: report([0x01, 0x1A], length: 1036)) }
    }

    @Test func eqRepliesAndPresetNames() throws {
        var hub = SimulatedGameHub()
        hub.wirelessEQ = WirelessEQ(preset: .custom, shortName: "PUNCH", name: "Punchy bass",
                                    bands: ParametricBand.flat.enumerated().map { i, b in
                                        var b = b
                                        b.gainTenths = i * 10 - 50
                                        return b
                                    })
        hub.micEQ = MicEQ(preset: .broadcastLowPitch, shortName: "BLP", name: "Broadcast", gainsTenths: [-120, -60, 0, 5, 10, 15, 20, 25, 30, 120])
        #expect(try WirelessEQ(report: hub.wirelessEQFeature()) == hub.wirelessEQ)
        #expect(try MicEQ(report: hub.graphicEQFeature(hub.micEQ)) == hub.micEQ)
        #expect(try BluetoothEQ(report: hub.graphicEQFeature(hub.bluetoothEQ)) == hub.bluetoothEQ)
        let name = try OmniPresetName(report: hub.presetNameFeature(.wirelessGame))
        #expect(name == OmniPresetName(slot: .wirelessGame, presetClass: 1, shortName: "GAME", name: "Game preset"))
        // A BT reply is not a mic reply.
        #expect(throws: OmniError.self) { try MicEQ(report: hub.graphicEQFeature(hub.bluetoothEQ)) }
    }

    @Test func parametricBandWireEncoding() {
        let band = ParametricBand(frequency: 16000, filter: .highShelf, gainDB: -12.0, q: 1.414)
        #expect(band.wireBytes == [0x80, 0x3E, 0x05, 0x88, 0x86, 0x05])
        #expect(ParametricBand(wire: ArraySlice(band.wireBytes)) == band)
        #expect(ParametricBand(frequency: 20, filter: .peaking, gainDB: 12, q: 0.2).wireBytes == [0x14, 0x00, 0x01, 0x78, 0xC8, 0x00])
    }

    // MARK: Events (§3.2)

    @Test func connectionEvent() {
        let event = OmniEvent(report: report([0x02, 0xB5, 0x02, 0x04, 0x08]))
        #expect(event == .connection(bluetoothMode: .pairing, bluetoothLink: .busy, headsetLink: .connected))
    }

    @Test func batteryEventIncludesSpareAndCharging() {
        #expect(OmniEvent(report: report([0x01, 0xB7, 0x2A, 0x64, 0x02])) == .battery(headset: 42, spare: 100, charging: .charging))
        #expect(OmniEvent(report: report([0x01, 0xB7, 0x05, 0x00, 0x08])) == .battery(headset: 5, spare: 0, charging: .discharging))
    }

    @Test func micMuteChatMixAndInputEvents() {
        #expect(OmniEvent(report: report([0x01, 0xBB, 0x01])) == .micMute(true))
        #expect(OmniEvent(report: report([0x01, 0xBB, 0x00])) == .micMute(false))
        #expect(OmniEvent(report: report([0x01, 0x45, 0x64, 0x28])) == .chatMix(ChatMix(game: 100, chat: 40)))
        #expect(OmniEvent(report: report([0x01, 0x23, 0x03])) == .audioInput(3))
    }

    /// Captured on real hardware (report ID 0x07 on the event collection).
    @Test func realHardwareEvents() {
        #expect(OmniEvent(report: report([0x07, 0xBB, 0x01])) == .micMute(true))
        #expect(OmniEvent(report: report([0x07, 0xBB])) == .micMute(false))
        #expect(OmniEvent(report: report([0x07, 0xB7, 0x5D, 0x64, 0x08])) == .battery(headset: 93, spare: 100, charging: .discharging))
        #expect(OmniEvent(report: report([0x07, 0xBD, 0x01])) == .settingChanged(.ancMode(.transparency)))
        #expect(OmniEvent(report: report([0x07, 0xB8, 0x03])) == .settingChanged(.ancLevel(.high)))
        #expect(OmniEvent(report: report([0x07, 0x25, 0x12])) == .hubVolume(18))
        var state = OmniState()
        let changed = state.apply(.hubVolume(14))
        #expect(changed)
        #expect(state.readouts.hubVolume == 14)
    }

    @Test func eqChangedEvents() {
        #expect(OmniEvent(report: report([0x01, 0x1B])) == .equalizerChanged(.wireless))
        #expect(OmniEvent(report: report([0x01, 0x1D])) == .equalizerChanged(.mic))
        #expect(OmniEvent(report: report([0x01, 0x1F])) == .equalizerChanged(.bluetooth))
    }

    @Test func settingEchoesUseTheWriteLayout() throws {
        let settings: [OmniSetting] = [
            .sidetone(Sidetone(isEnabled: false, level: 7)), .micVolume(3), .micNoiseReduction(.off), .micNoiseReduction(.high),
            .mutedMicLEDBrightness(0), .ancMode(.activeNoiseCancellation), .ancLevel(.low), .transparencyLevel(10),
            .autoOff(.fifteenMinutes), .volumeLimiter(false), .outputMode(.streaming), .streamMix(StreamMix(main: 80, aux: 35, mic: 5)),
            .oledBrightness(1), .screensaverTimeout(.oneMinute), .screensaverMode(.screenOff), .homeScreenView(.simple),
            .homeScreenOption(.preset), .bluetoothPowerOnDefault(true), .bluetoothCallBehaviour(.lowerOtherAudio),
        ]
        for setting in settings {
            let bytes = try setting.outputReport().bytes
            #expect(OmniEvent(report: bytes) == .settingChanged(setting), "\(setting)")
        }
    }

    @Test func queryRepliesAndJunkAreNotEvents() {
        #expect(OmniEvent(report: SimulatedGameHub().statusReport()) == nil)
        #expect(OmniEvent(report: report([0x01, 0x10])) == nil)
        #expect(OmniEvent(report: report([0x01, 0x80])) == nil)
        #expect(OmniEvent(report: [0x01]) == nil)
        #expect(OmniEvent(report: report([0x01, 0xBD, 0x07])) == nil) // unknown ANC mode
    }

    @Test func stateIsCodableForProfilesAndSnapshots() throws {
        var state = OmniState()
        state.apply(try OmniStatus(report: Self.statusBytes))
        state.apply(try OmniAudioSettings(report: SimulatedGameHub().audioSettingsFeature()))
        state.connection = .connected(OmniHubInfo(isSimulated: true))
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(OmniState.self, from: data) == state)
        let settings = state.settings.asSettings
        let decoded = try JSONDecoder().decode([OmniSetting].self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
