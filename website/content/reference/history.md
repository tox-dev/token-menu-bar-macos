---
title: History
description: Choose metrics and periods, compare series and export chart data.
weight: 5
---

{{< shot name="popover-history" alt="One History chart with a metric picker, period controls and a complete series legend" caption="A month of generated quota samples in the shared History chart." >}}

One metric picker chooses one chart and legend. It groups metrics by supplier: Windows, Claude and Codex, Claude, Codex,
and Projects. Attribution beside the picker names providers with applicable data.

| Data                              | Chart and controls                                                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Usage %                           | Connected step lines for quota samples; Minute, Hour or Day rollup, with local time by default and an optional UTC switch |
| Surface usage %                   | A line over Codex daily aggregates                                                                                        |
| Counts, tokens, credits and costs | Daily bars; Stacked appears when adding the series is meaningful                                                          |

Stored daily analytics use UTC day buckets. The UI shows **Daily · UTC** and omits rollup/timezone controls that would
not change those buckets. Parallel model and surface breakdowns are not additive; stacking stays unavailable for them.

**Now** follows the current period. Today, 7d, 30d, 60d and Custom select a period; arrows page through it and leave
live mode. Choose **Now** to follow live data again. **Custom** exposes editable From and To controls. **Export CSV**
writes the selected metric and period.

The legend lists applicable series with data from enabled providers and selected models. Click to hide a series,
double-click to isolate it, and hover to highlight it. Stroke and marker differences supplement colour beyond eight
series. Quota lines connect recorded samples across missing intervals, which does not mean usage was measured during
those gaps. A reset can introduce a drop.

**Data details** holds supporting history metadata. Retention limits the periods available, and analytics coverage
differs by provider. An empty metric does not imply zero usage.
