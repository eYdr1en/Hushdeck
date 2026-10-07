import Foundation

/// A stateful fake GameHub behind the `OmniTransport` protocol. It answers every query with a
/// correctly formed reply built from `SimulatedGameHub`, applies writes to that state, emits hub
/// events on demand (or on a timer in demo mode) and records every packet it is sent.
///
/// The app uses it when `HUSHDECK_SIMULATED_OMNI=1` (see `OmniTransportFactory`).
public final class SimulatedOmniTransport: OmniTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The hub is attached as soon as the transport starts.
        public var startsAttached: Bool
        /// Echo host writes on the event collection (protocol-notes §6.4 is open; default off so
        /// OmniKit is exercised without relying on echoes).
        public var echoesHostWrites: Bool
        /// Feature replies without the leading report ID (exercises the ±1 offset handling).
        public var featureRepliesOmitReportID: Bool
        /// Byte 0 of event reports (unconfirmed on hardware).
        public var eventReportID: UInt8
        /// Demo mode: battery drain, spare charging, occasional mic-mute toggles and hot swaps.
        public var autonomousActivityInterval: Duration?
        /// If set, `receiveInputReport` never gets a reply for these opcodes (timeout tests).
        public var silentQueryOpcodes: Set<UInt8>

        public init(startsAttached: Bool = true, echoesHostWrites: Bool = false, featureRepliesOmitReportID: Bool = false,
                    eventReportID: UInt8 = 0x01, autonomousActivityInterval: Duration? = nil, silentQueryOpcodes: Set<UInt8> = []) {
            self.startsAttached = startsAttached
            self.echoesHostWrites = echoesHostWrites
            self.featureRepliesOmitReportID = featureRepliesOmitReportID
            self.eventReportID = eventReportID
            self.autonomousActivityInterval = autonomousActivityInterval
            self.silentQueryOpcodes = silentQueryOpcodes
        }

        /// What the app uses for `HUSHDECK_SIMULATED_OMNI=1`.
        public static let demo = Configuration(echoesHostWrites: true, autonomousActivityInterval: .seconds(15))
    }

    public enum PacketKind: String, Sendable, Hashable {
        case outputReport
        case getFeature
        case setFeature
    }

    public struct Packet: Sendable, Hashable, CustomStringConvertible {
        public let kind: PacketKind
        /// Full bytes for output/set-feature; `[reportID]` for get-feature.
        public let bytes: [UInt8]
        public let at: ContinuousClock.Instant

        public var opcode: UInt8? { bytes.count > 1 ? bytes[1] : nil }
        public var description: String { "\(kind.rawValue) \(OmniHex.trimmed(bytes))" }
    }

    public let configuration: Configuration
    public let hubInfo: OmniHubInfo

    private let lock = NSLock()
    private var hubState: SimulatedGameHub
    private var attached: Bool
    private var running = false
    private var packets: [Packet] = []
    private var pendingFeatureReply: [UInt8]?
    private var autonomousTask: Task<Void, Never>?
    private var tick = 0
    private let broadcaster = OmniBroadcaster<OmniTransportEvent>()
    private let mailbox = OmniReplyMailbox()

    public init(hub: SimulatedGameHub = SimulatedGameHub(), configuration: Configuration = .init()) {
        self.hubState = hub
        self.configuration = configuration
        self.attached = configuration.startsAttached
        self.hubInfo = OmniHubInfo(productName: "Arctis Nova Pro Omni (simulated)", usbSerialNumber: "SIMULATED",
                                   releaseNumber: 0x0132, isSimulated: true)
    }

    // MARK: Inspection

    public var hub: SimulatedGameHub { lock.withLock { hubState } }
    public var isHubAttached: Bool { lock.withLock { attached } }
    public var isRunning: Bool { lock.withLock { running } }
    public var sentPackets: [Packet] { lock.withLock { packets } }
    public var sentOutputReports: [[UInt8]] { sentPackets.filter { $0.kind == .outputReport }.map(\.bytes) }
    public func clearRecordedPackets() { lock.withLock { packets.removeAll() } }

    /// Changes hub state silently (no events), e.g. to set up a test.
    public func updateHub(_ change: (inout SimulatedGameHub) -> Void) {
        lock.withLock { change(&hubState) }
    }

    // MARK: OmniTransport

    public func start() async throws {
        let announce: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            return attached
        }
        if announce { broadcaster.yield(.connected(hubInfo)) }
        if let interval = configuration.autonomousActivityInterval {
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    self.autonomousTick()
                }
            }
            lock.withLock { autonomousTask = task }
        }
    }

    public func stop() async {
        let task: Task<Void, Never>? = lock.withLock {
            running = false
            defer { autonomousTask = nil }
            return autonomousTask
        }
        task?.cancel()
        mailbox.failAll(OmniError.transportStopped)
    }

    public func events() -> AsyncStream<OmniTransportEvent> {
        let initial: [OmniTransportEvent] = lock.withLock { running && attached ? [.connected(hubInfo)] : [] }
        return broadcaster.subscribe(initial: initial)
    }

    public func sendOutputReport(_ report: OmniOutputReport) async throws {
        try OmniSafety.validateOutput(report.bytes)
        let bytes = report.bytes
        mailbox.reset()
        let effects: (reply: [UInt8]?, echo: [UInt8]?) = try lock.withLock {
            try checkReady()
            packets.append(Packet(kind: .outputReport, bytes: bytes, at: .now))
            return process(bytes)
        }
        if let reply = effects.reply {
            let input = OmniInputReport(bytes: reply, collection: .commands)
            mailbox.deliver(input)
            broadcaster.yield(.inputReport(input))
        }
        if let echo = effects.echo { emitEvent(echo) }
    }

    public func receiveInputReport(timeout: Duration, matching: @escaping @Sendable (OmniInputReport) -> Bool) async throws -> OmniInputReport {
        try lock.withLock { try checkReady() }
        return try await mailbox.receive(timeout: timeout, description: "simulated reply", matching: matching)
    }

    public func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] {
        try lock.withLock {
            try checkReady()
            packets.append(Packet(kind: .getFeature, bytes: [reportID], at: .now))
            var reply = pendingFeatureReply ?? [reportID]
            pendingFeatureReply = nil
            if configuration.featureRepliesOmitReportID { reply.removeFirst() }
            return Array(reply.prefix(length))
        }
    }

    public func setFeatureReport(_ report: OmniFeatureReport) async throws {
        try OmniSafety.validateFeatureWrite(report.bytes)
        try lock.withLock {
            try checkReady()
            packets.append(Packet(kind: .setFeature, bytes: report.bytes, at: .now))
            hubState.applyFeatureWrite(report.bytes)
        }
    }

    // MARK: Hub-side simulation (each emits the event the real hub would)

    /// Headset battery drops (event 0xB7).
    public func simulateBatteryDrain(by percent: Int = 1) {
        lock.withLock { hubState.headsetBattery = UInt8(max(0, Int(hubState.headsetBattery) - percent)) }
        emitBatteryEvent()
    }

    public func simulateBattery(headset: Int, spare: Int, charging: ChargingState) {
        lock.withLock {
            hubState.headsetBattery = UInt8(clamping: headset)
            hubState.spareBattery = UInt8(clamping: spare)
            hubState.charging = charging.rawValue
        }
        emitBatteryEvent()
    }

    /// Hot swap: the spare goes into the headset and the drained one starts charging in the hub.
    public func simulateBatteryHotSwap() {
        lock.withLock {
            let drained = hubState.headsetBattery
            hubState.headsetBattery = hubState.spareBattery
            hubState.spareBattery = drained
        }
        emitBatteryEvent()
    }

    /// The headset's mute button (event 0xBB). Returns the new mute state.
    @discardableResult
    public func simulateMicMuteToggle() -> Bool {
        let muted: Bool = lock.withLock {
            hubState.micMuted = hubState.micMuted == 0 ? 1 : 0
            return hubState.micMuted == 1
        }
        emitEvent([0xBB, muted ? 1 : 0])
        return muted
    }

    /// Headset power button: link 8/4 and charging 8/1 (events 0xB5 and 0xB7).
    public func simulateHeadsetPower(on: Bool) {
        let bytes: [UInt8] = lock.withLock {
            hubState.headsetLink = on ? HeadsetLinkState.connected.rawValue : HeadsetLinkState.disconnected.rawValue
            hubState.charging = on ? ChargingState.discharging.rawValue : ChargingState.unknown.rawValue
            return [0xB5, hubState.bluetoothMode, hubState.bluetoothLink, hubState.headsetLink]
        }
        emitEvent(bytes)
        emitBatteryEvent()
    }

    public func simulateBluetooth(mode: BluetoothMode, link: BluetoothLinkStatus) {
        let bytes: [UInt8] = lock.withLock {
            hubState.bluetoothMode = mode.rawValue
            hubState.bluetoothLink = link.rawValue
            return [0xB5, hubState.bluetoothMode, hubState.bluetoothLink, hubState.headsetLink]
        }
        emitEvent(bytes)
    }

    /// A change made on the hub's knob / OLED menu: applied, then echoed on the event collection.
    public func simulateHubChange(_ setting: OmniSetting) {
        let bytes = [OmniUSB.reportID, setting.opcode] + setting.arguments
        lock.withLock { _ = hubState.applySettingWrite(SimulatedGameHub.pad(bytes, to: OmniUSB.outputReportLength)) }
        emitEvent(Array(bytes.dropFirst()))
    }

    /// The ChatMix dial (event 0x45).
    public func simulateChatMixDial(game: Int, chat: Int) {
        lock.withLock {
            hubState.chatMixGame = UInt8(clamping: game)
            hubState.chatMixChat = UInt8(clamping: chat)
        }
        emitEvent([0x45, UInt8(clamping: game), UInt8(clamping: chat)])
    }

    /// Audio source change (event 0x23).
    public func simulateAudioInput(_ input: Int) {
        lock.withLock { hubState.audioInput = UInt8(clamping: input) }
        emitEvent([0x23, UInt8(clamping: input)])
    }

    /// An EQ preset picked on the OLED (events 0x1B / 0x1D / 0x1F).
    public func simulateEQPresetChangeOnHub(_ kind: OmniEqualizerKind, presetIndex: UInt8) {
        let opcode: UInt8 = lock.withLock {
            switch kind {
            case .wireless: hubState.wirelessEQ.presetIndex = presetIndex; return 0x1B
            case .mic: hubState.micEQ.presetIndex = presetIndex; return 0x1D
            case .bluetooth: hubState.bluetoothEQ.presetIndex = presetIndex; return 0x1F
            }
        }
        emitEvent([opcode])
    }

    /// USB unplug: pending reads fail and subscribers get `.disconnected`.
    public func simulateHubDisconnect() {
        let wasAttached: Bool = lock.withLock {
            defer { attached = false }
            return attached
        }
        guard wasAttached else { return }
        mailbox.failAll(OmniError.notConnected)
        broadcaster.yield(.disconnected)
    }

    public func simulateHubReconnect() {
        let announce: Bool = lock.withLock {
            guard !attached else { return false }
            attached = true
            return running
        }
        if announce { broadcaster.yield(.connected(hubInfo)) }
    }

    /// Emits an arbitrary event payload (opcode first) on the event collection.
    public func emitEvent(_ payload: [UInt8]) {
        let running = lock.withLock { self.running && attached }
        guard running else { return }
        let bytes = SimulatedGameHub.pad([configuration.eventReportID] + payload, to: OmniUSB.outputReportLength)
        broadcaster.yield(.inputReport(OmniInputReport(bytes: bytes, collection: .events)))
    }

    // MARK: Internals

    private func checkReady() throws {
        guard running else { throw OmniError.transportStopped }
        guard attached else { throw OmniError.notConnected }
    }

    /// Called with the lock held. Returns an input-report reply and/or an echo payload.
    private func process(_ bytes: [UInt8]) -> (reply: [UInt8]?, echo: [UInt8]?) {
        let opcode = bytes[1]
        if configuration.silentQueryOpcodes.contains(opcode) { return (nil, nil) }
        switch opcode {
        case 0xB0: return (hubState.statusReport(), nil)
        case 0x10: return (hubState.firmwareReport(), nil)
        case 0x12: return (hubState.serialReport(), nil)
        case 0x80: return (hubState.displayReport(), nil)
        case 0x20: pendingFeatureReply = hubState.audioSettingsFeature()
        case 0x1A: pendingFeatureReply = hubState.wirelessEQFeature()
        case 0x1E: pendingFeatureReply = hubState.graphicEQFeature(hubState.bluetoothEQ)
        case 0x1C: pendingFeatureReply = hubState.graphicEQFeature(hubState.micEQ)
        case 0x18:
            if let slot = OmniPresetNameSlot(rawValue: bytes[2]) { pendingFeatureReply = hubState.presetNameFeature(slot) }
        case OmniSafety.saveOpcode:
            hubState.saveCount += 1
            hubState.lastSavedSnapshot = hubState.settingsSnapshot
        default:
            if hubState.applySettingWrite(bytes), configuration.echoesHostWrites {
                return (nil, Array(bytes[1...]))
            }
        }
        return (nil, nil)
    }

    private func emitBatteryEvent() {
        let bytes: [UInt8] = lock.withLock { [0xB7, hubState.headsetBattery, hubState.spareBattery, hubState.charging] }
        emitEvent(bytes)
    }

    private func autonomousTick() {
        let (tick, battery, spare) = lock.withLock { () -> (Int, UInt8, UInt8) in
            self.tick += 1
            if hubState.spareBattery < 100 { hubState.spareBattery += 1 }
            return (self.tick, hubState.headsetBattery, hubState.spareBattery)
        }
        if battery <= 5 && spare > battery {
            simulateBatteryHotSwap()
        } else {
            simulateBatteryDrain(by: 1)
        }
        if tick.isMultiple(of: 4) { simulateMicMuteToggle() }
    }
}
