import Foundation
import Testing
@testable import OmniKit

/// Packet-level golden tests. `Fixtures/probe-golden.json` is produced by running
/// `tools/probe.py` in dry-run mode for every case (`tools/omnikit_golden.py`); OmniKit must
/// produce identical bytes, reject the same values and block the same opcodes.
@Suite("Golden packets vs probe.py")
struct GoldenPacketTests {
    struct GoldenCase: Decodable, Sendable {
        let id: String
        let kind: String
        let result: String
        let hex: String?
        let feature: String?
        let value: String?
        let read: String?
        let slot: Int?
        let opcode: Int?
    }

    struct GoldenFile: Decodable {
        let cases: [GoldenCase]
    }

    static func load() throws -> [GoldenCase] {
        try JSONDecoder().decode(GoldenFile.self, from: Fixture.data("probe-golden")).cases
    }

    /// What OmniKit makes of a probe.py `send <feature> <value>` invocation.
    enum Mapped {
        case setting(OmniSetting)
        case save
        /// The typed API can't even express the value (e.g. ANC mode 3, auto-off 45 min).
        case unrepresentable
    }

    static func map(feature: String, value: String) -> Mapped {
        let number = Int(value)
        func named<T>(_ table: [String: T], _ numeric: (UInt8) -> T?) -> T? {
            if let hit = table[value.lowercased()] { return hit }
            guard let n = number, let byte = UInt8(exactly: n) else { return nil }
            return numeric(byte)
        }
        func bool() -> Bool? { number == 0 ? false : number == 1 ? true : nil }
        func wrap(_ s: OmniSetting?) -> Mapped { s.map(Mapped.setting) ?? .unrepresentable }

        switch feature {
        case "sidetone":
            // probe.py: 0 = off (sent with level 1), 1...10 = on at that level.
            guard let n = number else { return .unrepresentable }
            return .setting(.sidetone(n == 0 ? Sidetone(isEnabled: false, level: 1) : Sidetone(isEnabled: true, level: n)))
        case "mic-volume": return wrap(number.map { .micVolume($0) })
        case "noise-reduction": return wrap(number.flatMap { UInt8(exactly: $0) }.flatMap(MicNoiseReduction.init(rawValue:)).map { .micNoiseReduction($0) })
        case "mic-led": return wrap(number.map { .mutedMicLEDBrightness($0) })
        case "anc-mode":
            return wrap(named(["off": .off, "transparency": .transparency, "anc": .activeNoiseCancellation], ANCMode.init(rawValue:)).map { .ancMode($0) })
        case "anc-level": return wrap(number.flatMap { UInt8(exactly: $0) }.flatMap(ANCLevel.init(rawValue:)).map { .ancLevel($0) })
        case "transparency-level": return wrap(number.map { .transparencyLevel($0) })
        case "auto-off": return wrap(number.flatMap(OmniTimeout.init(minutes:)).map { .autoOff($0) })
        case "volume-limiter": return wrap(bool().map { .volumeLimiter($0) })
        case "line-out":
            return wrap(named(["speakers": .speakers, "streaming": .streaming], OutputMode.init(rawValue:)).map { .outputMode($0) })
        case "stream-mix":
            let parts = value.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 3 else { return .unrepresentable }
            return .setting(.streamMix(StreamMix(main: parts[0], aux: parts[1], mic: parts[2])))
        case "oled-brightness": return wrap(number.map { .oledBrightness($0) })
        case "screensaver-timer": return wrap(number.flatMap(OmniTimeout.init(minutes:)).map { .screensaverTimeout($0) })
        case "screensaver-mode":
            return wrap(named(["off": .screenOff, "dim": .dim], ScreensaverMode.init(rawValue:)).map { .screensaverMode($0) })
        case "home-view":
            return wrap(named(["detailed": .detailed, "simple": .simple], HomeScreenView.init(rawValue:)).map { .homeScreenView($0) })
        case "home-option":
            return wrap(named(["stereo": .stereo, "preset": .preset, "meters": .meters], HomeScreenOption.init(rawValue:)).map { .homeScreenOption($0) })
        case "bt-power-default": return wrap(bool().map { .bluetoothPowerOnDefault($0) })
        case "bt-call":
            return wrap(named(["nothing": .doNothing, "lower": .lowerOtherAudio, "mute": .muteOtherAudio], BluetoothCallBehaviour.init(rawValue:))
                .map { .bluetoothCallBehaviour($0) })
        case "save": return .save
        default:
            Issue.record("golden case uses unknown probe feature \(feature)")
            return .unrepresentable
        }
    }

    static func query(read: String, slot: Int?) -> OmniQuery? {
        switch read {
        case "status": .status
        case "firmware": .firmwareVersions
        case "ux": .displaySettings
        case "serial": .serialNumber
        case "audio": .audioSettings
        case "eq-24g": .wirelessEQ
        case "eq-bt": .bluetoothEQ
        case "eq-mic": .micEQ
        case "eq-name": slot.flatMap { UInt8(exactly: $0) }.flatMap(OmniPresetNameSlot.init(rawValue:)).map { .presetName($0) }
        default: nil
        }
    }

    @Test func fixtureCoversEveryProbeSettingAndRead() throws {
        let cases = try Self.load()
        #expect(cases.count > 400)
        let features = Set(cases.compactMap(\.feature))
        #expect(features == ["sidetone", "mic-volume", "noise-reduction", "mic-led", "anc-mode", "anc-level", "transparency-level",
                             "auto-off", "volume-limiter", "line-out", "stream-mix", "oled-brightness", "screensaver-timer",
                             "screensaver-mode", "home-view", "home-option", "bt-power-default", "bt-call", "save"])
        #expect(Set(cases.compactMap(\.read)) == ["status", "firmware", "ux", "serial", "audio", "eq-24g", "eq-bt", "eq-mic", "eq-name"])
        #expect(cases.filter { $0.kind == "opcode" }.count == 256)
    }

    @Test func settingsPacketsMatchProbeByteForByte() throws {
        let sends = try Self.load().filter { $0.kind == "send" }
        var packets = 0, rejections = 0
        for golden in sends {
            let mapped = Self.map(feature: golden.feature!, value: golden.value!)
            switch (golden.result, mapped) {
            case ("packet", .setting(let setting)):
                let bytes = try setting.outputReport().bytes
                #expect(OmniHex.string(bytes) == golden.hex, "\(golden.id)")
                #expect(bytes.count == 64, "\(golden.id)")
                packets += 1
            case ("packet", .save):
                #expect(OmniHex.string(OmniOutputReport.saveToFlash().bytes) == golden.hex, "\(golden.id)")
                packets += 1
            case ("packet", .unrepresentable):
                Issue.record("probe.py accepts \(golden.id) but OmniKit can't express it")
            case ("rejected", .setting(let setting)):
                #expect(throws: OmniError.self, "\(golden.id) must be rejected") { try setting.outputReport() }
                rejections += 1
            case ("rejected", .unrepresentable):
                rejections += 1
            default:
                Issue.record("unexpected golden result \(golden.result) for \(golden.id)")
            }
        }
        #expect(packets == sends.filter { $0.result == "packet" }.count)
        #expect(rejections == sends.filter { $0.result == "rejected" }.count)
        #expect(packets + rejections == sends.count)
    }

    @Test func readQueriesMatchProbe() throws {
        var count = 0
        for golden in try Self.load() where golden.kind == "read" {
            let query = try #require(Self.query(read: golden.read!, slot: golden.slot), "\(golden.id)")
            #expect(golden.result == "packet")
            #expect(OmniHex.string(try query.outputReport().bytes) == golden.hex, "\(golden.id)")
            count += 1
        }
        #expect(count == 12)
    }

    @Test func blocklistMatchesProbeForAll256Opcodes() throws {
        var blocked = 0
        for golden in try Self.load() where golden.kind == "opcode" {
            let opcode = UInt8(golden.opcode!)
            let probeBlocks = golden.result == "blocked"
            #expect(OmniSafety.isBlocked(opcode) == probeBlocks, "opcode \(golden.id)")
            if probeBlocks {
                blocked += 1
                #expect(throws: OmniError.blockedOpcode(opcode, reason: OmniSafety.blockReason(for: opcode)!)) {
                    try OmniOutputReport(opcode: opcode)
                }
            } else if OmniSafety.outputOpcodes.contains(opcode) {
                #expect(throws: Never.self) { try OmniOutputReport(opcode: opcode, arguments: opcode == 0x18 ? [0] : []) }
            } else {
                // probe.py's `raw --force` would build it; OmniKit has no raw path at all.
                #expect(throws: OmniError.notAllowlisted(opcode)) { try OmniOutputReport(opcode: opcode) }
            }
        }
        #expect(blocked == 25)
    }
}
