import AppKit
import SwiftUI

/// Shared layout for the states where there's nothing to control.
private struct StatusMessage<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(title).font(.headline)
            message
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
    }
}

struct BinaryMissingView: View {
    @Environment(AppModel.self) private var model
    /// HeadsetControl isn't in homebrew-core; it comes from the maintainer's tap.
    private let installCommand = "brew install sapd/headsetcontrol/headsetcontrol"

    var body: some View {
        StatusMessage(
            symbol: "wrench.and.screwdriver",
            title: "HeadsetControl not found",
            message: Text("Hushdeck uses the headsetcontrol command-line tool to talk to your headset. Install it with Homebrew, or choose where it is.")
        ) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(installCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                        model.showBanner(String(localized: "Copied"), style: .info)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                    .help("Copy command")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack {
                    Button("Choose…") { model.chooseBinary() }
                    Button("Check Again") { model.reconfigure() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
        }
    }
}

struct NoDeviceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StatusMessage(
            symbol: "headset",
            title: "No headset connected",
            message: Text("Connect the base station or USB receiver. Hushdeck checks again every \(interval).")
        ) {
            Button("Check Now") { Task { await model.refresh() } }
                .controlSize(.small)
                .disabled(model.isRefreshing)
        }
    }

    private var interval: String {
        pollIntervalText(model.preferences.pollInterval)
    }
}

struct FailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        StatusMessage(
            symbol: "exclamationmark.triangle",
            title: "Couldn’t read the headset",
            message: Text(verbatim: message)
        ) {
            Button("Try Again") { Task { await model.refresh() } }
                .controlSize(.small)
        }
    }
}

/// "30 seconds", "1 minute", "2 minutes" – localised by Foundation.
func pollIntervalText(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
}
