# Security policy

## Reporting a vulnerability

Report it privately through
[GitHub security advisories](https://github.com/tox-dev/token-menu-bar-macos/security/advisories/new). Please do not
open a public issue, pull request or discussion for anything that could expose someone's credentials.

Say what you did and what happened, and give the version from Settings > About. A proof of concept helps. A diagnostics
report (Settings > About > **Copy Diagnostics**) names your plan and how much of it you have used, so send one only when
it bears on the report, and read it first.

This is a one-person project with no bounty. You get an answer, a fix where the problem holds up, and credit in the
advisory unless you would rather not have it.

## In scope

- The app, wherever it could leak a credential, read a file it has no business reading, write one it should not, or
  reach a host other than the ones below.
- How it finds credentials, which is the list further down. Path traversal, a symlink trick, or a way to make it read
  another account's tokens all belong here.
- The release pipeline: signing, notarization, the Sparkle appcast, the Homebrew cask, and the GitHub Actions workflows
  with their secrets.

## Out of scope

- The vendors' own APIs, CLIs and accounts. A bug in `claude`, `codex`, `gemini`, Cursor or Copilot goes to that vendor.
- The quota numbers themselves. The app reports what the endpoint returns, so a wrong number is a bug rather than a
  vulnerability.
- Anything that needs an attacker who already has your unlocked Mac and your login keychain.

## What the app touches

It reads the credentials the clients already stored. It never asks you for one, and never sends one anywhere but the
vendor it came from.

| Provider | Reads                                                                                                                        | Writes                                                                 |
| -------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Claude   | Keychain item `Claude Code-credentials`, or `~/.claude/.credentials.json`; `~/.claude.json`; `~/.claude/projects/**/*.jsonl` | Whichever of those two the token came from, only with token refresh on |
| Codex    | `~/.codex/auth.json` (`CODEX_HOME` honoured); `~/.codex/sessions/**/rollout-*.jsonl`                                         | `~/.codex/auth.json`, only with token refresh on                       |
| Gemini   | `~/.gemini/oauth_creds.json` (`GEMINI_CLI_HOME` honoured)                                                                    | `~/.gemini/oauth_creds.json`, only with token refresh on               |
| Cursor   | Cursor's `state.vscdb`, opened read-only and immutable; or `~/.cursor/auth.json`                                             | Nothing                                                                |
| Copilot  | `~/.config/github-copilot/hosts.json` and `apps.json` (`XDG_CONFIG_HOME` honoured)                                           | Nothing                                                                |

**Refresh expired tokens on my behalf** (Settings > Providers) is off by default. With it off the app never writes a
credential file or Keychain item; it shows a sign-in hint instead. With it on, an expired Claude, Codex or Gemini token
goes to that vendor's token endpoint, and the app writes the rotated token back where the CLI keeps it.

The sandboxed App Store build cannot reach those paths on its own and asks you to grant each one, keeping a
security-scoped bookmark for it.

## What the app stores and sends

Everything it keeps lives under `~/Library/Application Support/Token Menu Bar/`: the SQLite history, a snapshot cache of
the last values (which includes the plan name, and the account email when the vendor returns one), and `log.txt`. The
log holds request URLs stripped of their query strings and with UUIDs masked, the status, size and duration of each
response, and the first 200 bytes of an error body. It holds no request header and no token.

The widget snapshot in the `group.dev.tox.token-menu-bar` app group holds window labels, percentages and reset times,
with no token and no email in it.

Outbound traffic goes to the five vendor hosts documented in
[Privacy and rate limits](https://token-menu-bar-macos.readthedocs.io/en/latest/explanation/), plus GitHub releases for
the Sparkle update feed in the direct build. The app runs no telemetry, reports no crashes, and has no server of its
own.
