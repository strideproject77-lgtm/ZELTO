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
- **Codemagic IPA artifact:** each successful IPA build packages `Zelto.ipa` and `BUILD-INFO.txt` into `Zelto-IPA-Artifact.zip`; Codemagic uploads the ZIP instead of a separate raw IPA artifact. The IPA inside remains unsigned and must be re-signed before installation.
- **Latest verified Codemagic run:** build `6b0aa0f29491bc104972ae0c` on `main` completed with exit code 0 and `ARCHIVE SUCCEEDED`; its logs were received on `codemagic-logs`. ZIP packaging was added afterward and will be verified by the next Codemagic run.

The IPA builder creates an unsigned IPA; signing and installation validation are separate steps.

## iOS background-session integration

`BackgroundDownloadManager` owns two stable background `URLSession` identifiers:
- The standard background session handles compatible single-stream downloads and validator-based resume.
- `BackgroundParallelDownloadCoordinator` handles large files when the server supports byte ranges and supplies a safe ETag or Last-Modified validator. It creates up to four independent background download tasks, persists completed segment metadata, and resumes only missing segments after interruption.

Both sessions are forwarded through the same app-delegate callback. Keep one manager instance alive for the app lifetime and store download metadata in the app's Application Support directory.

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

Call `backgroundDownloads.enqueue(id:)` for a queued or paused task. Large eligible downloads use four background range tasks; small files or servers without validated range support fall back to the single-stream session. Completed ranges are stored separately with an atomic manifest; in-flight ranges are safely retried from their start. Use `pause(id:)` for a cooperative pause. The coordinator retains completed segments and discards transient in-flight bytes. Do not change either background-session identifier between app releases unless intentionally migrating the sessions.

Background URLSession transfers can continue while the app is suspended and iOS can relaunch the app to deliver events. This is not an unconditional guarantee: force-quitting the app, device shutdown, connectivity, server behavior, and system policy can affect transfers. A device-level test is still required.

## Current implementation status

- Download task state model and atomic JSON persistence: implemented
- Streaming HTTP transfer to disk: implemented
- HTTP Range resume with ETag / Last-Modified validation: implemented
- Process-restart recovery: implemented; persisted in-flight tasks reopen as paused and reconcile progress against the partial file size
- HTTP 200 fallback truncates stale partial bytes when a server ignores Range: implemented
- iOS background URLSession manager: implemented
- Background parallel range coordinator: implemented; four independent iOS-managed background download tasks, validator and Content-Range checks, per-segment durable manifest, pause/resume of completed segments, ordered merge and final-size verification; CI validation pending
- SwiftUI iOS app shell with add, list, pause, resume/retry controls and live progress refresh: implemented; simulator build passed for the latest app UI update
- App-delegate background-session forwarding: wired into the app target; device lifecycle validation pending
- Recovery regression tests added: 2
- HTTP range planner and Content-Range parser tests added alongside the existing core tests; latest CI result is tracked per commit in GitHub Actions
- Automated live-server parallel-segment interruption/restart integration test: pending
- Xcode project generation and iOS Simulator build: passed in GitHub Actions run `45995248781`
- Unsigned IPA archive: not yet verified
- Device validation, including locked-screen transfer: not run
