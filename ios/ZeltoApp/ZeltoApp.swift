import SwiftUI

@main
struct ZeltoApp: App {
    @UIApplicationDelegateAdaptor(ZeltoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DownloadListView()
        }
    }
}
