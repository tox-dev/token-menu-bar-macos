---
title: Privacy
description: Credential access, local data and what diagnostics can contain.
weight: 1
---

## Credential access

[Provider sources](/reference/providers/) lists all six integrations, credential locations and network destinations. The
app reads credentials that supported clients already store. It does not ask for passwords, create a Token Menu Bar
account, send telemetry or upload crash reports.

Credential reads are noninteractive. If a Keychain item denies access, the app reports that state in provider setup
without asking macOS to prompt during polling. The App Store sandbox requires grants for supported local resources.

Environment overrides must reach the app process. Finder and login-item launches do not load shell startup exports;
Settings > Providers shows the credential source and resolved path.

## Local storage and sharing

Direct and Homebrew builds keep history, snapshots and logs under `~/Library/Application Support/Token Menu Bar/`. The
App Store build uses `~/Library/Containers/dev.tox.token-menu-bar/Data/Library/Application Support/Token Menu Bar/`.

| Data             | Contents and controls                                                                                                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| History database | Quota samples and analytics, retained for 60 days by default. Settings > Data offers retention, export and confirmed clearing. Account changes keep retained usage scoped to its account. |
| Snapshot cache   | Last-known provider readings, including plan and email when reported. It supports offline display and the JSON command.                                                                   |
| `usage.json`     | Optional quota export for scripts. Contains provider IDs, plans, sample times and quota rows; no credential or email fields. Off by default.                                              |
| Log files        | Sanitized diagnostics, request metadata and UI events. Detailed logging is off by default. Review a report before sharing it.                                                             |
| Widget snapshot  | Selected labels, percentages and reset times, without credentials or email. Widgets read it without calling providers.                                                                    |

**Hide account and project details** masks display and diagnostic text; it does not erase the underlying cache,
transcripts or database. Exported files are copies under your control. Resetting preferences is different from clearing
history and does not sign the provider clients out.

The App Store widget uses the `group.dev.tox.token-menu-bar` app group. Direct and Homebrew builds use
`<Team ID>.dev.tox.token-menu-bar`. The channels do not share widget snapshots.

The network logger records operation, sanitized endpoint, response status, size and duration. It does not log request
headers or response bodies. Provider errors can still contain identifying details; inspect diagnostics before attaching
them to a public issue. [Troubleshooting](/troubleshooting/diagnostics/) describes the logging controls.

## Token refresh

**Refresh expired … tokens on my behalf** starts off. Enabling it permits supported OAuth refresh. Some integrations
save rotated credentials to the source they read. A client still holding the previous token may need another sign-in
after rotation.

Your [provider page](/reference/providers/) states whether refresh is supported and whether the app saves credentials or
keeps them in memory. A denied or failed save appears as a recovery issue. Leave refresh off to avoid shared credential
writes, and sign in through the client when its token expires.
