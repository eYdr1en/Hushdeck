import Foundation

public enum HeadsetControlError: Error, Sendable, Equatable, LocalizedError {
    case binaryNotFound
    case launchFailed(String)
    case timedOut(seconds: Double)
    /// The CLI exited non-zero without printing JSON (argument errors land here).
    case commandFailed(exitCode: Int32, message: String)
    case invalidOutput(String)
    case noDevice
    /// One or more setters were rejected by the device.
    case actionsFailed([ActionResult])

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "HeadsetControl isn’t installed."
        case .launchFailed(let reason):
            "Couldn’t start HeadsetControl: \(reason)"
        case .timedOut(let seconds):
            "HeadsetControl didn’t respond within \(Int(seconds)) s."
        case .commandFailed(_, let message):
            message.isEmpty ? "HeadsetControl reported an error." : message
        case .invalidOutput:
            "HeadsetControl returned output Hushdeck can’t read."
        case .noDevice:
            "No supported headset is connected."
        case .actionsFailed(let failures):
            failures.map { failure in
                let what = failure.capability.fallbackName.capitalizedFirst
                return "\(what): \(failure.errorMessage ?? "the headset rejected the change")."
            }.joined(separator: " ")
        }
    }
}

public struct HeadsetControlConfiguration: Sendable, Equatable {
    public enum TestDevice: Sendable, Equatable {
        case off
        /// `--test-device`, optionally with a profile (1 = errors, 2 = charging, 10 = limited…).
        case on(profile: Int?)
    }

    public var binary: URL
    public var testDevice: TestDevice
    public var timeout: Duration

    public init(binary: URL, testDevice: TestDevice = .off, timeout: Duration = .seconds(12)) {
        self.binary = binary
        self.testDevice = testDevice
        self.timeout = timeout
    }

    var baseArguments: [String] {
        switch testDevice {
        case .off: []
        case .on(nil): ["--test-device"]
        case .on(let profile?): ["--test-device=\(profile)"]
        }
    }
}

/// Talks to the HeadsetControl CLI. Invocations are strictly serialised: the actor
/// never has two `headsetcontrol` processes talking to the dongle at once.
public actor HeadsetControlClient {
    public nonisolated let configuration: HeadsetControlConfiguration
    private let runner: any CommandRunning
    private var tail: Task<Void, Never>?

    public init(configuration: HeadsetControlConfiguration, runner: any CommandRunning = ProcessRunner()) {
        self.configuration = configuration
        self.runner = runner
    }

    /// Reads everything the CLI can report (`headsetcontrol -o json`). No devices is
    /// a normal result (empty `devices`), not an error.
    public func status() async throws -> HeadsetControlOutput {
        try await invoke(["-o", "json"])
    }

    /// Applies setters in a single CLI call. Returns every action result; throws
    /// `.actionsFailed` only when *all* of them failed, so callers can record partial success.
    @discardableResult
    public func apply(_ settings: [HeadsetSetting], to device: DeviceID? = nil) async throws -> [ActionResult] {
        guard !settings.isEmpty else { return [] }
        var arguments = ["-o", "json"]
        if let device { arguments.append("--device=\(device.filterArgument)") }
        arguments += settings.map(\.argument)
        let output = try await invoke(arguments)
        if output.devices.isEmpty { throw HeadsetControlError.noDevice }
        let results = output.actions
        if !results.isEmpty, results.allSatisfy({ !$0.succeeded }) {
            throw HeadsetControlError.actionsFailed(results)
        }
        return results
    }

    /// `headsetcontrol --version`, e.g. "HeadsetControl 4.1.0-13-g25dadae".
    public func version() async throws -> String {
        let result = try await serialized { [runner, configuration] in
            try await runner.run(configuration.binary, arguments: ["--version"], timeout: configuration.timeout)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    private func invoke(_ arguments: [String]) async throws -> HeadsetControlOutput {
        let fullArguments = configuration.baseArguments + arguments
        let result = try await serialized { [runner, configuration] in
            try await runner.run(configuration.binary, arguments: fullArguments, timeout: configuration.timeout)
        }
        return try Self.interpret(result)
    }

    /// Maps a raw CLI result to output or a typed error. The CLI exits 1 with a valid
    /// JSON document when no device is present, and 0 even if an action failed.
    static func interpret(_ result: CommandResult) throws -> HeadsetControlOutput {
        let trimmed = result.stdout.drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        if trimmed.first == UInt8(ascii: "{") {
            do {
                return try HeadsetControlOutput.decode(from: Data(trimmed))
            } catch {
                throw HeadsetControlError.invalidOutput(String(describing: error))
            }
        }
        var message = result.stderrText
        if message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
        if message.isEmpty { message = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        throw HeadsetControlError.commandFailed(exitCode: result.exitCode, message: message)
    }

    /// Chains operations so each starts only after the previous one finished,
    /// even across actor re-entrancy at `await` points.
    private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
