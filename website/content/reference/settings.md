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

| Option        | What it does                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------------- |
| Order         | Keeps provider order, or sorts cells by percent used                                                                |
| Format        | Stacked, Inline, Mini bars, or Custom                                                                               |
| Decimals      | 0 to 2 decimals on the percent                                                                                      |
| Hide 0%       | Drops cells whose window sits at 0%                                                                                 |
| Fit to space  | Steps down to narrower layouts when macOS hides the item for lack of room, and remembers what fit per frontmost app |
| Template      | The custom format string, built from the tokens below                                                               |
| Windows shown | Ticks the windows that get a cell; one stays selected, and each label is editable                                   |

The same code that draws the menu bar renders the preview under the controls.

### Template tokens

- `{cell}`: provider tag, plus the window tag when a provider shows several windows
- `{provider}`: `CC` or `CX`
- `{providerName}`: `Claude` or `Codex`
- `{window}`: `5h`, `7d`, `FAB`, …
- `{label}`: the editable short label
- `{pct}`, `{pct0}`, `{pct1}`, `{pct2}`: percent used at the configured / 0 / 1 / 2 decimals
- `{remaining}`: percent left
- `{reset}`: live countdown to the reset
- `{resetClock}`: reset time
- `{plan}`: plan name
- `{credits}`: credit balance

`\n` starts a second line; `{{` and `}}` produce literal braces.

## Providers

Enable or disable each provider (Claude, Codex, Gemini, Cursor, Copilot), see the credential state, and set the refresh
interval per provider. The floors are 2 minutes for Claude and 1 minute for the others; while the popover is open the
app polls at the floor. **Refresh expired tokens on my behalf** starts off, since a refresh rotates the CLI's refresh
token and writes the new one back to the
[Keychain](https://developer.apple.com/documentation/security/keychain-services) or `~/.codex/auth.json`.

## Data

How often the app fetches analytics, where the history database lives, and buttons to reveal, export
([CSV](https://datatracker.ietf.org/doc/html/rfc4180)) or clear it.

## Notifications

Threshold notifications at 50/75/90/100%, window-reset notifications, and sign-in alerts.

## Log

The last 200 log lines, a full-log window, copy and clear, a detailed-logging switch that also turns on the status item
probe, which helps when the cell disappears behind the notch, and **Demo data**, which relaunches the app on generated
numbers with a separate history file, so you can walk the screens or take screenshots without showing your account.
