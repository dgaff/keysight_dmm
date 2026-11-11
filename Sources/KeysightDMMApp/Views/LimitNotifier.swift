import AppKit
import UserNotifications

/// One macOS notification and the system alert sound when a reading leaves its limits.
/// Everything here fails quietly: no bundle, no permission, no notification.
@MainActor
enum LimitNotifier {
    /// Shows banners even while the app is in front.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner]
        }
    }

    private static let delegate = Delegate()

    /// Notifications need a real app bundle; a bare `swift run` binary has none.
    private static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks for permission. Call when the user first turns the option on.
    static func requestAuthorization() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        Task {
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    static func post(title: String, body: String) {
        NSSound.beep()
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: "limit-\(UUID().uuidString)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
