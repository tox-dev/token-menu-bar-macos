# Token Menu Bar

A macOS menu bar app for AI coding quota, reset countdowns and pacing, with a shared History chart. Requires macOS 15 or
later on Apple silicon or Intel.

## Install

Download `TokenMenuBar.dmg` from the [latest release](https://github.com/tox-dev/token-menu-bar-macos/releases/latest),
or install it through Homebrew:

```sh
brew tap tox-dev/token-menu-bar https://github.com/tox-dev/token-menu-bar-macos
brew trust --cask tox-dev/token-menu-bar/token-menu-bar
brew install --cask token-menu-bar
```

Both downloads are signed and notarized. [Get started](https://token-menu-bar-macos.readthedocs.io/en/latest/start/)
covers the channels and initial setup.

## Your provider

Sign in through the client you use. Each guide covers authentication, available data and troubleshooting.

- [Claude](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/claude/)
- [Codex](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/codex/)
- [Gemini CLI](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/gemini/)
- [Antigravity](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/antigravity/)
- [Cursor](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/cursor/)
- [GitHub Copilot](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/copilot/)

## Use the app

- [Usage](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/usage/) and
  [History](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/history/): read current limits and compare
  periods.
- [Settings](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/settings/): choose models, labels and
  collection options.
- [Privacy](https://token-menu-bar-macos.readthedocs.io/en/latest/explanation/privacy/): credential access and local
  storage.
- [Troubleshooting](https://token-menu-bar-macos.readthedocs.io/en/latest/troubleshooting/): diagnose a symptom or
  collect logs.

## Development

[Build from source](https://token-menu-bar-macos.readthedocs.io/en/latest/contributing/build/) to work on the app or try
unreleased changes. [Contributing](CONTRIBUTING.md) covers mock-only testing and the development workflow.

MIT licensed, by [Bernát Gábor](https://bernat.tech).
