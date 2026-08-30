---
title: Work on the app
description: Build the targets, run the gate, add a provider and refresh the screenshots.
weight: 5
---

The repository is a SwiftPM package with three targets:

- `TokenMenuBarCore`: providers, credentials, history, chart pipeline, pace, notifications, settings. No AppKit.
- `TokenMenuBarUI`: status item rendering, popover, the three tabs, app composition. Renders Core value types only.
- `TokenMenuBar`: the executable that bootstraps the app.

Every line of Core and UI executes under the test suite; `Scripts/coverage.sh` fails otherwise.

```sh
swift build
swift test
Scripts/coverage.sh
Scripts/bundle-dev.sh --run     # ad-hoc .app for machines without Xcode
cd App && xcodegen generate     # Xcode project with Direct and AppStore schemes
```

## Adding a provider

Add a case to `ProviderID` (name, tag, usage page, sign-in hint), a `PollingPolicy` default and a glyph, then implement
`UsageProvider` (credential state, polling policy, `fetch`) and register it in `LiveDependencies.providers`. Map the
vendor's response to `QuotaWindow`s and, optionally, `ProviderAnalytics`; the menu bar, popover, history, widgets and
notifications pick the new provider up without further changes. `DemoData` needs a sample snapshot for the new case so
demo mode and the screenshots stay complete.

## Refreshing the docs screenshots

```sh
Scripts/screenshots.sh
```

The script launches the installed app with `TOKEN_MENU_BAR_DEMO=1`, so the captures show generated data rather than your
account, then grabs the popover tabs in light and dark mode and the menu bar strip, and builds the tour GIF into
`website/assets/images/`. It needs screen-recording permission for the terminal and temporarily switches the system
appearance.

## Releasing

Tag `vX.Y.Z`. The release workflow builds the direct app (signed and notarized when the secrets exist), publishes the
zip, DMG, checksums and Sparkle appcast, refreshes the Homebrew cask file, and uploads the App Store flavour when the
`APP_STORE_ENABLED` variable is set. The docs deploy to GitHub Pages on every push to `main`.

## The website

`website/` is a self-contained Hugo site: no theme module, no Node, no Sass — plain CSS and templates, so the Hugo
binary named in `website/.hugo-version` is the whole toolchain.

```sh
cd website && hugo server
```

The brand lives in two places that must stay in step: `Sources/TokenMenuBarCore/Brand.swift` for the app and the custom
properties at the top of `website/assets/css/site.css` for the site. Logo files are in `website/static/brand/` (`mark`,
`mark-mono`, `lockup`, `lockup-stacked`, `icon`, `seal`). Every page is also published as raw markdown next to it, and
`/llms.txt` indexes them for LLM crawlers.
