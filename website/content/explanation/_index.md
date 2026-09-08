---
title: Privacy and rate limits
description: What the app reads, where it sends it, and why the poll interval stays long.
weight: 4
aliases: [/explanation/privacy/]
---

## What the app reads

| Source                                                         | Files it reads                                                                                                                                              | Endpoints it calls                                                                                                                               |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| [Claude](https://docs.claude.com/en/docs/claude-code/overview) | Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`; `CLAUDE_CONFIG_DIR` honoured), `~/.claude.json`, `~/.claude/projects/**/*.jsonl` | `GET api.anthropic.com/api/oauth/usage`, `GET api.anthropic.com/api/oauth/profile`                                                               |
| [Codex](https://developers.openai.com/codex/cli/)              | `~/.codex/auth.json` (`CODEX_HOME` honoured), `~/.codex/sessions/**/rollout-*.jsonl`                                                                        | `chatgpt.com/backend-api/wham/usage`, `wham/rate-limit-reset-credits`, `wham/usage/daily-token-usage-breakdown`, `wham/analytics/*`              |
| [Gemini](https://github.com/google-gemini/gemini-cli)          | `~/.gemini/oauth_creds.json` (`GEMINI_CLI_HOME` honoured)                                                                                                   | `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`, `:retrieveUserQuota`, and `oauth2.googleapis.com/token` once you opt into token refresh |
| [Cursor](https://cursor.com/docs)                              | Cursor's `state.vscdb` (read-only, immutable open) or `~/.cursor/auth.json`                                                                                 | `cursor.com/api/usage-summary`, `cursor.com/api/auth/me`, falling back to `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`    |
| [Copilot](https://docs.github.com/en/copilot)                  | `~/.config/github-copilot/hosts.json`, `apps.json` (`XDG_CONFIG_HOME` honoured)                                                                             | `api.github.com/copilot_internal/user`                                                                                                           |
| [Widgets](https://developer.apple.com/documentation/widgetkit) | the JSON snapshot the app writes into the app group container: window labels, percentages and reset times, and no tokens                                    | none                                                                                                                                             |

Those five hosts are the only ones the app contacts. It runs no telemetry, reports no crashes, and keeps no account of
yours. Direct and Homebrew builds keep the [SQLite](https://sqlite.org) history database and the log under
`~/Library/Application Support/Token Menu Bar/`. The App Store build uses
`~/Library/Containers/dev.tox.token-menu-bar/Data/Library/Application Support/Token Menu Bar/`. The log records short
error snippets and leaves out tokens, request headers and response bodies.

Environment overrides apply only when they exist in the app process. Finder and login-item launches do not load exports
from shell startup files such as `.zshrc`; Settings > Providers shows the source and path the app resolved.

The App Store widget uses the `group.dev.tox.token-menu-bar` app group. Direct and Homebrew builds use
`<Team ID>.dev.tox.token-menu-bar`; the channels do not share widget snapshots.

## Scope

The app tracks these six providers on purpose: they are the ones it can read locally. A provider is added only when a
local credential and an official usage endpoint exist for it, so it never asks for a browser session or scrapes a
dashboard. Antigravity joined once its language server and the `agy` CLI exposed a quota summary; Gemini CLI stays for
Workspace and Code Assist accounts.

## Token refresh

Claude, Codex, and Gemini rotate their [OAuth refresh token](https://datatracker.ietf.org/doc/html/rfc6749#section-6)
when they refresh. The app leaves expired tokens alone and shows a sign-in hint unless Settings > Providers enables
refresh. Antigravity uses a Google refresh token that does not rotate; the same setting gates its refresh, and the
renewed access token stays in memory because Antigravity owns the Keychain item. If the app and a running CLI refresh
the same credential at once, the CLI can retain the old rotated token; its next refresh can fail and require another
sign-in.

## Rate limits

The [Anthropic](https://www.anthropic.com/pricing) usage endpoint carries no documentation and allows a handful of
requests per token before it answers `429` for a long time;
[Claude Code](https://docs.claude.com/en/docs/claude-code/overview) itself leaves it alone. So the app reads Claude
every 5 minutes by default (2 minutes while the popover is open) and Codex every 2 minutes (1 minute while open). It
backs off from `Retry-After` between a 60-second floor and a 30-minute cap, and keeps the last good values on screen
with their age.
