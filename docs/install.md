# Install

Token Menu Bar needs macOS 26 and at least one of the two CLIs signed in:

- `claude` (Claude Code) stores its OAuth token in the Keychain item `Claude Code-credentials`.
- `codex login` writes `~/.codex/auth.json`.

The app never asks for your Anthropic or OpenAI password; it reuses those tokens read-only.

=== "Direct download"

```
1. Download `TokenMenuBar.dmg` from the
   [latest release](https://github.com/tox-dev/token-menu-bar-macos/releases/latest).
2. Drag **Token Menu Bar** into `/Applications` and open it.
3. Approve the Keychain prompt with **Always Allow** so the app can read the Claude Code token.

The direct build is signed with a Developer ID, notarized, and updates itself through Sparkle (Settings > About).
```

=== "Homebrew"

````
```sh
brew install --cask token-menu-bar
```

Until the cask lands in homebrew-cask you can install it from a checkout:

```sh
brew install --cask Casks/token-menu-bar.rb
```
````

=== "Mac App Store"

```
The sandboxed build is submitted from the release pipeline once the Apple Developer account is enrolled. It asks
you to point it at `~/.codex` on first launch because the sandbox cannot read that folder on its own.
```

## First launch

The menu bar shows the app icon until the first refresh completes; then one cell per selected window appears. Open the
popover to see every window, and use **Settings > Menu bar** to choose which windows sit in the bar and how they are
formatted.

!!! tip "Launch at login" Turn on **Launch at login** under Settings > About. macOS may ask you to approve the item
under System Settings > General > Login Items; the app offers a shortcut to that pane.

## Building from source

```sh
git clone https://github.com/tox-dev/token-menu-bar-macos
cd token-menu-bar-macos
swift build
Scripts/bundle-dev.sh --run   # ad-hoc signed .app in dist/
```

`swift test` needs a toolchain that ships swift-testing (Xcode, or a swift.org toolchain through `swiftly`). Ad-hoc
builds get a new code signature every time, so macOS repeats the Keychain prompt after each rebuild.
