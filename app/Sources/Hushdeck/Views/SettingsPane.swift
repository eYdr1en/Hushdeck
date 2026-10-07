import HeadsetControlKit
import SwiftUI

/// Back button and title shared by the Settings and About panes.
struct PaneHeader: View {
    let title: LocalizedStringKey
    let onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Back")
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct SettingsPane: View {
    let onDone: () -> Void
    let showAbout: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Settings", onBack: onDone)
            Divider()
            SettingsForm(showAbout: showAbout)
                .scrollContentBackground(.hidden)
                .controlSize(.small)
                .frame(height: 560)
        }
    }
}

/// The window's Settings tab.
struct WindowSettingsTab: View {
    var body: some View {
        SettingsForm(showAbout: nil)
    }
}
