# Token Menu Bar rebuild brief

Research checked on 31 August 2026. The approved visual and interaction reference is [`approved.html`](approved.html).
Its layout is authoritative unless it conflicts with a later explicit decision in this brief.

## Outcome

The app will use one `NSPopover` on macOS 14, 15, 26, and 27. Width stays at 880 points across tab switches when the
screen can hold it and clamps on narrower screens. Each tab keeps its measured ideal height. Content uses that height
when it fits and otherwise consumes the drawable room below the status item. Overflow uses overlay scrollbars that the
system hides automatically. Opening the panel freezes status-item re-tiering. Closing it permits one deferred fit pass.

The rebuild keeps the Core/UI boundary:

- Core owns geometry policy, presentation models, filtering, ordering, chart specifications, tooltip timing and
  placement, diagnostics, launch policy, provider setup state, refresh policy, and persistence.
- UI owns SwiftUI views, AppKit windows and panels, controls, tracking areas, pasteboard, open and save panels, and
  status-item screen conversion.

Standard controls are the modern path. They provide native pressed, hover, disabled, inactive-window, keyboard, and
focus states on every supported release and adopt the current OS appearance automatically. Custom Liquid Glass is not
used for Settings content. It would add rendering cost and cannot compile with the older SDK used by the macOS 14 job.

The tab picker sits in one compact integrated header rather than a separate padded strip. Tab labels are
self-explanatory and do not show tooltips.

Meaningful strings do not truncate with ellipses at either the 880-point width or the minimum supported width. Dense
rows reflow or wrap. Paths, identifiers, and log lines use selectable scrolling text when wrapping would destroy their
meaning.

Small meaningful secondary text maintains at least 4.5:1 contrast against its surface in light and dark appearances.
Model IDs, recency, paths, authentication sources, timestamps, chart legends, pace, and reset text must not resemble a
disabled control. Only unavailable controls use the subdued disabled appearance.

## Sources and adopted patterns

The open-source references were read at fixed commits:

- [OpenUsage](https://github.com/robinebers/openusage/tree/05c40a1dc50a16ecdc7b55d2e4fadf26827b4f61), `05c40a1d`:
  constant width, per-screen height, a drawable cap, one animation clock, lazy screens, and a shared tooltip panel.
- [Stats](https://github.com/exelban/stats/tree/d4c10b8ac6df1aa010a600148a6fc74dd32272dd), `d4c10b8a`: a scrollbar
  budget, dense cards, hidden-popup work suspension, and history gaps.
- [Maccy](https://github.com/p0deje/Maccy/tree/39e0ba5e8161dc75ac082ea51bcedc74d6a23564), `39e0ba5e`:
  top-edge-preserving panel resize, macOS 14 `onGeometryChange`, and IME-safe keyboard routing.
- [Itsycal](https://github.com/sfsam/Itsycal/tree/8d7676d2269a37c926ecf79a5095944559beeea3), `8d7676d2`: screen
  re-resolution, custom tooltip content, and an on-screen arrow escape hatch.
- [Ice](https://github.com/jordanbaird/Ice/tree/11edd39115f3f43a83ae114b5348df6a0e1741cf), `11edd391`: custom flat forms
  and an AppKit drag island inside a SwiftUI Settings shell.
- [SwiftBar](https://github.com/swiftbar/SwiftBar/tree/b9fa1ed3fc75868913bf604c1620500e7468460a), `b9fa1ed3`: stable
  object identity and collection diffs while a menu is open.
- [xbar](https://github.com/matryer/xbar/tree/d624239058997c80118eaebe2e7f8331b3c765e0), `d6242390`: deferred
  status-item reconstruction while its menu is visible.
- [FluidMenuBarExtra](https://github.com/wadetregaskis/FluidMenuBarExtra/tree/568f9defa5ce12bcfca6318284c38004dfb16450),
  `568f9def`: complete frame recomputation from the status-item screen and top anchor.
- [Shopify Tophat](https://github.com/Shopify/tophat/tree/0f597d6b9116e3064e269c9c2f8abbddb90afbdb), `0f597d6b`:
  top-edge preservation during height changes.
- [CodexBar](https://github.com/steipete/CodexBar/tree/8a732e743564abdb68ab3bee9332153ef88597a4), `8a732e74`: provider
  search, counts, ordering, status, and scalable navigation.

[iStat Menus 7.3](https://bjango.com/mac/istatmenus/) is proprietary. Its current trial and official help establish the
interaction and density reference: fixed-width arrowless menu windows, live status-item and dropdown previews,
hover-revealed enable and drag controls, anchored component editors, neutral bounded controls, compact card groups, and
color reserved for state and data. The relevant official demonstrations are the
[welcome editor](https://bjango.com/help/istatmenus7/welcome/),
[dropdown editor](https://bjango.com/help/istatmenus7/menus/), and
[history behavior](https://bjango.com/help/istatmenus7/historygraphs/).

Apple's current guidance supports the component choices:

- [`NSPopover`](https://developer.apple.com/documentation/appkit/nspopover) owns the native arrow, but Apple does not
  promise which edge remains fixed when `contentSize` changes.
- The one-value
  [`onGeometryChange`](<https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)>)
  overload is back-deployed to macOS 13. The old/new overload begins on macOS 15.
- [`NSHostingController.sizingOptions`](https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions)
  can center content whose ideal and assigned frames differ, so the root's top alignment is required.
- [AppKit's current design guidance](https://developer.apple.com/videos/play/wwdc2025/310/) recommends native controls,
  semantic materials, Auto Layout, and compact control metrics for dense inspectors.
- [SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
  recommends small geometry observations, stored presentation work, narrow invalidation, and lazy construction.

## Geometry and lifecycle

### Current `NSPopover` phase

The first repair stays on supported popover APIs:

1. Each tab emits a typed `(tab, size)` event from inside that tab's view. No asynchronous callback reads the mutable
   selected tab.
2. The controller stores height by tab and only applies a measurement when it belongs to the active tab.
3. Width resolves once per open session: 880 points on a normal display, or the available screen width minus margins. It
   never uses `fittingSize` or a transient measured width.
4. The maximum body height is the room below the status item after fixed chrome and screen margins. Oversized content
   uses that complete viewport and scrolls; shorter content keeps its ideal height.
5. The status-item button's screen and current `visibleFrame` are read on every open and after screen-parameter changes.
6. The hosting root fills its assigned frame with `.top` alignment.
7. `NSPopover.animates` drives the size change. A simultaneous independent SwiftUI transition is not used.
8. The visibility guard is set before `NSApplication.activate()`. Fit tasks are cancelled while open and one restart
   runs after close.

The UI must not call `setFrameTopLeftPoint` on the popover's private backing window. Every surveyed implementation with
explicit top-edge control owns an `NSPanel` or `NSWindow`; none resizes an `NSPopover` this way.

### Panel gate

On-screen verification decides the next step. If the corrected popover still moves its top edge or clips its arrow, the
host changes to an owned panel. The Core geometry already exposes the required invariant:

```text
frame.origin.y = anchorTopY - frame.height
frame.maxY = anchorTopY
```

That migration needs an integrated body-and-arrow AppKit path or an intentionally arrowless panel. It does not use a
SwiftUI-only triangle over a visual-effect sibling.

## Usage

Usage becomes a compact quota surface:

- Provider cards retain every quota window, plan, identity, credits, pace, spend, source, refresh state, warning, and
  accessibility value.
- Provider setup and sign-in move to Settings > Providers. Undiscovered providers do not appear as missing Usage cards.
- Usage-site URLs are removed from plan chips, provider cards, the status menu, and command handling.
- Official provider marks appear in the card header where distribution permission exists. The common slot falls back to
  the official provider name when it does not.
- Cards use immutable Core presentation snapshots. A one-second clock does not rebuild 60-day analytics summaries.
- Only leaf reset-age text observes a visible-only deadline clock.
- Every quota row shows an expected-use marker on its meter and compact expected, ratio, and projection text. A status
  title alone is insufficient. The tooltip explains the calculation but does not carry the only visible pace value.
- The curated model selection decision applies consistently to the status renderer and Settings preview. Usage keeps all
  provider data reachable and can visually de-emphasize unselected models; it does not delete them.

## Settings

One outer `ScrollView` contains six flat sections in this order: About, Menu bar, Providers, Data, Notifications, and
Log. Section labels are small, gray, and left aligned. A custom section shell and explicit label/value grid replace
`Form`, `GroupBox`, and the current multi-row content inside a single labeled cell.

All existing controls remain:

- About: Launch at login, Open Login Items, Reset All Settings, Copy Diagnostics, Report Issue, and Source.
- About in direct builds: Check for updates automatically and Check Now.
- Menu bar: Order, Format, decimals, Hide 0%, Fit to space, the custom template, model selection, and labels.
- Providers: per-provider enablement and intervals, resource grants, token-refresh consent, setup, and recovery.
- Data: retention, analytics refresh, the full History path, Open, Export, and Clear with confirmation.
- Notifications: Notify at, threshold toggles, Window resets, and Sign-in needed.
- Log: search, level filter, Copy, Clear, Show Full Log, detailed logging, and a fixed-height log view.

Update controls do not exist in App Store or Homebrew builds. `Report Issue` appears once. Reset All Settings and Clear
use native destructive confirmation. Settings has one global reset action and no scoped reset controls.

### Menu bar editor

The approved preview is a real editor surface backed by the same Core status-item model as the renderer:

- Order and Format use segmented pickers. The template field and token reference appear only under Custom.
- The preview renders the actual status string.
- Preview cells and model rows share local hover and focus identity. Selecting a preview cell scrolls to and focuses its
  model row.
- The list groups by provider. Headers expose provider selection, count, and provider ordering.
- The filter matches provider, display name, model ID, and effective short label. Command-F focuses it.
- Each row has a checkbox, display name, monospaced ID, usage percentage and recency, faint usage gauge, prefilled short
  label, character budget, override state, and a conditional revert action.
- Clearing an override restores the derived label. An empty stored override is never shown as an empty default.
- Effective short labels are unique across selected models. Core owns the invariant, and the UI reports a conflict
  inline before it persists an ambiguous override.
- Hide unused changes presentation only; selection, label, usage, and order stay reachable.
- Stable order is provider-major in the grouped surface: provider headers reorder providers and rows reorder within a
  provider. The preview exposes the resulting global status order. Drag actions have Move Earlier and Move Later
  keyboard and accessibility actions.

The model list mounts its regular stack in stages inside the tab's single scroller. A lazy stack cannot be the source of
an intrinsic popover height: its reported height changes with the viewport and creates a resize-layout feedback loop. An
AppKit drag island is used only if native SwiftUI drop feedback proves unstable on screen.

### Providers

Core exposes typed setup metadata and separate resource, credential, and service health. The UI never parses provider
error strings to choose an action.

The provider header contains enablement, mark or text fallback, official name, last-known account and plan, compact
status, and refresh interval. Recovery details remain lazy and follow this order:

1. Disabled: preserve account, credential source, and failure detail while polling stops.
2. Access needed: show each resource as Needed, Granted, Stale, or Error with Grant or Grant Again.
3. Credential store unreadable or unsupported: name the store and show the matching setup path.
4. Missing, expired, or revoked: show a copyable official CLI recovery command and Check Again.
5. Policy or license denial: show the account or administrator action.
6. Offline or rate limited: keep stale data and show retry timing.
7. Connected: show account, plan, credential source, and last successful refresh.

Providers discovered from installed CLIs, credential stores, or existing snapshots appear by default. Show All reveals
the remaining supported providers for manual setup. Recovery and empty states keep the provider mark or fallback badge
beside the provider name.

Current credential sources remain supported. New source detection does not erase legacy Claude, Codex, Gemini, Cursor,
or Copilot paths. Security-scoped resource leases balance `startAccessingSecurityScopedResource()` with stop calls,
replace stale bookmarks, and release when providers rebuild or the app exits.

Token refresh consent stays off by default and names the affected providers. Shared credential writes re-read and
compare the source after the network exchange so a rotated token cannot overwrite a concurrent CLI login.

### Provider marks

The asset loader caches one decoded image per provider and appearance. Marks keep their original colors and are never
template-tinted. Each vendored asset records its source, retrieval date, approval state, and required attribution.

OpenAI and Cursor publish usable source assets. Anthropic, Gemini, and GitHub require permission, partner access, or a
current approved product lockup for this distribution. Those providers use a compact provider-colored name badge in the
common mark slot until approval is recorded. The badge is a text fallback, not a fabricated icon. Simple Icons are not
shipped.

## History

History uses one metric picker, one summary, a materially taller chart of about 360 points, one complete legend,
selected-period CSV export, and the existing footer. The legend contributes its ideal height to the tab's one outer
scroll view; it has no fixed-height nested scroller. All presenter state remains reachable: available models, earliest
sample, selection and hover, custom dates, paging, follow-now, and reset timestamps.

There are 17 metric choices:

- Windows: Usage %.
- Claude and Codex: input, cached-input, and output tokens.
- Claude: cache-write tokens, cost, messages, sessions, and tool calls.
- Codex: surface usage, model credits, turns, threads, credits, skill calls, plugin calls, and code reviews.

The capability table belongs to Core. The picker names contributors and the selected metric displays provider, shape,
and time-basis attribution.

The approved prototype contains two stale controls:

- Mark Type is removed. Window Usage % and surface usage are lines. Additive daily metrics are bars.
- Top-series and Show All controls are removed. Every series with a stored row in the selected period starts visible.
  Zero-valued rows count as data. A user-hidden series stays in the legend and can be restored.

Window usage uses a step line. Daily percentages use linear interpolation. Additive metrics use grouped or stacked bars.
Stacked is enabled only when the metric supports it and more than one series is visible. Percentage axes use 0...100;
quantity axes start at zero.

Series identity is stable across range, metric, and visibility changes. Core assigns a style slot to each provider-
qualified series ID. UI maps the slot to hue, stroke dash, point symbol, and bar outline or pattern so 13 series never
repeat the same identity. Toggling a series does not renumber the others.

Now is the leading range segment. Selecting it returns to live. Paging leaves Now while preserving the chosen span.
Fixed and custom ranges page with calendar arithmetic, not fixed seconds, so daylight-saving transitions do not drift.
Changing either date field enters Custom immediately. Analytics use UTC day axes. Rollup remains available for window
samples and shows Day as the effective read-only value for daily provider analytics.

Reset boundaries survive downsampling and appear in chart selection and accessibility. Stale data creates a gap rather
than extending to the viewport edge. Chart hover uses one sorted timeline and binary search. The chart supplies an
accessibility descriptor and keyboard selection.

History loads one selected metric and supplier set for the visible day range. Transforms run off the main actor. The
existing SQL rollup and extrema-preserving point limit remain. Metric and legend changes reuse cached rows; a range
change cancels and replaces one task.

macOS 14 renders line collections with `LineMark`. macOS 15 and later may use vectorized `LinePlot` behind a floor
availability check. Bars use `BarMark` on every release.

## Rich help

Every control except the tab picker gets explanatory help without `.help()`. Hover presentation and dismissal each wait
150 ms:

- One lazy, reusable, mouse-transparent, nonactivating AppKit panel exists per open popover session.
- One `NSVisualEffectView` with `.toolTip` material and one wrapping `NSTextField` render title, body, and monospaced
  inline spans.
- Lightweight tracking views report only enter and exit. Pointer movement inside a target performs no work.
- One cancellable task, owner token, and generation reject stale presentation and dismissal events.
- Placement is screen-aware, inset by 8 points, seven points from the target, and flips above near the bottom edge.
- Keyboard focus uses the same presenter without adding focus stops.
- Escape, scrolling, removal, window close, and popover close cancel pending work and release the panel.
- Reduce Motion removes the 90 ms fade. Reduce Transparency uses an opaque semantic background.

The tooltip panel is absent from the accessibility tree. Each source control carries the same explanation in its label,
value, and hint.

## Logging

`LogBuffer` remains a bounded Core-owned support log and gains a second Apple Unified Logging sink. A closed typed event
model covers panel geometry, tab measurement, status re-tiering, provider refresh, and safe request results. AppKit
objects are converted to Core geometry and identifiers at the UI boundary.

Detailed events use an autoclosure and are not constructed while logging is off. Unified loggers use component
categories and typed interpolation at the call site so privacy remains intact. Response bodies, headers, tokens,
cookies, emails, URL queries, and raw Keychain failures never enter logs.

The app-owned buffer keeps 500 records. Each line is capped at 2 KiB. File output uses a serial utility queue, rotates
at 1 MiB, retains at most three files younger than seven days, and schedules one delayed flush when pending output
changes from empty to nonempty. It has no repeating timer.

Core adds warning to Debug, Info, Warning, and Error and fixes debug entries currently stored as info. The Settings log
uses a fixed-height `NSTextView` with search and level filters. It subscribes only while visible. Show Full Log follows
the tail until the user scrolls up. Core owns filtering and sanitized export; UI owns pasteboard and save panels.

Signposts measure provider fetches, History reload and queries, panel open, and resize. They remain in Instruments and
do not inflate the in-app buffer.

## Performance work

The approved appearance does not require continuous work. The implementation follows these rules:

- Views render stored immutable Core presentation snapshots. View bodies do not scan analytics or decode credentials.
- Only visible leaf text schedules its next meaningful age or reset update.
- Closed tabs do not create charts, tooltip windows, log subscriptions, or clocks.
- Closed panels stop presentation clocks and geometry work.
- Status rendering coalesces changes, skips identical output, and defers width fitting while the panel is open.
- Usage refresh, analytics refresh, and forced recovery are separate policies. Refresh Now does not request every Codex
  analytics endpoint unless analytics is due or explicitly requested.
- Codex reset-credit lookup uses a time-to-live cache and an in-flight guard.
- History has one reload owner and one cancellable selected-metric task.
- Provider work is concurrent by provider, deduplicated in flight, and retains last-good data.
- SQLite writes batch in explicit rollback-safe transactions.
- Provider marks decode once per provider and appearance.

Performance verification measures app launch, panel open-to-ready, tab-to-stable-frame, 13-series chart preparation,
repeated open and close, Settings scroll, idle CPU, and retained memory. A disabled detailed-log benchmark constructs no
events and writes no files.

## OS and build matrix

- Shell: native `NSPopover` on macOS 14 and 15. macOS 26 adopts the current material; macOS 27 follows the same floor.
- Controls: native bordered buttons, segmented controls, checkboxes, switches, and steppers on every release. macOS 26
  adopts current control geometry after compact-metric verification; macOS 27 follows the same floor.
- Charts: `LineMark` and `BarMark` on macOS 14. macOS 15 and later may use `LinePlot` where it earns its cost.
- Content: a semantic standard surface without glass cards on every release.
- Rich help: one shared AppKit tooltip panel on every release.

`Package.swift` uses Swift tools 6.0 and Swift 6 language mode so the manifest remains parseable on the macOS 14 job.
The deployment target remains 14.0.

The CI matrix covers:

- macOS 14 runtime smoke for the release artifact and fallback source compilation while GitHub's runner remains
  available; a self-hosted or third-party runner replaces it after retirement.
- macOS 15 full behavior and UI tests.
- macOS 26 strict coverage, both distribution flavors, and performance gates.
- Xcode 27 compile and test on its available host, plus self-hosted macOS 27 runtime verification.

Any 26- or 27-only source needs both a compiler gate and a runtime floor. Shared interfaces expose Core enums and
protocols. No newer AppKit type appears in a file parsed by the Xcode 16.2 job.

## Verification contract

The offscreen exporter remains a design artifact renderer. It cannot prove an arrow, AppKit bezel, focus ring, tab event
order, window placement, screen selection, or real analytics.

Verification uses:

1. Core tests for typed measurements, constant width, caps, geometry, chart rules, style identity, launch policy,
   tooltip timing, provider setup, refresh policy, and diagnostics.
2. AppKit integration tests with a real popover and window frame.
3. An Xcode UI-test target for status-item opening, Command-R, Command-F, Escape, Tab and Shift-Tab order, controls,
   accessibility, and performance.
4. An on-screen release matrix for macOS 14, 15, 26, and 27 covering light and dark mode, contrast, reduced motion and
   transparency, both screen edges, notch-adjacent placement, external displays, every Dock position, every tab pair,
   arrow shape, bezels, hover, press, and focus.

UI verification runs in a dedicated defaults suite and temporary support directory. It forces demo state independently
of persisted user settings. Development launch recipes use that isolated mode by default; real-data launch is explicit.

## Delivery order

1. Preserve the existing quick-win changes, correct their sizing seam, and add the research brief and approved artifact.
2. Land geometry, measurement, visibility, status re-tier, launch isolation, and CI foundations.
3. Land Core presentation, setup, refresh, diagnostics, tooltip, and chart models.
4. Land the approved Usage and Settings sections with native controls and complete inventory.
5. Land the unified History chart, legend, selection, export, and accessibility.
6. Land the shared tooltip panel, log UI, keyboard routes, and provider marks with approved licensing metadata.
7. Run the full unit, integration, UI, accessibility, coverage, performance, and OS verification matrix.

Nothing except usage-site links is removed. Condensed information remains reachable and stays in accessibility values.
