import OmniKit
import SwiftUI

/// A quiet marker for features that haven't been confirmed on real hardware. Most Omni
/// features are in that state until the headset arrives, so the marker has to read as
/// information, not as a warning: tertiary text, no colour, the reason in a tooltip.
struct UnverifiedBadge: View {
    enum Style { case tag, dot }

    let feature: OmniFeature
    var style: Style = .tag

    var body: some View {
        if !feature.isVerified {
            Group {
                switch style {
                case .tag:
                    Text("Unverified")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                case .dot:
                    Image(systemName: "circle.dotted")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .help(feature.unverifiedExplanation)
            .accessibilityLabel(Text("Unverified"))
            .accessibilityHint(Text(feature.unverifiedExplanation))
        }
    }
}

/// A control label with its badge, for Form rows.
struct FeatureLabel: View {
    let title: LocalizedStringKey
    let feature: OmniFeature
    var subtitle: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                UnverifiedBadge(feature: feature)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// Grouped `Form` footers are trailing-aligned on macOS; section notes read better leading-aligned.
    func sectionFooterStyle() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
