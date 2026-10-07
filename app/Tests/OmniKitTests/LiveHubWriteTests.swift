import Foundation
import Testing
@testable import OmniKit

/// Write round-trip against a real GameHub. For every allowlisted setting: read it, write a
/// different valid value, re-read everything from the hub, then restore the original and re-read
/// again. Never saves to flash and never writes EQs, so a power cycle undoes anything left over.
/// Opt in with `OMNIKIT_LIVE_WRITE=1 swift test --filter LiveHubWriteTests`.
@Suite("Live hub write round-trip", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["OMNIKIT_LIVE_WRITE"] == "1"))
struct LiveHubWriteTests {
    struct Result: CustomStringConvertible {
        let name: String, original: String, written: String, readBack: String, restored: String
        let accepted: Bool, restoredOK: Bool
        var description: String {
            "\(accepted && restoredOK ? "OK  " : "FAIL") \(name): \(original) -> \(written), read back \(readBack), restored \(restored)"
        }
    }

    @Test func everySettingRoundTrips() async throws {
        let device = OmniDevice(transport: IOKitOmniTransport(), configuration: .init(pollInterval: nil))
        try await device.start()
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if case .connected = await device.state.connection, await device.state.lastRefresh != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        var results: [Result] = []

        func check<V: Equatable>(_ name: String, _ keyPath: KeyPath<OmniSettings, V?>,
                                 alternative: (V) -> V, setting: (V) -> OmniSetting) async throws {
            let before = try await device.refresh()
            #expect(before.issues.isEmpty, "\(name): read issues \(before.issues)")
            guard let original = before.settings[keyPath: keyPath] else {
                Issue.record("\(name): not read from the hub"); return
            }
            let written = alternative(original)
            var readBack: V?
            do {
                try await device.apply(setting(written))
                try await Task.sleep(for: .milliseconds(300))
                let after = try await device.refresh()
                #expect(after.issues.isEmpty, "\(name): read issues \(after.issues)")
                readBack = after.settings[keyPath: keyPath]
            } catch {
                Issue.record("\(name): write failed: \(error)")
            }
            try await device.apply(setting(original))
            try await Task.sleep(for: .milliseconds(300))
            let restored = try await device.refresh().settings[keyPath: keyPath]
            let result = Result(name: name, original: "\(original)", written: "\(written)",
                                readBack: readBack.map { "\($0)" } ?? "nil", restored: restored.map { "\($0)" } ?? "nil",
                                accepted: readBack == written, restoredOK: restored == original)
            print(result)
            results.append(result)
        }

        let alt: (Int, Int, Int) -> Int = { v, a, b in v == a ? b : a }
        try await check("sidetone level", \.sidetone, alternative: { Sidetone(isEnabled: $0.isEnabled, level: alt($0.level, 5, 6)) }, setting: { .sidetone($0) })
        try await check("sidetone on/off", \.sidetone, alternative: { Sidetone(isEnabled: !$0.isEnabled, level: $0.level) }, setting: { .sidetone($0) })
        try await check("mic volume", \.micVolume, alternative: { alt($0, 5, 6) }, setting: { .micVolume($0) })
        try await check("mic noise reduction", \.micNoiseReduction, alternative: { $0 == .medium ? .low : .medium }, setting: { .micNoiseReduction($0) })
        try await check("muted-mic LED", \.mutedMicLEDBrightness, alternative: { alt($0, 5, 6) }, setting: { .mutedMicLEDBrightness($0) })
        try await check("ANC mode", \.ancMode, alternative: { $0 == .transparency ? .off : .transparency }, setting: { .ancMode($0) })
        try await check("ANC level", \.ancLevel, alternative: { $0 == .medium ? .low : .medium }, setting: { .ancLevel($0) })
        try await check("transparency level", \.transparencyLevel, alternative: { alt($0, 5, 6) }, setting: { .transparencyLevel($0) })
        try await check("auto-off", \.autoOff, alternative: { $0 == .fifteenMinutes ? .tenMinutes : .fifteenMinutes }, setting: { .autoOff($0) })
        try await check("volume limiter", \.volumeLimiter, alternative: { !$0 }, setting: { .volumeLimiter($0) })
        try await check("output mode", \.outputMode, alternative: { $0 == .speakers ? .streaming : .speakers }, setting: { .outputMode($0) })
        try await check("stream mix", \.streamMix, alternative: { StreamMix(main: $0.main, aux: alt($0.aux, 80, 70), mic: $0.mic) }, setting: { .streamMix($0) })
        try await check("OLED brightness", \.oledBrightness, alternative: { alt($0, 5, 6) }, setting: { .oledBrightness($0) })
        try await check("screensaver timer", \.screensaverTimeout, alternative: { $0 == .fifteenMinutes ? .tenMinutes : .fifteenMinutes }, setting: { .screensaverTimeout($0) })
        try await check("screensaver mode", \.screensaverMode, alternative: { $0 == .dim ? .screenOff : .dim }, setting: { .screensaverMode($0) })
        try await check("home view", \.homeScreenView, alternative: { $0 == .simple ? .detailed : .simple }, setting: { .homeScreenView($0) })
        try await check("home option", \.homeScreenOption, alternative: { $0 == .preset ? .stereo : .preset }, setting: { .homeScreenOption($0) })
        try await check("BT at power on", \.bluetoothPowerOnDefault, alternative: { !$0 }, setting: { .bluetoothPowerOnDefault($0) })
        try await check("BT call behaviour", \.bluetoothCallBehaviour, alternative: { $0 == .lowerOtherAudio ? .doNothing : .lowerOtherAudio }, setting: { .bluetoothCallBehaviour($0) })

        await device.stop()
        print("\n\(results.filter { $0.accepted && $0.restoredOK }.count)/\(results.count) settings round-tripped")
        for r in results where !(r.accepted && r.restoredOK) { Issue.record("\(r)") }
    }
}
