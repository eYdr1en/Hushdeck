import Foundation
import Testing
@testable import OmniKit

/// EQ write round-trip against a real GameHub: nudge one band by +2 dB, re-read, restore.
/// Mic first (nothing audible), then Bluetooth (silent while on 2.4 GHz), then 2.4 GHz.
/// Stops at the first EQ that doesn't round-trip. Never saves to flash.
/// Opt in with `OMNIKIT_LIVE_EQ=1 swift test --filter LiveHubEQTests`.
@Suite("Live hub EQ round-trip", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OMNIKIT_LIVE_EQ"] == "1"))
struct LiveHubEQTests {
    @Test func eqWritesRoundTrip() async throws {
        let device = OmniDevice(transport: IOKitOmniTransport(), configuration: .init(pollInterval: nil))
        try await device.start()
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if case .connected = await device.state.connection, await device.state.lastRefresh != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        await device.setExperimentalEQWrites(true)
        defer { Task { await device.stop() } }

        // Mic EQ.
        try await device.refreshEqualizer(.mic)
        let micOriginal = try #require(await device.state.equalizers.mic)
        // Factory slots ignore uploaded bands (first hardware run), so test on the Custom slot.
        var micTest = MicEQ(preset: .custom, shortName: "CUSTOM", name: "CUSTOM", gainsTenths: micOriginal.gainsTenths)
        micTest.gainsTenths[5] = min(micTest.gainsTenths[5] + 20, 120)
        let micOK = try await roundTrip("mic", device: device, kind: .mic,
                                        write: { try await device.setMicEQ(micTest) },
                                        restore: { try await device.setMicEQ(micOriginal) },
                                        read: { await device.state.equalizers.mic },
                                        expected: micTest, original: micOriginal)
        guard micOK else { return }

        // Bluetooth EQ.
        try await device.refreshEqualizer(.bluetooth)
        let btOriginal = try #require(await device.state.equalizers.bluetooth)
        var btTest = BluetoothEQ(preset: .custom, shortName: "CUSTOM", name: "CUSTOM", gainsTenths: btOriginal.gainsTenths)
        btTest.gainsTenths[5] = min(btTest.gainsTenths[5] + 20, 120)
        let btOK = try await roundTrip("bluetooth", device: device, kind: .bluetooth,
                                       write: { try await device.setBluetoothEQ(btTest) },
                                       restore: { try await device.setBluetoothEQ(btOriginal) },
                                       read: { await device.state.equalizers.bluetooth },
                                       expected: btTest, original: btOriginal)
        guard btOK else { return }

        // 2.4 GHz parametric EQ.
        try await device.refreshEqualizer(.wireless)
        let wOriginal = try #require(await device.state.equalizers.wireless)
        var wTest = WirelessEQ(preset: .custom, shortName: "CUSTOM", name: "CUSTOM", bands: wOriginal.bands)
        wTest.bands[5].gainTenths = min(wTest.bands[5].gainTenths + 20, 120)
        _ = try await roundTrip("2.4 GHz", device: device, kind: .wireless,
                                write: { try await device.setWirelessEQ(wTest) },
                                restore: { try await device.setWirelessEQ(wOriginal) },
                                read: { await device.state.equalizers.wireless },
                                expected: wTest, original: wOriginal)
    }

    private func roundTrip<E: Equatable>(_ name: String, device: OmniDevice, kind: OmniEqualizerKind,
                                         write: () async throws -> Void, restore: () async throws -> Void,
                                         read: () async -> E?, expected: E, original: E) async throws -> Bool {
        print("[\(name)] original: \(original)")
        try await write()
        try await Task.sleep(for: .milliseconds(400))
        try await device.refreshEqualizer(kind)
        let readBack = await read()
        print("[\(name)] wrote:    \(expected)")
        print("[\(name)] read:     \(readBack.map { "\($0)" } ?? "nil")")
        try await restore()
        try await Task.sleep(for: .milliseconds(400))
        try await device.refreshEqualizer(kind)
        let restored = await read()
        print("[\(name)] restored: \(restored.map { "\($0)" } ?? "nil")")
        let ok = readBack == expected && restored == original
        print("[\(name)] \(ok ? "OK" : "FAIL")")
        #expect(readBack == expected, "\(name): hub didn't take the write")
        #expect(restored == original, "\(name): original not restored")
        return ok
    }
}
