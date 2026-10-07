import AppKit
import OSLog
import UserNotifications

enum NotificationPermission: Sendable, Equatable {
    /// Not running from an app bundle (e.g. `swift run`): UserNotifications needs one.
    case unavailable
    case notDetermined
    case denied
    case authorized

    var canDeliver: Bool { self == .authorized }
}

/// Posts local notifications. Abstracted so the model can be driven without the system.
@MainActor
protocol Notifying: AnyObject {
    func permission() async -> NotificationPermission
    /// Shows the system prompt if the user hasn't decided yet.
    func requestPermission() async -> NotificationPermission
    func post(identifier: String, threadIdentifier: String, title: String, body: String) async throws
}

@MainActor
final class SystemNotifier: Notifying {
    private static let log = Logger(subsystem: "com.adrianhorvath.hushdeck", category: "notifications")

    private let center: UNUserNotificationCenter?
    private let presenter = ForegroundPresenter()

    /// UNUserNotificationCenter crashes when the process has no bundle identifier,
    /// so it's only touched when running as Hushdeck.app.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    init() {
        if Self.isAvailable {
            let center = UNUserNotificationCenter.current()
            center.delegate = presenter
            self.center = center
        } else {
            center = nil
        }
    }

    func permission() async -> NotificationPermission {
        guard let center else { return .unavailable }
        return Self.map(await center.notificationSettings().authorizationStatus)
    }

    func requestPermission() async -> NotificationPermission {
        guard let center else { return .unavailable }
        let current = await permission()
        guard current == .notDetermined else { return current }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Self.log.info("Notification permission \(granted ? "granted" : "declined", privacy: .public)")
        } catch {
            Self.log.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
        }
        return await permission()
    }

    func post(identifier: String, threadIdentifier: String, title: String, body: String) async throws {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            Self.log.notice("Posted notification \(identifier, privacy: .public): \(body, privacy: .public)")
        } catch {
            Self.log.error("Couldn't post notification \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Opens System Settings at Hushdeck's notification settings.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.adrianhorvath.hushdeck"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }
}

/// A menu-bar app counts as "in the foreground" while its popover is open; show
/// banners then too instead of silently filing them in Notification Center.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
