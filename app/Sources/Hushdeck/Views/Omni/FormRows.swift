import OmniKit
import SwiftUI

/// A slider row for the grouped forms: label with badge on the left, slider and value on the right.
struct OmniSliderRow: View {
    let title: LocalizedStringKey
    let feature: OmniFeature
    var subtitle: LocalizedStringKey? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var valueText: (Double) -> String = { Int($0.rounded()).formatted() }

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 140, maxWidth: 220)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(valueText(value))
                Text(valueText(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        } label: {
            FeatureLabel(title: title, feature: feature, subtitle: subtitle)
        }
    }
}

/// Shared shape for a window navigator so deep links (EQ note → Developer settings) work.
@Observable
@MainActor
final class WindowNavigator {
    var tab: HushdeckWindow.Tab

    init(tab: HushdeckWindow.Tab) {
        self.tab = tab
    }
}

/// "5 min", "Never", "Off" for the two timeout pickers.
func timeoutLabel(_ timeout: OmniTimeout, zero: LocalizedStringKey) -> Text {
    timeout == .never ? Text(zero) : Text(timeout.localizedMinutes)
}

/// A read-only value row with an optional badge.
struct ReadoutRow: View {
    let title: LocalizedStringKey
    let feature: OmniFeature?
    let value: String?

    init(_ title: LocalizedStringKey, feature: OmniFeature? = nil, value: String?) {
        self.title = title
        self.feature = feature
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value ?? String(localized: "—", comment: "Value not available"))
                .foregroundStyle(value == nil ? .tertiary : .secondary)
                .textSelection(.enabled)
                .monospacedDigit()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if let feature { UnverifiedBadge(feature: feature) }
            }
        }
    }
}
