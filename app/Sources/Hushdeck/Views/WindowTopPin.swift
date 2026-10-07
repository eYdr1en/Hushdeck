import AppKit
import SwiftUI

/// MenuBarExtra's window grows with its SwiftUI content but never shrinks, so when
/// the content gets shorter (Settings, collapsing "More", a banner going away) it
/// floats inside an oversized window, detached from the menu bar. This sizes the
/// window to the measured content height while keeping the top edge where the
/// system placed it.
struct WindowTopPin: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> PinView { PinView() }

    func updateNSView(_ nsView: PinView, context: Context) {
        nsView.contentHeight = contentHeight
        nsView.fit()
    }

    final class PinView: NSView {
        var contentHeight: CGFloat = 0
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            }
            fit()
        }

        func fit() {
            guard let window, contentHeight > 1 else { return }
            let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: window.contentLayoutRect.width, height: contentHeight)).height
            guard abs(window.frame.height - target) > 0.5 else { return }
            let top = window.frame.maxY
            window.setFrame(NSRect(x: window.frame.minX, y: top - target, width: window.frame.width, height: target), display: true)
        }
    }
}
