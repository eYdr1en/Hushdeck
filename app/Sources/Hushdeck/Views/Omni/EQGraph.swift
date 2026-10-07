import SwiftUI

/// One draggable point on the graph: a band's centre frequency and gain.
struct EQNode: Identifiable, Equatable {
    var id: Int
    var frequency: Double
    var gainDB: Double
    var isEnabled: Bool
    /// Pass and notch filters have no gain; their node sits on 0 dB and only moves sideways.
    var usesGain: Bool = true
}

/// An interactive frequency-response graph. Log frequency axis (20 Hz – 20 kHz), dB axis, the
/// combined response drawn from real biquad maths, a hairline per band, and one node per band
/// that can be dragged (gain always; frequency when `allowsFrequencyDrag`).
struct EQGraph: View {
    let composite: (Double) -> Double
    let bandResponses: [(Double) -> Double]
    let nodes: [EQNode]
    @Binding var selection: Int?
    var gainRange: ClosedRange<Double> = -12...12
    var gainStep: Double = 0.1
    var allowsFrequencyDrag = true
    /// Called continuously while dragging: node index, new frequency (nil when frequency drags
    /// are off), new gain.
    var onDrag: (Int, Double?, Double) -> Void
    var onReset: (Int) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragging: Int?

    private let insets = EdgeInsets(top: 10, leading: 34, bottom: 20, trailing: 12)
    private let nodeRadius: CGFloat = 8
    private static let sampleFrequencies = EQCurve.logSpacedFrequencies(count: 240)
    private static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let plot = CGRect(x: insets.leading, y: insets.top,
                              width: size.width - insets.leading - insets.trailing,
                              height: size.height - insets.top - insets.bottom)
            guard plot.width > 20, plot.height > 20 else { return }
            drawGrid(&context, plot)
            context.clipToLayer(opacity: 1) { layer in
                layer.fill(Path(plot), with: .color(.black))
            }
            drawBands(&context, plot)
            drawComposite(&context, plot)
        }
        .overlay {
            GeometryReader { geo in
                let plot = plotRect(geo.size)
                ZStack {
                    ForEach(nodes) { node in
                        nodeView(node)
                            .position(point(for: node, in: plot))
                    }
                    if let dragging, let node = nodes.first(where: { $0.id == dragging }) {
                        readout(node)
                            .position(readoutPosition(for: node, in: plot))
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(plot: plot))
                .onTapGesture(count: 2) { location in
                    if let index = nearestNode(to: location, in: plot) { onReset(index) }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Frequency response"))
        .accessibilityValue(Text(accessibilitySummary))
        .accessibilityHint(Text("Drag a band to change its gain and frequency. Double-click a band to reset it."))
    }

    // MARK: Geometry

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: insets.leading, y: insets.top,
               width: max(size.width - insets.leading - insets.trailing, 1),
               height: max(size.height - insets.top - insets.bottom, 1))
    }

    private func x(_ frequency: Double, _ plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(EQCurve.position(of: frequency)) * plot.width
    }

    private func y(_ dB: Double, _ plot: CGRect) -> CGFloat {
        let span = gainRange.upperBound - gainRange.lowerBound
        let fraction = (min(max(dB, gainRange.lowerBound - 1), gainRange.upperBound + 1) - gainRange.lowerBound) / span
        return plot.maxY - CGFloat(fraction) * plot.height
    }

    private func point(for node: EQNode, in plot: CGRect) -> CGPoint {
        CGPoint(x: x(node.frequency, plot), y: y(node.usesGain ? node.gainDB : 0, plot))
    }

    private func nearestNode(to location: CGPoint, in plot: CGRect) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for node in nodes {
            let p = point(for: node, in: plot)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d <= nodeRadius * 2.2, best == nil || d < best!.distance { best = (node.id, d) }
        }
        return best?.index
    }

    // MARK: Drawing

    private func drawGrid(_ context: inout GraphicsContext, _ plot: CGRect) {
        let hairline = GraphicsContext.Shading.color(Color(nsColor: .quaternaryLabelColor))
        let zeroLine = GraphicsContext.Shading.color(Color(nsColor: .tertiaryLabelColor))

        for frequency in Self.gridFrequencies {
            let px = x(frequency, plot)
            var path = Path()
            path.move(to: CGPoint(x: px, y: plot.minY))
            path.addLine(to: CGPoint(x: px, y: plot.maxY))
            context.stroke(path, with: hairline, lineWidth: 1)
            if frequency > 20, frequency < 20000 {
                let label = context.resolve(Text(verbatim: frequencyLabel(frequency)).font(.caption2).foregroundStyle(.tertiary))
                context.draw(label, at: CGPoint(x: px, y: plot.maxY + 9), anchor: .center)
            }
        }
        var dB = gainRange.lowerBound
        while dB <= gainRange.upperBound + 0.001 {
            let py = y(dB, plot)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: py))
            path.addLine(to: CGPoint(x: plot.maxX, y: py))
            context.stroke(path, with: dB == 0 ? zeroLine : hairline, lineWidth: 1)
            if Int(dB) % 6 == 0 {
                let label = context.resolve(Text(verbatim: format(dB)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary))
                context.draw(label, at: CGPoint(x: plot.minX - 6, y: py), anchor: .trailing)
            }
            dB += 3
        }
    }

    private func curvePath(_ response: (Double) -> Double, _ plot: CGRect) -> Path {
        var path = Path()
        for (i, f) in Self.sampleFrequencies.enumerated() {
            let p = CGPoint(x: x(f, plot), y: y(response(f), plot))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func drawBands(_ context: inout GraphicsContext, _ plot: CGRect) {
        guard isEnabled else { return }
        for (index, response) in bandResponses.enumerated() {
            let path = curvePath(response, plot)
            let emphasised = index == selection || index == dragging
            context.stroke(path, with: .color(.accentColor.opacity(emphasised ? 0.55 : 0.22)), lineWidth: emphasised ? 1.5 : 1)
        }
    }

    private func drawComposite(_ context: inout GraphicsContext, _ plot: CGRect) {
        let curve = curvePath(composite, plot)
        var area = curve
        area.addLine(to: CGPoint(x: plot.maxX, y: y(0, plot)))
        area.addLine(to: CGPoint(x: plot.minX, y: y(0, plot)))
        area.closeSubpath()
        let tint: Color = isEnabled ? .accentColor : Color(nsColor: .tertiaryLabelColor)
        context.fill(area, with: .linearGradient(
            Gradient(colors: [tint.opacity(0.28), tint.opacity(0.04)]),
            startPoint: CGPoint(x: plot.midX, y: plot.minY), endPoint: CGPoint(x: plot.midX, y: plot.maxY)
        ))
        context.stroke(curve, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func nodeView(_ node: EQNode) -> some View {
        let active = node.id == selection || node.id == dragging
        return ZStack {
            Circle()
                .fill(node.isEnabled ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                .overlay(Circle().strokeBorder(node.isEnabled ? Color.accentColor : Color(nsColor: .tertiaryLabelColor),
                                               lineWidth: active ? 2.5 : 1.5))
                .shadow(color: .black.opacity(node.isEnabled ? 0.18 : 0), radius: 1.5, y: 0.5)
            Text(node.id + 1, format: .number)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(node.isEnabled ? Color.primary : Color(nsColor: .tertiaryLabelColor))
        }
        .frame(width: nodeRadius * 2, height: nodeRadius * 2)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.snappy(duration: 0.12), value: active)
    }

    private func readout(_ node: EQNode) -> some View {
        Text(verbatim: node.usesGain ? "\(frequencyText(node.frequency)) · \(format(node.gainDB)) dB" : frequencyText(node.frequency))
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.quaternary))
            .fixedSize()
    }

    private func readoutPosition(for node: EQNode, in plot: CGRect) -> CGPoint {
        var p = point(for: node, in: plot)
        p.y += p.y < plot.minY + 40 ? 24 : -22
        p.x = min(max(p.x, plot.minX + 50), plot.maxX - 50)
        return p
    }

    // MARK: Gesture

    private func dragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if dragging == nil {
                    guard let index = nearestNode(to: drag.startLocation, in: plot) else { return }
                    dragging = index
                    selection = index
                }
                guard let index = dragging, let node = nodes.first(where: { $0.id == index }) else { return }
                let span = gainRange.upperBound - gainRange.lowerBound
                let rawGain = gainRange.lowerBound + Double((plot.maxY - drag.location.y) / plot.height) * span
                let gain = node.usesGain ? snap(rawGain) : node.gainDB
                var frequency: Double?
                if allowsFrequencyDrag {
                    let position = Double((drag.location.x - plot.minX) / plot.width)
                    frequency = EQCurve.frequency(atPosition: position).rounded()
                }
                onDrag(index, frequency, gain)
            }
            .onEnded { _ in dragging = nil }
    }

    private func snap(_ raw: Double) -> Double {
        let snapped = (raw / gainStep).rounded() * gainStep
        return min(max(snapped, gainRange.lowerBound), gainRange.upperBound)
    }

    // MARK: Text

    private var accessibilitySummary: String {
        nodes.filter(\.isEnabled).map { "\(frequencyText($0.frequency)) \(format($0.gainDB)) dB" }.joined(separator: ", ")
    }
}

/// "50", "1k", "2.5k" for axis labels.
func frequencyLabel(_ hz: Double) -> String {
    if hz < 1000 { return Int(hz.rounded()).formatted() }
    return (hz / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k"
}

/// "250 Hz", "1.5 kHz" for readouts.
func frequencyText(_ hz: Double) -> String {
    if hz < 1000 { return String(localized: "\(Int(hz.rounded())) Hz", comment: "Frequency in hertz") }
    let k = (hz / 1000).formatted(.number.precision(.fractionLength(0...2)))
    return String(localized: "\(k) kHz", comment: "Frequency in kilohertz")
}
