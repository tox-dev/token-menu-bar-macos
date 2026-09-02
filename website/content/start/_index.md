---
title: Get started
description: Install the app, sign in to the clients you use, and read your first numbers.
weight: 1
aliases: [/start/install/]
---

## Before you start

Token Menu Bar needs macOS 14 or later on an Apple Silicon Mac, and one signed-in client. It reads the token that client
already stored, so no password reaches this app and nothing asks you to sign in twice. A provider you have not signed
into stays hidden until its token appears; Settings > Providers toggles them.

| Client                                                              | Sign in with                            | Token lands in                                                                                  |
| ------------------------------------------------------------------- | --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) | `claude`                                | Keychain item `Claude Code-credentials`                                                         |
| [Codex](https://developers.openai.com/codex/cli/)                   | `codex login`                           | `~/.codex/auth.json`                                                                            |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli)           | `gemini`, through Login with Google     | `~/.gemini/oauth_creds.json`                                                                    |
| [Cursor](https://cursor.com/docs)                                   | the Cursor app, or `cursor-agent login` | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, or `~/.cursor/auth.json` |
| [Copilot](https://docs.github.com/en/copilot)                       | Copilot CLI, Neovim or JetBrains        | `~/.config/github-copilot/hosts.json` or `apps.json`                                            |

## Get the app

### Mac App Store

The release pipeline uploads the sandboxed build once the Apple Developer account is enrolled. On first launch it asks
you to point it at `~/.codex`, which the sandbox cannot read on its own.

### Homebrew

```sh
brew install --cask token-menu-bar
```

Until the cask lands in homebrew-cask you can install it from a checkout:

```sh
brew install --cask Casks/token-menu-bar.rb
```

### Direct download

1. Download `TokenMenuBar.dmg` from the
   [latest release](https://github.com/tox-dev/token-menu-bar-macos/releases/latest).
2. Drag **Token Menu Bar** into `/Applications` and open it.
3. Approve the Keychain prompt with **Always Allow** so the app can read the Claude Code token.

The direct build carries a
[Developer ID signature and Apple's notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
and updates itself through [Sparkle](https://sparkle-project.org) (Settings > About).

## First launch

The menu bar shows the app icon until the first refresh lands; then one cell per selected window appears. Open the
popover to see every window, and pick the windows and their format under **Settings > Menu bar**.

{{< callout kind="tip" title="Launch at login" >}} Turn on **Launch at login** under Settings > About. macOS may ask you
to approve the item under
[System Settings > General > Login Items](https://support.apple.com/guide/mac-help/open-items-automatically-when-you-log-in-mh15189/mac);
the app offers a shortcut to that pane. {{< /callout >}}
