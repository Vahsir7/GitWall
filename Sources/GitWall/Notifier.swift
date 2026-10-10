import Foundation
import UserNotifications
import AppKit

enum Notifier {
    static let prCategory = "PR"
    static let ignoreAction = "IGNORE_PR"
    static let muteMenuBarAction = "MUTE_MENU_BAR"

    /// "Ignore" options shown on every PR notification.
    static func registerCategories() {
        let ignore = UNNotificationAction(identifier: ignoreAction, title: "Ignore PR completely")
        let mute = UNNotificationAction(identifier: muteMenuBarAction, title: "Ignore in menu bar")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: prCategory, actions: [ignore, mute], intentIdentifiers: []),
        ])
    }

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

    static func post(title: String, body: String, url: String?, prID: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        var info: [String: String] = [:]
        if let url { info["url"] = url }
        if let prID { info["pr"] = prID; c.categoryIdentifier = prCategory }
        c.userInfo = info
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
    /// Set by the Store: (action id, PR id).
    @MainActor static var onAction: ((String, String) -> Void)?

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive r: UNNotificationResponse) async {
        let action = r.actionIdentifier
        if action == Notifier.ignoreAction || action == Notifier.muteMenuBarAction {
            if let id = r.notification.request.content.userInfo["pr"] as? String {
                await MainActor.run { Self.onAction?(action, id) }
            }
            return
        }
        if let s = r.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: s) {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }
}
