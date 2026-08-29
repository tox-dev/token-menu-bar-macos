# Token Menu Bar

A macOS menu bar app that shows how much of your Claude (Pro/Max) and OpenAI Codex (Plus/Pro) plan limits you have used,
with the same detail the vendor usage pages show: session and weekly windows per model, usage credits and spend limits,
reset countdowns, pace projections, notifications, 60 days of local history, and the Codex analytics charts.

It reads the tokens the `claude` and `codex` CLIs already store on your Mac; it never asks you to sign in again and
never sends anything anywhere but `api.anthropic.com` and `chatgpt.com`.

## Install

- **Direct download**: grab `TokenMenuBar.dmg` from the
  [latest release](https://github.com/tox-dev/token-menu-bar-macos/releases/latest); the app updates itself through
  Sparkle.
- **Homebrew**: `brew install --cask token-menu-bar` once the cask lands in homebrew-cask; until then
  `brew install --cask Casks/token-menu-bar.rb` from a checkout.
- **Mac App Store**: sandboxed build, submitted from the release workflow once the Apple Developer account is enrolled.

Requires macOS 26. Sign in once with `claude` and `codex login`; the app picks the tokens up from the Keychain
(`Claude Code-credentials`) and `~/.codex/auth.json`. The App Store build asks you to point it at `~/.codex` because the
sandbox cannot read it on its own.

## What you see

- **Menu bar**: one cell per selected window (`CC 36%`, `CX 62%`), stacked, inline, mini bars, or a custom template with
  `{provider}`, `{window}`, `{pct}`, `{reset}` and friends. Windows at 0% stay hidden; the icon turns gray offline and
  gets a badge when a sign-in is needed.
- **Usage tab**: per provider, plan chips (`Max 20x`, `Pro`), every limit window with percent, reset countdown and pace
  ("Ahead of pace, hits 100% at 3:40 PM"), Claude usage credits and monthly spend cap, Codex credits, reset credits and
  spend controls, promotions and limit-reached notices.
- **History tab**: window percentages over time with reset cliffs, min/max-preserving downsampling, stacked mode,
  UTC/local, custom ranges with paging, an inspector legend, and the Codex analytics the website charts (usage by
  surface, credits by model, turns, tokens, skills, plugins, code review).
- **Settings tab**: menu bar format with live preview, window selection and short labels, providers and credential
  status, refresh cadence, history export/clear, notification thresholds, and the log.

Token refresh is off by default: refreshing rotates the CLI's refresh token, so the app only does it when you opt in
under Settings > Providers.

## Development

The package has three targets: `TokenMenuBarCore` (all logic, no AppKit), `TokenMenuBarUI` (thin SwiftUI/AppKit layer),
and the `TokenMenuBar` executable. Every line of Core and UI is covered by tests; `Scripts/coverage.sh` fails otherwise.

```sh
swift build
swift test
Scripts/coverage.sh          # tests plus the 100% line gate
Scripts/bundle-dev.sh --run  # ad-hoc .app for machines without Xcode
```

`swift test` needs a toolchain that ships swift-testing (Xcode, or a swift.org toolchain via `swiftly`). Ad-hoc dev
builds get a fresh code signature each time, so macOS asks for Keychain access on every rebuild; signed release builds
ask once.

The Xcode project is generated: `cd App && xcodegen generate`. Two schemes exist, `TokenMenuBar-Direct` (Developer ID,
hardened runtime, Sparkle) and `TokenMenuBar-AppStore` (sandbox, no updater).

## Releasing

Tag `vX.Y.Z`. The release workflow builds the Direct app, signs and notarizes it when the `DEVELOPER_ID_*` and
`APP_STORE_CONNECT_*` secrets exist (ad-hoc otherwise), publishes the zip, DMG, checksums and Sparkle appcast on the
GitHub release, refreshes `Casks/token-menu-bar.rb`, and, when the `APP_STORE_ENABLED` variable is `true`, archives the
sandboxed flavor and uploads it to App Store Connect.

Secrets the workflow understands: `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`,
`APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`,
`APP_STORE_PROVISIONING_PROFILE_BASE64`, `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_KEY_BASE64`, `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_PRIVATE_ED_KEY`.

## How the data is fetched

- **Claude**: the Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) supplies the OAuth token;
  the app calls `GET /api/oauth/usage` and `GET /api/oauth/profile` on `api.anthropic.com` with
  `anthropic-beta: oauth-2025-04-20`.
- **Codex**: `~/.codex/auth.json` (`CODEX_HOME` honoured) supplies the token; the app calls
  `chatgpt.com/backend-api/wham/usage`, `wham/rate-limit-reset-credits`, `wham/usage/daily-token-usage-breakdown` and
  the `wham/analytics/*` endpoints.

When Codex is offline or signed out the app falls back to the last `rate_limits` event in `~/.codex/sessions`.
