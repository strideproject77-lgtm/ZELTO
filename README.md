# Zelto

Zelto is a cross-platform download manager project. The repository starts with the CI/build foundation; product code will be added in verified milestones.

## Repository rules

- Application development happens on `main`.
- Codemagic build diagnostics are published separately to `codemagic-logs`.
- Codemagic and GitHub Actions use the same canonical IPA build script.
- No IPA build is considered successful until a real Xcode archive and IPA packaging complete.

## CI setup

### GitHub Actions

Open **Actions → Zelto iOS IPA Builder → Run workflow**. The workflow runs on a macOS runner and uploads the IPA and build diagnostics as artifacts.

### Codemagic

Connect this repository to Codemagic and select the `zelto-ipa` workflow from `codemagic.yaml`.

Create a Codemagic environment variable group named `zelto-github-logs` with:

- `ZELTO_LOGS_GITHUB_TOKEN`: a fine-grained GitHub token with Contents: Read and write permission for this repository.

The log publisher redacts common credential patterns and writes the latest build logs as parts under `latest/` on the `codemagic-logs` branch. Each part is kept below 5 MiB.

### Build prerequisites

The repository currently has no Xcode project/workspace. The builders are scaffolded and will intentionally stop with a clear diagnostic until the iOS app target is added. The IPA packaging path creates an unsigned IPA suitable for a later sideload-signing step; it does not claim to produce an install-ready signed IPA.

## Current status

- CI/CD scaffold: in progress
- iOS app source: not started
- IPA build: not run (no Xcode project exists)
- Device validation: not run
