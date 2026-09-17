---
title: Get started
description: Install a release, connect a provider and choose your menu bar models.
weight: 1
aliases: [/start/install/]
---

## Install

Token Menu Bar targets macOS 14, 15, 26 and 27 on Apple silicon and Intel.

[Version 0.1.0](https://github.com/tox-dev/token-menu-bar-macos/releases/latest) is the current release. Apple notarized
both downloads, so Gatekeeper opens them without a detour through System Settings.

| Channel         | Install and update                                                                                                                                                                                                |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Direct download | Download `TokenMenuBar.dmg` from the [latest release](https://github.com/tox-dev/token-menu-bar-macos/releases/latest), drag the app to `/Applications`, then open it. This build updates itself through Sparkle. |
| Homebrew        | Tap this repository, trust the cask, then install it. The commands are below. This build carries no updater, so `brew upgrade` brings each new version.                                                           |
| App Store       | No listing yet. The sandboxed build needs provider resource grants, and the upload leg of the release waits on App Store credentials.                                                                             |

```sh
brew tap tox-dev/token-menu-bar https://github.com/tox-dev/token-menu-bar-macos
brew trust --cask tox-dev/token-menu-bar/token-menu-bar
brew install --cask token-menu-bar
```

Homebrew refuses casks from a tap it does not trust, hence the middle command. Its own cask repository takes software
that has drawn a following, around 75 stars or 30 forks or 30 watchers, so `brew install --cask token-menu-bar` without
the tap does not find this app yet.

For unreleased changes, [build from source](/contributing/build/).

## First use

1. [Connect a provider](/start/connect/) through the client you use.
2. Choose models and short labels in [Menu bar settings](/reference/settings/menu-bar/).
3. Read current limits in [Usage](/reference/usage/) or compare periods in [History](/reference/history/).

**Launch at login** and its adjacent **Open Login Items** button are in Settings > About. Demo data starts off; the
checkbox in that section is its one control.
