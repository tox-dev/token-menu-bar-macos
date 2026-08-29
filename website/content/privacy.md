---
title: Privacy and limits
description: What the app reads, where it sends it, and why polling is deliberately slow.
weight: 4
---

## What the app reads

- **Claude** reads the Keychain item `Claude Code-credentials` (or `~/.claude/.credentials.json`), `~/.claude.json` and
  `~/.claude/projects/**/*.jsonl`; it calls `GET api.anthropic.com/api/oauth/usage` and
  `GET api.anthropic.com/api/oauth/profile`.
- **Codex** reads `~/.codex/auth.json` (`CODEX_HOME` honoured) and `~/.codex/sessions/**/rollout-*.jsonl`; it calls
  `chatgpt.com/backend-api/wham/usage`, `wham/rate-limit-reset-credits`, `wham/usage/daily-token-usage-breakdown` and
  `wham/analytics/*`.
- **Gemini** reads `~/.gemini/oauth_creds.json` (`GEMINI_CLI_HOME` honoured); it calls
  `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `:retrieveUserQuota`, and `oauth2.googleapis.com/token`
  only when you opt into token refresh.
- **Cursor** reads Cursor's `state.vscdb` (read-only, immutable open) or `~/.cursor/auth.json`; it calls
  `cursor.com/api/usage-summary`, `cursor.com/api/auth/me` and, as a fallback,
  `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`.
- **Copilot** reads `~/.config/github-copilot/hosts.json` and `apps.json` (`XDG_CONFIG_HOME` honoured); it calls
  `api.github.com/copilot_internal/user`.
- **Widgets** read a JSON snapshot the app writes into the app group container; it holds window labels, percentages and
  reset times, never tokens.

Nothing is sent anywhere else. There is no telemetry, no crash reporting, and no account of ours. The history database
and log live under `~/Library/Application Support/Token Menu Bar/`; the log never contains tokens, request headers or
response bodies other than short error snippets.

## Token refresh

Both CLIs rotate their refresh tokens when a token is refreshed. If the app refreshed on your behalf and could not write
the new token back, the CLI would be signed out, so the app leaves expired tokens alone and shows a sign-in hint
instead. You can opt in under Settings > Providers.

## Rate limits

The Anthropic usage endpoint is undocumented and allows only a handful of requests per token before it answers `429` for
a long time; Claude Code itself never polls it. The app therefore polls Claude every 5 minutes by default (2 minutes
while the popover is open), Codex every 2 minutes (1 minute while open), backs off exponentially from `Retry-After` (60
s floor, 30 min cap) and keeps showing the last good values with their age.
