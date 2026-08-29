---
title: Settings
description: 'Every option: menu bar format, providers, refresh cadence, data, notifications and the log.'
weight: 3
---

Everything lives in the popover's Settings tab; changes apply immediately and persist.

## About

Version and build flavour, **Launch at login** (with a shortcut to Login Items when macOS wants approval), **Reset
Defaults**, **Copy Diagnostics** (a report with versions, provider state and the last log lines), **Report Issue**
(opens a pre-filled GitHub issue), and, in the direct build, automatic update checks.

## Menu bar

- **Order**: keep provider order, or sort cells by percent used.
- **Format**: Stacked, Inline, Mini bars, or Custom.
- **Decimals**: 0 to 2 decimals on the percent.
- **Hide 0%**: drop cells whose window is at 0%.
- **Fit to space**: step down to narrower layouts when macOS hides the item for lack of room, and remember what fit per
  frontmost app.
- **Template**: the custom format string, built from the tokens below.
- **Windows shown**: tick the windows that get a cell; at least one stays selected, and labels are editable per window.

The preview under the controls is rendered by the same code that draws the menu bar.

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
app polls at the floor. **Refresh expired tokens on my behalf** is off by default because refreshing rotates the CLI's
refresh token and writes it back to the Keychain or `~/.codex/auth.json`.

## Data

How often analytics are fetched, where the history database lives, and buttons to reveal, export (CSV) or clear it.

## Notifications

Threshold notifications at 50/75/90/100%, window-reset notifications, and sign-in alerts.

## Log

The last 200 log lines, a full-log window, copy and clear, a detailed-logging switch that also enables the status item
probe (useful when the cell disappears behind the notch), and **Demo data**, which relaunches the app on generated
numbers with a separate history file so you can try every screen, or take screenshots, without exposing your account.
