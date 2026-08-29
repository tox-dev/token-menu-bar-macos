# Contributing

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

Implement `UsageProvider` (credential state, polling policy, `fetch`) and register it in `LiveDependencies.providers`.
Map the vendor's response to `QuotaWindow`s and, optionally, `ProviderAnalytics`; the menu bar, popover, history and
notifications pick the new provider up without further changes.

## Refreshing the docs screenshots

```sh
Scripts/screenshots.sh
```

The script captures the installed app's popover tabs in light and dark mode, the menu bar strip, and builds the tour GIF
into `docs/images/`. It needs screen-recording permission for the terminal and temporarily switches the system
appearance.

## Releasing

Tag `vX.Y.Z`. The release workflow builds the direct app (signed and notarized when the secrets exist), publishes the
zip, DMG, checksums and Sparkle appcast, refreshes the Homebrew cask file, and uploads the App Store flavour when the
`APP_STORE_ENABLED` variable is set. The docs deploy to GitHub Pages on every push to `main`.
