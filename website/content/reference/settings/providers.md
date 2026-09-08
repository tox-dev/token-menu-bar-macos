---
title: Providers settings
description: Discovery, enabled accounts, refresh intervals and recovery actions.
weight: 3
---

**Show all providers** starts off. Without it, the list contains providers with usable authentication or stored data. It
does not enable a provider by itself. Missing, expired or unreadable credentials without retained data belong in this
setup view, not empty sign-in cards in Usage.

Each provider has its mark, an enable box and an **Authentication** source. **Connection details** adds the safe
credential path, account identity, service state and last success. Recovery actions remain outside that disclosure. The
App Store build shows resource-grant buttons where needed.

Enabled providers expose a refresh stepper, up to 30 minutes. Each [provider page](/reference/providers/) gives its
polling default and open-panel floor. [Rate-limit backoff](/explanation/collection/) takes precedence.

**Refresh expired … tokens on my behalf** starts off and appears for relevant providers. It permits OAuth refresh, which
can rotate credentials shared with a CLI. Read [the refresh trade-off](/explanation/privacy/#token-refresh) before
enabling it.
