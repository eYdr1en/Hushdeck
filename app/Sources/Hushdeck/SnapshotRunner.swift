import AppKit
import OmniKit
import SwiftUI

/// Renders the popover and every window tab and hub state to PNG files without activating
/// the app, taking focus or using synthetic input (`-HushdeckSnapshot <dir>`). Each view is
/// hosted in a window that is never made key; the window's frame view is drawn with
/// `cacheDisplay`, which works without the window being on the visible space.
///
/// Runs against the simulated hub (`HUSHDECK_SIMULATED_OMNI=1`) so it can drive the states.
/// Settings, profiles and presets come from a throwaway defaults domain that is removed at exit.
@MainActor
final class SnapshotRunner {
    private let model: AppModel
    private let directory: URL
    private let suffix: String
    private var windows: [NSWindow] = []

    init(model: AppModel, directory: URL, appearance: String?) {
        self.model = model
        self.directory = directory
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        suffix = "-\(appearance ?? "dark")" + (language == "en" ? "" : "-\(language)")
    }

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let omni = model.omni
        guard omni.simulator != nil else {
            // No simulated hub (e.g. HUSHDECK_TEST_DEVICE=1): just the popover and Settings.
            await wait(for: "HeadsetControl", timeout: .seconds(10)) { model.phase != .starting }
            await popover("headsetcontrol-popover")
            await window(.settings, "headsetcontrol-window-settings")
            NSApp.terminate(nil)
            return
        }
        await wait(for: "hub ready") { omni.isReady && omni.state.lastRefresh != nil }

        await popover("omni-popover")
        for tab in [HushdeckWindow.Tab.audio, .microphone, .hub, .profiles, .device, .settings] {
            await window(tab, "omni-window-\(tab.rawValue)")
        }

        // Parametric EQ with a shaped curve: a factory preset plus one hand edit.
        omni.selectWirelessPreset(.bassBoost)
        omni.updateWirelessBand(6) { band in
            band.frequency = 2500
            band.gainTenths = -30
            band.qThousandths = 2000
        }
        omni.updateGraphicGain(.bluetooth, band: 8, gainTenths: 25)
        await window(.audio, "omni-eq-parametric", height: 1560)
        omni.revert(.wireless)
        omni.revert(.bluetooth)

        // Profiles with content, and the menu-bar switcher that appears with them.
        omni.saveProfile(named: String(localized: "Desk", comment: "Sample profile name in snapshots"))
        omni.set(.ancMode(.activeNoiseCancellation))
        omni.set(.autoOff(.never))
        await wait(for: "writes") { omni.overlay.isEmpty }
        omni.saveProfile(named: String(localized: "Late night", comment: "Sample profile name in snapshots"))
        await window(.profiles, "omni-profiles")
        await popover("omni-popover-profile")

        if let simulator = omni.simulator {
            simulator.simulateHeadsetPower(on: false)
            await wait(for: "headset off") { !omni.headsetOnline }
            await popover("omni-state-headset-off")
            await window(.audio, "omni-state-headset-off-window")
            simulator.simulateHeadsetPower(on: true)
            await wait(for: "headset on") { omni.headsetOnline }

            simulator.simulateHubDisconnect()
            await wait(for: "unplugged") { !omni.isPresent }
            await popover("omni-state-unplugged")
            await window(.audio, "omni-state-unplugged-window")

            simulator.simulateHubReconnect()
            await wait(for: "settling") { omni.isSettling }
            await popover("omni-state-settling")
            await window(.audio, "omni-state-settling-window")
            await wait(for: "hub ready again", timeout: .seconds(15)) { omni.isReady }
        }

        NSApp.terminate(nil)
    }

    // MARK: Views

    private func popover(_ name: String) async {
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: PopoverView().environment(model))
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        let window = SnapshotWindow(contentRect: effect.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = effect
        await render(window, view: effect, name: name, cornerRadius: 10)
    }

    private func window(_ tab: HushdeckWindow.Tab, _ name: String, height: CGFloat = 860) async {
        let hosting = NSHostingView(rootView: HushdeckWindow(initialTab: tab).environment(model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = SnapshotWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: height),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        await render(window, view: nil, name: name)
    }

    /// Draws the window (frame view, so the title bar and toolbar are included) to a PNG.
    private func render(_ window: NSWindow, view: NSView?, name: String, cornerRadius: CGFloat = 0) async {
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)) // off every screen
        windows.append(window)
        // Ordering the window (not key, not front-most of an active app) lets SwiftUI run its
        // layout and display passes; the app is never activated.
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(1500))
        let target = view ?? (window.contentView?.superview ?? window.contentView!)
        target.layoutSubtreeIfNeeded()
        target.displayIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        let final = cornerRadius > 0 ? Self.rounded(rep, radius: cornerRadius) : rep
        if let data = final.representation(using: .png, properties: [:]) {
            let url = directory.appendingPathComponent("\(name)\(suffix).png")
            try? data.write(to: url)
            print("snapshot: \(url.path)")
        }
        window.orderOut(nil)
        windows.removeAll { $0 === window }
    }

    /// Clips a rendered bitmap to a rounded rectangle (the popover's shape).
    private static func rounded(_ rep: NSBitmapImageRep, radius: CGFloat) -> NSBitmapImageRep {
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = CGFloat(rep.pixelsWide) / max(rep.size.width, 1)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius * scale, yRadius: radius * scale).addClip()
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    private func wait(for what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline {
                print("snapshot: timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Never becomes key or main, so hosting it can't take focus from the user.
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
