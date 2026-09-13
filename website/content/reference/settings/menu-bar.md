---
title: Menu bar settings
description: Model selection, short labels, status formats and template tokens.
weight: 2
---

| Control                          | Default and effect                                                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Order                            | **Stable**. Drag provider groups or models to set their order. **Usage** sorts by the used percentage.                     |
| Format                           | **Stacked**. Alternatives are Inline, Mini bars, Countdown, Countdown at 100% and Custom.                                  |
| Preview                          | Renders the actual status string. Hover a preview cell or model row to identify its counterpart.                           |
| Models                           | Select models or rate-limit periods. Groups have provider marks and a select-all box. Filter by name or ID.                |
| Short label                      | Prefilled, unique labels of up to six characters. Clear an override or use its revert button to restore the derived label. |
| Hide models with no usage        | Off. Hides unused rows from the model list for the current range; it does not delete their settings or history.            |
| Hide account and project details | Off. Masks identifying display text. It does not remove the underlying records from disk.                                  |

**Display options** contains:

| Control       | Default and effect                                                                                                   |
| ------------- | -------------------------------------------------------------------------------------------------------------------- |
| Decimals      | 0; choose 0–2 decimal places.                                                                                        |
| Hide 0%       | On. Hides zero-used status cells without deleting their data.                                                        |
| Fit to space  | On. Tries narrower status layouts when the current one does not fit.                                                 |
| Show usage as | **Used**; **Left** displays remaining quota in the menu bar, Usage and widgets. Colours still follow the used share. |

### Custom templates

The Template field appears only for **Custom**. Built-in text formats use the edited short label without requiring a
custom template.

| Token                                 | Output                                                               |
| ------------------------------------- | -------------------------------------------------------------------- |
| `{label}`                             | Resolved, unique short label                                         |
| `{cell}`                              | Provider code, plus the period/model tag when needed                 |
| `{provider}`, `{providerName}`        | Provider code or full name                                           |
| `{window}`                            | Period/model tag                                                     |
| `{pct}`, `{pct0}`, `{pct1}`, `{pct2}` | Percentage with configured or explicit decimals, following Used/Left |
| `{remaining}`                         | Percentage left, independent of Used/Left                            |
| `{pctOrReset}`                        | Percentage until exhausted, then a reset countdown                   |
| `{reset}`, `{resetClock}`             | Countdown or reset clock time                                        |
| `{plan}`, `{credits}`                 | Reported plan or credit balance                                      |

Use `\n` for a line break and `{{` or `}}` for literal braces. Unknown tokens produce no text. For example:

```text
{label}\n{pctOrReset}
```

Exhausted provider-wide or model-specific limits remain visible as restrictions even if a custom template omits them.
