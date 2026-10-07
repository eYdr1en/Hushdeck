import AppKit
import OmniKit
import SwiftUI

/// The full Hushdeck window: GG Engine's Audio / Microphone / Settings tabs, Mac-native.
/// Opened from the popover; the app stays a menu-bar accessory while it's closed.
struct HushdeckWindow: View {
    static let sceneID = "hushdeck-main"

    /// Sidebar entries. Add a Sonar-style extras section (software ChatMix, per-app routing…)
    /// as new cases here when there is something to put in it.
    enum Tab: String, CaseIterable, Identifiable {
        case audio, microphone, hub, profiles, device, settings

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .audio: "Audio"
            case .microphone: "Microphone"
            case .hub: "Headset & Hub"
            case .profiles: "Profiles"
            case .device: "Device"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .audio: "speaker.wave.2"
            case .microphone: "mic"
            case .hub: "rectangle.on.rectangle.angled"
            case .profiles: "person.crop.rectangle.stack"
            case .device: "info.circle"
            case .settings: "gearshape"
            }
        }

        /// Tabs that only make sense with a GameHub; the rest are always available.
        var needsHub: Bool {
            switch self {
            case .audio, .microphone, .hub, .device: true
            case .profiles, .settings: false
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var navigator: WindowNavigator
    /// An explicitly requested tab is shown even without a hub (snapshots, deep links).
    private let tabWasRequested: Bool

    init(initialTab: Tab? = nil) {
        let requested = initialTab ?? LaunchOptions.windowTab
        tabWasRequested = requested != nil
        _navigator = State(initialValue: WindowNavigator(tab: requested ?? .audio))
    }

    private var tab: Tab { navigator.tab }

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            List(selection: $navigator.tab) {
                // The device card is a row rather than a safe-area inset: an inset can be
                // laid out before the toolbar height is known and end up under the title bar.
                SidebarDeviceCard()
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
                Section {
                    ForEach([Tab.audio, .microphone, .hub]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                } header: {
                    Text("On-device settings")
                }
                Section {
                    ForEach([Tab.profiles, .device, .settings]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .environment(model.omni)
        }
        .navigationTitle(Text(tab.title))
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.omni.isReady, tab.needsHub {
                    Button {
                        Task { await model.omni.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.omni.isRefreshing)
                    .help("Read everything from the GameHub again")
                    Button {
                        model.omni.saveToDevice()
                    } label: {
                        Label("Save to Hub", systemImage: "square.and.arrow.down")
                    }
                    .help("Keep the current settings on the GameHub after it loses power (GG does this after every change)")
                }
            }
        }
        .onAppear {
            WindowActivation.windowDidOpen()
            if !tabWasRequested, !model.omni.isPresent, navigator.tab.needsHub { navigator.tab = .settings }
        }
        .onDisappear { WindowActivation.windowDidClose() }
        .environment(model.omni)
        .environment(navigator)
    }

    @ViewBuilder
    private var detail: some View {
        if tab.needsHub, !model.omni.isPresent {
            OmniAbsentView()
        } else if tab.needsHub, model.omni.isSettling {
            OmniSettlingView()
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            switch tab {
            case .audio: AudioTab()
            case .microphone: MicrophoneTab()
            case .hub: HubTab()
            case .profiles: ProfilesTab()
            case .device: DeviceInfoTab()
            case .settings: WindowSettingsTab()
            }
        }
    }
}

/// Name, battery and link state at the top of the sidebar, like a device card.
private struct SidebarDeviceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let omni = model.omni
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "headset")
                    .font(.system(size: 15))
                    .foregroundStyle(omni.headsetOnline ? .primary : .tertiary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: OmniController.deviceName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if omni.isReady, let spare = omni.readouts.spareBattery {
                HStack(spacing: 4) {
                    Image(systemName: "battery.100percent")
                        .imageScale(.small)
                    Text("Spare \(percentString(spare))")
                    Text(verbatim: "·")
                    Text(spare >= 100 ? "Charged" : "Charging")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        let omni = model.omni
        guard omni.isPresent else { return String(localized: "Not connected") }
        guard omni.isReady else { return String(localized: "Connecting…") }
        guard omni.headsetOnline else { return omni.readouts.headsetLink?.localizedName ?? String(localized: "Off or out of range") }
        if let level = omni.readouts.trustedHeadsetBattery {
            let charging = omni.readouts.charging == .charging
            return charging ? String(localized: "\(percentString(level)), charging") : percentString(level)
        }
        return String(localized: "Connected")
    }
}

/// While the window is open the app behaves like a regular app (Dock icon, ⌘W, focus);
/// closing it returns to the menu-bar-only accessory mode.
@MainActor
enum WindowActivation {
    private static var openWindows = 0

    static func windowDidOpen() {
        guard LaunchOptions.snapshotDirectory == nil else { return } // snapshot runs never activate
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowDidClose() {
        guard LaunchOptions.snapshotDirectory == nil else { return }
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Command-line switches for screenshots and development. Only the argument domain is read,
/// so a saved default can never change the normal behaviour.
enum LaunchOptions {
    private static var arguments: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    /// `-HushdeckWindowTab audio|microphone|hub|profiles|device|settings` opens the window on
    /// that tab at launch.
    static var windowTab: HushdeckWindow.Tab? {
        (arguments["HushdeckWindowTab"] as? String).flatMap(HushdeckWindow.Tab.init(rawValue:))
    }

    /// `-HushdeckSnapshot <dir>` renders the popover, every tab and the hub states to PNGs in
    /// that directory without activating the app, then quits. See `SnapshotRunner`.
    static var snapshotDirectory: URL? {
        guard let path = arguments["HushdeckSnapshot"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// `-HushdeckSnapshotAppearance light|dark` (default dark) names the files and sets the appearance.
    static var snapshotAppearanceName: String? {
        switch (arguments["HushdeckSnapshotAppearance"] as? String)?.lowercased() {
        case "light": "light"
        case "dark": "dark"
        default: nil
        }
    }

    static let snapshotSuiteName = "com.adrianhorvath.hushdeck.snapshot"

    /// A throwaway defaults domain for snapshot runs.
    static var snapshotDefaults: UserDefaults {
        UserDefaults(suiteName: snapshotSuiteName) ?? .standard
    }

    /// `-HushdeckAppearance light|dark` forces the app's appearance (also honoured by
    /// `-HushdeckSnapshotAppearance`).
    static var appearance: NSAppearance? {
        switch ((arguments["HushdeckAppearance"] as? String) ?? snapshotAppearanceName)?.lowercased() {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}
