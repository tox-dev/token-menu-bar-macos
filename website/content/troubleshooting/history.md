---
title: Missing History data
description: Check metric coverage, retained periods, timezones and cost attribution.
weight: 4
---

- Check the chosen metric, period and model selection. A provider can supply quota samples without supplying daily
  analytics. The metric attribution identifies contributors.
- Choose **Now** to resume following the current period after paging. **Custom** exposes From and To.
- Check retained data coverage. A local transcript reader cannot include activity recorded only on another machine.
- A line between samples bridges a collection gap; it does not claim that the app measured intermediate values.
- Quota samples support local time or UTC. Daily analytics and current cost summaries retain UTC buckets. Their timezone
  cannot be changed by relabelling daily totals.
- Costs are API-equivalent estimates, separate from subscription fees and provider credit balances.

Unknown and zero are different. An unavailable metric stays empty rather than becoming a zero. Copy diagnostics if the
provider has returned applicable data but the chart still does not show it.
