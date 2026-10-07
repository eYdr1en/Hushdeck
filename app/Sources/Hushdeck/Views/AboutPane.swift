import AppKit
import SwiftUI

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "About", onBack: onBack)
            Divider()

            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    AppIconView()
                    Text(verbatim: "Hushdeck").font(.title3.weight(.semibold))
                    Text("Version \(AppInfo.version) (\(AppInfo.build))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Menu bar controls for your wireless headset.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                if AppInfo.repositoryURL != nil {
                    HStack(spacing: 16) {
                        if let url = AppInfo.repositoryURL { Link("Website", destination: url) }
                        if let url = AppInfo.issuesURL { Link("Report an Issue", destination: url) }
                    }
                    .font(.callout)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Acknowledgements").font(.subheadline.weight(.semibold))
                    Credit(
                        name: "HeadsetControl",
                        detail: model.cliVersion.map { Text(verbatim: $0) },
                        notice: Text("Hushdeck runs HeadsetControl as a separate program to talk to your headset. HeadsetControl is free software under the GNU General Public License, version 3. Its source code is available from its project page."),
                        project: AppInfo.headsetControlURL,
                        license: AppInfo.headsetControlLicense,
                        licenseFallback: AppInfo.gplURL
                    )
                    if AppInfo.hidapiLicense != nil {
                        Credit(
                            name: "HIDAPI",
                            detail: nil,
                            notice: Text("Used by the bundled HeadsetControl. Distributed under its BSD-style licence."),
                            project: AppInfo.hidapiURL,
                            license: AppInfo.hidapiLicense,
                            licenseFallback: nil
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let copyright = AppInfo.copyright {
                    Text(verbatim: copyright)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

private struct Credit: View {
    let name: String
    let detail: Text?
    let notice: Text
    let project: URL
    let license: URL?
    let licenseFallback: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: name).font(.callout.weight(.medium))
                if let detail {
                    detail.font(.caption).foregroundStyle(.secondary)
                }
            }
            notice
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link("Project Page", destination: project)
                if let license {
                    Button("View Licence") { NSWorkspace.shared.open(license) }
                        .buttonStyle(.link)
                } else if let licenseFallback {
                    Link("View Licence", destination: licenseFallback)
                }
            }
            .font(.caption)
        }
    }
}

/// The bundle's icon; a glyph when running without one (`swift run`).
private struct AppIconView: View {
    var body: some View {
        Group {
            if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
            } else {
                Image(systemName: "headset")
                    .font(.system(size: 26, weight: .regular))
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }
}
