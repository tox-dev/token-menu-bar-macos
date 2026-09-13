---
title: Claude
description: Claude Code sign-in, session and weekly limits, usage credits and transcript analytics.
provider: claude
weight: 1
---

## Connect

Sign in through Claude Code with `claude auth login`, then enable Claude in **Settings > Providers**. Use **Show all
providers** if Claude is absent. Check **Authentication** for the source in use.

The app reads Keychain service `Claude Code-credentials` or `~/.claude/.credentials.json`. Local profile and transcript
files live under `~/.claude`; `CLAUDE_CONFIG_DIR` selects a different root. See
[custom credential paths](/start/connect/#custom-credential-paths) for Finder and login-item launches.

## Quota and credits

Usage shows the current session, account-wide weekly and model-specific limits, plus plan and email when reported. An
exhausted weekly limit marks affected menu bar cells even if you selected a session that has quota left. Reset
timestamps use local time; exact deadlines include a countdown.

Reported credit details include the cap, spend, balance, reload state and deadlines. A zero credit cap is meaningful.
Credit balances and quota percentages measure different limits.

The app reads vendor responses, not the browser usage page. Promotional text, billing details or browser-only fields may
have no equivalent in the API; absent fields do not become zeroes or “not reported” rows.

## History and costs

Claude Code transcripts supply input, output, cached-input and cache-write tokens, API-equivalent costs, messages,
sessions, tools and project breakdowns. They exclude browser-only activity and work recorded on another Mac.

Costs estimate API pricing for recorded model usage; they are not your subscription bill. Daily records retain UTC day
buckets. [History](/reference/history/) explains the timezone and metric controls.

## Expired credentials

Use **Sign in…** to open the detected client's recovery route. Cached quota turns gray until a fetch succeeds; local
transcript costs have their own freshness. File-access failures offer setup or a resource grant.

**Refresh expired tokens on my behalf** starts off. Enabling it permits OAuth refresh and saving credentials to the
original source. Rotation can invalidate a token still held by Claude Code; read the
[shared-token trade-off](/explanation/privacy/#token-refresh).

## Polling and network

The default quota interval is five minutes, with a two-minute floor while the panel is open. Analytics use the separate
[collection clock](/explanation/collection/).

- Usage and profile: `api.anthropic.com/api/oauth/usage`, `api.anthropic.com/api/oauth/profile`.
- Optional token refresh: `platform.claude.com/v1/oauth/token`.

These vendor APIs can change. [Diagnostics](/troubleshooting/diagnostics/) describes what to include in a failure
report.
