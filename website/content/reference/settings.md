---
title: Settings reference
description: What each option in the Settings tab does.
icon: M4 6h16M4 12h16M4 18h16M8 4v4M16 10v4M11 16v4
weight: 3
---

The popover's Settings tab holds these options. A change takes effect as you make it and survives a restart.

## About

Version and build flavour,
**[Launch at login](https://developer.apple.com/documentation/servicemanagement/smappservice)** (with a shortcut to
Login Items when macOS wants approval), **Reset Defaults**, **Copy Diagnostics** (a report with versions, provider state
and the last log lines), **Report Issue** (opens a pre-filled GitHub issue), and, in the direct build, automatic update
checks through [Sparkle](https://sparkle-project.org).

## Menu bar

| Option               | What it does                                                                                                                                                                        |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Order                | Keeps provider order, or sorts cells by percent used                                                                                                                                |
| Format               | Stacked, Inline, Mini bars, Countdown (percent then the time to reset), Countdown at 100% (percent until a window is exhausted, then the time to its reset), or Custom              |
| Decimals             | 0 to 2 decimals on the percent                                                                                                                                                      |
| Hide 0%              | Drops cells whose window sits at 0%                                                                                                                                                 |
| Fit to space         | Steps down to narrower layouts when macOS hides the item for lack of room, and remembers what fit per frontmost app                                                                 |
| Hide account details | Replaces e-mail addresses with `account` and workspace names with `workspace` in the popover, the provider list and the diagnostics report                                          |
| Show usage as        | Used shows the share of each window spent; Left shows what remains. Applies to the menu bar, the Usage tab, the widgets and the `{pct}` tokens; colours still follow the used share |
| Template             | The custom format string, built from the tokens below                                                                                                                               |
| Windows shown        | Ticks the windows that get a cell; one stays selected, and each label is editable                                                                                                   |

The same code that draws the menu bar renders the preview under the controls.

### Template tokens

- `{cell}`: provider tag, plus the window tag when a provider shows several windows
- `{provider}`: `CC` or `CX`
- `{providerName}`: `Claude` or `Codex`
- `{window}`: `5h`, `7d`, `FAB`, …
- `{label}`: the editable short label
- `{pct}`, `{pct0}`, `{pct1}`, `{pct2}`: percent at the configured / 0 / 1 / 2 decimals, used or left per **Show usage
  as**
- `{remaining}`: percent left, whatever **Show usage as** says
- `{pctOrReset}`: the percent, or the reset countdown once the window is at 100%
- `{reset}`: live countdown to the reset
- `{resetClock}`: reset time
- `{plan}`: plan name
- `{credits}`: credit balance

`\n` starts a second line; `{{` and `}}` produce literal braces.

## Providers

Enable or disable each provider (Claude, Codex, Gemini, Antigravity, Cursor, Copilot), see the credential state, and set
the refresh interval per provider. The floors are 2 minutes for Claude and 1 minute for the others; while the popover is
open the app polls at the floor. **Refresh expired tokens on my behalf** starts off, since a refresh rotates the CLI's
refresh token and writes the new one back to the
[Keychain](https://developer.apple.com/documentation/security/keychain-services) or credential file. If the app and a
running CLI refresh the same credential at once, the CLI can retain the old rotated token; its next refresh can fail and
require another sign-in.

Each provider row shows the credential source and resolved path. `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `GEMINI_CLI_HOME`,
and `XDG_CONFIG_HOME` apply only when the app process receives them. The same rule covers `GH_TOKEN` and Gemini's
credential-storage and OAuth-client variables. Finder and login-item launches do not load exports from shell startup
files such as `.zshrc`.

## Data

How often the app fetches analytics, where the history database lives, and buttons to reveal, export
([CSV](https://datatracker.ietf.org/doc/html/rfc4180)) or clear it. **Expect usage on N days a week** (4 to 7) spreads
the expected pace of windows longer than a day over Monday to the chosen weekday, so a weekly window is not ahead of
pace on Monday morning; 7 keeps an even pace.

## Notifications

Threshold notifications at 50/75/90/100%, window-reset notifications, sign-in alerts, a warning when a Codex reset
credit expires within 24 hours, pace notices, and a sound switch. Several windows crossing a threshold in one refresh
arrive as one grouped notice. The pace notices say when a window will run out before it resets and when it pulls ahead
of pace; each fires once per window and reset period, arms again after a refresh on which the pace had recovered, and
stays quiet during the first 5% of a window.

## Log

The last 200 log lines, a full-log window, copy and clear, a detailed-logging switch that also turns on the status item
probe, which helps when the cell disappears behind the notch, and **Demo data**, which relaunches the app on generated
numbers with a separate history file, so you can walk the screens or take screenshots without showing your account.
