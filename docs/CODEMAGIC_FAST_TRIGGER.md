# Zelto fast Codemagic trigger

Zelto can start its Codemagic IPA workflow from GitHub Actions using the Codemagic REST API. This avoids opening the Codemagic dashboard just to submit a build request.

## One-time GitHub repository secrets

In **Settings → Secrets and variables → Actions**, add:

- `CODEMAGIC_API_TOKEN`: your personal Codemagic API token from Codemagic Account settings → API token.
- `CODEMAGIC_APP_ID`: the Zelto application ID shown in the Codemagic app URL:
  `https://codemagic.io/app/<APP_ID>/settings`.

These are different credentials from `ZELTO_LOGS_GITHUB_TOKEN`. Do not put the Codemagic API token in the log-publishing variable group and do not commit either value to the repository.

## Start a build

1. Open the Zelto repository's **Actions** tab.
2. Select **Trigger Zelto Codemagic Build**.
3. Select **Run workflow** on the `main` branch.

The action calls Codemagic with workflow ID `zelto-ipa` and branch `main`, then prints the returned build ID and direct build link.

## Important queue behavior

The GitHub action normally submits the API request within seconds. This does **not** bypass Codemagic concurrency limits, machine allocation, or a provider-side queue. Codemagic can still show the accepted build as `queued` or `waiting`; the API trigger cannot guarantee that the macOS machine itself starts within 10 seconds.

This trigger is manual by design. Normal pushes and GitHub Actions tests do not automatically launch a second Codemagic build.
