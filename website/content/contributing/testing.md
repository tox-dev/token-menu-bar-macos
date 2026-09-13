---
title: Testing
description: Mock-only package tests, native interaction checks and runtime coverage.
weight: 4
---

## Choose the check

`just test` runs nonpresenting tests with generated data. Its wrapper checks the captured text with Tesseract and `jq`;
bare `swift test` does not set up that render-check workflow. Render fixtures have no windows. CI also requires the
native package suite, full coverage and scripted application checks. `just test-native`, `just coverage` and `just ui`
require a GitHub-hosted desktop; do not bypass their guards on a developer Mac. See
[the test workflow](https://github.com/tox-dev/token-menu-bar-macos/blob/main/CONTRIBUTING.md) for the execution
boundary. `just ui-local --prepare-only all` builds and validates the verification-only application without opening it.
`just ui-local TokenMenuBarApplicationUITests/TokenMenuBarApplicationUITests/testEveryTabExposesNamedControls` runs a
named application UI test on the current desktop. This explicit route uses internal temporary products and mock
providers; it does not enable local execution of the native package suite or change privacy permissions. Keep the
current desktop unlocked for native input. The launcher refuses a locked session and stops its owned processes if the
screen locks during a test; build-only and nonpresenting checks do not require an unlocked desktop.

Local native interaction also requires preconfigured unattended XCTest Automation Mode. The launcher refuses to run
without it; it does not request approval or change macOS security settings. Use compile-only preparation on an
unconfigured desktop.

## Performance benchmarks

`TokenMenuBarPerformanceTests` is a separate target with its own `TokenMenuBar-Benchmarks` scheme and test plan. The
functional suite and normal CI exclude it.

Run `just benchmark` for mock-only measurements on the latest deployed macOS, or
`just ui-local --suite performance --prepare-only all` to compile without launching. For a hosted run, dispatch CI with
`ui_group=performance`; it selects the latest deployed runtime regardless of the diagnostic runtime input. Benchmarks
report startup, tab-switch timing, CPU and memory. These measurements guide development and do not impose performance
thresholds on CI.

## Panel acceptance

Run this check on macOS 14, 15, 26, and 27 before a release:

```sh
just run-demo
```

The demo launch uses seeded providers, a separate defaults suite, and a temporary support directory. Do not use
`just run`, which loads the current account's provider data, for verification.

1. Open the status item near the left edge, centre, and right edge of the menu bar. The arrow must meet the status item
   at each position.
2. Switch through Usage, History, and Settings. The panel's top edge and width must stay fixed while its bottom edge
   moves. Repeat on a short display and a secondary display with a different scale.
3. Make each tab exceed the screen height. The body must scroll without clipping the tab control or moving the arrow.
4. Press each action button. It must show a bezel, pressed state, and non-accent label. Check light, dark, increased
   contrast, and reduced transparency appearances.
5. Enable Keyboard navigation under System Settings > Keyboard. Use Tab and Shift-Tab to reach each control, Command-R
   to refresh, Command-F to focus the Settings model filter, and Escape to close the panel. Focus rings must remain
   visible.
6. Leave the panel open for two minutes. Activity Monitor should show stable memory and no sustained CPU work while the
   data remains unchanged.

The functional application UI suite checks all three tabs for accessibility faults, controls and panel positioning. It
uses bounded waits to catch hangs and removes its defaults and support files after each test. CI requires GitHub-hosted
macOS 14, 15 and 26. A rollout gate adds macOS 27 after GitHub completes its image deployment; runtime assertions remain
in each job. Until then, macOS 27 jobs are omitted, not retried against randomly assigned macOS 26 images. The
`xcode-27` label alone does not prove macOS 27 coverage.
