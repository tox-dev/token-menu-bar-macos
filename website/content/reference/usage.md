---
title: Usage
description: Read current quota, pacing, resets and supporting provider detail.
weight: 4
---

{{< shot name="popover-usage" alt="Usage cards with provider marks, quota meters, reset countdowns and supporting detail" caption="Usage with generated provider data. Expanded content scrolls within the live panel." >}}

Usage shows active providers with data. Use **Open Providers** or Settings > Providers to connect a missing one; enable
**Show all providers** there to inspect providers without usable authentication.

Use **Refresh** in the footer to fetch all active providers. A card's refresh button fetches that provider alone. The
**Demo data** badge identifies sample values; change demo mode with the checkbox in Settings > About.

Each card shows its provider mark, reported plan and account identity, quota meters, pacing and reset times. **Hide
account and project details** masks identity text. A reset has a countdown and a separate local date/time line. Day-only
deadlines remain dates because the source did not supply an exact instant.

The main meters remain visible for a glance. Credit breakdowns, local token counts and provider details open on demand.
The app omits unsupported or absent fields; a reported zero remains data. Limit notices do not repeat an exhausted meter
already visible on the card, but restrictions outside the visible meters still appear.

Cost estimates stay with the provider that supplied the data. They are API-equivalent estimates from supported local
records, not your subscription invoice. Provider-reported credit balances and spend caps are separate. Current daily
cost summaries use UTC buckets; changing History's UTC switch cannot reconstruct local-day costs from those aggregates.

[Provider sources](/reference/providers/) explains the differences between credits, quotas and local analytics.
