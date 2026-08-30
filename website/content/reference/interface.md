---
title: Interface reference
description: What the menu bar, the tabs and the widgets show.
icon: M3 5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM3 9h18
weight: 2
---

## Menu bar

{{< shot name="menubar" scale="3" alt="Menubar" caption="Menu bar cells for the selected windows." >}}

One cell per selected window. The label is the provider tag (`CC`, `CX`); when a provider shows more than one window the
window tag joins it (`CC 5h`, `CC FAB`, `CX 7d`) to keep the two apart. The percent takes a traffic-light colour from
green to red. Four formats exist:

| Format            | Looks like                                                                                         |
| ----------------- | -------------------------------------------------------------------------------------------------- |
| Stacked (default) | Label over value, in the proportions the [Stats](https://github.com/exelban/stats) CPU widget uses |
| Inline            | `CC:36%` on one line, the narrowest option                                                         |
| Mini bars         | Provider glyph plus tiny bars, one cell per provider carrying its windows                          |
| Custom            | Any template built from tokens such as `{cell}`, `{pct1}` and `{reset}`                            |

Windows at 0% stay hidden until you ask for them. The icon turns grey when the network drops and takes an orange badge
when a client needs a sign-in. The countdown redraws once a second, and only while the template references `{reset}`.

With **Fit to space** on, the app notices when macOS hides the item (typically behind the notch once a busy app menu
takes the left half of the bar) and steps down through narrower layouts: the configured format, stacked, one cell per
provider, mini bars, icon only. It remembers which layout fit for each frontmost app, so a switch between apps holds
steady.

## Widgets

Small, medium and large widgets show the windows selected for the menu bar with percent bars and reset countdowns. After
each refresh the app writes a snapshot to the shared app group and asks
[WidgetKit](https://developer.apple.com/documentation/widgetkit) to reload, which puts the widget at most one poll
behind the menu bar. The signed builds carry the widgets; an ad-hoc development bundle has no extension.

## Usage tab

{{< shot name="popover-usage" alt="Usage" caption="Usage tab: every window with percent, reset countdown and pace." >}}

One card per provider:

| Section                         | What it shows                                                                                                                                                                                                                                                                          |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plan chips                      | `Max 20x`, `Pro`, the account e-mail, renewal date; a click opens the vendor page, or copies                                                                                                                                                                                           |
| Windows                         | Each limit the vendor reports with percent used, a bar, "Resets in 4 hr 24 min · 6:49 PM", and a pace line ("Ahead of pace (expected 20%); hits 100% at 3:40 PM"). Hover a row for the full numbers                                                                                    |
| Claude usage credits            | The monthly spend cap, amount spent, balance, auto-reload state and reset date, as on [claude.ai/settings/usage](https://claude.ai/settings/usage)                                                                                                                                     |
| Claude local session logs       | Tokens and API-equivalent cost of the current 5-hour block, burn rate per hour, and today's totals, read from Claude Code's own transcripts                                                                                                                                            |
| Codex credits and reset credits | Balance, approximate messages left, limit resets available, spend controls                                                                                                                                                                                                             |
| Notices                         | Promotions, limit-reached and spend-limit messages, stale-data and rate-limit banners                                                                                                                                                                                                  |
| Gemini                          | One row per model with the daily request bucket, the [Code Assist](https://codeassist.google) tier and any [Google One AI](https://one.google.com/about/google-ai-plans/) credits; a personal account that Google cut off in June 2026 reads an explanation rather than a sign-in loop |
| Cursor                          | Plan usage for the billing cycle, on-demand spend against its limit, team pools, and the [membership tier](https://cursor.com/pricing)                                                                                                                                                 |
| Copilot                         | [Premium requests](https://docs.github.com/en/copilot/managing-copilot/monitoring-usage-and-entitlements/about-premium-requests), chat and completion quotas for the month, overage counts and token-based billing credits                                                             |

## History tab

{{< shot name="popover-history" alt="History" caption="History tab: 60 days of samples plus vendor analytics." >}}

The chart draws window percentages over time with the reset cliffs in place, min/max-preserving downsampling, stacked
mode, UTC or local day boundaries, and Today / 7d / 30d / 60d / custom ranges with paging. In the inspector legend, a
click hides a row, a double-click isolates it, and a hover highlights it while the value column follows the cursor.

Below the chart sit the **Codex analytics** from [chatgpt.com](https://chatgpt.com/codex/settings/analytics) (usage by
surface, credits by model, turns, tokens, skills, plugin calls, code review metrics) and the **Claude analytics** from
the local transcripts (input, output, cache-read and cache-write tokens by model, API-equivalent cost, messages,
sessions and tool calls per day).

## Settings tab

{{< shot name="popover-settings" alt="Settings" caption="Settings tab: menu bar, providers, data and the log." >}}

[Settings](/reference/settings/) describes each option.
