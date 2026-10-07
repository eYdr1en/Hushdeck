import Foundation
@testable import HeadsetControlKit

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    static func output(_ name: String) throws -> HeadsetControlOutput {
        try HeadsetControlOutput.decode(from: data(name))
    }

    static func device(_ name: String) throws -> DeviceInfo {
        let output = try output(name)
        guard let device = output.devices.first else { throw CocoaError(.coderValueNotFound) }
        return device
    }
}

/// Returns canned results and records the arguments it was called with.
final class MockRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [CommandResult]
    private(set) var calls: [[String]] = []

    init(_ results: [CommandResult]) {
        queue = results
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult {
        try lock.withLock {
            calls.append(arguments)
            guard !queue.isEmpty else { throw HeadsetControlError.launchFailed("no canned result") }
            return queue.removeFirst()
        }
    }

    var recordedCalls: [[String]] { lock.withLock { calls } }
}

/// Locates the real CLI for live tests: $HEADSETCONTROL_BIN, then the usual places.
enum LiveBinary {
    static let url: URL? = {
        if let path = ProcessInfo.processInfo.environment["HEADSETCONTROL_BIN"],
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return BinaryLocator(overridePath: nil, bundleResourcesURL: nil).locate()?.url
    }()

    static var isAvailable: Bool { url != nil }
}
