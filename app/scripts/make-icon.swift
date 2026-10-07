// Draws Hushdeck's app icon and writes an .iconset directory for `iconutil`.
//
//   swift scripts/make-icon.swift /path/to/AppIcon.iconset
//   iconutil -c icns /path/to/AppIcon.iconset
//
// Drawn with plain CoreGraphics paths (SF Symbols may not be used in app icons).
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.42, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.20, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    // Headset: headband arc and two ear cups.
    let cx = body.midX
    let unit = body.width / 100
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(unit * 7)
    ctx.addArc(center: CGPoint(x: cx, y: body.minY + unit * 46), radius: unit * 28,
               startAngle: .pi * 0.02, endAngle: .pi * 0.98, clockwise: false)
    ctx.strokePath()

    ctx.setFillColor(NSColor.white.cgColor)
    for side in [-1.0, 1.0] {
        let cup = CGRect(x: cx + side * unit * 30 - unit * 9, y: body.minY + unit * 22, width: unit * 18, height: unit * 30)
        ctx.addPath(CGPath(roundedRect: cup, cornerWidth: unit * 7, cornerHeight: unit * 7, transform: nil))
        ctx.fillPath()
    }

    // "Hush": three quiet sound bars between the cups, fading out.
    for (i, height) in [12.0, 18.0, 10.0].enumerated() {
        let x = cx + CGFloat(i - 1) * unit * 8 - unit * 2
        let bar = CGRect(x: x, y: body.minY + unit * 37 - unit * height / 2, width: unit * 4, height: unit * height)
        ctx.setFillColor(NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.95, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: unit * 2, cornerHeight: unit * 2, transform: nil))
        ctx.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(size: points * scale).write(to: output.appendingPathComponent(name))
    }
}
