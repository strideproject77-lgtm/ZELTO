# Zelto

Zelto is a cross-platform download manager project, beginning with iOS.

## Repository rules

- Application development happens on `main`.
- Codemagic build diagnostics are published separately to `codemagic-logs`.
- Codemagic and GitHub Actions share the canonical IPA build script.
- Build, test, and device-validation claims are reported separately.

## CI

- **Core tests:** GitHub Actions runs `swift test` on Ubuntu 24.04 for changes to `Package.swift`, `Sources/`, or `Tests/`.
- **iOS compile:** GitHub Actions uses macOS 15 and the iOS SDK to compile the Swift package for `arm64-apple-ios16.0`.
- **iOS app:** `ios/project.yml` defines the XcodeGen app project; GitHub Actions has successfully generated the project and built the iOS Simulator target.
- **iOS IPA:** GitHub Actions and Codemagic generate the Xcode project from `ios/project.yml` and run the shared unsigned IPA archive script.
- **Codemagic log receiver:** configure environment group `zelto-github-logs` with `ZELTO_LOGS_GITHUB_TOKEN`, a fine-grained token with Contents read/write access to this repository. Latest logs are split into parts no larger than 4 MiB and published under `latest/` on `codemagic-logs`.

The IPA builder creates an unsigned IPA; signing and installation validation are separate steps.

## iOS background-session integration

`BackgroundDownloadManager` uses a stable background `URLSession` identifier and iOS-managed download tasks. Keep one manager instance alive for the app lifetime and store download metadata in the app's Application Support directory.

The host app must forward the background-session callback from its app delegate. Example integration:

```swift
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var downloadStore: DownloadStore!
    private var backgroundDownloads: BackgroundDownloadManager!

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
            downloadStore = try DownloadStore(
                fileURL: support.appendingPathComponent("zelto-downloads.json")
            )
            backgroundDownloads = BackgroundDownloadManager(store: downloadStore)
            Task { await backgroundDownloads.reconcileAfterRelaunch() }
        } catch {
            assertionFailure("Zelto download storage could not be initialized: \(error)")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        backgroundDownloads.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
```

Call `backgroundDownloads.enqueue(id:)` for a queued or paused task. Use `pause(id:)` for a cooperative pause. iOS may supply opaque resume data; when it does not, a later enqueue starts a fresh transfer. Do not change the background-session identifier between app releases unless intentionally migrating the session.

Background URLSession transfers can continue while the app is suspended and iOS can relaunch the app to deliver events. This is not an unconditional guarantee: force-quitting the app, device shutdown, connectivity, server behavior, and system policy can affect transfers. A device-level test is still required.

## Current implementation status

- Download task state model and atomic JSON persistence: implemented
- Streaming HTTP transfer to disk: implemented
- HTTP Range resume with ETag / Last-Modified validation: implemented
- Process-restart recovery: implemented; persisted in-flight tasks reopen as paused and reconcile progress against the partial file size
- HTTP 200 fallback truncates stale partial bytes when a server ignores Range: implemented
- iOS background URLSession manager: implemented and successfully compiled by the macOS/iOS SDK workflow
- SwiftUI iOS app shell with add, list, pause, resume/retry controls and live progress refresh: implemented; simulator build passed for the latest app UI update
- App-delegate background-session forwarding: wired into the app target; device lifecycle validation pending
- Recovery regression tests added: 2
- Total Swift unit tests in repository: 6; GitHub Actions test step passed for commit `8a9f414`
- Automated live-server interruption/restart integration test: pending
- Xcode project generation and iOS Simulator build: passed in GitHub Actions run `45995248781`
- Unsigned IPA archive: not yet verified
- Device validation, including locked-screen transfer: not run
