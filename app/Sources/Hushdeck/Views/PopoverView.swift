import AppKit
import HeadsetControlKit
import SwiftUI

struct PopoverView: View {
    enum Pane: String { case main, settings, about }

    @Environment(AppModel.self) private var model
    @State private var pane = Self.initialPane

    /// `-HushdeckInitialPane settings|about` on the command line opens that pane the
    /// first time the popover appears (for screenshots). Only the argument domain is
    /// read, so a saved default can never change the normal behaviour.
    private static var initialPane: Pane {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return (arguments["HushdeckInitialPane"] as? String).flatMap(Pane.init(rawValue:)) ?? .main
    }
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            switch pane {
            case .main:
                MainPane { pane = .settings }
            case .settings:
                SettingsPane(onDone: { pane = .main }, showAbout: { pane = .about })
            case .about:
                AboutPane { pane = .settings }
            }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background(WindowTopPin(contentHeight: contentHeight))
        .animation(.snappy(duration: 0.2), value: model.banner)
        .onAppear { model.popoverDidOpen() }
        .onDisappear { pane = .main }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.popoverDidOpen()
        }
    }
}

private struct MainPane: View {
    @Environment(AppModel.self) private var model
    let showSettings: () -> Void
    @State private var contentHeight: CGFloat = 0

    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 180
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.omni.isPresent {
                // The Omni GameHub is driven by OmniKit; HeadsetControl's phase doesn't apply.
                OmniQuickPane()
                    .environment(model.omni)
            } else {
                switch model.phase {
                case .starting:
                    starting
                case .binaryMissing:
                    BinaryMissingView()
                case .noDevice:
                    NoDeviceView()
                case .failed(let message):
                    FailedView(message: message)
                case .ready:
                    if let device = model.device {
                        DeviceHeader(device: device)
                        Divider().padding(.horizontal, 12)
                        ScrollView {
                            DeviceControls(device: device)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: min(max(contentHeight, 40), maxScrollHeight))
                    }
                }
            }

            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Divider()
            FooterBar(showSettings: showSettings)
        }
    }

    private var starting: some View {
        Group {
            switch model.phase {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your headset…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            default:
                EmptyView()
            }
        }
    }
}

private struct FooterBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if model.omni.isPresent {
                    Task { await model.omni.refresh() }
                } else {
                    Task { await model.refresh() }
                }
            } label: {
                if model.isRefreshing || model.omni.isRefreshing {
                    ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
            }
            .help("Refresh now")
            .disabled(model.omni.isPresent ? !model.omni.isReady : model.phase == .binaryMissing)

            if let last = model.lastRefresh, model.phase == .ready, !model.omni.isPresent {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(last, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if model.omni.isPresent, model.omni.isSimulated {
                Image(systemName: "testtube.2")
                    .help("Hushdeck is talking to OmniKit’s simulated GameHub")
                    .accessibilityLabel(Text("Simulated", comment: "Footer tag: the Omni GameHub is OmniKit's simulated one"))
            } else if model.isUsingTestDevice {
                Image(systemName: "testtube.2")
                    .help("Hushdeck is talking to HeadsetControl’s simulated test device")
                    .accessibilityLabel(Text("Test device"))
            }

            Button {
                openWindow(id: HushdeckWindow.sceneID)
                NSApp.activate()
            } label: {
                Text("Open Hushdeck")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Open the full window with every setting, the equalizers and profiles")

            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Hushdeck")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .imageScale(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: AppModel.Banner

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: banner.style == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.style == .error ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
            Text(banner.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                model.dismissBanner()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
