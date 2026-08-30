# Token Menu Bar

A macOS menu bar app that shows how much of your Claude (Pro/Max), OpenAI Codex (Plus/Pro), Gemini CLI, Cursor and
GitHub Copilot plan limits you have used, in the detail the vendor usage pages show: session, weekly and monthly windows
per model, usage credits and spend limits, reset countdowns, pace projections, notifications, 60 days of local history,
desktop widgets, and the Codex and Claude analytics charts.

It reads the tokens the `claude`, `codex`, `gemini`, Cursor and Copilot clients keep on your Mac, so you sign in to the
clients rather than to this app, and it calls only the vendors' own endpoints.

| Provider                                                   | Reads                      | Windows         |
| ---------------------------------------------------------- | -------------------------- | --------------- |
| <img src="website/static/brand/glyph/claude.svg"> Claude   | Keychain, `~/.claude`      | session, weekly |
| <img src="website/static/brand/glyph/codex.svg"> Codex     | `~/.codex`                 | 5-hour, weekly  |
| <img src="website/static/brand/glyph/gemini.svg"> Gemini   | `~/.gemini`                | daily per model |
| <img src="website/static/brand/glyph/cursor.svg"> Cursor   | Cursor app, `~/.cursor`    | plan, spend     |
| <img src="website/static/brand/glyph/copilot.svg"> Copilot | `~/.config/github-copilot` | premium         |

Website with screenshots and a feature tour: <https://tox-dev.github.io/token-menu-bar-macos/>. `just shots` refreshes
the screenshots.

## Install

| Channel         | How                                                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mac App Store   | sandboxed build, which the release workflow uploads once the Apple Developer account is enrolled                                                    |
| Homebrew        | `brew install --cask token-menu-bar` once the cask lands in homebrew-cask; until then `brew install --cask Casks/token-menu-bar.rb` from a checkout |
| Direct download | `TokenMenuBar.dmg` from the [latest release](https://github.com/tox-dev/token-menu-bar-macos/releases/latest), which updates itself through Sparkle |

Requires macOS 26. Sign in once with each client you use (`claude`, `codex login`, `gemini`, the Cursor app, Copilot
CLI/Neovim/JetBrains); the app picks the tokens up from the Keychain (`Claude Code-credentials`), `~/.codex/auth.json`,
`~/.gemini/oauth_creds.json`, Cursor's `state.vscdb` and `~/.config/github-copilot`. A provider you have not signed into
stays hidden until its token appears; Settings > Providers toggles them. The App Store build asks you to point it at
`~/.codex`, which the sandbox cannot read on its own.

## What you see

### Menu bar

One cell per selected window (`CC 36%`, `CX 62%`), stacked, inline, mini bars, or a custom template with `{provider}`,
`{window}`, `{pct}`, `{reset}` and friends. Windows at 0% stay hidden; the icon turns gray offline and takes a badge
when a client needs a sign-in. With "Fit to space" on, the cells step down to narrower layouts (one cell per provider,
mini bars, icon only) when the menu bar runs out of room next to the notch, and step back up per app.

### Widgets

Small, medium and large desktop and Notification Center widgets carrying the selected windows, percent bars and reset
countdowns. Each fetch refreshes them.

### Usage tab

Per provider: plan chips (`Max 20x`, `Pro`), every limit window with percent, reset countdown and pace ("Ahead of pace,
hits 100% at 3:40 PM"), Claude usage credits and monthly spend cap, Codex credits, reset credits and spend controls,
promotions and limit-reached notices.

### History tab

Window percentages over time with reset cliffs, min/max-preserving downsampling, stacked mode, UTC or local time, custom
ranges with paging, an inspector legend, and the Codex analytics the website charts (usage by surface, credits by model,
turns, tokens, skills, plugins, code review).

### Settings tab

Menu bar format with live preview, window selection and short labels, providers and credential status, refresh cadence,
history export and clear, notification thresholds, the log, and a demo-data switch that swaps in generated numbers
(`open -a "Token Menu Bar" --args --demo` and `TOKEN_MENU_BAR_DEMO=1` do the same).

The app keeps the poll interval long on purpose: the Anthropic usage endpoint allows a handful of calls per token before
it answers 429 for a long time, so it reads Claude every 5 minutes (2 minutes while the popover is open) and Codex every
2 minutes (1 minute while open). A 429 backs the interval off from 5 to 30 minutes, and the last good values stay on
screen.

Token refresh starts off. Refreshing rotates the CLI's refresh token, so the app touches it only after you opt in under
Settings > Providers.

## Development

[mise](https://mise.jdx.dev) pins the tools and [just](https://just.systems) runs the workflows.

```sh
mise install   # hugo, just, pre-commit, xcodegen
just           # the list of workflows
just check     # build, tests with the coverage gate, every lint hook
just run       # ad-hoc .app for machines without Xcode, launched
just install   # the same build, into /Applications
```

The package has three targets: `TokenMenuBarCore` (the logic, no AppKit), `TokenMenuBarUI` (a thin SwiftUI and AppKit
layer), and the `TokenMenuBar` executable. `just coverage` fails when a line in Core or UI never runs during the tests.

`swift test` needs a toolchain that ships swift-testing (Xcode, or a swift.org toolchain via `swiftly`). Ad-hoc dev
builds take a fresh code signature each time, so macOS asks for Keychain access on every rebuild; signed release builds
ask once.

`just xcode` writes the Xcode project. Two schemes exist, `TokenMenuBar-Direct` (Developer ID, hardened runtime,
Sparkle) and `TokenMenuBar-AppStore` (sandbox, no updater).

## Releasing

Tag `vX.Y.Z`. The release workflow builds the Direct app, signs and notarizes it when the `DEVELOPER_ID_*` and
`APP_STORE_CONNECT_*` secrets exist (ad-hoc otherwise), publishes the zip, DMG, checksums and Sparkle appcast on the
GitHub release, refreshes `Casks/token-menu-bar.rb`, and, when the `APP_STORE_ENABLED` variable is `true`, archives the
sandboxed flavor and uploads it to App Store Connect.

Secrets the workflow understands: `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`,
`APPLE_DISTRIBUTION_CERTIFICATE_BASE64`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`,
`APP_STORE_PROVISIONING_PROFILE_BASE64`, `APPLE_TEAM_ID`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_KEY_BASE64`, `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_PRIVATE_ED_KEY`.

## Where the numbers come from

**Claude**: the Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`) supplies the OAuth token; the
app calls `GET /api/oauth/usage` and `GET /api/oauth/profile` on `api.anthropic.com` with
`anthropic-beta: oauth-2025-04-20`.

**Codex**: `~/.codex/auth.json` (`CODEX_HOME` honoured) supplies the token; the app calls
`chatgpt.com/backend-api/wham/usage`, `wham/rate-limit-reset-credits`, `wham/usage/daily-token-usage-breakdown` and the
`wham/analytics/*` endpoints.

**Gemini**: `~/.gemini/oauth_creds.json` (`GEMINI_CLI_HOME` honoured) supplies the Google OAuth token; the app calls
`cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` for the plan and project, then `:retrieveUserQuota` for the
per-model daily buckets. Google ended Login with Google for personal accounts in June 2026, so quota reaches Workspace
and Code Assist Standard/Enterprise accounts alone; the app says so instead of showing numbers.

**Cursor**: the app sends the session token from Cursor's `state.vscdb` (or `~/.cursor/auth.json` from `cursor-agent`)
as the `WorkosCursorSessionToken` cookie to `cursor.com/api/usage-summary` and `/api/auth/me`, falling back to
`api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`.

**Copilot**: the app sends the `oauth_token` from `~/.config/github-copilot/hosts.json` or `apps.json` to
`api.github.com/copilot_internal/user`, which reports premium requests, chat and completion quotas per month.

When Codex is offline or signed out the app falls back to the last `rate_limits` event in `~/.codex/sessions`.
