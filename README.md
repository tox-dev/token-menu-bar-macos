# Token Menu Bar

A macOS menu bar app that shows how much of your Claude (Pro/Max), OpenAI Codex (Plus/Pro), Gemini CLI, Cursor and
GitHub Copilot plan limits you have used, in the detail the vendor usage pages show: session, weekly and monthly windows
per model, usage credits and spend limits, reset countdowns, pace projections, notifications, 60 days of local history,
desktop widgets, and the Codex and Claude analytics charts.

It reads the tokens the `claude`, `codex`, `gemini`, Cursor and Copilot clients keep on your Mac, so you sign in to the
clients rather than to this app, and it calls only the vendors' own endpoints.

**Documentation: <https://token-menu-bar-macos.readthedocs.io>**

| Provider                                                   | Reads                      | Windows         |
| ---------------------------------------------------------- | -------------------------- | --------------- |
| <img src="website/static/brand/glyph/claude.svg"> Claude   | Keychain, `~/.claude`      | session, weekly |
| <img src="website/static/brand/glyph/codex.svg"> Codex     | `~/.codex`                 | 5-hour, weekly  |
| <img src="website/static/brand/glyph/gemini.svg"> Gemini   | `~/.gemini`                | daily per model |
| <img src="website/static/brand/glyph/cursor.svg"> Cursor   | Cursor app, `~/.cursor`    | plan, spend     |
| <img src="website/static/brand/glyph/copilot.svg"> Copilot | `~/.config/github-copilot` | premium         |

Requires macOS 14 or later on Apple Silicon, and one signed-in client.

- [Get started](https://token-menu-bar-macos.readthedocs.io/en/latest/start/): install it and read your first numbers
- [Interface reference](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/interface/): the menu bar, the
  three tabs and the widgets
- [Settings reference](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/settings/): what each option does
- [Privacy and rate limits](https://token-menu-bar-macos.readthedocs.io/en/latest/explanation/): what it reads, where it
  sends it, why the poll interval stays long
- [Troubleshooting](https://token-menu-bar-macos.readthedocs.io/en/latest/troubleshooting/): the log to capture, and
  what each symptom means
- [Contributing](https://token-menu-bar-macos.readthedocs.io/en/latest/contributing/): the architecture, the house
  style, and every workflow

## Working on it

[mise](https://mise.jdx.dev) pins the tools and [just](https://just.systems) runs the workflows.

```sh
mise install   # hugo, just, pre-commit, xcodegen
just           # the list of workflows
just check     # build, tests with the coverage gate, every lint hook
just run       # ad-hoc .app for machines without Xcode, launched
just install   # the same build, into /Applications
```

MIT licensed, by [Bernát Gábor](https://bernat.tech).
