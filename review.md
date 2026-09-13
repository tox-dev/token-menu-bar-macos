# App review

Updated September 12, 2026. Unresolved defects, source-contract gaps and acceptance checks only. Readiness requires a
fully green CI run on the final commit. Earlier passes and cancelled groups do not establish acceptance.

## Confirmed failures

Candidate `a599d23`, [run 34566788923](https://github.com/tox-dev/token-menu-bar-macos/actions/runs/34566788923):

- Candidate `dccfefc`, [run 34581726798](https://github.com/tox-dev/token-menu-bar-macos/actions/runs/34581726798),
  passes nine of ten macOS 14 lifecycle tests, including all four previously failing hittability checks, launch budget,
  footprint and History return-to-idle. Demo off/on still fails when turning Demo back on: the replacement's Settings
  popover opens after the five-second stable-window deadline. The log places 3.5 seconds between the stable-anchor check
  and the window-chrome callback. The targeted startup profile on `c297a2d`,
  [run 34702362900](https://github.com/tox-dev/token-menu-bar-macos/actions/runs/34702362900), reproduces the failure.
  Of 4,987 main-thread samples, 2,083 are in the layout triggered by popover positioning. SwiftUI generic metadata
  lookup and model-list construction dominate that path, not recursive keyboard-focus traversal. Named provider-header
  and model-row views now separate the list's generic content types; native performance remains unverified. Complete tab
  switches in the unprofiled run take 14.8-43.9 ms. The full performance group and other runtimes remain unverified for
  this candidate.

- Startup logs show an unattached status-item frame at `(8, -23, 22, 22)` forcing a 200-point viewport before relayout
  at full height. The Core fallback now uses the drawable screen height. Both invalid-anchor cases fail against the old
  implementation and pass after the change; valid-anchor and small-screen clamping checks pass. Initial launch now
  passes on macOS 14, but the Demo relaunch above and cross-runtime first-frame positioning remain open.

- The macOS 26 provider-access audit reaches its five-minute deadline while completing all 14 recovery/resource actions.
  It spends about a minute expanding unrelated connection details and returning to the top before those actions. The
  follow-up removes that duplicate setup and repeated panel accessibility queries. The dedicated Providers audit retains
  disclosure checks. Verify completion with the same action inventory and deadline.

- All 1,686 tests pass in coverage, but one Settings line remains uncovered. Removing the obsolete disappearance handler
  did not close it. The local profile identifies an untested provider-focus branch during incremental mounting; the
  follow-up exercises both mounting modes. Coverage failures now name unexecuted functions, including closures whose
  source line also contains executed code. Confirm the full gate.

- The macOS 14 Collection capture contains the complete text, but OCR reads "a week" as "aweek". The follow-up matches
  non-whitespace characters without dropping expected text. All 19 saved captures pass locally; missing words, excluded
  text and incorrect endings still fail their negative tests. Confirm the rendered-text job across all runtimes.

- Complete the remaining Settings audits, including checkbox mutation, removal on collapse, retained settings and
  scrolling to all sections. macOS 14/26 fail-fast cancellation leaves these groups incomplete. The macOS 26 About and
  History groups pass. File choosers and narrow-dark text pass on macOS 15/26; other text variants remain required.

- The macOS 14 Settings menu-bar audit finds the Template identifier on the scroll container and an unnamed, disabled
  text view. The replacement native editor passes local macOS 26 multiline editing and restoration. Verify macOS 14/15
  and the remaining Settings menu-bar assertions.

- Complete required captures with the existing exact positive and negative OCR assertions.

## Local verification still needed

The local mock-only workflow checks product identity, signatures and the exact 37-method UI inventory. See
[the verification audit](mockups/macos-verification.md) for the implementation and upstream evidence.

This Mac still requires authentication to enable XCTest Automation Mode. The latest launch stopped before running a test
at that system request. The launcher now checks the unattended policy before building and before starting XCTest; it
must not prompt or silently skip native tests. Complete the documented administrator setup and then the affected native
checks. Previous successful runs do not establish that temporary authorization will persist.

Replacing the installed ad-hoc app changed its code requirement and triggered a separate App Data request. Use a stable
development or distribution signing identity for real-data reinstalls that need to retain consent. No valid signing
identity is configured here. Mock verification must continue without reinstalling or signing the real app.

Earlier local macOS 26 native checks passed Template editing, History date controls, Settings Data/retention, Log
controls and return to idle after selecting History. Those runs predate the current startup and viewport changes and do
not establish acceptance for them. The native-root candidate passes 217 nonpresenting UI tests and 20 rendered-text
assertions locally; the tests take 21 seconds, or 49 seconds including compilation and OCR, with 0.60 GiB sampled owned
RSS. Cached-frame and viewport sizing checks no longer require native presentation. The unused SwiftUI wrapper and its
unreachable presentation callback are removed. Native package and application test targets compile without execution.
Hosted native execution remains required for this candidate.

The menu-bar manager places the verification status item outside the display, previously at x = -9,282. Its pixel check
now rejects off-screen frames before requesting a capture. Opening the mock popover through the verification fallback
does not validate status-item pixels or the real arrow anchor. Complete those checks without changing the installed app
or the user's menu-bar configuration.

Use targeted checks for changed behavior or a reproduced failure; repeat only after a relevant change. Reserve the full
suite for final validation. Local runs keep one compiler job and one build/test workload at a time. Stop if owned RSS
exceeds 4 GiB, pressure becomes critical or unknown, or swap grows by 1 GiB. Warning pressure alone must not abort runs.

Default package tests remain nonpresenting. Native package compilation does not require execution; application tests use
the unlocked desktop and isolated mock dependencies. Tests must not read user credentials or provider directories,
contact provider services, change privacy permissions or launch a real sign-in command.

Verify stale-value and sign-in behavior on the required runtimes. Cached quota numbers and bars must stay muted until a
successful fetch, including Settings percentages and the status item. Provider labels retain contrast. Independent local
cost analytics must not become stale solely because quota authentication expires. Authentication recovery must use the
credential owner's supported login, preserve configured credential locations and show failures; network failures retain
Retry. The real Terminal handoff has not been executed during testing.

## CI coverage and duration

Candidate `a599d23` passes lint, all distribution builds, all UI builds, every package compatibility job and the macOS
14 release smoke test. The previous candidate passed macOS 15/26 native performance with first Settings at 11.8/56.1 ms
and repeated switches peaking at 36/153 ms; the current macOS 15 performance group was cancelled. Lifecycle, coverage
and rendered text fail as listed above. Cancelled groups leave the control inventory incomplete.

Use the targeted hosted workflow for cross-version diagnosis. It reuses the isolated app build and existing group
inventory without running unrelated package or distribution jobs. Diagnostic passes do not replace the full PR matrix.

Reusing each offscreen host reduced the six-shot export test from 102 to 44 seconds on macOS 14 and from 35 to 15
seconds in macOS 26 coverage. The latest coverage job took 5m58s with a cold timestamp-cache namespace, including 139
seconds of compilation and 163 seconds of tests. Package jobs now use the existing hash-checked input-timestamp cache
action. On the next commit, the timestamp-cache hit reduced macOS 14 nonpresenting compilation to 28 seconds and macOS
15 native compilation to 55 seconds; the preceding native compilation took 144 seconds. Complete warm-job timing after
the test corrections.

The local six-render mock profiling workload took 10.0 seconds with 0.40 GiB sampled owned RSS before the Settings
changes, and 6.9 seconds with 0.30 GiB afterward. Both runs included the stack sampler. These offscreen measurements
justify retaining the experiment, not declaring native startup fixed.

Keep the full Core/UI coverage gate and its zero-live-boundary assertion. Include the new native controller tests and
the Terminal launcher boundary. A compile-only pass does not establish native execution or coverage.

macOS 27 remains omitted while GitHub's image migration release is a prerelease. Restore its jobs after deployment and
retain actual runtime assertions. Xcode/SDK versions and deployment targets do not establish runtime coverage. A green
three-OS run meets the temporary exception, not macOS 27 acceptance.

Each OS runs at most two UI groups at once and stops remaining groups after a failure. Do not use retries, skipped
native actions or a reduced control inventory. Aim for roughly five minutes per job after allocation; queue time is
separate and five minutes is guidance. Measure cold and warm caches on each toolchain.

## Local performance investigation and lifecycle acceptance

Use the separate opt-in benchmark suite on the latest deployed macOS. Performance numbers guide local iteration; they
are not CI acceptance thresholds. Measurements include input event to AppKit draw, not display scanout. Keep 20 ms as an
optimization target and investigate transitions above 200 ms. Functional coverage on all supported runtimes still checks
cold History and Settings, fixed tab/footer positions and first-frame completeness.

Earlier hosted warm footprints were about 130-131 MiB on macOS 14/15 and 200 MiB on macOS 26. An earlier local sample
reached 269.5 MiB. Reconcile build configuration, screen size and workload; profile retained tab hosts, charts and
rendered surfaces. Short-run passes do not explain the earlier memory incident.

Profile cold startup, delayed providers, repeated refreshes with the popover open/closed, synthetic 60-day History and
hidden-History updates. Include minute-scale polling and analytics refresh, CPU and physical footprint. Check current
logs for startup layout recursion. Keep timing measurements separate from stack sampling overhead.

Verify cold opening and reopening through WindowServer frame assertions. Earlier activation moved the status item after
attachment polling; activation now precedes the stable-anchor check. Confirm that the panel does not move after its
first frame, including Custom format and display changes. An NSPanel migration remains out of scope.

## Visual and interaction acceptance

Complete the following with isolated mock data, both appearances and supported widths:

- Full Settings inventory, including retention arrow accessibility, disclosure hit targets, multiline Template
  restoration, model selection, duplicate short labels and immediate status-item updates. A responding click does not
  excuse a disabled accessibility state.
- Full long-text traversal without ellipses, blocked scrolling or tooltip-covered captures. Keep exact text checks and
  verify Settings independently from Usage/History. Gutter scrolling alone does not prove model-row scrolling works.
- Arrow alignment, available screen-height use before overflow, constant width and fixed tabs/footer. Compare collapsed
  and expanded layouts with the approved mockup, including increased text size, complete range labels, readable pacing,
  two-line resets and identity-button wrapping/copy actions.
- Keyboard focus on open, Escape dismissal and focus return without stealing focus from another app. Verify demo off/on
  relaunch and post-rollout macOS 27 status-item visibility.
- Credit-disabled percentages, zero amounts, expanded credit detail and the first Usage frame during delayed or failed
  spend loading. Keep unknown distinct from zero, Off and unlimited.
- Privacy masking in charts, legend, inspector, accessibility and exports, using recognizable synthetic account and
  project names.
- Disclosure keyboard order, expanded-state announcements and focus after collapse. Preserve open groups across tab
  switches and reopening.
- Tooltip placement after scrolling/resizing: 150 ms outside History, 1.2 seconds in History, 150 ms dismissal. Tabs and
  the History diagram must have no text tooltip.
- Log filtering, footer actions, complete selected-model legend, native chooser cancellation and CSV saving. Inspect
  screenshots and complete the second data/state and live UI/performance review after the remaining fixes.

Documentation now uses dedicated provider and task pages. Eight mock-data screenshots were refreshed from the Release
build with the viewport-prewarming changes and inspected in both appearances, using the compact viewport and single
Settings demo checkbox. The export took 7.4 seconds and 0.25 GiB sampled owned RSS; documentation checks pass. Offscreen
exports do not establish arrow geometry, native bezels or interaction acceptance.

## Provider source-contract gaps

Usage money tiles query Claude and Codex `.costUSD` rows, but the production Codex reader emits no dollar-cost rows.
Credits and token counts cannot be added to USD. Establish a supported Codex model/token pricing source and provider
model breakdown before claiming dollar-cost coverage; demo cost rows are not evidence of production collection.

Claude's local transcript reader discards event timestamps when storing daily UTC analytics. The spend summary cannot
calculate local Today/Yesterday totals from those rows even though it accepts a time zone. Preserve event time or
time-zone-aware aggregates, then test local midnight, daylight-saving transitions and migration of existing UTC rows.
Keep API daily aggregates distinct when a provider supplies no intraday timestamps.

The [provider contract research](mockups/provider-contracts.md) covers Claude, Codex, Gemini, Cursor, Copilot and
Antigravity. Claude's account-specific promotion payload, richer auto-reload details and separate billing/reset
endpoints remain unverified. Establish where the supplied usage page obtains the 50% boost/expiry, prepaid balance,
auto-reload details and billing reset. Sanitized response fixtures must distinguish endpoint availability from account
eligibility; parsing support does not prove that current credentials can fetch those fields.

Do not invent promotions or calendar-month resets, scrape browser cookies, prompt for Keychain access or use the user's
account as test data to close these gaps.
