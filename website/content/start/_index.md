---
title: Get started
description: Install a release, connect a provider and choose your menu bar models.
weight: 1
aliases: [/start/install/]
---

## Install

Token Menu Bar targets macOS 14, 15, 26 and 27 on Apple silicon and Intel.

The first release is in development. [Check GitHub releases](https://github.com/tox-dev/token-menu-bar-macos/releases)
for downloads; there is no published release at present.

| Channel         | Install and update                                                                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Direct download | Download `TokenMenuBar.dmg` from a published release, drag the app to `/Applications`, then open it. Signed release builds include the updater.         |
| Homebrew        | Install the cask when a release is available; update through Homebrew. The checked-in cask still has a placeholder checksum.                            |
| App Store       | Install and update through the listing when available. This project has no published App Store link yet. The sandbox requires provider resource grants. |

For unreleased changes, [build from source](/contributing/build/).

## First use

1. [Connect a provider](/start/connect/) through the client you use.
2. Choose models and short labels in [Menu bar settings](/reference/settings/menu-bar/).
3. Read current limits in [Usage](/reference/usage/) or compare periods in [History](/reference/history/).

**Launch at login** and its adjacent **Open Login Items** button are in Settings > About. Demo data starts off; the
checkbox in that section is its one control.
