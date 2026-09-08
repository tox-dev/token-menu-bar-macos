# App review

Updated September 8, 2026. This file contains unresolved defects, source-contract gaps, and pending acceptance checks.
Implemented findings and the fix history have been removed.

The latest macOS 14/26 control audits, macOS 14/15 package tests and macOS 14/26/27 performance and lifecycle results
are from [CI run 34260352860](https://github.com/tox-dev/token-menu-bar-macos/actions/runs/34260352860). The macOS 27
control audit and other OS jobs are still pending. Earlier failures remain open until their corresponding reruns finish.

## UI fixes awaiting live acceptance

### macOS 27 package-test compatibility

[Job 102307556130](https://github.com/tox-dev/token-menu-bar-macos/actions/runs/34300624786/job/102307556130) runs on
actual macOS 27. CPU device selection succeeds, but recognition throws `.nilError` in all six Settings OCR cases in both
execution modes and with both Swift 7 build engines. PNG input and off-main-actor recognition do not resolve it. Every
other package test passes, including the corrected native fixtures. Framework-log collection in run 34299066294 reports
no OCR-process error. CI now retains the six mock Settings PNGs from each execution mode; inspect the failing images
before changing the recognition path. The error precedes the text assertions and does not establish that the displayed
text is incorrect.

The PNG-input, off-main-actor path passes both package suites on macOS 14, 15 and 26. The macOS 26 coverage gate remains
at 100% measured Core/UI lines, with no live-data boundary calls. Resolve the OCR failure before this finding closes.

The native suite runs after a successful build even when the nonpresenting suite fails; both remain required.

### Custom format moves the popover

The macOS 15 Menu bar recording shows the popover moving upward by 22 pt when selecting Custom. Its top changes from 36
pt to 14 pt while its height remains 636 pt. The status-item width assertion passes, so this recording does not
establish status-item widening as the cause.

The controller now re-pins move notifications as well as resize notifications. Regression tests reproduce and prevent
move-only displacements in both directions. The latest macOS 14 audit passes the Custom selection anchor assertion, then
fails to detect a status-item change after editing its template. Its log also records transient 44 pt status-button
heights while editing. The native cell now prevents attachment wrapping; verify this on macOS 14/15. The template audit
now turns off Fit to space while checking the configured format; the adaptive fallback does not use a Custom template.
Separate tests retain coverage of fallback updates and frozen width while the popover is open.

### Resource chooser opens behind the popover

The macOS 14 and 15 Providers recordings show the native resource chooser behind the disabled popover. Raising
`NSSavePanel.level` did not fix this.

Chooser presentation now lowers the invoking window during the dialog and restores its level afterward. A local macOS 26
window capture and guarded mouse click confirm the chooser is in front and Cancel is reachable. The modal event-routing
fix passes its regression test, and a second local mouse-click run confirms that Cancel retains the popover and its
Settings position. The driver now recognizes `open-panel` as well as `save-panel`.

Verify selection and cancellation on every OS using resources inside the isolated verification directory. The test must
not request access to user credentials or real provider directories.

### Identity button wrapping on macOS 14 and 15

The multiline `NSButtonCell` passes the package wrapping and copy tests on macOS 14, 15 and 26. Earlier long-text
recordings show clipped native identity titles; rerun the control audit before closing the visual finding.

The native AppKit accessibility label is populated. The live driver now includes the native title when distinguishing
buttons with empty XCTest labels. Keep wrapping, copy-action and rendered-text checks in the live audit.

### Activation and native tooltip hit testing

The macOS 26 reopen recording shows a wider status-item probe after returning to the same app, followed by shrinking and
movement before the next click. The planner now retains its active context and suppresses redundant activation probes.
Regression tests cover the same app, our own app and a different app. The latest macOS 26 warm benchmark now completes
reopening and its opening-geometry checks. On macOS 27, the item disappears from the menu bar while AppKit still reports
an on-screen frame and visible occlusion; both the warm benchmark and lifecycle reopen test fail. The macOS 27 path now
also checks WindowServer's on-screen window list. Verify that a narrower visible item survives Escape and reopens the
popover. macOS 15 remains pending.

Native tooltip tracking views now pass mouse hit tests through to their controls. A regression test fails without that
override. All three macOS 14 tooltip audits now pass. macOS 26 passes Usage and History, but Settings fails to show the
Order tooltip after scrolling. The other OS hover audits remain pending.

### Full Log window handoff

The Full Log action left a normal-level window behind the higher-level popover. It now closes the popover without
restoring the previous application's activation before presenting the log. Regression tests cover dismissal and focus
restoration policy. The live audit must complete Command-F, closing the log, reopening Settings and retaining the
disclosure state.

## Unresolved control-audit failures

- History: macOS 14 completes metrics, UTC, rollups, stacking, legend and paging, then cannot hit the From date-picker
  container. The driver now targets its native increment arrow and still requires a hit and a changed date. Complete
  both dates and export. macOS 26 still cannot hit the visible metric picker.
- Data: the retention stepper is visible in the recording, but the driver reports it as unavailable. The new driver
  reveals the native increment arrow instead of testing the stepper container. Verify value changes and restoration
  before proceeding through Storage and Collection.
- Log: macOS 14 now clicks every level segment, then fails at Search. The driver now scrolls Search and each action into
  view before clicking. Complete searching, clearing and Full Log handoff.
- Long text: macOS 14 renders complete warning banners but the OCR audit looks for an unprefixed static-text label.
  Match the combined `Warning:` accessibility label and audit its rendered body. Keep the nonzero banner-count check.
- Demo relaunch: replacement-PID activation passes off/on on macOS 14 and 26. Complete macOS 15/27 acceptance.

The failing audit cases remain open until the controls complete their actions. A suspected driver problem does not
establish that the application behavior is correct.

Native stepper hit tests pass inside the scrolling container at two scroll positions. They do not reproduce the live
History picker and retention failures. No scrollbar-view change was retained from that investigation.

## Performance acceptance (R14, R16, R21)

The macOS 14 benchmark in [run 34279219576](https://github.com/tox-dev/token-menu-bar-macos/actions/runs/34279219576)
still fails warm latency at 228 ms p95, with a 26 ms first Settings presentation. This run includes the resize-observer
suppression below. It does not close the performance finding.

The latest macOS 14 warm-tab benchmark reaches 192.4 ms p95 and maximum, failing the unchanged 20 ms p95 and 50 ms
maximum limits. Its first Settings click passes at 17.4 ms; the warm test's first Settings presentation passes at 42.8
ms. The latest macOS 26 warm run fails at 345.4 ms p95/maximum, with a 47.0 ms first Settings presentation. Its slow
Usage switch spends 337.6 ms after receiving the click, following a scheduled mock-provider refresh. The earlier macOS
15 warm result also failed at 74.6 ms p95. The macOS 27 first Settings click fails at 80.2 ms; its warm run stops at the
status-item reopening failure before collecting tab timings.

Current optimized UI benchmarks omit coverage counters. Rerun input-event-to-AppKit-draw measurements after the
remaining fixes. Local accessibility action-to-draw timings do not include queued input and cannot close this finding.
AppKit draw completion also does not prove display scanout.

Explicit viewport sizing removes the default fitting traversal from the sampled macOS 14 selection path, but does not
close the latency failure. The new profile still includes hidden-view propagation and subtree layout. In the warm run,
History and Settings height changes take 130.5–192.4 ms; unchanged-height Usage switches take 18.9–30.6 ms. Added
debug-only phase timings separate content selection, viewport application and the `contentSize` setter. A simple
transparent-window resize test passes locally; it does not reproduce the full live hierarchy's cost. A guarded local
mouse-click run reproduces a 143.9 ms Usage switch, including 115.1 ms inside `contentSize`, after time spent on another
tab. Subsequent switches range from 16.4 to 23.3 ms. This six-click diagnostic is not a replacement for the benchmark.

The controller now suppresses its move/resize observer while applying its own content size, then pins and records the
result once. A regression test fails on the duplicate handling and passes with the change; move-only pinning remains
covered. Measure the latency and first visible frame on every OS before closing this finding.

The local uninstrumented warm sample reports a 269.5 MiB physical footprint on a 1080 pt screen, above the 256 MB gate.
The latest macOS 26 warm CI run reports 201.7 MiB before and 200.0 MiB after interaction, and all ten lifecycle cases
pass. The latest macOS 14 warm run stays below the gate at 124.6 MiB before and 126.6 MiB after interaction. Its
lifecycle memory-snapshot request still times out despite removing the main-queue task hop; the teardown snapshot
arrives and records 120.2 MiB. Demo seeding finishes 9.4 seconds after launch in that failing case. Diagnose the delayed
response instead of extending the timeout. Repeat macOS 26 resource measurements with the benchmark workload and account
for retained hosts, charts and rendered surfaces.

Local isolated startup samples before and after explicit viewport sizing retain 241.2 and 207.0 MiB respectively. The
latter uses 33.1 MiB of image surfaces versus 47.6 MiB before. These locked-session startup samples do not replace the
warm interaction workload or its peak-memory check.

Profile cold startup, delayed providers and repeated refreshes with the popover open and closed. Include the synthetic
60-day History workload and hidden-History updates. Ten idle seconds do not cover minute-scale polling or analytics
refreshes. Report build configuration, footprint and CPU alongside the interaction timings.

Investigate the startup layout-recursion warning from earlier live runs and check whether the current build still emits
it. Do not classify it as resolved without a clean reproduction run.

## Four-OS acceptance (R23)

- macOS 14: package tests, including wrapping, and application compilation pass. The live acceptance failures above
  remain.
- macOS 15 and 26: complete the current control, lifecycle and performance suites. Earlier passes do not cover the
  subsequent changes.
- macOS 27: recent jobs still received macOS 26.5.2 despite their `xcode-27` label. GitHub has published a
  [macOS 27 image](https://github.com/actions/runner-images/releases/tag/xcode-27-arm64%2F20260907.0173), but the
  rollout has supplied mixed runtime versions. Homebrew and Direct builds have passed on macOS 27.0 (26A5406e); package
  acceptance must resolve the native failures above, and App Store acceptance still needs an actual macOS 27 run. An
  earlier UI job passes its actual macOS 27 runtime assertion and builds, but fails first-click performance and
  status-item reopening. Retain the runtime assertion.

Acceptance requires package tests, distribution builds and live UI checks on macOS 14, 15, 26 and 27. Xcode version and
deployment target do not establish the runtime OS.

## Provider source-contract gaps (R2)

The [provider contract research](mockups/provider-contracts.md) covers Claude, Codex, Gemini, Cursor, Copilot and
Antigravity. Claude's account-specific promotion payload, richer auto-reload object details and separate billing/reset
endpoints remain unverified.

Establish where the supplied usage page obtains the 50% boost and expiry, current prepaid balance, auto-reload details
and billing reset. A sanitized response fixture is still needed to distinguish endpoint availability from account
eligibility. Existing parsing support does not prove that the current credentials can fetch those fields.

Keep unknown values distinct from zero, Off and unlimited. Do not invent a promotion or calendar-month reset, scrape
browser cookies, prompt for Keychain access, or use the user's account as test data to close this gap.

## Remaining visual and interaction acceptance (R4, R12, R17, R18, R22)

Use an isolated mock app for the following checks:

- Confirm arrow alignment, opening position and status-item stability across the supported OS versions. The local
  offscreen status-item anchor cannot validate these. The macOS 15 opening-geometry pass does not cover the Custom
  format movement above.
- Verify keyboard focus on open, Escape dismissal and focus return to the previous app without stealing focus from an
  app the user clicks.
- Compare collapsed and expanded layouts with the approved mockup at narrow/wide widths and increased text size. Check
  the range picker, native identity buttons, full Settings content, readable pacing and two-line Usage resets.
- Verify that expansion uses the available screen height before scrolling, keeps the tab bar and footer fixed, and
  preserves disclosure state across tab switches and reopening.
- Check disabled-credit percentages and zero amounts in both summary and expanded detail. Verify the first Usage frame
  with delayed spend loading and with a failed reload.
- Audit privacy masking in the chart, legend, inspector, accessibility text and exports using recognizable synthetic
  account/project names.
- Verify disclosure keyboard order, expanded state, focus after collapse, and 150 ms tooltip appearance/dismissal. Tabs
  should have no tooltip.
- Complete the control inventory and inspect screenshots after fixes. Keep the Log section, footer actions, model
  selection and full selected-model legend reachable.

Finish the data/state review and the live UI/performance review after the remaining fixes. Unit coverage and offscreen
renders do not close these acceptance checks.
