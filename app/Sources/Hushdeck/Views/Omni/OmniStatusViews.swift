import OmniKit
import SwiftUI

/// The 5 s GG waits after the hub enumerates before sending anything.
struct OmniSettlingView: View {
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("GameHub connected")
                    .font(compact ? .subheadline : .body)
                Text("Waiting a few seconds before talking to it, as SteelSeries GG does.")
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 14 : 0)
        .padding(.vertical, compact ? 18 : 0)
    }
}

/// Hub present, headset off / out of range.
struct OmniHeadsetOfflineNotice: View {
    @Environment(OmniController.self) private var omni
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "headset")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(omni.readouts.headsetLink == .pairing ? "Headset is pairing" : "Headset is off or out of range")
                    .font(compact ? .subheadline : .body)
                Text("Hub settings still work. Headset settings apply when it reconnects.")
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 12 : 0)
        .padding(.vertical, compact ? 8 : 0)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One read that failed during the last refresh, shown inside the section it affects.
struct OmniIssueRow: View {
    @Environment(OmniController.self) private var omni
    let issues: [OmniReadIssue]
    var compact = false

    var body: some View {
        if !issues.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn’t read this section from the GameHub")
                        .font(compact ? .caption : .callout)
                    ForEach(issues) { issue in
                        Text(verbatim: issue.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button("Retry") { Task { await omni.refresh() } }
                    .controlSize(.small)
                    .disabled(omni.isRefreshing || !omni.isReady)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The full window when no GameHub is attached.
struct OmniAbsentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No GameHub connected")
                .font(.title3.weight(.semibold))
            Text("Plug the Arctis Nova Pro Omni GameHub into this Mac over USB. Hushdeck notices it within a few seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let error = model.omni.startupError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 380)
            }
            if let device = model.device {
                Text("\(device.name) is connected through HeadsetControl. Its controls are in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One-line summary at the top of the window while nothing is hardware-confirmed.
struct OmniVerificationNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
            Text("Controls marked “Unverified” follow SteelSeries GG’s device data but haven’t been tried on a real Omni yet. Hover a marker for details.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
