---
title: Privacy and rate limits
description: What the app reads, where it sends it, and why the poll interval stays long.
weight: 4
aliases: [/explanation/privacy/]
---

## What the app reads

| Source                                                         | Files it reads                                                                                                                | Endpoints it calls                                                                                                                               |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| [Claude](https://docs.claude.com/en/docs/claude-code/overview) | Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`), `~/.claude.json`, `~/.claude/projects/**/*.jsonl` | `GET api.anthropic.com/api/oauth/usage`, `GET api.anthropic.com/api/oauth/profile`                                                               |
| [Codex](https://developers.openai.com/codex/cli/)              | `~/.codex/auth.json` (`CODEX_HOME` honoured), `~/.codex/sessions/**/rollout-*.jsonl`                                          | `chatgpt.com/backend-api/wham/usage`, `wham/rate-limit-reset-credits`, `wham/usage/daily-token-usage-breakdown`, `wham/analytics/*`              |
| [Gemini](https://github.com/google-gemini/gemini-cli)          | `~/.gemini/oauth_creds.json` (`GEMINI_CLI_HOME` honoured)                                                                     | `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`, `:retrieveUserQuota`, and `oauth2.googleapis.com/token` once you opt into token refresh |
| [Cursor](https://cursor.com/docs)                              | Cursor's `state.vscdb` (read-only, immutable open) or `~/.cursor/auth.json`                                                   | `cursor.com/api/usage-summary`, `cursor.com/api/auth/me`, falling back to `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`    |
| [Copilot](https://docs.github.com/en/copilot)                  | `~/.config/github-copilot/hosts.json`, `apps.json` (`XDG_CONFIG_HOME` honoured)                                               | `api.github.com/copilot_internal/user`                                                                                                           |
| [Widgets](https://developer.apple.com/documentation/widgetkit) | the JSON snapshot the app writes into the app group container: window labels, percentages and reset times, and no tokens      | none                                                                                                                                             |

Those five hosts are the only ones the app contacts. It runs no telemetry, reports no crashes, and keeps no account of
yours. The [SQLite](https://sqlite.org) history database and the log live under
`~/Library/Application Support/Token Menu Bar/`; the log records short error snippets, and leaves out tokens, request
headers and response bodies.

## Token refresh

Both CLIs rotate their [OAuth refresh token](https://datatracker.ietf.org/doc/html/rfc6749#section-6) each time they
refresh. If the app refreshed on your behalf and then failed to write the new token back, the CLI would lose its
session, so the app leaves expired tokens alone and shows a sign-in hint instead. Settings > Providers turns the refresh
on.

## Rate limits

The [Anthropic](https://www.anthropic.com/pricing) usage endpoint carries no documentation and allows a handful of
requests per token before it answers `429` for a long time;
[Claude Code](https://docs.claude.com/en/docs/claude-code/overview) itself leaves it alone. So the app reads Claude
every 5 minutes by default (2 minutes while the popover is open) and Codex every 2 minutes (1 minute while open). It
backs off from `Retry-After` between a 60-second floor and a 30-minute cap, and keeps the last good values on screen
with their age.
