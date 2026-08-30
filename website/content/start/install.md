---
title: Install Token Menu Bar
description: Download the app, sign in to the clients you use, and read your first numbers.
weight: 1
---

## Before you start

Token Menu Bar needs macOS 26 and one signed-in client. It reads the token that client already stored, so no password
reaches this app and nothing asks you to sign in twice. A provider you have not signed into stays hidden until its token
appears; Settings > Providers toggles them.

| Client      | Sign in with                            | Token lands in                                                                                  |
| ----------- | --------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Claude Code | `claude`                                | Keychain item `Claude Code-credentials`                                                         |
| Codex       | `codex login`                           | `~/.codex/auth.json`                                                                            |
| Gemini CLI  | `gemini`, through Login with Google     | `~/.gemini/oauth_creds.json`                                                                    |
| Cursor      | the Cursor app, or `cursor-agent login` | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, or `~/.cursor/auth.json` |
| Copilot     | Copilot CLI, Neovim or JetBrains        | `~/.config/github-copilot/hosts.json` or `apps.json`                                            |

## Get the app

### Direct download

1. Download `TokenMenuBar.dmg` from the
   [latest release](https://github.com/tox-dev/token-menu-bar-macos/releases/latest).
2. Drag **Token Menu Bar** into `/Applications` and open it.
3. Approve the Keychain prompt with **Always Allow** so the app can read the Claude Code token.

The direct build carries a Developer ID signature and Apple's notarization, and updates itself through Sparkle (Settings
\> About).

### Homebrew

```sh
brew install --cask token-menu-bar
```

Until the cask lands in homebrew-cask you can install it from a checkout:

```sh
brew install --cask Casks/token-menu-bar.rb
```

### Mac App Store

The release pipeline uploads the sandboxed build once the Apple Developer account is enrolled. On first launch it asks
you to point it at `~/.codex`, which the sandbox cannot read on its own.

## First launch

The menu bar shows the app icon until the first refresh lands; then one cell per selected window appears. Open the
popover to see every window, and pick the windows and their format under **Settings > Menu bar**.

{{< callout kind="tip" title="Launch at login" >}} Turn on **Launch at login** under Settings > About. macOS may ask you
to approve the item under System Settings > General > Login Items; the app offers a shortcut to that pane.
{{< /callout >}}

## Building from source

```sh
git clone https://github.com/tox-dev/token-menu-bar-macos
cd token-menu-bar-macos
swift build
Scripts/bundle-dev.sh --run   # ad-hoc signed .app in dist/
```

`swift test` needs a toolchain that ships swift-testing (Xcode, or a swift.org toolchain through `swiftly`). Ad-hoc
builds take a new code signature each time, so macOS repeats the Keychain prompt after every rebuild.
