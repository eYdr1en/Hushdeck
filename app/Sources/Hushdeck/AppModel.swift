import AppKit
import HeadsetControlKit
import Observation
import OmniKit
import OSLog
import SwiftUI

/// Owns the HeadsetControl client, polling, debounced writes and per-device memory, plus the
/// OmniKit controller for the Arctis Nova Pro Omni. Anything that shows "the headset" (menu bar,
/// notifications, popover) asks this model, which picks the backend.
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case starting
        case binaryMissing
        case noDevice
        case ready
        case failed(String)
    }

    struct Banner: Identifiable, Equatable {
        enum Style { case error, info }
        let id = UUID()
        let text: String
        let style: Style
    }

    /// Values bound to the controls. Write-only settings come from `RememberedSettings`;
    /// sidetone comes from the device when it can report it.
    struct Controls: Equatable {
        var sidetone: Double = 64
        var microphoneVolume: Double = 96
        var microphoneMuteLEDBrightness: Int = 2
        var inactiveTime: Int? = nil
        var lights: Bool = true
        var voicePrompts: Bool = true
        var rotateToMute: Bool = true
        var noiseFilter: NoiseFilterLevel = .off
        var volumeLimiter: Bool = false
        var bluetoothWhenPoweredOn: Bool = false
        var bluetoothCallVolume: Double = 50
        var noiseCancelling: NoiseCancellingMode = .off
        /// nil when the current curve is custom or unknown.
        var presetIndex: Int? = nil
        var equalizerBands: [Double] = []
    }

    // MARK: Observable state

    private(set) var phase: Phase = .starting
    private(set) var devices: [DeviceInfo] = []
    private(set) var selectedDeviceID: String?
    private(set) var binaryLocation: BinaryLocation?
    private(set) var overrideIsInvalid = false
    private(set) var cliVersion: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var banner: Banner?
    private(set) var remembered = RememberedSettings()
    var controls = Controls()
    /// Band sliders were edited but not applied yet.
    private(set) var equalizerIsDirty = false
    private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    private(set) var notificationPermission: NotificationPermission = .notDetermined

    let preferences: Preferences
    /// The native backend for the Omni GameHub. Present (`isPresent`) only while a hub is attached.
    let omni: OmniController

    // MARK: Private

    @ObservationIgnored private let store: RememberedSettingsStore
    @ObservationIgnored private var client: HeadsetControlClient?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var writeGeneration: [String: Int] = [:]
    @ObservationIgnored private var inFlightKeys: Set<String> = []
    @ObservationIgnored private var reachableDeviceIDs: Set<String> = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastReportedSidetone: [String: Int] = [:]
    @ObservationIgnored private let notifier: any Notifying
    @ObservationIgnored private var batteryAlerts = BatteryAlertPolicy()
    @ObservationIgnored private let systemEvents = SystemEventsMonitor()
    @ObservationIgnored private var eventRefreshTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.adrianhorvath.hushdeck", category: "model")

    init(
        preferences: Preferences = Preferences(),
        store: RememberedSettingsStore = RememberedSettingsStore(),
        notifier: (any Notifying)? = nil,
        omni: OmniController? = nil
    ) {
        self.preferences = preferences
        self.store = store
        self.notifier = notifier ?? SystemNotifier()
        self.omni = omni ?? OmniController(configuration: .init(experimentalEQWrites: preferences.experimentalEQWrites))
    }

    var device: DeviceInfo? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    var isUsingTestDevice: Bool { preferences.effectiveUseTestDevice }

    // MARK: Lifecycle

    func start() {
        preferences.onConnectionSettingsChange = { [weak self] in self?.reconfigure() }
        preferences.onPollIntervalChange = { [weak self] in self?.restartPolling() }
        preferences.onAlertSettingsChange = { [weak self] in self?.alertSettingsChanged() }
        preferences.onEQWritesChange = { [weak self] in
            guard let self else { return }
            self.omni.setExperimentalEQWrites(self.preferences.experimentalEQWrites)
        }
        systemEvents.start { [weak self] in self?.systemDidChange() }
        omni.onMessage = { [weak self] text, isError in self?.showBanner(text, style: isError ? .error : .info) }
        omni.onStateChange = { [weak self] in self?.evaluateBatteryAlerts() }
        omni.shouldReapplyOnConnect = { [weak self] in self?.preferences.reapplyOnConnect ?? false }
        omni.start()
        reconfigure()
        Task { [weak self] in
            await self?.updateNotificationPermission(requestIfNeeded: self?.preferences.wantsNotifications ?? false)
        }
    }

    /// Wake from sleep or a USB device came or went: read again shortly, once.
    private func systemDidChange() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Re-resolves the binary and rebuilds the client (path override / test device changed).
    func reconfigure() {
        pendingWrites.values.forEach { $0.cancel() }
        pendingWrites = [:]
        reachableDeviceIDs = []
        devices = []
        selectedDeviceID = nil
        cliVersion = nil

        let locator = BinaryLocator(overridePath: preferences.binaryPathOverride)
        binaryLocation = locator.locate()
        overrideIsInvalid = locator.overrideIsInvalid

        guard let binaryLocation else {
            client = nil
            phase = .binaryMissing
            pollTask?.cancel()
            return
        }
        let testDevice: HeadsetControlConfiguration.TestDevice =
            preferences.effectiveUseTestDevice ? .on(profile: preferences.effectiveTestProfile) : .off
        let client = HeadsetControlClient(configuration: .init(binary: binaryLocation.url, testDevice: testDevice))
        self.client = client
        phase = .starting
        Task { [weak self] in
            let version = try? await client.version()
            self?.cliVersion = version?.replacingOccurrences(of: "HeadsetControl ", with: "")
        }
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        guard client != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.preferences.pollInterval ?? 30
                try? await Task.sleep(for: .seconds(max(interval, 5)))
            }
        }
    }

    /// Called when the popover opens. Skips the read if one just happened.
    func popoverDidOpen() {
        // The user may have changed notification permission in System Settings.
        if preferences.wantsNotifications {
            Task { await updateNotificationPermission(requestIfNeeded: false) }
        }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 4 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard let client else {
            phase = .binaryMissing
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }
        do {
            let output = try await client.status()
            guard client === self.client else { return } // reconfigured meanwhile
            apply(output)
        } catch is CancellationError {
            return
        } catch {
            if devices.isEmpty {
                phase = .failed(ErrorText.message(for: error))
            } else {
                showBanner(ErrorText.message(for: error), style: .error)
            }
        }
    }

    private func apply(_ output: HeadsetControlOutput) {
        let previousID = device?.id
        // The Omni GameHub is OmniKit's; HeadsetControl must not drive it as well.
        devices = BackendRouter.headsetControlDevices(from: output.devices)
        guard !devices.isEmpty else {
            phase = .noDevice
            selectedDeviceID = nil
            reachableDeviceIDs = []
            return
        }
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            let preferred = devices.first { $0.isTestDevice == preferences.effectiveUseTestDevice }
            selectedDeviceID = (preferred ?? devices[0]).id
        }
        phase = .ready
        syncControls(resetEqualizer: previousID != device?.id)
        reapplyOnNewConnections()
        evaluateBatteryAlerts()
    }

    func selectDevice(_ id: String) {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        equalizerIsDirty = false
        syncControls(resetEqualizer: true)
    }

    // MARK: Re-apply on connect

    private func reapplyOnNewConnections() {
        let reachableNow = Set(devices.filter { $0.connection.isReachable }.map(\.id))
        let newlyReachable = reachableNow.subtracting(reachableDeviceIDs)
        reachableDeviceIDs = reachableNow
        guard preferences.reapplyOnConnect else { return }
        for device in devices where newlyReachable.contains(device.id) {
            let settings = store.settings(for: device.id).settingsToReapply(on: device)
            guard !settings.isEmpty else { continue }
            Task { [weak self] in
                await self?.perform(settings, on: device, successMessage: String(localized: "Restored your settings on \(device.name)"))
            }
        }
    }

    // MARK: Writes

    /// Updates a control and schedules the write. Sliders pass a debounce so dragging
    /// sends one command after the hand stops, not one per pixel.
    func set(_ setting: HeadsetSetting, debounce: Duration? = nil) {
        let key = setting.debounceKey
        pendingWrites[key]?.cancel()
        let generation = (writeGeneration[key] ?? 0) + 1
        writeGeneration[key] = generation
        pendingWrites[key] = Task { [weak self] in
            if let debounce {
                try? await Task.sleep(for: debounce)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            if self.writeGeneration[key] == generation { self.pendingWrites[key] = nil }
            guard let device = self.device else { return }
            self.inFlightKeys.insert(key)
            await self.perform([setting], on: device, successMessage: nil)
            self.inFlightKeys.remove(key)
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<Controls, Value>, debounce: Duration? = nil, _ makeSetting: @escaping (Value) -> HeadsetSetting) -> Binding<Value> {
        Binding(
            get: { self.controls[keyPath: keyPath] },
            set: { newValue in
                self.controls[keyPath: keyPath] = newValue
                self.set(makeSetting(newValue), debounce: debounce)
            }
        )
    }

    @discardableResult
    private func perform(_ settings: [HeadsetSetting], on device: DeviceInfo, successMessage: String?) async -> Bool {
        guard let client else { return false }
        do {
            let results = try await client.apply(settings, to: device.deviceID)
            let failed = results.filter { !$0.succeeded }
            var memory = store.settings(for: device.id)
            for setting in settings where !failed.contains(where: { $0.capability == setting.capability }) {
                memory.record(setting)
            }
            store.save(memory, for: device.id)
            if device.id == self.device?.id { remembered = memory }
            if !failed.isEmpty {
                showBanner(ErrorText.message(for: HeadsetControlError.actionsFailed(failed)), style: .error)
                syncControls(resetEqualizer: false)
                return false
            }
            if let successMessage { showBanner(successMessage, style: .info) }
            return true
        } catch is CancellationError {
            return false
        } catch {
            showBanner(ErrorText.message(for: error), style: .error)
            syncControls(resetEqualizer: false)
            if case HeadsetControlError.noDevice = error { Task { await refresh() } }
            return false
        }
    }

    // MARK: Equalizer

    func selectPreset(_ index: Int) {
        controls.presetIndex = index
        if let device, index < device.equalizerPresets.count {
            controls.equalizerBands = fitted(device.equalizerPresets[index].bands, to: device)
        }
        equalizerIsDirty = false
        set(.equalizerPreset(index))
    }

    func setBand(_ index: Int, to value: Double) {
        guard controls.equalizerBands.indices.contains(index) else { return }
        controls.equalizerBands[index] = value
        equalizerIsDirty = true
    }

    func applyCustomEqualizer() {
        controls.presetIndex = nil
        equalizerIsDirty = false
        set(.equalizer(controls.equalizerBands))
    }

    func revertEqualizer() {
        equalizerIsDirty = false
        syncControls(resetEqualizer: true)
    }

    func flattenEqualizer() {
        guard let info = device?.equalizer else { return }
        controls.equalizerBands = Array(repeating: info.baseline, count: info.bands)
        equalizerIsDirty = true
    }

    private func fitted(_ bands: [Double], to device: DeviceInfo) -> [Double] {
        guard let info = device.equalizer else { return bands }
        var result = Array(bands.prefix(info.bands))
        if result.count < info.bands {
            result += Array(repeating: info.baseline, count: info.bands - result.count)
        }
        return result.map { min(max($0, info.min), info.max) }
    }

    // MARK: Sync

    private func syncControls(resetEqualizer: Bool) {
        guard let device else { return }
        let memory = store.settings(for: device.id)
        remembered = memory
        var c = controls
        let busy = inFlightKeys.union(pendingWrites.keys)

        if !busy.contains(Capability.sidetone.rawValue) {
            // Follow the device only when its reading changes (e.g. adjusted on the
            // base station); otherwise show what the user last applied. Some devices
            // (and the test device) report a fixed or stale level.
            let reported = device.sidetone?.level
            let previous = lastReportedSidetone[device.id]
            if let reported { lastReportedSidetone[device.id] = reported }
            if let reported, let previous, reported != previous {
                c.sidetone = Double(reported)
            } else if let level = memory.sidetone ?? reported {
                c.sidetone = Double(level)
            }
        }
        if let v = memory.microphoneVolume { c.microphoneVolume = Double(v) }
        if let v = memory.microphoneMuteLEDBrightness { c.microphoneMuteLEDBrightness = v }
        c.inactiveTime = memory.inactiveTime
        if let v = memory.lights { c.lights = v }
        if let v = memory.voicePrompts { c.voicePrompts = v }
        if let v = memory.rotateToMute { c.rotateToMute = v }
        if let v = memory.noiseFilter { c.noiseFilter = v }
        if let v = memory.volumeLimiter { c.volumeLimiter = v }
        if let v = memory.bluetoothWhenPoweredOn { c.bluetoothWhenPoweredOn = v }
        if let v = memory.bluetoothCallVolume { c.bluetoothCallVolume = Double(v) }
        if let v = memory.noiseCancelling { c.noiseCancelling = v }

        let bandCount = device.equalizer?.bands ?? 0
        if resetEqualizer || (!equalizerIsDirty && !busy.contains("equalizer")) || c.equalizerBands.count != bandCount {
            switch memory.equalizer {
            case .preset(let index)?:
                c.presetIndex = index
                let presetBands = index < device.equalizerPresets.count ? device.equalizerPresets[index].bands : []
                c.equalizerBands = fitted(presetBands, to: device)
            case .custom(let bands)?:
                c.presetIndex = nil
                c.equalizerBands = fitted(bands, to: device)
            case nil:
                c.presetIndex = nil
                c.equalizerBands = fitted([], to: device)
            }
            if resetEqualizer { equalizerIsDirty = false }
        }
        if c != controls { controls = c }
    }

    // MARK: Misc actions

    func playNotificationSound() {
        set(.notificationSound(1))
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
        } catch {
            showBanner(String(localized: "Couldn’t change Open at Login: \(error.localizedDescription) Move Hushdeck to Applications and try again."), style: .error)
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func forgetRememberedSettings() {
        guard let device else { return }
        store.forget(device.id)
        remembered = RememberedSettings()
        showBanner(String(localized: "Forgot saved settings for \(device.name)"), style: .info)
    }

    func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the headsetcontrol executable")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            preferences.binaryPathOverride = url.path
        }
    }

    func showBanner(_ text: String, style: Banner.Style) {
        let banner = Banner(text: text, style: style)
        self.banner = banner
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(style == .error ? 6 : 3))
            guard !Task.isCancelled, self?.banner?.id == banner.id else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() {
        banner = nil
    }

    // MARK: Battery notifications

    private func alertSettingsChanged() {
        Task {
            if preferences.wantsNotifications {
                await updateNotificationPermission(requestIfNeeded: true)
            }
            evaluateBatteryAlerts()
        }
    }

    /// Asks for permission only when an alert is switched on (or already on at launch).
    func updateNotificationPermission(requestIfNeeded: Bool) async {
        let before = notificationPermission
        notificationPermission = requestIfNeeded
            ? await notifier.requestPermission()
            : await notifier.permission()
        if notificationPermission != before, notificationPermission.canDeliver {
            evaluateBatteryAlerts()
        }
    }

    private func evaluateBatteryAlerts() {
        var readings: [BatteryReading] = []
        if phase == .ready {
            readings += devices.compactMap { device -> BatteryReading? in
                guard case .connected(let charging) = device.connection else { return nil }
                return BatteryReading(deviceID: device.id, deviceName: device.name, level: device.battery?.percent, charging: charging)
            }
        }
        if let reading = Self.omniBatteryReading(omni.state) { readings.append(reading) }
        guard !readings.isEmpty else { return }
        // Without permission nothing is posted and no alert is used up.
        let settings = notificationPermission.canDeliver ? preferences.alertSettings : .off
        for alert in batteryAlerts.evaluate(readings, settings: settings) {
            post(alert)
        }
    }

    /// The Omni's battery as one reading, while a headset is linked to the hub. The spare
    /// battery in the hub is reported whenever the hub is ready, headset or not.
    nonisolated static func omniBatteryReading(_ state: OmniState) -> BatteryReading? {
        guard state.connection.isReady else { return nil }
        let readouts = state.readouts
        guard readouts.isHeadsetOnline || readouts.spareBattery != nil else { return nil }
        return BatteryReading(
            deviceID: BackendRouter.omniNotificationID,
            deviceName: OmniController.deviceName,
            level: readouts.trustedHeadsetBattery,
            charging: readouts.isHeadsetOnline && readouts.charging == .charging,
            spareLevel: readouts.spareBattery
        )
    }

    private func post(_ alert: BatteryAlert) {
        let title: String
        let body: String
        let kind: String
        switch alert {
        case .low(_, let name, let level):
            kind = "low"
            title = String(localized: "Headset battery low")
            body = String(localized: "\(name) is at \(percentString(level)). Charge it soon.")
        case .fullyCharged(_, let name):
            kind = "full"
            title = String(localized: "Headset fully charged")
            body = String(localized: "\(name) is fully charged.")
        case .spareCharged(_, let name):
            kind = "spare"
            title = String(localized: "Spare battery charged")
            body = String(localized: "The spare battery in the \(name) GameHub is at 100 %. Swap it in whenever you like.")
        }
        Self.log.notice("Battery alert \(kind, privacy: .public) for \(alert.deviceID, privacy: .public)")
        Task {
            try? await notifier.post(
                identifier: "battery.\(kind).\(alert.deviceID)",
                threadIdentifier: alert.deviceID,
                title: title,
                body: body
            )
        }
    }

    // MARK: Menu bar

    var statusIconState: StatusIcon.State {
        if omni.isPresent { return omniStatusIconState }
        guard phase == .ready, let device else { return .inactive }
        switch device.connection {
        case .offline: return .inactive
        case .unknown: return .active(level: nil, charging: false)
        case .connected(let charging):
            let level = preferences.showBatteryPercentage ? device.battery?.percent : nil
            return .active(level: level, charging: charging)
        }
    }

    private var omniStatusIconState: StatusIcon.State {
        let readouts = omni.readouts
        guard omni.isReady else { return .active(level: nil, charging: false) }
        guard readouts.isHeadsetOnline else { return .inactive }
        let level = preferences.showBatteryPercentage ? readouts.trustedHeadsetBattery : nil
        return .active(level: level, charging: readouts.charging == .charging)
    }

    var statusAccessibilityLabel: String {
        if omni.isPresent {
            let name = OmniController.deviceName
            let readouts = omni.readouts
            guard omni.isReady else { return String(localized: "Hushdeck, \(name)") }
            guard readouts.isHeadsetOnline else { return String(localized: "Hushdeck, \(name) is off") }
            let charging = readouts.charging == .charging
            guard let level = readouts.trustedHeadsetBattery else {
                return charging ? String(localized: "Hushdeck, charging") : String(localized: "Hushdeck, \(name)")
            }
            return charging
                ? String(localized: "Hushdeck, battery \(percentString(level)), charging")
                : String(localized: "Hushdeck, battery \(percentString(level))")
        }
        switch phase {
        case .binaryMissing: return String(localized: "Hushdeck, HeadsetControl not found")
        case .noDevice, .starting, .failed: return String(localized: "Hushdeck, no headset")
        case .ready:
            guard let device else { return "Hushdeck" }
            switch device.connection {
            case .offline: return String(localized: "Hushdeck, \(device.name) is off")
            case .unknown: return String(localized: "Hushdeck, \(device.name)")
            case .connected(let charging):
                guard let level = device.battery?.percent else {
                    return charging ? String(localized: "Hushdeck, charging") : String(localized: "Hushdeck, \(device.name)")
                }
                return charging
                    ? String(localized: "Hushdeck, battery \(percentString(level)), charging")
                    : String(localized: "Hushdeck, battery \(percentString(level))")
            }
        }
    }
}
