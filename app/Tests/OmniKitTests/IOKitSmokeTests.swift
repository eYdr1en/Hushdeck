import Foundation
import IOKit
import IOKit.hid
import Testing
@testable import OmniKit

/// Runs the real IOKit transport. Nothing is plugged in on CI / the dev machine, so it must find
/// no hub and shut down promptly. Set OMNIKIT_EXPECT_HUB=1 to run it with a GameHub attached.
@Suite("IOKit transport smoke test", .serialized)
struct IOKitSmokeTests {
    /// OMNIKIT_EXPECT_HUB=1/0 forces the expectation; otherwise it follows what's plugged in.
    let expectHub: Bool = switch ProcessInfo.processInfo.environment["OMNIKIT_EXPECT_HUB"] {
    case "1": true
    case "0": false
    default: Self.hubInRegistry()
    }

    static func hubInRegistry() -> Bool {
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDVendorIDKey] = OmniUSB.vendorID
        matching[kIOHIDProductIDKey] = OmniUSB.gameHubProductID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }

    @Test func startsFindsNoHubAndStopsCleanly() async throws {
        let transport = IOKitOmniTransport()
        let clock = ContinuousClock()
        try await transport.start()
        #expect(transport.isRunning)
        try await transport.start() // idempotent

        // Matching callbacks for already-attached devices arrive right after activation.
        try await Task.sleep(for: .milliseconds(500))
        #expect(transport.isHubAttached == expectHub)
        if !expectHub {
            #expect(transport.hubInfo == nil)
            await #expect(throws: OmniError.notConnected) { try await transport.sendOutputReport(OmniQuery.status.outputReport()) }
            await #expect(throws: OmniError.notConnected) {
                try await transport.receiveInputReport(timeout: .milliseconds(10)) { _ in true }
            }
            await #expect(throws: OmniError.notConnected) { _ = try await transport.getFeatureReport(reportID: 1, length: 1036) }
        }

        let stopStart = clock.now
        await transport.stop()
        let stopTook = stopStart.duration(to: clock.now)
        #expect(stopTook < .seconds(1.5), "the cancel handler should run; the 2 s fallback must not be needed (took \(stopTook))")
        #expect(!transport.isRunning)
        await #expect(throws: OmniError.transportStopped) { try await transport.sendOutputReport(OmniQuery.status.outputReport()) }
        await transport.stop() // idempotent

        // It can be started again after a stop.
        try await transport.start()
        #expect(transport.isRunning)
        await transport.stop()
        #expect(!transport.isRunning)
    }

    @Test func omniDeviceOverIOKitStaysSearching() async throws {
        guard !expectHub else { return }
        let device = OmniDevice(transport: IOKitOmniTransport(), configuration: .init(pollInterval: .milliseconds(100)))
        try await device.start()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await device.connection == .searching)
        await #expect(throws: OmniError.notConnected) { try await device.refresh() }
        await device.stop()
        #expect(await device.connection == .stopped)
    }
}
