import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Abstraction over running a subprocess, so the client can be tested with canned output.
public protocol CommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult
}

/// Runs a process off the cooperative thread pool, drains both pipes concurrently
/// (so a chatty child can't deadlock on a full pipe), and terminates it on timeout
/// or task cancellation.
public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try handle.runBlocking(executable: executable, arguments: arguments, timeout: timeout)
                    })
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// Owns one `Process`. All mutable state is guarded by `lock`.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    func runBlocking(executable: URL, arguments: [String], timeout: Duration) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Keep the CLI's output plain.
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try lock.withLock {
            if cancelled { throw CancellationError() }
            self.process = process
            do {
                try process.run()
            } catch {
                throw HeadsetControlError.launchFailed(error.localizedDescription)
            }
        }

        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if let running = self.process, running.isRunning {
                    self.timedOut = true
                    running.terminate()
                }
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)

        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        timer.cancel()

        let (wasCancelled, wasTimedOut) = lock.withLock { (cancelled, timedOut) }
        if wasCancelled { throw CancellationError() }
        if wasTimedOut { throw HeadsetControlError.timedOut(seconds: seconds) }
        return CommandResult(exitCode: process.terminationStatus, stdout: stdoutData, stderr: stderrBox.get())
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
