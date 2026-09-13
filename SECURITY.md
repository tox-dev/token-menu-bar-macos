# Security policy

## Reporting a vulnerability

Use [GitHub security advisories](https://github.com/tox-dev/token-menu-bar-macos/security/advisories/new) for issues
that could expose credentials. Do not post tokens, credential files or private transcripts in public issues.

Include the source version and channel from Settings > About, reproduction steps and the observed result. **Copy
Diagnostics** is in the Settings footer. Review its account, usage and path information before sharing it.

This is a one-person project without a bounty programme. Reports receive investigation and credit in the advisory unless
the reporter asks to remain unnamed.

## Scope

Report credential disclosure, unauthorized file access or modification, account-mixing bugs and requests that send
credentials to an unintended host. The signing, notarization, update and release workflows are also in scope.

Provider API availability or incorrect quota values are product bugs unless they expose data or cross an access
boundary. Vulnerabilities in the provider clients belong with their vendors. An attacker with access to your unlocked
account and Keychain is outside this app's security boundary.

## Credential handling

[Provider sources](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/) documents all six
integrations, their credential stores and endpoint families. Supported sources include client files and Keychain items;
Copilot can also read a token from the app's launch environment.

Background Keychain reads prohibit user interaction. Denied reads appear in provider setup rather than repeated
permission prompts. The App Store build requests security-scoped grants for supported client resources.

Token refresh is off by default. When enabled, Claude, Codex and Gemini may write updated credentials to their original
source. Antigravity refreshes remain in memory because its client owns the Keychain item. Cursor and Copilot sources
remain read-only. Refreshing shared credentials can invalidate a value retained by a running CLI; the settings reference
explains that trade-off.

Environment variables affect the app only when its process receives them. Finder and login-item launches do not read
shell startup files. Check Authentication and Connection details in Settings before enabling credential writes.

## Stored data and network traffic

Direct and Homebrew support files live under `~/Library/Application Support/Token Menu Bar/`. App Store files live under
`~/Library/Containers/dev.tox.token-menu-bar/Data/Library/Application Support/Token Menu Bar/`.

The snapshot cache can contain plan names and account email. History stores quota and analytics records, with account
scoping and configurable retention. Hiding account/project details masks presentation, not the files on disk. Exported
history and copied diagnostics remain under the user's control.

The optional `usage.json` export contains provider IDs, plans, timestamps and quota rows, without credential or email
fields. Widget snapshots contain labels, percentages and reset times. The App Store widget uses
`group.dev.tox.token-menu-bar`; Direct and Homebrew use `<Team ID>.dev.tox.token-menu-bar`.

Logs sanitize URLs and sensitive values. The HTTP logger records metadata without request headers or response bodies.
Detailed logging adds refresh timing and UI geometry and is off by default. Review reports before sharing them;
sanitization is not a substitute for inspecting information about your account and local paths.

Usage requests go to the
[documented provider destinations](https://token-menu-bar-macos.readthedocs.io/en/latest/reference/providers/#network-destinations),
including Antigravity's discovered loopback service and Copilot enterprise hosts where configured. Direct releases also
contact the update feed. Browser actions such as Source and Report Issue open external pages on request.

The app has no telemetry service or crash-upload endpoint. Verification and package-test fixtures use generated data and
injected credential/network boundaries; they must not read a user's provider accounts.
