import SwiftUI
import UserNotifications

@main
struct GitWallApp: App {
    @StateObject private var store = Store()
    private let notifDelegate = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notifDelegate
        Task { await Notifier.requestAccess() }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.menuBarSymbol)
                if store.changesRequestedCount > 0 {
                    Text("\(store.changesRequestedCount)")
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
