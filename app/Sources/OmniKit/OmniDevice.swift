import Foundation

/// The typed front door to one Omni GameHub.
///
/// ```swift
/// let device = OmniDevice(transport: OmniTransportFactory.makeDefault())
/// await device.start()
/// for await state in await device.updates() { … }
/// try await device.setANCMode(.activeNoiseCancellation)
/// try await device.saveToDevice()
/// ```
///
/// State is driven by hub events (usage page 0xFF00) with a status poll as a fallback. Setters
/// are fire-and-forget like GG's: the local state is updated after the write is sent, and the next
/// event or poll confirms it. Writes are only accepted while `connection` is `.connected`.
public actor OmniDevice {
    public struct Configuration: Sendable, Equatable {
        /// Allows EQ uploads (SET_FEATURE). Off by default; the layout is unconfirmed.
        public var experimentalEQWrites: Bool
        /// Quiet period after the hub enumerates (GG: 5 s).
        public var startupSettle: Duration
        /// Status poll interval while connected; `nil` disables polling.
        public var pollInterval: Duration?
        /// Wait before save-to-flash after the last write (GG: 500 ms, minimum 50 ms).
        public var saveDelay: Duration
        public var replyTimeout: Duration
        /// Re-read the full state when the headset reconnects (GG re-syncs on reconnect).
        public var refreshOnHeadsetReconnect: Bool

        public init(experimentalEQWrites: Bool = false, startupSettle: Duration = OmniTiming.startupSettle,
                    pollInterval: Duration? = .seconds(20), saveDelay: Duration = OmniTiming.saveDelay,
                    replyTimeout: Duration = OmniTiming.replyTimeout, refreshOnHeadsetReconnect: Bool = true) {
            self.experimentalEQWrites = experimentalEQWrites
            self.startupSettle = startupSettle
            self.pollInterval = pollInterval
            self.saveDelay = saveDelay
            self.replyTimeout = replyTimeout
            self.refreshOnHeadsetReconnect = refreshOnHeadsetReconnect
        }
    }

    public nonisolated let transport: any OmniTransport
    public private(set) var configuration: Configuration
    public private(set) var state = OmniState()

    private let channel: OmniChannel
    private let stateStream = OmniBroadcaster<OmniState>()
    private let eventStream = OmniBroadcaster<OmniEvent>()
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var generation = 0

    public init(transport: any OmniTransport, configuration: Configuration = .init()) {
        self.transport = transport
        self.configuration = configuration
        self.channel = OmniChannel(transport: transport, policy: OmniWritePolicy(experimentalEQWrites: configuration.experimentalEQWrites),
                                   saveDelay: configuration.saveDelay)
        state.experimentalEQWrites = configuration.experimentalEQWrites
    }

    // MARK: - Lifecycle

    /// Starts watching for the hub. Safe to call again after `stop()`.
    public func start() async throws {
        guard eventTask == nil else { return }
        let stream = transport.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        state.connection = .searching
        publish()
        do {
            try await transport.start()
        } catch {
            await stop()
            throw error
        }
        startPolling()
    }

    public func stop() async {
        generation += 1
        eventTask?.cancel()
        pollTask?.cancel()
        settleTask?.cancel()
        eventTask = nil
        pollTask = nil
        settleTask = nil
        await transport.stop()
        let flags = state.experimentalEQWrites
        state = OmniState()
        state.experimentalEQWrites = flags
        publish()
    }

    /// Current state first, then every change.
    public func updates() -> AsyncStream<OmniState> {
        stateStream.subscribe(initial: [state])
    }

    /// Decoded hub events as they arrive (for toasts, e.g. mic mute).
    public func events() -> AsyncStream<OmniEvent> {
        eventStream.subscribe()
    }

    public var connection: OmniConnectionState { state.connection }

    public func setExperimentalEQWrites(_ enabled: Bool) async {
        configuration.experimentalEQWrites = enabled
        await channel.setPolicy(OmniWritePolicy(experimentalEQWrites: enabled))
        state.experimentalEQWrites = enabled
        publish()
    }

    // MARK: - Reads

    /// Reads everything GG reads at startup: status, preset names, audio settings, the three EQs,
    /// OLED settings, firmware and serial. Only the status read is required; a section that
    /// fails is noted in `state.issues`.
    @discardableResult
    public func refresh() async throws -> OmniState {
        try requireReady()
        var issues: [String] = []
        try await refreshStatus(publishing: false)

        for slot: OmniPresetNameSlot in [.wirelessCustom, .wirelessGame, .bluetoothCustom, .micCustom] {
            await attempt(.presetName(slot), into: &issues) { self.state.equalizers.store(try OmniPresetName(report: $0)) }
        }
        await attempt(.audioSettings, into: &issues) { self.state.apply(try OmniAudioSettings(report: $0)) }
        await attempt(.wirelessEQ, into: &issues) { self.state.equalizers.wireless = try WirelessEQ(report: $0) }
        await attempt(.bluetoothEQ, into: &issues) { self.state.equalizers.bluetooth = try BluetoothEQ(report: $0) }
        await attempt(.micEQ, into: &issues) { self.state.equalizers.mic = try MicEQ(report: $0) }
        await attempt(.displaySettings, into: &issues) { self.state.apply(try OmniDisplaySettings(report: $0)) }
        await attempt(.firmwareVersions, into: &issues) { self.state.info.firmware = try OmniFirmwareVersions(report: $0) }
        await attempt(.serialNumber, into: &issues) { self.state.info.serialNumber = try OmniSerialReply.decode($0) }

        state.issues = issues
        state.lastRefresh = Date()
        publish()
        return state
    }

    /// Reads only the status reply (battery, charging, links, ANC, mic mute…). This is the poll.
    public func refreshStatus() async throws {
        try requireReady()
        try await refreshStatus(publishing: true)
    }

    /// Re-reads one EQ (after a 0x1B/0x1D/0x1F event, or on demand).
    public func refreshEqualizer(_ kind: OmniEqualizerKind) async throws {
        try requireReady()
        switch kind {
        case .wireless: state.equalizers.wireless = try WirelessEQ(report: await read(.wirelessEQ))
        case .bluetooth: state.equalizers.bluetooth = try BluetoothEQ(report: await read(.bluetoothEQ))
        case .mic: state.equalizers.mic = try MicEQ(report: await read(.micEQ))
        }
        publish()
    }

    public func refreshFirmwareVersions() async throws {
        try requireReady()
        state.info.firmware = try OmniFirmwareVersions(report: await read(.firmwareVersions))
        publish()
    }

    // MARK: - Writes

    /// Sends one allowlisted setting and updates the local state.
    public func apply(_ setting: OmniSetting) async throws {
        try setting.validate()
        try requireReady()
        try await channel.send(setting)
        state.settings.apply(setting)
        publish()
    }

    /// Deploys several settings (a profile), then optionally saves to flash like GG does.
    public func apply(_ settings: [OmniSetting], saveToDevice save: Bool) async throws {
        for setting in settings { try setting.validate() }
        for setting in settings { try await apply(setting) }
        if save { try await saveToDevice() }
    }

    /// Save-to-flash (`01 09`), sent at least `saveDelay` after the last write.
    public func saveToDevice() async throws {
        try requireReady()
        try await channel.saveToFlash()
    }

    public func setSidetone(_ sidetone: Sidetone) async throws { try await apply(.sidetone(sidetone)) }
    /// Toggles sidetone and keeps the current level (GG keeps it when switching off).
    public func setSidetoneEnabled(_ enabled: Bool) async throws {
        let level = state.settings.sidetone?.level ?? 5
        try await apply(.sidetone(Sidetone(isEnabled: enabled, level: level)))
    }
    public func setMicVolume(_ level: Int) async throws { try await apply(.micVolume(level)) }
    public func setMicNoiseReduction(_ value: MicNoiseReduction) async throws { try await apply(.micNoiseReduction(value)) }
    public func setMutedMicLEDBrightness(_ level: Int) async throws { try await apply(.mutedMicLEDBrightness(level)) }
    public func setANCMode(_ mode: ANCMode) async throws { try await apply(.ancMode(mode)) }
    public func setANCLevel(_ level: ANCLevel) async throws { try await apply(.ancLevel(level)) }
    public func setTransparencyLevel(_ level: Int) async throws { try await apply(.transparencyLevel(level)) }
    public func setAutoOff(_ timeout: OmniTimeout) async throws { try await apply(.autoOff(timeout)) }
    public func setVolumeLimiter(_ enabled: Bool) async throws { try await apply(.volumeLimiter(enabled)) }
    public func setOutputMode(_ mode: OutputMode) async throws { try await apply(.outputMode(mode)) }
    public func setStreamMix(_ mix: StreamMix) async throws { try await apply(.streamMix(mix)) }
    public func setOLEDBrightness(_ level: Int) async throws { try await apply(.oledBrightness(level)) }
    public func setScreensaverTimeout(_ timeout: OmniTimeout) async throws { try await apply(.screensaverTimeout(timeout)) }
    public func setScreensaverMode(_ mode: ScreensaverMode) async throws { try await apply(.screensaverMode(mode)) }
    public func setHomeScreenView(_ view: HomeScreenView) async throws { try await apply(.homeScreenView(view)) }
    public func setHomeScreenOption(_ option: HomeScreenOption) async throws { try await apply(.homeScreenOption(option)) }
    public func setBluetoothPowerOnDefault(_ enabled: Bool) async throws { try await apply(.bluetoothPowerOnDefault(enabled)) }
    public func setBluetoothCallBehaviour(_ behaviour: BluetoothCallBehaviour) async throws {
        try await apply(.bluetoothCallBehaviour(behaviour))
    }

    /// Uploads the 2.4 GHz EQ (preset index, names and bands in one write). Experimental.
    public func setWirelessEQ(_ eq: WirelessEQ) async throws {
        try preflightEQ { try eq.featureReport(policy: $0) }
        try await channel.writeWirelessEQ(eq)
        state.equalizers.wireless = eq
        publish()
    }

    /// Uploads the Bluetooth graphic EQ. Experimental.
    public func setBluetoothEQ(_ eq: BluetoothEQ) async throws {
        try preflightEQ { try eq.featureReport(policy: $0) }
        try await channel.writeGraphicEQ(eq)
        state.equalizers.bluetooth = eq
        publish()
    }

    /// Uploads the mic graphic EQ. Experimental.
    public func setMicEQ(_ eq: MicEQ) async throws {
        try preflightEQ { try eq.featureReport(policy: $0) }
        try await channel.writeGraphicEQ(eq)
        state.equalizers.mic = eq
        publish()
    }

    // MARK: - Internals

    private func preflightEQ(_ build: (OmniWritePolicy) throws -> OmniFeatureReport) throws {
        // Build once up front so the flag and value checks throw before the connection check.
        _ = try build(OmniWritePolicy(experimentalEQWrites: configuration.experimentalEQWrites))
        try requireReady()
    }

    private func requireReady() throws {
        switch state.connection {
        case .connected: return
        case .settling: throw OmniError.hubSettling
        case .searching: throw OmniError.notConnected
        case .stopped: throw OmniError.transportStopped
        }
    }

    private func read(_ query: OmniQuery) async throws -> [UInt8] {
        try await channel.query(query, timeout: configuration.replyTimeout)
    }

    private func refreshStatus(publishing: Bool) async throws {
        let status = try OmniStatus(report: await read(.status))
        state.apply(status)
        if publishing { publish() }
    }

    private func attempt(_ query: OmniQuery, into issues: inout [String], _ apply: ([UInt8]) throws -> Void) async {
        do {
            try apply(try await read(query))
        } catch {
            issues.append("\(query): \(error.localizedDescription)")
        }
    }

    private func publish() {
        stateStream.yield(state)
    }

    private func handle(_ event: OmniTransportEvent) async {
        switch event {
        case .connected(let info):
            generation += 1
            let current = generation
            let flags = state.experimentalEQWrites
            state = OmniState()
            state.experimentalEQWrites = flags
            state.connection = .settling(info)
            publish()
            settleTask?.cancel()
            let settle = configuration.startupSettle
            settleTask = Task { [weak self] in
                if settle > .zero { try? await Task.sleep(for: settle) }
                await self?.finishSettling(generation: current, info: info)
            }
        case .disconnected:
            generation += 1
            settleTask?.cancel()
            let flags = state.experimentalEQWrites
            state = OmniState()
            state.experimentalEQWrites = flags
            state.connection = .searching
            publish()
        case .inputReport(let report):
            // Event opcodes never overlap query-reply opcodes, so replies are ignored here.
            guard let decoded = OmniEvent(report: report.bytes) else { return }
            await handle(decoded)
        }
    }

    private func handle(_ event: OmniEvent) async {
        let wasOnline = state.readouts.isHeadsetOnline
        state.apply(event)
        state.lastEvent = Date()
        publish()
        eventStream.yield(event)
        guard state.connection.isReady else { return }
        switch event {
        case .equalizerChanged(let kind):
            let current = generation
            Task { [weak self] in await self?.refreshEqualizerAfterEvent(kind, generation: current) }
        case .connection where !wasOnline && state.readouts.isHeadsetOnline && configuration.refreshOnHeadsetReconnect:
            let current = generation
            Task { [weak self] in await self?.resyncAfterHeadsetReconnect(generation: current) }
        default:
            break
        }
    }

    private func refreshEqualizerAfterEvent(_ kind: OmniEqualizerKind, generation expected: Int) async {
        guard generation == expected else { return }
        try? await refreshEqualizer(kind)
    }

    /// GG retries the firmware read up to 10× at 500 ms after the headset reconnects, then re-syncs.
    private func resyncAfterHeadsetReconnect(generation expected: Int) async {
        for attempt in 0..<10 {
            guard generation == expected else { return }
            try? await refreshFirmwareVersions()
            if state.info.firmware?.hasHeadsetVersions == true { break }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard generation == expected else { return }
        _ = try? await refresh()
    }

    private func finishSettling(generation expected: Int, info: OmniHubInfo) async {
        guard generation == expected, !Task.isCancelled else { return }
        state.connection = .connected(info)
        publish()
        do {
            try await refresh()
        } catch {
            state.issues = ["initial refresh: \(error.localizedDescription)"]
            publish()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        guard let interval = configuration.pollInterval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        guard state.connection.isReady else { return }
        try? await refreshStatus()
    }
}
