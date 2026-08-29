# What you see

## Menu bar

![Menu bar cells](images/menubar-dark.png#only-dark){ .menubar-shot }
![Menu bar cells](images/menubar-light.png#only-light){ .menubar-shot }

One cell per selected window. The label is the provider tag (`CC`, `CX`); when a provider shows more than one window the
window tag joins it (`CC 5h`, `CC FAB`, `CX 7d`) so nothing looks duplicated. The percent takes a traffic-light colour
from green to red. Four formats are available:

- **Stacked** (default): label over value, the same proportions as the Stats CPU widget.
- **Inline**: `CC:36%` on one line, the narrowest option.
- **Mini bars**: provider glyph plus tiny bars, one cell per provider with all its windows.
- **Custom**: any template built from tokens such as `{cell}`, `{pct1}` and `{reset}`.

Windows at 0% stay hidden by default. The icon turns grey when the network is unreachable and gets an orange badge when
a sign-in is needed. A live countdown redraws once a second only when the template references `{reset}`.

## Usage tab

![Usage tab](images/popover-usage-dark.png#only-dark){ .tab-shot }
![Usage tab](images/popover-usage-light.png#only-light){ .tab-shot }

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

## History tab

![History tab](images/popover-history-dark.png#only-dark){ .tab-shot }
![History tab](images/popover-history-light.png#only-light){ .tab-shot }

- Window percentages over time with the reset cliffs drawn in, min/max-preserving downsampling, stacked mode, UTC or
  local day boundaries, Today / 7d / 30d / 60d / custom ranges with paging.
- An inspector legend: click a row to hide it, double-click to isolate it, hover to highlight; the value column follows
  the cursor.
- **Codex analytics** from chatgpt.com: usage by surface, credits by model, turns, tokens, skills, plugin calls, code
  review metrics.
- **Claude analytics** from the local transcripts: input, output, cache-read and cache-write tokens by model,
  API-equivalent cost, messages, sessions and tool calls per day.

## Settings tab

![Settings tab](images/popover-settings-dark.png#only-dark){ .tab-shot }
![Settings tab](images/popover-settings-light.png#only-light){ .tab-shot }

See [Settings](settings.md) for every option.
