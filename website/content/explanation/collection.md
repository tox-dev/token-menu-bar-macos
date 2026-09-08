---
title: Polling and rate limits
description: Separate quota and analytics clocks, sleep behavior and retry deadlines.
weight: 2
---

## Polling

Each enabled provider has its own quota interval. Its [provider page](/reference/providers/) gives the default and
open-panel floor. Disabled providers do not poll.

Daily analytics use a separate clock, 15 minutes by default. **Refresh** requests current quota and analytics only when
due; it does not force the full analytics pipeline on each click. Missing providers do not generate a stream of ordinary
error messages.

A provider's `429` response starts a backoff based on `Retry-After`, with a 60-second floor and 30-minute cap. The app
preserves last-known readings with their age. **Refresh** does not bypass an active rate-limit hold. Repeated clicks
cannot restore the provider's quota or remove its rate limit.

The app pauses polling during sleep and checks for stale data on wake. A failed provider does not prevent the others
from updating.
