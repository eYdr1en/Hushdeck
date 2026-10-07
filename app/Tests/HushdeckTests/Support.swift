import Foundation
import OmniKit
import Testing
@testable import Hushdeck

struct WaitTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` on the main actor until it holds.
@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { throw WaitTimeout(what: what) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// No settle delay, no polling, quick save.
func testOmniConfiguration(experimentalEQWrites: Bool = false) -> OmniDevice.Configuration {
    OmniDevice.Configuration(experimentalEQWrites: experimentalEQWrites, startupSettle: .zero, pollInterval: nil,
                             saveDelay: .milliseconds(60), replyTimeout: .milliseconds(500))
}

/// A throwaway UserDefaults domain so tests never touch the real profiles or settings.
func scratchDefaults() -> UserDefaults {
    let name = "hushdeck.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Records notifications instead of posting them.
@MainActor
final class NullNotifier: Notifying {
    var posted: [(identifier: String, title: String, body: String)] = []
    func permission() async -> NotificationPermission { .authorized }
    func requestPermission() async -> NotificationPermission { .authorized }
    func post(identifier: String, threadIdentifier: String, title: String, body: String) async throws {
        posted.append((identifier, title, body))
    }
}

/// A started controller on a simulated hub, after its first full read.
@MainActor
func readyController(_ sim: SimulatedOmniTransport = SimulatedOmniTransport(),
                     experimentalEQWrites: Bool = false,
                     defaults: UserDefaults = scratchDefaults()) async throws -> OmniController {
    let omni = OmniController(transport: sim, configuration: testOmniConfiguration(experimentalEQWrites: experimentalEQWrites), defaults: defaults)
    omni.start()
    try await waitUntil("initial refresh") { omni.isReady && omni.state.lastRefresh != nil }
    return omni
}
