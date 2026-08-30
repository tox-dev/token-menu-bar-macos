---
title: Work on the app
description: Build the targets, run the gate, add a provider, refresh the screenshots.
weight: 5
---

The repository is a SwiftPM package with three targets:

- `TokenMenuBarCore`: providers, credentials, history, chart pipeline, pace, notifications, settings. No AppKit.
- `TokenMenuBarUI`: status item rendering, popover, the three tabs, app composition. Renders Core value types only.
- `TokenMenuBar`: the executable that bootstraps the app.

`Scripts/coverage.sh` fails when a line in Core or UI never runs during the suite.

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
vendor's response to `QuotaWindow`s, and to `ProviderAnalytics` when the vendor reports any. The menu bar, popover,
history, widgets and notifications then pick the provider up on their own. Add a sample snapshot to `DemoData` for the
new case, which keeps demo mode and the screenshots whole.

## Refreshing the docs screenshots

```sh
Scripts/screenshots.sh
```

The script runs the built binary with its export flags, so the app renders the popover tabs and the menu bar strip on
demo data and writes them into `website/assets/images/`. Nothing captures the screen, so the shots carry no part of your
desktop and no part of your account.

## Releasing

Tag `vX.Y.Z`. The release workflow builds the direct app (signed and notarized when the secrets exist), publishes the
zip, DMG, checksums and Sparkle appcast, refreshes the Homebrew cask file, and uploads the App Store flavour when the
`APP_STORE_ENABLED` variable is set. The docs deploy to GitHub Pages on every push to `main`.

## The website

`website/` is a self-contained Hugo site built from plain CSS and templates, with no theme module, Node or Sass. The
Hugo binary named in `website/.hugo-version` is the whole toolchain.

```sh
cd website && hugo server
```

The brand lives in two places that have to stay in step: `Sources/TokenMenuBarCore/Brand.swift` for the app, and the
custom properties at the top of `website/assets/css/site.css` for the site. `website/static/brand/` holds the logo files
(`mark`, `mark-mono`, `lockup`, `lockup-stacked`, `icon`, `seal`). Each page also ships as raw markdown next to itself,
and `/llms.txt` indexes them for LLM crawlers.
