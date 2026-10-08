import Foundation
import Observation
import OmniKit
import OSLog
import SwiftUI

/// Drives one Arctis Nova Pro Omni GameHub through OmniKit and adapts its state for the UI:
/// observable state, debounced typed writes with an optimistic overlay, EQ drafts, local presets,
/// profiles and re-apply-on-connect. `AppModel` owns one and folds it into the menu bar,
/// notifications and the popover so the rest of the app doesn't care which backend a headset uses.
@Observable
@MainActor
final class OmniController {
    static let log = Logger(subsystem: "com.adrianhorvath.hushdeck", category: "omni")
    nonisolated static let deviceName = "Arctis Nova Pro Omni"

    // MARK: Observable state

    /// The last state OmniKit published. Read `settings` for values the user may be editing.
    private(set) var state = OmniState()
    private(set) var isRefreshing = false
    private(set) var isStarted = false
    /// A failure that stopped the transport (IOKit refused to start, for example).
    private(set) var startupError: String?
    var profiles: [OmniProfile]
    var customPresets: [CustomEQPreset]
    /// The profile applied last, until a setting is changed by hand.
    var activeProfileID: UUID?
    /// Edits to the three EQs that haven't been sent (or can't be, with EQ writes off).
    var wirelessDraft: WirelessEQ?
    var bluetoothDraft: BluetoothEQ?
    var micDraft: MicEQ?

    // MARK: Hooks for AppModel

    @ObservationIgnored var onMessage: ((String, Bool) -> Void)?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var shouldReapplyOnConnect: (() -> Bool)?

    // MARK: Private

    @ObservationIgnored let device: OmniDevice
    /// Present when running against `SimulatedOmniTransport`, for the Developer controls.
    @ObservationIgnored let simulator: SimulatedOmniTransport?
    @ObservationIgnored let profileStore: OmniProfileStore
    @ObservationIgnored let presetStore: EQPresetStore
    @ObservationIgnored let memoryStore: OmniMemoryStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored var pendingWrites: [OmniFeature: Task<Void, Never>] = [:]
    @ObservationIgnored var writeGeneration: [OmniFeature: Int] = [:]
    /// Values the user set that the device hasn't confirmed yet, keyed by feature. Observed,
    /// because `settings` is derived from it.
    var overlay: [OmniFeature: OmniSetting] = [:]
    @ObservationIgnored private(set) var remembered: OmniSettings
    @ObservationIgnored private var reapplyPending = false
    @ObservationIgnored private var lastSeenRefresh: Date?
    @ObservationIgnored private var lastConnectionReady = false
    @ObservationIgnored private var lastHeadsetOnline = false

    init(transport: any OmniTransport = OmniTransportFactory.makeDefault(),
         configuration: OmniDevice.Configuration = .init(),
         defaults: UserDefaults = .standard) {
        self.device = OmniDevice(transport: transport, configuration: configuration)
        self.simulator = transport as? SimulatedOmniTransport
        self.defaults = defaults
        self.profileStore = OmniProfileStore(defaults: defaults)
        self.presetStore = EQPresetStore(defaults: defaults)
        self.memoryStore = OmniMemoryStore(defaults: defaults)
        self.profiles = profileStore.load()
        self.customPresets = presetStore.load()
        self.remembered = memoryStore.load()
        self.activeProfileID = defaults.string(forKey: "omniActiveProfile").flatMap(UUID.init(uuidString:))
        self.state.experimentalEQWrites = configuration.experimentalEQWrites
    }

    // MARK: Derived state

    /// A hub is attached (settling or ready).
    var isPresent: Bool { state.connection.hub != nil }
    var isReady: Bool { state.connection.isReady }
    var isSettling: Bool {
        if case .settling = state.connection { return true }
        return false
    }
    var isSimulated: Bool { state.connection.hub?.isSimulated ?? (simulator != nil) }
    var headsetOnline: Bool { state.readouts.isHeadsetOnline }
    var experimentalEQWrites: Bool { state.experimentalEQWrites }

    /// Device settings with the user's unconfirmed edits laid over them.
    var settings: OmniSettings {
        var merged = state.settings
        for setting in overlay.values { merged.apply(setting) }
        return merged
    }

    var readouts: OmniReadouts { state.readouts }

    /// Non-fatal read problems from the last refresh, grouped by UI section.
    var issues: [OmniReadIssue] { state.issues.map(OmniReadIssue.init(raw:)) }

    func issues(in section: OmniReadIssue.Section) -> [OmniReadIssue] {
        issues.filter { $0.section == section }
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        startupError = nil
        updatesTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.device.updates()
            for await state in stream {
                guard !Task.isCancelled else { return }
                self.receive(state)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.device.start()
            } catch {
                self.startupError = error.localizedDescription
                Self.log.error("OmniKit transport failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        pendingWrites.values.forEach { $0.cancel() }
        pendingWrites = [:]
        overlay = [:]
        isStarted = false
        Task { [device] in await device.stop() }
    }

    private func receive(_ new: OmniState) {
        let wasReady = lastConnectionReady
        let wasOnline = lastHeadsetOnline
        state = new
        lastConnectionReady = new.connection.isReady
        lastHeadsetOnline = new.readouts.isHeadsetOnline
        if !new.connection.isReady {
            // Drafts and overlays belong to the state that just went away.
            overlay = [:]
            wirelessDraft = nil
            bluetoothDraft = nil
            micDraft = nil
        }
        if (!wasReady && new.connection.isReady) || (!wasOnline && new.readouts.isHeadsetOnline) {
            reapplyPending = true
        }
        if let refreshed = new.lastRefresh, refreshed != lastSeenRefresh {
            lastSeenRefresh = refreshed
            if reapplyPending {
                reapplyPending = false
                reapplyRememberedIfNeeded()
            }
        }
        onStateChange?()
    }

    /// Re-reads everything (GG's startup sequence).
    func refresh() async {
        guard isReady, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await device.refresh()
        } catch {
            report(error)
        }
    }

    func setExperimentalEQWrites(_ enabled: Bool) {
        Task { await device.setExperimentalEQWrites(enabled) }
    }

    func report(_ error: any Error) {
        Self.log.error("\(error.localizedDescription, privacy: .public)")
        onMessage?(OmniErrorText.message(for: error), true)
    }

    func notify(_ text: String) {
        onMessage?(text, false)
    }

    // MARK: Active profile bookkeeping

    func setActiveProfile(_ id: UUID?) {
        activeProfileID = id
        if let id {
            defaults.set(id.uuidString, forKey: "omniActiveProfile")
        } else {
            defaults.removeObject(forKey: "omniActiveProfile")
        }
    }

    /// Records a write the device accepted. Its own state update arrives a hop later; applying it
    /// here too keeps the value from flicking back when the overlay clears.
    func didApply(_ setting: OmniSetting) {
        state.settings.apply(setting)
        remember(setting)
    }

    // MARK: Memory (re-apply on connect)

    func remember(_ setting: OmniSetting) {
        remembered.apply(setting)
        memoryStore.save(remembered)
    }

    func forgetRemembered() {
        remembered = OmniSettings()
        memoryStore.clear()
    }

    var hasRememberedSettings: Bool { !remembered.asSettings.isEmpty }

    /// After a (re)connect: send the remembered settings the device doesn't already report.
    private func reapplyRememberedIfNeeded() {
        guard shouldReapplyOnConnect?() ?? false, isReady else { return }
        let current = Set(state.settings.asSettings)
        let missing = remembered.asSettings.filter { !current.contains($0) }
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.device.apply(missing, saveToDevice: false)
                self.notify(String(localized: "Restored your settings on \(Self.deviceName)"))
            } catch {
                self.report(error)
            }
        }
    }
}

/// The settings the user applied through Hushdeck, kept so they can be sent again after the
/// hub or headset reconnects (the "Restore settings on reconnect" preference).
final class OmniMemoryStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "omniRemembered.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> OmniSettings {
        guard let data = defaults.data(forKey: key) else { return OmniSettings() }
        return (try? JSONDecoder().decode(OmniSettings.self, from: data)) ?? OmniSettings()
    }

    func save(_ settings: OmniSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// One entry of `OmniState.issues`, mapped to the UI section it affects.
struct OmniReadIssue: Identifiable, Hashable {
    enum Section: Hashable {
        case general, audio, wirelessEQ, bluetoothEQ, micEQ, display, firmware, serial, presetNames
    }

    let raw: String
    var id: String { raw }

    /// `OmniDevice` formats issues as "<query description>: <error>".
    var section: Section {
        let lower = raw.lowercased()
        if lower.hasPrefix("audio settings") { return .audio }
        if lower.hasPrefix("2.4 ghz eq") { return .wirelessEQ }
        if lower.hasPrefix("bluetooth eq") { return .bluetoothEQ }
        if lower.hasPrefix("mic eq") { return .micEQ }
        if lower.hasPrefix("oled settings") { return .display }
        if lower.hasPrefix("firmware") { return .firmware }
        if lower.hasPrefix("serial") { return .serial }
        if lower.hasPrefix("preset name") { return .presetNames }
        return .general
    }

    /// The error text without the query prefix.
    var message: String {
        guard let colon = raw.firstIndex(of: ":") else { return raw }
        return raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}

enum OmniErrorText {
    static func message(for error: any Error) -> String {
        guard let error = error as? OmniError else { return error.localizedDescription }
        switch error {
        case .notConnected: return String(localized: "The GameHub isn’t connected.")
        case .hubSettling: return String(localized: "The GameHub just connected. Hushdeck waits 5 seconds before talking to it, like SteelSeries GG.")
        case .experimentalEQWritesDisabled: return String(localized: "EQ writes are turned off. Turn them on in Settings → Developer to send this to the hub.")
        case .replyTimeout(let query): return String(localized: "The GameHub didn’t answer (\(query)).")
        case .transportStopped: return String(localized: "Hushdeck isn’t listening for the GameHub.")
        default: return error.localizedDescription
        }
    }
}
