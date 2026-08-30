---
title: What you see
description: Menu bar cells, the Usage, History and Settings tabs, and the widgets.
weight: 2
---

## Menu bar

{{< shot name="menubar" alt="Menubar" caption="Menu bar cells for the selected windows." >}}

One cell per selected window. The label is the provider tag (`CC`, `CX`); when a provider shows more than one window the
window tag joins it (`CC 5h`, `CC FAB`, `CX 7d`) so nothing looks duplicated. The percent takes a traffic-light colour
from green to red. Four formats are available:

- **Stacked** (default): label over value, the same proportions as the Stats CPU widget.
- **Inline**: `CC:36%` on one line, the narrowest option.
- **Mini bars**: provider glyph plus tiny bars, one cell per provider with all its windows.
- **Custom**: any template built from tokens such as `{cell}`, `{pct1}` and `{reset}`.

Windows at 0% stay hidden by default. The icon turns grey when the network is unreachable and gets an orange badge when
a sign-in is needed. A live countdown redraws once a second only when the template references `{reset}`.

With **Fit to space** on, the app notices when macOS hides the item (typically behind the notch once a busy app menu
takes the left half of the bar) and steps down through narrower layouts: the configured format, stacked, one cell per
provider, mini bars, icon only. It remembers which layout fit for each frontmost app, so switching apps does not
flicker.

## Widgets

Small, medium and large widgets show the windows selected for the menu bar with percent bars and reset countdowns. The
app writes a snapshot to the shared app group after every refresh and asks WidgetKit to reload, so the widget is at most
one poll behind the menu bar. Widgets ship in the signed builds; ad-hoc development bundles have no extension.

## Usage tab

{{< shot name="popover-usage" alt="Usage" caption="Usage tab: every window with percent, reset countdown and pace." >}}

One card per provider:

- **Plan chips**: `Max 20x`, `Pro`, the account e-mail, renewal date; click to open the vendor page, or copy.
- **Windows**: every limit the vendor reports with percent used, a bar, "Resets in 4 hr 24 min · 6:49 PM", and a pace
  line ("Ahead of pace (expected 20%); hits 100% at 3:40 PM"). Hover any row for the full numbers.
- **Claude usage credits**: the monthly spend cap, amount spent, balance, auto-reload state and reset date, as on
  claude.ai/settings/usage.
- **Claude local session logs**: tokens and API-equivalent cost of the current 5-hour block, burn rate per hour, and
  today's totals, computed from Claude Code's own transcripts.
- **Codex credits and reset credits**: balance, approximate messages left, limit resets available, spend controls.
- **Notices**: promotions, limit-reached and spend-limit messages, stale-data and rate-limit banners.
- **Gemini**: one row per model with the daily request bucket, the Code Assist tier and any Google One AI credits;
  personal accounts that Google cut off in June 2026 get an explicit explanation instead of a sign-in loop.
- **Cursor**: plan usage for the billing cycle, on-demand spend against its limit, team pools, and the membership tier.
- **Copilot**: premium requests, chat and completion quotas for the month, overage counts and token-based billing
  credits.

## History tab

{{< shot name="popover-history" alt="History" caption="History tab: 60 days of samples plus vendor analytics." >}}

- Window percentages over time with the reset cliffs drawn in, min/max-preserving downsampling, stacked mode, UTC or
  local day boundaries, Today / 7d / 30d / 60d / custom ranges with paging.
- An inspector legend: click a row to hide it, double-click to isolate it, hover to highlight; the value column follows
  the cursor.
- **Codex analytics** from chatgpt.com: usage by surface, credits by model, turns, tokens, skills, plugin calls, code
  review metrics.
- **Claude analytics** from the local transcripts: input, output, cache-read and cache-write tokens by model,
  API-equivalent cost, messages, sessions and tool calls per day.

## Settings tab

{{< shot name="popover-settings" alt="Settings" caption="Settings tab: menu bar, providers, data and the log." >}}

See [Settings](settings.md) for every option.
