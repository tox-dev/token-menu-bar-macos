---
title: Installation and demo mode
description: Identify local builds, update behavior and isolated sample sessions.
weight: 6
---

## Local update errors

Local development bundles have no self-updater. Replace an old local install with `just install` from the current
checkout. App Store and Homebrew users update through their distribution channel; Sparkle belongs to signed Direct
releases. Include the source version and channel from Settings > About if a local build still offers an update.

## Demo data

That is intentional for `just run-demo` and `--verify-ui`: they use mock providers and isolated state. Quit the
verification instance and open your installed app for real data.

The ordinary app's Demo data switch is in Settings > About. Turning it off relaunches the app in real-data mode. Do not
use real-data mode to run benchmarks or tests.
