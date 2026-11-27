import Foundation
import UIKit
import ZeltoCore

@MainActor
final class ZeltoAppDelegate: NSObject, UIApplicationDelegate {
    private(set) var downloadStore: DownloadStore?
    private(set) var backgroundDownloads: BackgroundDownloadManager?
    private(set) var startupError: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let downloads = support.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

            let store = try DownloadStore(
                fileURL: support.appendingPathComponent("zelto-downloads.json")
            )
            let manager = BackgroundDownloadManager(store: store)
            downloadStore = store
            backgroundDownloads = manager

            Task {
                await manager.reconcileAfterRelaunch()
            }
        } catch {
            startupError = error.localizedDescription
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard let backgroundDownloads else {
            completionHandler()
            return
        }
        backgroundDownloads.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
