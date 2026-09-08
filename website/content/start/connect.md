---
title: Connect a provider
description: Find an existing client session and enable its usage feed.
weight: 1
---

## Choose your client

Follow your provider's setup page:

- [Claude](/reference/providers/claude/)
- [Codex](/reference/providers/codex/)
- [Gemini CLI](/reference/providers/gemini/)
- [Antigravity](/reference/providers/antigravity/)
- [Cursor](/reference/providers/cursor/)
- [GitHub Copilot](/reference/providers/copilot/)

## Enable collection

Open **Settings > Providers**. It lists providers with usable authentication or retained data. Turn on **Show all
providers** to find a missing provider and inspect setup instructions. Check its enable box, resolve any recovery
action, then press **Refresh**.

**Authentication** names the source; **Connection details** adds the safe location and diagnostics. The app does not
display the token.

Background credential reads do not request Keychain interaction. A denied read appears in setup without repeated
permission requests. App Store builds use **Grant** or **Grant Again** for supported local resources. Do not paste
tokens into an issue or the app.

## Custom credential paths

Environment variables must exist in the app process. Finder and login-item launches do not read `.zshrc`. Each
[provider page](/reference/providers/) names its supported overrides.

For example, to select a Codex home for subsequent launches in this login session:

```sh
launchctl setenv CODEX_HOME /path/to/codex-home
```

Quit and reopen Token Menu Bar, then check the resolved source in Settings. Remove the override when finished:

```sh
launchctl unsetenv CODEX_HOME
```

Do not move or copy secrets to troubleshoot a path.
