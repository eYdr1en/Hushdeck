import AppKit
import HeadsetControlKit
import OmniKit
import SwiftUI

@main
struct HushdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Hand the scene action to AppKit-side code (launch options, notifications).
        let _ = appDelegate.openMainWindow = { openWindow(id: HushdeckWindow.sceneID) }
        // Snapshot runs keep the status item out of the menu bar.
        MenuBarExtra(isInserted: .constant(LaunchOptions.snapshotDirectory == nil)) {
            PopoverView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        // The full window (GG Engine's tabs). Opened from the popover; the app stays an
        // accessory while it's closed.
        Window("Hushdeck", id: HushdeckWindow.sceneID) {
            HushdeckWindow()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 920, height: 660)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Snapshot runs use a throwaway defaults domain so they never touch real settings.
    let model: AppModel = {
        guard LaunchOptions.snapshotDirectory != nil else { return AppModel() }
        let defaults = LaunchOptions.snapshotDefaults
        let preferences = Preferences(defaults: defaults)
        return AppModel(preferences: preferences,
                        store: RememberedSettingsStore(defaults: defaults),
                        omni: OmniController(configuration: .init(experimentalEQWrites: preferences.experimentalEQWrites),
                                             defaults: defaults))
    }()
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the bundled app; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
        if let appearance = LaunchOptions.appearance { NSApp.appearance = appearance }
        model.start()
        // `-HushdeckWindowTab <tab>` opens the window at launch (screenshots).
        if LaunchOptions.windowTab != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.openMainWindow?() }
        }
        if let directory = LaunchOptions.snapshotDirectory {
            let runner = SnapshotRunner(model: model, directory: directory, appearance: LaunchOptions.snapshotAppearanceName)
            snapshotRunner = runner
            Task { await runner.run() }
        }
    }

    private var snapshotRunner: SnapshotRunner?

    /// Snapshot runs open and close many windows; the menu-bar app must outlive them.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.omni.stop()
        if LaunchOptions.snapshotDirectory != nil {
            LaunchOptions.snapshotDefaults.removePersistentDomain(forName: LaunchOptions.snapshotSuiteName)
        }
        return .terminateNow
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: StatusIcon.image(for: model.statusIconState))
            .accessibilityLabel(model.statusAccessibilityLabel)
    }
}
