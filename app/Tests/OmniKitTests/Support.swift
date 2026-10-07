import Foundation
import Testing
@testable import OmniKit

struct TestTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Waits for the first published state that satisfies `predicate`.
@discardableResult
func waitForState(_ device: OmniDevice, _ what: String = "state", timeout: Duration = .seconds(5),
                  _ predicate: @escaping @Sendable (OmniState) -> Bool) async throws -> OmniState {
    let stream = await device.updates()
    return try await withThrowingTaskGroup(of: OmniState?.self) { group in
        group.addTask {
            for await state in stream where predicate(state) { return state }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        guard let first else { throw TestTimeout(what: what) }
        return first
    }
}

/// Test configuration: no settle delay, no polling unless asked.
func testConfiguration(experimentalEQWrites: Bool = false, pollInterval: Duration? = nil) -> OmniDevice.Configuration {
    OmniDevice.Configuration(experimentalEQWrites: experimentalEQWrites, startupSettle: .zero, pollInterval: pollInterval,
                             saveDelay: .milliseconds(60), replyTimeout: .milliseconds(300))
}

/// A started device on a simulated hub, after its initial refresh.
func connectedDevice(_ sim: SimulatedOmniTransport = SimulatedOmniTransport(),
                     configuration: OmniDevice.Configuration = testConfiguration()) async throws -> OmniDevice {
    let device = OmniDevice(transport: sim, configuration: configuration)
    try await device.start()
    try await waitForState(device, "initial refresh") { $0.connection.isReady && $0.lastRefresh != nil }
    return device
}

enum Fixture {
    static func data(_ name: String, ext: String = "json") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/\(name).\(ext)"])
        }
        return try Data(contentsOf: url)
    }
}

/// Builds a 64-byte report from leading bytes.
func report(_ bytes: [UInt8], length: Int = 64) -> [UInt8] {
    bytes + [UInt8](repeating: 0, count: max(0, length - bytes.count))
}
