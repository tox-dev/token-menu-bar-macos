---
title: Menu bar
description: Read selected limits, weekly restrictions and reset countdowns.
weight: 3
---

{{< shot name="menubar" scale="3" alt="Demo menu bar cells with short labels and quota percentages" caption="Menu bar preview with generated Claude and Codex data." >}}

The menu bar shows selected models or rate-limit periods with unique, editable short labels. Colours follow the used
share, including when **Show usage as** displays what is left.

| Format            | Presentation                                                                          |
| ----------------- | ------------------------------------------------------------------------------------- |
| Stacked           | Label above percentage; the default                                                   |
| Inline            | Label and percentage on one line                                                      |
| Mini bars         | Compact provider marks and quota bars                                                 |
| Countdown         | Label, percentage and time to reset                                                   |
| Countdown at 100% | Percentage until exhausted, then time to reset                                        |
| Custom            | Text assembled from [template tokens](/reference/settings/menu-bar/#custom-templates) |

A selected session can have quota left while a weekly limit prevents its use. Claude and Codex restrictions mark the
affected status cells. A provider-wide weekly restriction affects that provider's selected models, while a
model-specific restriction affects the matching model. The warning survives compact and custom formats, including
icon-only fallback.

Reset countdowns change at the next displayed time boundary, without a permanent per-second redraw. **Hide 0%** removes
zero-used cells by default. **Fit to space** tries narrower layouts when macOS has insufficient menu bar space and
remembers fitting choices per frontmost app. Passive re-tiering pauses while the panel is open; explicit display edits
still apply.

The app icon appears when there are no visible cells or the width fallback reaches icon-only. Open the panel for the
textual provider state and last-refresh age.
