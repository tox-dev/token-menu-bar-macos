---
title: Antigravity
description: IDE and agy discovery, shared model pools and Cloud Code fallback.
provider: antigravity
weight: 4
---

## Connect

Sign in through Antigravity IDE or `agy`, then enable Antigravity in **Settings > Providers**. Use **Show all
providers** if it is absent.

The app reads Keychain service `gemini`, account `antigravity`, and can contact the running client's local language
server. **Authentication** and **Connection details** identify the source in use.

## Available data

Usage shows shared model pools, short and weekly windows, and reported tier and identity. The app uses the running
language server when available, with Cloud Code as a fallback.

History contains collected quota samples. Antigravity supplies no separate daily analytics feed. Missing account or
credit fields remain absent; reported zeroes stay visible.

## Expired credentials

Sign in through Antigravity again if setup reports an expired or unreadable session. A Keychain denial appears in setup
without repeated background permission requests.

**Refresh expired tokens on my behalf** starts off. The app keeps refreshed access tokens in memory; it does not replace
Antigravity's Keychain item. See [credential handling](/explanation/privacy/#token-refresh).

## Polling and network

The default quota interval is two minutes, with a one-minute floor while the panel is open.
[Rate-limit backoff](/explanation/collection/) takes precedence.

- Local source: the discovered loopback language-server port.
- Cloud fallback: `daily-cloudcode-pa.googleapis.com` or `cloudcode-pa.googleapis.com`.
- Optional token refresh: `oauth2.googleapis.com/token`.

These vendor APIs can change. [Provider troubleshooting](/troubleshooting/providers/) covers stale and inaccessible
data.
