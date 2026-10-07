import Foundation
import Testing
@testable import HeadsetControlKit

/// Runs the real `headsetcontrol` against its built-in `--test-device`. Skipped when
/// no binary is installed (set HEADSETCONTROL_BIN to point at one).
@Suite("Live CLI with --test-device", .enabled(if: LiveBinary.isAvailable, "headsetcontrol binary not found"))
struct LiveBinaryTests {
    func client(profile: Int? = nil) throws -> HeadsetControlClient {
        let url = try #require(LiveBinary.url)
        return HeadsetControlClient(configuration: .init(binary: url, testDevice: .on(profile: profile), timeout: .seconds(10)))
    }

    @Test func statusReportsTestDevice() async throws {
        let output = try await client().status()
        let device = try #require(output.devices.first { $0.isTestDevice })
        #expect(device.supports(.sidetone))
        #expect(device.supports(.equalizer))
        #expect(device.battery?.percent == 42)
        #expect(device.presetNames == ["flat", "bass boost", "treble boost", "v-shape"])
        #expect(device.equalizer?.bands == 10)
    }

    @Test func versionIsReported() async throws {
        let version = try await client().version()
        #expect(version.hasPrefix("HeadsetControl "))
    }

    @Test func everySetterSucceeds() async throws {
        let settings: [HeadsetSetting] = [
            .sidetone(50), .equalizerPreset(2), .microphoneVolume(64), .microphoneMuteLEDBrightness(2),
            .inactiveTime(minutes: 15), .lights(true), .voicePrompts(false), .rotateToMute(true),
            .noiseFilter(.high), .volumeLimiter(true), .bluetoothWhenPoweredOn(true), .bluetoothCallVolume(40),
        ]
        let results = try await client().apply(settings, to: .testDevice)
        #expect(results.count == settings.count)
        #expect(results.allSatisfy { $0.succeeded })
        #expect(Set(results.map(\.capability)) == Set(settings.map(\.capability)))
    }

    @Test func negativeEqualizerValuesParse() async throws {
        let results = try await client().apply([.equalizer([-12, -2.5, 0, 1.5, 3, 0, 0, 0, 0, 12])], to: .testDevice)
        #expect(results.map(\.capability) == [.equalizer])
        #expect(results.first?.succeeded == true)
    }

    @Test func parametricEqualizer() async throws {
        let results = try await client().apply([.parametricEqualizer([.init(frequency: 100, gain: 3, q: 0.7)])], to: .testDevice)
        #expect(results.first?.succeeded == true)
    }

    @Test func errorProfileReportsFailures() async throws {
        let c = try client(profile: 1)
        let status = try await c.status()
        #expect(status.devices.first?.status == .partial)
        #expect(status.devices.first?.connection.isReachable == false)

        let mixed = try await c.apply([.sidetone(5), .lights(true)], to: .testDevice)
        #expect(mixed.first { $0.capability == .sidetone }?.succeeded == false)
        #expect(mixed.first { $0.capability == .lights }?.succeeded == true)

        await #expect(throws: HeadsetControlError.self) {
            try await c.apply([.sidetone(5)], to: .testDevice)
        }
    }

    @Test func limitedProfile() async throws {
        let device = try #require(try await client(profile: 10).status().devices.first)
        #expect(device.capabilities == [.sidetone, .batteryStatus, .lights])
    }

    @Test func concurrentCallsAreSerialised() async throws {
        let c = try client()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for level in 0..<8 {
                group.addTask { try await c.apply([.sidetone(level * 10)], to: .testDevice).count }
            }
            for try await count in group { #expect(count == 1) }
        }
    }

    /// Without --test-device nothing is attached on the dev machine, but this only
    /// asserts the shape so it also passes with a real headset plugged in.
    @Test func withoutTestDeviceDecodes() async throws {
        let url = try #require(LiveBinary.url)
        let output = try await HeadsetControlClient(configuration: .init(binary: url)).status()
        #expect(output.deviceCount == output.devices.count)
        #expect(!output.devices.contains { $0.isTestDevice })
    }
}
