import Foundation

/// Which vendor collection an input report came from.
public enum OmniReportCollection: String, Sendable, Hashable, Codable {
    /// Usage page 0xFFC0: query replies.
    case commands
    /// Usage page 0xFF00: unsolicited change events.
    case events
    /// The transport couldn't tell (both collections share the report ID).
    case unknown
}

public struct OmniInputReport: Sendable, Hashable {
    public let bytes: [UInt8]
    public let collection: OmniReportCollection

    public init(bytes: [UInt8], collection: OmniReportCollection) {
        self.bytes = bytes
        self.collection = collection
    }

    public var reportID: UInt8? { bytes.first }
    public var opcode: UInt8? { bytes.count > 1 ? bytes[1] : nil }
}

public enum OmniTransportEvent: Sendable, Hashable {
    /// A GameHub (1038:2290, interface 3) appeared. Sent again to each new subscriber if one is attached.
    case connected(OmniHubInfo)
    case disconnected
    /// Every input report from either collection, including query replies.
    case inputReport(OmniInputReport)
}

/// Moves bytes between OmniKit and one GameHub. Implementations: `IOKitOmniTransport` (real
/// hardware) and `SimulatedOmniTransport` (a stateful fake hub).
///
/// Safety: writes only accept `OmniOutputReport` / `OmniFeatureReport`, which can only be built
/// from allowlisted, range-checked typed commands. Implementations must still call
/// `OmniSafety.validateOutput` / `validateFeatureWrite` right before the bytes leave.
/// Callers must serialise access (`OmniChannel` does); transports are not required to.
public protocol OmniTransport: AnyObject, Sendable {
    /// Begins hot-plug monitoring. Idempotent.
    func start() async throws
    /// Stops monitoring and releases the device. Must return promptly and never hang.
    func stop() async
    /// A new subscription to hot-plug events and input reports. If a hub is attached, the stream
    /// starts with `.connected`.
    func events() -> AsyncStream<OmniTransportEvent>
    /// Sends a 64-byte output report (control SET_REPORT; the hub has no interrupt OUT endpoint).
    /// Clears the reply buffer first, so a following `receiveInputReport` only sees newer replies.
    func sendOutputReport(_ report: OmniOutputReport) async throws
    /// Waits for an input report on the command collection that `matching` accepts, including
    /// any that arrived since the last `sendOutputReport`.
    func receiveInputReport(timeout: Duration, matching: @escaping @Sendable (OmniInputReport) -> Bool) async throws -> OmniInputReport
    /// GET_FEATURE. The returned buffer starts with the report ID if the OS includes it.
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8]
    /// SET_FEATURE with a full 1036-byte block (EQ uploads only).
    func setFeatureReport(_ report: OmniFeatureReport) async throws
}

// MARK: - Shared plumbing for transports

/// Fan-out of values to any number of `AsyncStream` subscribers.
final class OmniBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func subscribe(initial: [Element] = []) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        for value in initial { continuation.yield(value) }
        lock.withLock { continuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ value: Element) {
        let targets = lock.withLock { Array(continuations.values) }
        for continuation in targets { continuation.yield(value) }
    }

    func finish() {
        let targets = lock.withLock {
            let all = Array(continuations.values)
            continuations.removeAll()
            return all
        }
        for continuation in targets { continuation.finish() }
    }
}

/// Buffers command-collection input reports and hands them to a waiting receiver. Used by both
/// transports to implement `receiveInputReport` without losing a reply that arrives early.
final class OmniReplyMailbox: @unchecked Sendable {
    private struct Waiter {
        let matching: @Sendable (OmniInputReport) -> Bool
        let continuation: CheckedContinuation<OmniInputReport, any Error>
    }

    private let lock = NSLock()
    private var buffer: [OmniInputReport] = []
    private var waiters: [UUID: Waiter] = [:]
    private static let bufferLimit = 64

    /// Drops buffered replies (called before each output report).
    func reset() {
        lock.withLock { buffer.removeAll() }
    }

    func deliver(_ report: OmniInputReport) {
        let waiter: Waiter? = lock.withLock {
            if let (id, waiter) = waiters.first(where: { $0.value.matching(report) }) {
                waiters.removeValue(forKey: id)
                return waiter
            }
            buffer.append(report)
            if buffer.count > Self.bufferLimit { buffer.removeFirst(buffer.count - Self.bufferLimit) }
            return nil
        }
        waiter?.continuation.resume(returning: report)
    }

    /// Fails every pending receive (disconnect / stop).
    func failAll(_ error: any Error) {
        let pending = lock.withLock {
            let all = Array(waiters.values)
            waiters.removeAll()
            buffer.removeAll()
            return all
        }
        for waiter in pending { waiter.continuation.resume(throwing: error) }
    }

    func receive(timeout: Duration, description: String,
                 matching: @escaping @Sendable (OmniInputReport) -> Bool) async throws -> OmniInputReport {
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.fail(id, with: OmniError.replyTimeout(query: description))
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OmniInputReport, any Error>) in
                let early: OmniInputReport? = lock.withLock {
                    if let index = buffer.firstIndex(where: matching) {
                        return buffer.remove(at: index)
                    }
                    waiters[id] = Waiter(matching: matching, continuation: continuation)
                    return nil
                }
                if let early { continuation.resume(returning: early) }
            }
        } onCancel: {
            self.fail(id, with: CancellationError())
        }
    }

    private func fail(_ id: UUID, with error: any Error) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.continuation.resume(throwing: error)
    }
}
