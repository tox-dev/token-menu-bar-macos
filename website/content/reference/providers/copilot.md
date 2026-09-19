---
title: GitHub Copilot
description: Copilot credential discovery, host selection and account-specific allowances.
provider: copilot
weight: 6
---

## Connect

Sign in through a supported Copilot client, such as `copilot login`, then enable Copilot in **Settings > Providers**.
Use **Show all providers** if it is absent.

The app takes the first source it finds: `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN`, then Keychain service
`copilot-cli`, then the Copilot CLI's `~/.copilot/config.json`, then the editor extensions' `hosts.json` and `apps.json`
under `~/.config/github-copilot`. `COPILOT_HOME` and `XDG_CONFIG_HOME` move those roots. The credential's host
determines the API endpoint. See [custom credential paths](/start/connect/#custom-credential-paths) for GUI-launch
environment overrides.

**Authentication** and **Connection details** identify the source and safe location without displaying the token.

### What macOS asks

- **Keychain password**, when a `copilot-cli` Keychain item exists. The file sources need no password. See
  [Keychain access](/start/connect/#keychain-access).
- **App Store build.** Grant one folder, and only if the sign-in is not in the Keychain: `~/.copilot` for the Copilot
  CLI or `~/.config/github-copilot` for the editor extensions. See [folder grants](/start/connect/#folder-grants). A
  token in an environment variable needs no grant.

## Available data

Usage shows reported premium, chat or completion allowances, overage and token-billing credits. Your account and host
determine the categories available. Categories can overlap, so the app does not sum them into a fabricated total.

History contains collected quota samples. Copilot supplies no separate daily analytics feed.

## Expired credentials

Use the client or token source listed in provider setup to renew access. For a detected Copilot CLI session, **Sign
in…** can open the client's login command. Other sources open setup instructions. The app does not refresh or write
Copilot credentials.

## Polling and network

The default quota interval is five minutes, with a one-minute floor while the panel is open.
[Rate-limit backoff](/explanation/collection/) takes precedence.

Usage requests go to `api.github.com/copilot_internal/user`, or the credential's enterprise API host. These vendor APIs
can change. [Provider troubleshooting](/troubleshooting/providers/) covers stale and inaccessible data.
