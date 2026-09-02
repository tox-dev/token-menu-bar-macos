---
title: Troubleshooting
description: The log to capture, the report to send, and what each symptom means.
weight: 6
---

## Capture the evidence first

A report without a log is a guess. The order matters, because the log only records what happened after you turned it on.

1. Turn on **Detailed logging** under Settings > Log, before you reproduce the problem. It is high-volume: a line for
   every request sent and every response received, and a line each time the menu bar item changes size or visibility.
   The buffer keeps the last 500 lines and 7 days, so a day spent with it on pushes out the very thing you wanted to
   report.
2. Reproduce the problem.
3. Send the report, or attach the log.
4. Turn **Detailed logging** back off.

The log sits next to the history database:

```sh
open -R ~/Library/Application\ Support/Token\ Menu\ Bar/log.txt
```

The App Store build is sandboxed, so its copy sits under `~/Library/Containers/dev.tox.token-menu-bar/Data/` instead.
Lines reach the file in batches, up to five seconds behind the app; Settings > Log shows the last 200 straight from
memory, so read there for the newest ones.

### What the log leaves out

- Request URLs lose their query string, and any UUID in the path becomes `{id}`.
- The app writes no request headers, so no token reaches the file.
- A successful response leaves its status, byte count and duration behind. The body stays out.
- A rejected request records the first 200 bytes of its body, which is the vendor's own error text. Skim it before you
  attach it, since vendors sometimes name the account or the organisation there.

### Which route to use

**Report Issue** under Settings > About opens a GitHub issue pre-filled with the diagnostics report, cut to the whole
lines that fit in an 8000-character URL, and the log tail is what falls off first. When the log is the point, use **Copy
Diagnostics** and paste it into the issue yourself.

Either way the report carries the version and build flavour, the macOS version, the poll intervals and menu bar format,
the enabled providers, the history path, the age of the last refresh, one line per provider with its status, plan,
window percentages, last error and credential state, and the last 80 log lines. It names your plan and how much of it
you have used, so read it before you send it.

## A provider shows nothing

When a provider has no card in the Usage tab at all, it is either switched off or the app found no credential for it.
Settings > Providers holds a switch and a credential line for each one: `No credentials: …`, `Token expired …`, or
`Token valid until …`.

When the card is there, its status line names one of eight states, and those eight are the only distinctions the app can
draw:

| Status                    | What it means                                                                      | What to do                                                                                             |
| ------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Loading                   | The first fetch is in flight                                                       | Wait a poll                                                                                            |
| Up to date                | The last fetch worked; "No usage yet" under it means the vendor reported no window | Nothing                                                                                                |
| Showing last known values | A fetch failed and the numbers below are the previous ones, with their age         | Read the reason next to it                                                                             |
| Sign-in required          | No usable token, or the vendor answered `401`/`403`                                | Sign in with the client; Settings > Providers can let the app refresh Claude, Codex and Gemini for you |
| Offline                   | The request never reached the vendor                                               | Check the network                                                                                      |
| Rate limited              | The vendor answered `429`                                                          | See [below](#a-provider-is-rate-limited)                                                               |
| Unavailable               | The vendor answered, but with an error or a shape the app could not read           | The card and the log carry the vendor's own message                                                    |
| Disabled                  | Switched off                                                                       | Settings > Providers                                                                                   |

A vendor outage, a changed response shape and a body the app cannot decode all land on **Unavailable** with whatever the
vendor said. The app does not guess between them, and neither should a report. After any failure it waits a minute
before trying that provider again.

## The menu bar shows only the icon

The icon appears only when there is no cell to draw, and disappears the moment one number lands. So an icon on its own
means one of:

- No refresh has finished yet.
- No window is ticked under Settings > Menu bar, or **Hide 0%** is on and every ticked window sits at 0%.
- **Fit to space** stepped all the way down to the icon-only layout, because macOS had no room for the numbers.

## The icon is grey, or carries an orange dot

Grey ink means at least one enabled provider is offline. An orange dot means at least one needs a sign-in, and it wins
when both are true. Both tones are visible only in the icon-only state above; once cells show, the popover card is where
a provider says it is offline or signed out.

## The menu bar item disappears

macOS hides status items it has no room for, most often behind the notch once a busy app takes the left half of the bar.
**Fit to space** under Settings > Menu bar exists for this, and steps down through narrower layouts instead.

To report one that vanishes anyway, turn on **Detailed logging**, which also starts the status item probe. The probe
samples once a second and writes a line whenever the reading changes:

```text
status item visible=true buttonHidden=false window=true occlusion=false length=64 width=64 front=Xcode
```

Attach those lines, along with `status item does not fit; stepping down to tier N`, and say which app was frontmost.
`visible=true` with a non-zero `width` and `occlusion=false` is the notch case; `visible=false` is macOS removing the
item outright, which is a different bug.

## Cursor stops reporting

The app reads Cursor's session from `state.vscdb` read-only and with SQLite's `immutable=1`, so it never locks the
database and cannot disturb a running Cursor. The cost is that an immutable open ignores the write-ahead log, so a token
Cursor wrote since its last checkpoint is invisible to the app. Sign in or out while Cursor is running and the card can
say **Sign-in required** while Cursor itself works fine.

Quit Cursor, which checkpoints the database, then press **Refresh**. Or run `cursor-agent login`, which writes
`~/.cursor/auth.json`; the app reads that next when `state.vscdb` yields nothing.

## A provider is rate limited

The card says **Rate limited** and names the time of the next attempt, and the last good numbers stay on screen with
their age. [Privacy and rate limits](/explanation/#rate-limits) covers why the poll interval is what it is and how the
backoff works.

**Refresh** ignores the backoff window, and each `429` doubles the hold that follows, so a run of manual refreshes
against a rate-limited provider makes the wait longer rather than shorter.

## Widgets show stale numbers

Widgets read a snapshot the app writes into the shared app group. The app rewrites it and asks WidgetKit to reload at
the end of a refresh cycle, and only when a value in it changed; otherwise the widget re-renders from what it has, every
15 minutes, within whatever budget WidgetKit allows. So a widget is at most one poll behind the menu bar, and one that
never moves points at an app that is not running.

Opening the popover and pressing **Refresh** fetches every enabled provider at once, ignoring both the poll intervals
and the backoff, and republishes the snapshot if anything moved. Widgets ship with the signed builds only; an ad-hoc
development build has no widget extension, and demo mode writes no snapshot.

## What VoiceOver reads

The menu bar item draws its numbers as an image, which VoiceOver would otherwise read as nothing, so the button carries
a label with the same readings the tooltip shows, rebuilt on every redraw:
`Token Menu Bar, Claude Session: 36%, resets 2 hr 14 min`, or `Token Menu Bar, no usage yet` when there are no cells.

- Icon-only controls carry their own labels: **Refresh usage**, **Previous period**, **Next period**, and the copy
  button beside each copyable value.
- The history chart exposes one chart descriptor with every visible series, date, and value. A legend row reads its
  total and can hide, restore, or isolate its series. VoiceOver skips decorative swatches; provider marks use the
  provider name as their label.
- Meaning survives without colour. A banner spells out `Warning:` or `Note:`, each meter carries its label and
  percentage, and the provider status is words before it is a tint. The menu bar icon is the exception, since its grey
  and orange tones stand alone in the bar, and the popover card is where that state appears in words.
- No alert is sound-only. Every notification carries a title and a body, and the sound comes with them.

If VoiceOver reads something other than the above, that is a bug worth a report, with the diagnostics attached.
