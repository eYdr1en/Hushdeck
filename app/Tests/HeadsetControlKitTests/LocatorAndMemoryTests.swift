import Foundation
import Testing
@testable import HeadsetControlKit

@Suite("Binary resolution")
struct BinaryLocatorTests {
    let home = URL(fileURLWithPath: "/Users/tester")
    let resources = URL(fileURLWithPath: "/Applications/Hushdeck.app/Contents/Resources")

    func locator(override: String? = nil, existing: Set<String>) -> BinaryLocator {
        BinaryLocator(overridePath: override, bundleResourcesURL: resources, homeDirectory: home) { existing.contains($0) }
    }

    @Test func candidateOrder() {
        let paths = locator(override: "/custom/hc", existing: []).candidates.map(\.url.path)
        #expect(paths == [
            "/custom/hc",
            "/Applications/Hushdeck.app/Contents/Resources/headsetcontrol",
            "/opt/homebrew/bin/headsetcontrol",
            "/usr/local/bin/headsetcontrol",
            "/Users/tester/coding/HeadsetControl/build/headsetcontrol",
        ])
    }

    @Test func overrideWins() {
        let everything: Set<String> = [
            "/custom/hc", "/Applications/Hushdeck.app/Contents/Resources/headsetcontrol", "/opt/homebrew/bin/headsetcontrol",
        ]
        #expect(locator(override: "/custom/hc", existing: everything).locate()?.source == .userOverride)
        #expect(locator(override: "  ", existing: everything).locate()?.source == .bundled)
    }

    @Test func invalidOverrideFallsThrough() {
        let l = locator(override: "/missing", existing: ["/usr/local/bin/headsetcontrol"])
        #expect(l.overrideIsInvalid)
        #expect(l.locate()?.source == .usrLocal)
    }

    @Test func developmentBuildIsLastResort() {
        let l = locator(existing: ["/Users/tester/coding/HeadsetControl/build/headsetcontrol"])
        #expect(l.locate()?.source == .developmentBuild)
    }

    @Test func nothingFound() {
        #expect(locator(existing: []).locate() == nil)
    }

    @Test func realFileSystemCheckRejectsDirectories() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("headsetcontrol"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = BinaryLocator(overridePath: dir.appendingPathComponent("headsetcontrol").path, bundleResourcesURL: nil, homeDirectory: dir)
        #expect(l.overrideIsInvalid)
    }
}

@Suite("Remembered settings")
struct RememberedSettingsTests {
    @Test func recordsAndReappliesOnlySupported() throws {
        var memory = RememberedSettings()
        #expect(memory.isEmpty)
        memory.record(.sidetone(40))
        memory.record(.lights(false))
        memory.record(.equalizer([1, 2, 3]))
        memory.record(.inactiveTime(minutes: 15))
        memory.record(.noiseFilter(.low))
        memory.record(.notificationSound(1)) // momentary; ignored
        #expect(!memory.isEmpty)

        let full = try Fixture.device("status_full")
        #expect(memory.settingsToReapply(on: full) == [
            .sidetone(40), .equalizer([1, 2, 3]), .inactiveTime(minutes: 15), .lights(false), .noiseFilter(.low),
        ])

        let limited = try Fixture.device("status_limited")
        #expect(memory.settingsToReapply(on: limited) == [.sidetone(40), .lights(false)])
    }

    @Test func presetReplacesCustomCurve() throws {
        var memory = RememberedSettings()
        memory.record(.equalizer([1, 2]))
        memory.record(.equalizerPreset(3))
        #expect(memory.equalizer == .preset(3))
        #expect(memory.settingsToReapply(on: try Fixture.device("status_full")) == [.equalizerPreset(3)])
    }

    @Test func noiseCancellingReappliesWhenCapabilityAppears() throws {
        var memory = RememberedSettings()
        let device = try Fixture.device("synthetic_future_anc")
        let capability = try #require(device.noiseCancellingCapability)
        memory.record(.noiseCancelling(.transparency, NoiseCancellingControl(capability: capability, flag: "whatever")))
        let settings = memory.settingsToReapply(on: device)
        #expect(settings.map(\.argument) == ["--noise-cancelling=1"])
        #expect(memory.settingsToReapply(on: try Fixture.device("status_full")).isEmpty)
    }

    @Test func storePersistsPerDevice() throws {
        let suite = "hushdeck.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = RememberedSettingsStore(defaults: defaults)
        var a = RememberedSettings()
        a.record(.sidetone(10))
        a.record(.equalizer([-1.5, 0, 2]))
        store.save(a, for: "f00b:a00c")
        var b = RememberedSettings()
        b.record(.lights(true))
        store.save(b, for: "1038:12e0")

        let reloaded = RememberedSettingsStore(defaults: defaults)
        #expect(reloaded.settings(for: "f00b:a00c") == a)
        #expect(reloaded.settings(for: "1038:12e0") == b)
        #expect(reloaded.settings(for: "unknown").isEmpty)

        reloaded.forget("f00b:a00c")
        #expect(RememberedSettingsStore(defaults: defaults).settings(for: "f00b:a00c").isEmpty)
        #expect(RememberedSettingsStore(defaults: defaults).settings(for: "1038:12e0") == b)
    }
}
