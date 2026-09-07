import Foundation
import UserNotifications
import AppKit

enum Notifier {
    @discardableResult
    static func requestAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Current OS-level permission, so the UI can tell the difference between
    /// "never asked", "denied in System Settings", and "all good".
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func post(title: String, body: String, url: String?) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let url { c.userInfo = ["url": url] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Deep-links straight to this app's row in System Settings > Notifications.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Opens the PR when a notification is clicked.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive r: UNNotificationResponse) async {
        if let s = r.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: s) {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }
}
