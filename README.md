# Token Menu Bar

A macOS menu bar app that shows how much of your Claude (Pro/Max), OpenAI Codex (Plus/Pro), Gemini CLI, Google
Antigravity, Cursor and GitHub Copilot plan limits you have used, in the detail the vendor usage pages show: session,
weekly and monthly windows per model, usage credits and spend limits, reset countdowns, pace projections, notifications,
60 days of local history, desktop widgets, and the Codex and Claude analytics charts.

It reads the tokens the `claude`, `codex`, `gemini`, Antigravity, Cursor and Copilot clients keep on your Mac, so you
sign in to the clients rather than to this app, and it calls only the vendors' own endpoints.

**Documentation: <https://token-menu-bar-macos.readthedocs.io>**

| Provider                                                           | Reads                                                                    | Windows                                                            |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| <img src="website/static/brand/glyph/claude.svg"> Claude           | Keychain, `~/.claude`                                                    | session, weekly                                                    |
| <img src="website/static/brand/glyph/codex.svg"> Codex             | `~/.codex`                                                               | 5-hour, weekly                                                     |
| <img src="website/static/brand/glyph/gemini.svg"> Gemini           | `~/.gemini`                                                              | daily per model; personal accounts stopped reporting on 2026-06-18 |
| <img src="website/static/brand/glyph/antigravity.svg"> Antigravity | Keychain (Antigravity), local language server when the IDE or `agy` runs | 5-hour, weekly                                                     |
| <img src="website/static/brand/glyph/cursor.svg"> Cursor           | Cursor app, `~/.cursor`                                                  | plan, spend                                                        |
| <img src="website/static/brand/glyph/copilot.svg"> Copilot         | `~/.config/github-copilot`                                               | premium                                                            |

Requires macOS 14 or later on Apple silicon or Intel, and one signed-in client.

The app tracks these six providers on purpose: they are the ones it can read locally. A provider is added only when a
local credential and an official usage endpoint exist for it. Antigravity reads the quota its language server reports
while the IDE or `agy` runs and asks Cloud Code with the Keychain token otherwise. Gemini CLI personal accounts stopped
reporting quota on 2026-06-18, so the Gemini card shows an unsupported-account notice for them; Workspace and Code
Assist accounts still work.

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
just check     # build, nonpresenting tests, lint
just run       # ad-hoc .app for machines without Xcode, launched
just install   # the same build, into /Applications
```

MIT licensed, by [Bernát Gábor](https://bernat.tech).
