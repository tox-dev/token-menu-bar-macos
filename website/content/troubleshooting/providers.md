---
title: Missing or stale providers
description: Authentication, resource grants, retained data and rate-limit holds.
weight: 2
---

## Missing or stale data

Open Settings > Providers and turn on **Show all providers**. Check the provider's enable box and Authentication source.
A missing, expired or unreadable credential without retained data stays out of the default provider list and Usage.

An expired session replaces the provider's Refresh button with **Sign in…**. Use your
[provider page](/reference/providers/) for the supported login route, credential paths and account limitations.

Cached percentages and progress bars turn gray in Usage, the model list and the menu bar. Their values remain readable;
VoiceOver identifies them as stale. The app restores their normal colors after a successful fetch. Independent local
cost history keeps its own freshness.

Network failures offer **Retry**, while file-access problems open setup. A sandboxed build may need **Grant** or **Grant
Again**. Connection details shows the resolved source and last successful refresh.

A provider with retained data can remain visible after a failure; its age and status distinguish stale readings from a
fresh response. Offline, rate-limited, authentication-required and unavailable states have different causes. A provider
security check is not evidence that you need to replace your token.

See [provider sources](/reference/providers/) for account eligibility, authentication locations and data coverage.

## Credential paths

Check **Connection details** before changing credentials.
[GUI environment overrides](/start/connect/#custom-credential-paths) differ from terminal exports.
[Cursor's database guidance](/reference/providers/cursor/#cursor-works-but-quota-does-not) covers uncheckpointed local
changes.

## Rate-limit hold

The app keeps last-known values and reports the next attempt. Wait for that deadline. Refresh respects the active
rate-limit hold; repeated clicks do not bypass it. Per-provider polling and analytics intervals are separate.
[Rate-limit policy](/explanation/collection/) describes both clocks.
