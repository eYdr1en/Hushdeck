import Foundation
import Testing
@testable import OmniKit

/// Read-only check against a real GameHub: starts `OmniDevice` on the IOKit transport, waits for
/// the startup read, and prints the decoded state as JSON. Never writes. Opt in with
/// `OMNIKIT_LIVE_READ=1 swift test --filter LiveHubRead`.
@Suite("Live hub read", .enabled(if: ProcessInfo.processInfo.environment["OMNIKIT_LIVE_READ"] == "1"))
struct LiveHubReadTests {
    @Test func readsStateFromRealHub() async throws {
        let device = OmniDevice(transport: IOKitOmniTransport(), configuration: .init(pollInterval: nil))
        try await device.start()
        defer { Task { await device.stop() } }

        var state = await device.state
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            state = await device.state
            if state.lastRefresh != nil, case .connected = state.connection { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(state), as: UTF8.self))

        #expect(state.lastRefresh != nil, "startup read never completed")
        #expect(state.issues.isEmpty, "sections failed to read: \(state.issues)")
    }
}
