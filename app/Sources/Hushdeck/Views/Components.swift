import OmniKit
import SwiftUI

/// Small secondary-coloured title above a group of rows, like Control Center modules.
struct SectionTitle: View {
    let title: LocalizedStringKey
    /// Adds the "Unverified" dot for an OmniKit feature that isn't hardware-confirmed.
    var feature: OmniFeature? = nil

    init(_ title: LocalizedStringKey, feature: OmniFeature? = nil) {
        self.title = title
        self.feature = feature
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let feature { UnverifiedBadge(feature: feature, style: .dot) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Label on the left, control on the right.
struct ControlRow<Accessory: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var feature: OmniFeature? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            if let feature { UnverifiedBadge(feature: feature, style: .dot) }
            Spacer(minLength: 8)
            accessory
        }
        .frame(minHeight: 26)
    }
}

/// A titled slider with a live value readout.
struct LabeledSlider: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var valueText: (Double) -> String = { Int($0.rounded()).formatted() }
    /// Adds the "Unverified" dot for an OmniKit feature that isn't hardware-confirmed.
    var feature: OmniFeature? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                if let feature { UnverifiedBadge(feature: feature, style: .dot) }
                Spacer()
                Text(valueText(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .padding(.leading, 26)
                .accessibilityLabel(Text(title))
                .accessibilityValue(valueText(value))
        }
        .padding(.vertical, 2)
    }
}

/// Formats a 0...max device level as a percentage.
func percentText(_ max: Double) -> (Double) -> String {
    { value in percentString(Int((value / max * 100).rounded())) }
}
