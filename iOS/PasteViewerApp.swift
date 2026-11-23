import SwiftUI
import UIKit

@main
struct PasteViewerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ClipListView()
                .themedRoot()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CloudKit's silent pushes let iOS wake the app to sync while it's closed.
        application.registerForRemoteNotifications()
        Task { await CloudSync.shared.start() }
        return true
    }

    nonisolated func application(_ application: UIApplication,
                                 didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await CloudSync.shared.fetchNow()
        return .newData
    }
}
