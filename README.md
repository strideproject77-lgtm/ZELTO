# Zelto

Zelto is a cross-platform download manager project, beginning with iOS.

## Repository rules

- Application development happens on `main`.
- Codemagic build diagnostics are published separately to `codemagic-logs`.
- Codemagic and GitHub Actions share the canonical IPA build script.
- Build, test, and device-validation claims are reported separately.

## CI

- **Core tests:** GitHub Actions runs `swift test` on changes to `Package.swift`, `Sources/`, or `Tests/`.
- **iOS IPA:** GitHub Actions and Codemagic build only when files under `ios/` or the iOS build configuration change. The repository does not yet contain an Xcode project, so an IPA build is not currently possible.
- **Codemagic log receiver:** configure environment group `zelto-github-logs` with `ZELTO_LOGS_GITHUB_TOKEN`, a fine-grained token with Contents read/write access to this repository. Latest logs are split into parts no larger than 4 MiB and published under `latest/` on `codemagic-logs`.

The IPA builder creates an unsigned IPA; signing and installation validation are separate steps.

## Current implementation status

- Download task state model: implemented
- Atomic JSON persistence: implemented
- Streaming HTTP transfer to disk: implemented
- HTTP Range resume with ETag / Last-Modified validation: implemented
- Progress persistence and transfer state coordination: implemented
- Swift unit tests: 4 passing locally on Swift 6.2.1 / Linux
- Local HTTP 206 resume smoke test: passed (1 MiB payload, byte-for-byte verified)
- Automated interrupted-connection/restart integration test: pending
- iOS background URLSession integration: not implemented
- Xcode app target / IPA build: not implemented or run
- Device validation: not run
