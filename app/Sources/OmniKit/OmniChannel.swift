import Foundation

/// The single serialisation point between `OmniDevice` and a transport.
///
/// - Every transfer (output report, GET_FEATURE, SET_FEATURE) runs one at a time, in call order.
/// - Transfers are at least `OmniTiming.minimumCommandSpacing` (50 ms) apart. Not configurable.
/// - Save-to-flash waits `saveDelay` (≥ 50 ms, default 500 ms) after the last settings write.
/// - Packets are built (and so validated) before the lock is taken: a blocked opcode, an
///   out-of-range value or an EQ write with the flag off throws without touching the transport.
public actor OmniChannel {
    public nonisolated let transport: any OmniTransport
    public private(set) var policy: OmniWritePolicy
    public nonisolated let saveDelay: Duration

    private let clock = ContinuousClock()
    private var lastTransferEnd: ContinuousClock.Instant?
    private var lastSettingWrite: ContinuousClock.Instant?
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    public init(transport: any OmniTransport, policy: OmniWritePolicy = .init(), saveDelay: Duration = OmniTiming.saveDelay) {
        self.transport = transport
        self.policy = policy
        self.saveDelay = max(saveDelay, OmniTiming.minimumCommandSpacing)
    }

    public func setPolicy(_ policy: OmniWritePolicy) {
        self.policy = policy
    }

    /// Sends one allowlisted setting.
    public func send(_ setting: OmniSetting) async throws {
        let report = try setting.outputReport()
        try await exclusive {
            try await self.transfer { try await self.transport.sendOutputReport(report) }
            self.lastSettingWrite = self.clock.now
        }
    }

    /// Save-to-flash (`01 09`), no sooner than `saveDelay` after the last settings write.
    public func saveToFlash() async throws {
        let report = OmniOutputReport.saveToFlash()
        try await exclusive {
            if let last = self.lastSettingWrite {
                try await Task.sleep(until: last.advanced(by: self.saveDelay), clock: self.clock)
            }
            try await self.transfer { try await self.transport.sendOutputReport(report) }
        }
    }

    /// Runs a read query and returns the raw reply (64-byte input report or feature buffer).
    public func query(_ query: OmniQuery, timeout: Duration = OmniTiming.replyTimeout) async throws -> [UInt8] {
        let report = try query.outputReport()
        return try await exclusive {
            try await self.transfer { try await self.transport.sendOutputReport(report) }
            switch query.replyKind {
            case .inputReport:
                let opcode = query.opcode
                let reply = try await self.transport.receiveInputReport(timeout: timeout) { report in
                    report.collection != .events && report.reportID == OmniUSB.reportID && report.opcode == opcode
                }
                return reply.bytes
            case .featureReport:
                return try await self.transfer {
                    try await self.transport.getFeatureReport(reportID: OmniUSB.reportID, length: OmniUSB.featureReportLength)
                }
            }
        }
    }

    /// Uploads an EQ. Throws `experimentalEQWritesDisabled` unless the policy allows it.
    public func writeWirelessEQ(_ eq: WirelessEQ) async throws {
        try await writeFeature(eq.featureReport(policy: policy))
    }

    public func writeGraphicEQ<P: GraphicEQPreset>(_ eq: GraphicEQ<P>) async throws {
        try await writeFeature(eq.featureReport(policy: policy))
    }

    private func writeFeature(_ report: OmniFeatureReport) async throws {
        try await exclusive {
            try await self.transfer { try await self.transport.setFeatureReport(report) }
            self.lastSettingWrite = self.clock.now
        }
    }

    // MARK: - Pacing and exclusion

    private func transfer<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if let last = lastTransferEnd {
            try await Task.sleep(until: last.advanced(by: OmniTiming.minimumCommandSpacing), clock: clock)
        }
        defer { lastTransferEnd = clock.now }
        return try await body()
    }

    private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty {
            busy = false
        } else {
            queue.removeFirst().resume() // Ownership passes straight to the next waiter.
        }
    }
}
