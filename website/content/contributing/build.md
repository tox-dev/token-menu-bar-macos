---
title: Build from source
description: Fallback installation and a mock-data development setup.
weight: 1
---

Use a published [release](/start/) for a normal install. Build from source to work on the app or try unreleased changes.

## Tools

[mise](https://mise.jdx.dev) pins the task runner, site generator and formatting tools in `mise.lock`.
[just](https://just.systems) drives the workflows.

```sh
git clone https://github.com/tox-dev/token-menu-bar-macos
cd token-menu-bar-macos
mise install
brew install jq tesseract webp
```

Install [Xcode](https://developer.apple.com/xcode/) for distribution builds. A compatible
[swiftly](https://swiftlang.github.io/swiftly/) toolchain can build the package. Credential reads are noninteractive,
including ad-hoc builds. Use mock verification for development checks.

## Build and install

```sh
TOKEN_MENU_BAR_BUILD_JOBS=2 just app
open "dist/Token Menu Bar.app"
```

This opens a development build with your provider data. Run `just install` to install it in `/Applications` and open it.
Local bundles have no Sparkle updater or widget extension. Build commands use two compiler jobs; set
`TOKEN_MENU_BAR_BUILD_JOBS=1` on a memory-constrained machine.

## Isolated preview

Use `just run-demo` to explore generated data in a separate verification instance with mock credentials, its own
preferences and a temporary support directory. Quit that instance when finished.

Read [Testing](/contributing/testing/) before running application UI tests. Compile-only preparation does not open a
window.
