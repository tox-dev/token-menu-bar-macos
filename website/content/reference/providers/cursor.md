---
title: Cursor
description: Cursor app and Agent credentials, billing-cycle usage, team pools and database access.
provider: cursor
weight: 5
---

## Connect

Sign in through Cursor or run `cursor-agent login`, then enable Cursor in **Settings > Providers**. Use **Show all
providers** if it is absent.

The app reads Cursor's `User/globalStorage/state.vscdb` under its Application Support directory, or
`~/.cursor/auth.json`. **Authentication** and **Connection details** identify the source in use. Database access is
read-only.

## Available data

Usage shows billing-cycle plan and on-demand usage, plus team pools and membership details when reported. History
contains collected quota samples; Cursor supplies no separate daily analytics feed.

Account and billing fields depend on the response. The app does not fill absent fields with invented zeroes.

## Cursor works but quota does not

The immutable SQLite read cannot see uncheckpointed write-ahead-log changes. Quit Cursor to let it checkpoint, then
refresh Token Menu Bar. A `cursor-agent login` credential file is another supported source. Do not delete Cursor's
database to repair this app.

For an expired Agent session, **Sign in…** can open its login command. Other sources open setup instructions. The app
does not refresh or write Cursor credentials.

## Polling and network

The default quota interval is five minutes, with a one-minute floor while the panel is open.
[Rate-limit backoff](/explanation/collection/) takes precedence.

- Usage and identity: `cursor.com/api/usage-summary` and `cursor.com/api/auth/me`.
- Fallback: `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`.

These vendor APIs can change. [Diagnostics](/troubleshooting/diagnostics/) describes what to include in a failure
report.
