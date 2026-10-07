import AppKit

/// Draws the menu bar item: headset glyph, battery percentage and a charging bolt.
///
/// The result is a template image so the menu bar tints it for light/dark and
/// highlighted states. "Greyed" is expressed through alpha, which template images
/// honour, so the disconnected state still adapts to every appearance.
enum StatusIcon {
    enum State: Equatable {
        case active(level: Int?, charging: Bool)
        case inactive
    }

    @MainActor private static var cache: [State: NSImage] = [:]

    @MainActor
    static func image(for state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = render(state)
        cache[state] = image
        return image
    }

    private static func render(_ state: State) -> NSImage {
        let height: CGFloat = 18
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let headset = NSImage(systemSymbolName: "headset", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage()

        var text: NSAttributedString?
        var bolt: NSImage?
        var alpha: CGFloat = 1
        switch state {
        case .inactive:
            alpha = 0.4
        case .active(let level, let charging):
            if let level {
                let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                text = NSAttributedString(string: "\(level)%", attributes: [.font: font, .foregroundColor: NSColor.black])
            }
            if charging {
                bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            }
        }

        let spacing: CGFloat = 3
        var width = headset.size.width
        if let text { width += spacing + ceil(text.size().width) }
        if let bolt { width += 1 + bolt.size.width }

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { rect in
            var x: CGFloat = 0
            let headsetY = (rect.height - headset.size.height) / 2
            headset.draw(in: NSRect(x: x, y: headsetY, width: headset.size.width, height: headset.size.height),
                         from: .zero, operation: .sourceOver, fraction: alpha)
            x += headset.size.width
            if let text {
                x += spacing
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: (rect.height - size.height) / 2))
                x += ceil(size.width)
            }
            if let bolt {
                x += 1
                bolt.draw(in: NSRect(x: x, y: (rect.height - bolt.size.height) / 2, width: bolt.size.width, height: bolt.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension StatusIcon.State: Hashable {}
