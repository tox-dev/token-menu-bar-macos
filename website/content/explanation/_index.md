---
title: Privacy and rate limits
description: What the app reads, where it sends it, and why the poll interval stays long.
weight: 4
aliases: [/explanation/privacy/]
---

## What the app reads

| Source  | Files it reads                                                                                                                | Endpoints it calls                                                                                                                               |
| ------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Claude  | Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`), `~/.claude.json`, `~/.claude/projects/**/*.jsonl` | `GET api.anthropic.com/api/oauth/usage`, `GET api.anthropic.com/api/oauth/profile`                                                               |
| Codex   | `~/.codex/auth.json` (`CODEX_HOME` honoured), `~/.codex/sessions/**/rollout-*.jsonl`                                          | `chatgpt.com/backend-api/wham/usage`, `wham/rate-limit-reset-credits`, `wham/usage/daily-token-usage-breakdown`, `wham/analytics/*`              |
| Gemini  | `~/.gemini/oauth_creds.json` (`GEMINI_CLI_HOME` honoured)                                                                     | `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`, `:retrieveUserQuota`, and `oauth2.googleapis.com/token` once you opt into token refresh |
| Cursor  | Cursor's `state.vscdb` (read-only, immutable open) or `~/.cursor/auth.json`                                                   | `cursor.com/api/usage-summary`, `cursor.com/api/auth/me`, falling back to `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`    |
| Copilot | `~/.config/github-copilot/hosts.json`, `apps.json` (`XDG_CONFIG_HOME` honoured)                                               | `api.github.com/copilot_internal/user`                                                                                                           |
| Widgets | the JSON snapshot the app writes into the app group container: window labels, percentages and reset times, and no tokens      | none                                                                                                                                             |

Those five hosts are the only ones the app contacts. It runs no telemetry, reports no crashes, and keeps no account of
yours. The history database and log live under `~/Library/Application Support/Token Menu Bar/`; the log records short
error snippets, and leaves out tokens, request headers and response bodies.

## Token refresh

Both CLIs rotate their refresh token each time they refresh. If the app refreshed on your behalf and then failed to
write the new token back, the CLI would lose its session, so the app leaves expired tokens alone and shows a sign-in
hint instead. Settings > Providers turns the refresh on.

## Rate limits

The Anthropic usage endpoint carries no documentation and allows a handful of requests per token before it answers `429`
for a long time; Claude Code itself leaves it alone. So the app reads Claude every 5 minutes by default (2 minutes while
the popover is open) and Codex every 2 minutes (1 minute while open). It backs off from `Retry-After` between a
60-second floor and a 30-minute cap, and keeps the last good values on screen with their age.
