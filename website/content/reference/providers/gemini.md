---
title: Gemini CLI
description: Gemini credentials, account eligibility, per-model quota buckets and reported credits.
provider: gemini
weight: 3
---

## Connect

Sign in through Gemini CLI, then enable Gemini in **Settings > Providers**. Use **Show all providers** if Gemini is
absent; **Authentication** identifies the source in use.

The app reads `~/.gemini/oauth_creds.json` or the configured `gemini-cli-oauth` Keychain store. `GEMINI_CLI_HOME`
selects the home containing `.gemini/oauth_creds.json`. Gemini credential-storage and OAuth-client environment variables
also affect discovery. [Custom credential paths](/start/connect/#custom-credential-paths) explains how to pass overrides
to a GUI launch.

## Available data

Usage shows per-model quota buckets, tier and reported credits. History contains the quota samples collected by Token
Menu Bar; Gemini supplies no separate daily analytics feed.

An absent credit field remains absent. A reported zero balance remains visible.

## Account eligibility and sign-in

An authenticated account can still receive an unsupported-client or subscription-required response. Read the setup
message before changing credentials: token refresh cannot change account eligibility.

**Refresh expired tokens on my behalf** starts off. Enabling it permits OAuth refresh and saving to the original source.
Rotation can affect the token held by Gemini CLI; read the
[shared-token trade-off](/explanation/privacy/#token-refresh).

## Polling and network

The default quota interval is two minutes, with a one-minute floor while the panel is open.
[Rate-limit backoff](/explanation/collection/) takes precedence.

- Account and quota: `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and
  `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`.
- Optional token refresh: `oauth2.googleapis.com/token`.

These vendor APIs can change. [Provider troubleshooting](/troubleshooting/providers/) covers stale and inaccessible
data.
