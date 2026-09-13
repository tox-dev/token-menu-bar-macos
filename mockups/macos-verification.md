# macOS development and verification

Token Menu Bar needs three distinct test environments: nonpresenting tests on the developer Mac, an explicit local
application UI test route, and the supported-runtime matrix on GitHub-hosted Macs. The local application route must use
synthetic provider data and a separate application identity. It must not require access to the installed app, Keychain,
provider files or removable volumes.

The deployment target remains macOS 14. Tests on macOS 26 establish behavior on that runtime; they cannot establish
compatibility with macOS 14, 15 or 27. GitHub's `xcode-27` label identifies a toolchain image, not a guarantee that the
assigned machine runs macOS 27. The September 7 rollout release remained a prerelease when checked on September 10,
2026\. Keep macOS 27 jobs out of the required matrix until that rollout completes, then retain the runtime assertion. Do
not retry the job in search of a different OS.<sup>[1](#source-1)</sup>

## Permission failures

The local failures identify a specific permission request. `tccd` reported `kTCCServiceSystemPolicyRemovableVolumes` for
both the verification application and the Xcode test runner. Their executables lived under `/Volumes/OWC`. The log also
recorded a mismatch between the saved code requirement and the new executable's code hash after a rebuild. A later
application process stopped in the dynamic loader before normal startup, with a physical footprint of about 208 KB.
These are local observations from the September 10 runs, not evidence of an application layout hang.

Apple documents that first access to a removable volume can prompt for consent. Apple DTS also warns that ad-hoc signing
causes problems for TCC; development signing gives an application a more consistent identity. That DTS discussion dates
from 2021, so it is supporting guidance rather than a claim about a new macOS 26 API. The local code-requirement
mismatch corroborates its relevance here.<sup>[2](#source-2)</sup><sup>[3](#source-3)</sup>

For this test application, the required correction is to remove protected-volume access. Copy the complete Xcode
Products directory to a fresh internal-disk directory, then run `test-without-building` from that directory. The app,
runner, resource bundles and framework dependencies must move together. Copying the executable alone leaves dependencies
behind. Validate the copied test plan and links before starting the runner.

Retain ad-hoc signing for the mock-only application. Tests do not need a Developer ID private key or a developer's Apple
account. Development signing remains appropriate for development builds that exercise real protected-resource
integration, but those builds do not belong in automated mock verification. A custom usage string would explain a
prompt; it would not eliminate the unwanted access.

Apple's UI-testing documentation describes a first-use authorization for Xcode Helper. XCTest also needs Automation
Mode, which has a separate authentication policy. Earlier successful runs did not prove unattended readiness. At 11:12
on September 10, `testmanagerd` logged that the writer daemon required authentication, then requested “Enable UI
Automation” through LocalAuthentication before starting a test. `automationmodetool` confirmed that this Mac requires
authentication. The TCC log had no prompt for that run; checking TCC alone missed the request.<sup>[4](#source-4)</sup>

Apple's installed `automationmodetool(1)` manual documents the device-wide unattended-testing setting. An administrator
can run `sudo /usr/bin/automationmodetool enable-automationmode-without-authentication`; the inverse command restores
authentication. The launcher reads the policy before building and before starting XCTest, rejecting required or unknown
authentication states without launching a runner. It does not modify that policy, TCC, Developer Tools security settings
or Full Disk Access. Mock native tests remain enabled, with the setup instructions in
[CONTRIBUTING.md](../CONTRIBUTING.md).<sup>[28](#source-28)</sup>

The installed app must remain running and unchanged during this work. A VM or second user account is not required for
the explicit local mock-app route. Untrusted pull-request code still belongs on hosted runners, not a developer desktop.

Native input also requires an unlocked console owned by the test user. Check it before compilation and throughout the UI
run. On the second local attempt, the app's log reported `frontmost=com.apple.loginwindow`; `ioreg` then confirmed
`IOConsoleLocked=true`. The window existed, but XCTest could not interact with it. Window geometry alone does not
establish an interactive desktop.

The local launcher reads the kernel's console diagnostics through `ioreg`, including console ownership and login state.
Apple defines these keys in a private kernel header, so this is a development-tool diagnostic, not a public API contract
for the shipping app. Reject unknown schemas as well as locked or switched-away sessions. Xpra checks the same session
ownership and lock state before display access. The launcher does not unlock the screen, keep it awake or change
security settings.<sup>[20](#source-20)</sup><sup>[21](#source-21)</sup>

## Test layers

| Layer                     | Local entry point                       | Evidence                                                                        | Limits                                            |
| ------------------------- | --------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------- |
| Core and nonpresenting UI | `just test`                             | Provider contracts, state transitions, geometry decisions, render text          | No displayed-window, arrow or input validation    |
| Native package compile    | `just compile-native-tests`             | Native source compatibility with the selected SDK                               | No runtime acceptance                             |
| Launcher safety           | `bash Scripts/test-local-ui-runner.sh`  | Synthetic bundle validation, cancellation, resource limits, exact results       | No application UI launch                          |
| Application preparation   | `just ui-local --prepare-only all`      | Verification build, signatures and relocated test dependencies                  | No native UI execution                            |
| Focused application UI    | `just ui-local Target/Class/testMethod` | Actual input, native layout, lifecycle and app-owned performance measurements   | Uses the current desktop and its runtime          |
| Runtime acceptance        | Required GitHub jobs                    | Full inventory, native package coverage, distribution builds, text verification | Only the runtime versions that completed the jobs |

Swift Testing remains suitable for Core and most in-process tests. XCUIAutomation is the appropriate layer for clicking
real controls, observing focus and testing native sheets. Apple separates tests with access to implementation details
from UI tests that interact with the app through accessibility. Replacing the latter with offscreen render assertions
would lose the behavior under investigation.<sup>[4](#source-4)</sup><sup>[5](#source-5)</sup>

Do not add sleeps to conceal state transitions. Wait for a named prerequisite within a deadline, perform the action,
then assert the resulting state. A failed prerequisite should stop the scenario. Continuing to click missing controls
adds secondary failures and consumes time without explaining the original failure. Diagnostics and cleanup belong in
teardown so they still run after the first assertion fails.

The local async test continued after a failed `XCTAssertTrue` despite setting `continueAfterFailure = false`. Do not
rely on that setting to abort an async scenario. Throw on a failed launch prerequisite. Before the first accessibility
query, the launcher waits for the owned application's on-screen window to settle, using public window geometry rather
than traversing an accessibility tree while the app is still presenting.

Keep the native-package execution guard separate from the application UI-test opt-in. Setting the local application flag
must not allow cached native package tests to present windows. The constructor guard enforces that distinction before a
native test body runs. Build-only commands remain available on the host.

For window-relative geometry and accessibility, use `NonpresentingWindow`. This test fixture defers window creation,
rejects ordering and focus requests with a test failure, and cannot become key or main. It permits local hit-testing
without showing a window or starting XCTest Automation Mode. The source guard rejects other local window subclasses;
negative tests verify that ordering fails. This does not replace input tests on a displayed window.

The native-root tab regression runs through both root and window hit-testing. Removing the root's forwarding method
returns the enclosing group instead of the selected tab in all three cases. Restoring it passes the six cases without
presentation. The September 11 hosted follow-up passes the four failing hittability checks, and its application-level
trace resolves the three tabs. The Demo relaunch still exceeds its startup deadline; hit-testing does not establish
startup performance.

## Mock-only startup

`--demo` is not an isolation guarantee. An ordinary build can honor a saved choice to disable demo mode and proceed to
live providers. Verification therefore has its own launch policy, bundle identifier, defaults suite and temporary
support directory. In the Verification configuration, the compiled entry point forces verification mode even if the
caller omits `--verify-ui`.

The Core launch policy chooses the mode and preserves it across relaunches. The executable then injects a disabled HTTP
transport, empty credential client and in-memory login-at-launch backend. It omits the notification service and updater.
Turning demo mode off inside verification selects an empty provider registry, not live provider discovery. The mode
decision and its behavior tests remain in Core; AppKit wiring stays in the executable and UI target.

This isolation applies to the entire workflow, including startup, refresh, provider enablement, reset, demo toggles,
relaunch, diagnostics and resource selection. A test with a mock HTTP response can still read a real credential file
before reaching that response. Source scans catch accidental direct calls, while startup and relaunch tests exercise the
injected dependencies. Neither check should replace the other.

Verification support files live beneath a per-run directory in the test runner's own container. Each test retains its
existing unique defaults suite and per-test cleanup. The outer launcher owns the temporary run directory and removes
remaining support files after termination. Ordinary application preferences, the installed bundle and provider accounts
are outside those paths.

## Build products and signing

Apple's documented split between `build-for-testing` and `test-without-building -xctestrun` supports running prepared
products without rebuilding the project. The generated file contains the paths the runner uses. The local
`xcodebuild.xctestrun(5)` manual defines `__TESTROOT__` as the directory containing that file, which makes a complete
Products directory relocatable when the generated references remain
relative.<sup>[6](#source-6)</sup><sup>[7](#source-7)</sup>

The launcher builds the optimized Verification configuration with one compiler job. It then checks:

- One `.xctestrun` file and one application UI-test target.
- The expected test runner and verification application identities.
- Verification-only metadata, rejecting Debug and distribution builds.
- Automatic capture disabled, with screenshots selected instead of video.
- Product-relative app, runner and test-bundle paths.
- Absence of protected-volume paths in the plan.
- Containment of symbolic links and existence of product-relative dependencies.
- Signature validity for the copied app and runner.

The runtime working directory must also be internal. Keep compiler caches in the checkout to avoid duplicating the whole
build on the smaller internal disk, but do not let the launched app load framework or resource dependencies from that
cache. `--prepare-only` performs these checks, removes its temporary copy and exits without starting native tests.

The metadata check is a build-integrity check for repository-owned products, not a sandbox against hostile executables.
It does not authorize running arbitrary downloaded test bundles on the host. The launcher accepts test identifiers, not
arbitrary Xcode options or shell command strings.

## Execution, failure and artifacts

Local runs take an exclusive per-user lock. A second run fails before compilation instead of starting another compiler
or competing for the pointer. Test methods come from the same inventory as CI. Unknown methods, duplicate selectors and
an empty selection are errors. The `all` selection uses that inventory.

The launcher runs one UI test method at a time. It adds no test retries and requires each selected method to have one
passing result. A skipped test, an extra result, a duplicate pass or a successful Xcode exit with no test records fails
acceptance. This protects against misspelled selectors and tests that skip unsupported instrumentation.

Raw `.xcresult` data, JSON results and fixture artifacts stay under a unique `.build/local-ui-results.*` directory.
Failed runs retain that evidence before removing their staged executable products. Plain verification logs and process
snapshots are copied outside the result bundle before per-test cleanup, because a runner crash can leave `.xcresult`
unfinished and unreadable. Local screenshots may contain visible desktop material; local artifacts are not uploaded by
the launcher. Inspect them before sharing. Hosted artifacts come from the hosted test desktop and retain the existing
short retention period.

Disable automatic screen capture in the test plan and retain screenshots at scenario checkpoints. Apple's test-plan
options distinguish capture policy from video-versus-still format; XcodeGen exposes both. Check the generated
`.xctestrun`, not just the YAML, because a test plan can override the scheme. The local failed run produced a 443 MB
unfinished result bundle with the previous video configuration. That observation warrants removing automatic video; it
does not prove video caused the accessibility crash.<sup>[16](#source-16)</sup><sup>[17](#source-17)</sup>

Text capture and text recognition remain separate. The native test generates cropped images and expectations; the
external OCR check evaluates those artifacts after the app exits. Local text runs must execute that second stage, not
treat capture as proof of readable text. Require captured assertions for each selected long-text scenario. Keep the
negative OCR fixtures so a disabled or ineffective recognizer cannot produce a false pass.

## Memory, CPU and responsiveness

The local machine has 16 GB of RAM. A resource watchdog samples the owned process tree, including verification
applications that LaunchServices reparents to `launchd`. It stops the workload if owned RSS exceeds 4 GiB or swap grows
by more than 1 GiB from the run's baseline. Critical pressure or an unknown pressure level stops the workload; warning
pressure permits starting and continuing within the same resource limits. These are local safety thresholds, not
application performance budgets. Summed process RSS can double-count shared pages, so this guard is conservative.

`xcodebuild -jobs 1` does not limit Swift's whole-module backend threads: the local build log still requested ten. Set
`SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO` together with `OTHER_SWIFT_FLAGS=$(inherited) -num-threads 1`. The
former prevents Xcode from appending a larger thread count; the latter preserves per-file object output. On the
installed Xcode, disabling parallelism alone emitted a module-level object while the linker retained stale per-file
objects. Current Swift Build explicitly selects one thread to preserve per-file output. Check the emitted command and
linked object timestamps after toolchain updates.<sup>[25](#source-25)</sup>

XNU converts its internal pressure states to dispatch flags before returning the sysctl value: normal is 1, warning is 2
and critical is 4. Warning is not critical pressure. The removed two-second cutoff was a local policy, not an
Apple-prescribed interval. It stopped a run at 0.27 GiB owned RSS before the selected test started. The watchdog now
permits warning pressure while retaining the critical-pressure, RSS and swap-growth stops.<sup>[22](#source-22)</sup>

Use process identities, including creation-time checks supplied by psutil, for signalling and cleanup. Do not use
`killall TokenMenuBar`, broad process-name matching or a saved PID without protection against PID reuse. On timeout or
cancellation, terminate the owned processes and escalate after a grace period. The installed application does not belong
to the relocated runtime path and is not a cleanup target.<sup>[8](#source-8)</sup>

Run performance measurements through the separate `TokenMenuBarPerformanceTests` target and `TokenMenuBar-Benchmarks`
scheme. `just benchmark` runs this opt-in suite on the latest deployed macOS; the runtime check rejects older versions
before building or starting a test runner. To compile without running, use
`just ui-local --suite performance --prepare-only all`. The suites have separate derived-data directories and runner
bundle identities.

For a hosted benchmark, dispatch CI with `ui_group=performance`. The runtime selector chooses the newest deployed macOS
regardless of the diagnostic runtime input. Normal CI excludes the benchmark target and retains functional coverage on
the supported runtimes. Benchmark reports include latency, CPU and physical footprint without pass/fail performance
thresholds. Keep 20 ms as the local optimization target and investigate transitions above 200 ms.

Record the app's input-to-presented-frame interval separately from XCTest event delivery and accessibility-query time.
Include cold first-open, first Settings selection and warm switches; cached tabs can conceal expensive first layout.
Functional tests retain bounded readiness waits to catch hangs and verify frame position and visible controls.

Measure physical footprint and RSS separately. Footprint better reflects the app's memory cost; RSS helps explain
resident pages and process-tree pressure. Compare memory before and after repeated interactions, then after the app
returns to idle. For CPU, use the app's own process snapshot with the corrected Mach timebase conversion rather than
assuming raw Mach time values are nanoseconds. Existing tests bracket that conversion with `getrusage` readings.

Sampling changes the workload. The local `sample(1)` manual describes suspending the process at sampling intervals, and
Apple's performance guidance distinguishes diagnosis from measurement. Collect CPU samples in the dedicated profiling
scenario. Do not attach a sampler during the latency or idle-CPU measurement interval and then compare those figures
with uninstrumented runs.<sup>[9](#source-9)</sup><sup>[10](#source-10)</sup>

Xcode 26 adds compilation caching and Instruments improvements, including SwiftUI profiling and CPU analysis. Use those
tools to identify repeated body evaluation, main-thread work and unnecessary wakeups. Their availability does not
justify importing new runtime symbols into macOS 14 source paths. Keep API availability checks and deployment tests
independent of the developer's installed Xcode version.<sup>[11](#source-11)</sup>

## Open-source practice

The inspected workflows provide concrete examples, with limits to what they prove:

| Project and pinned revision                                    | Practice                                                                                        | Applicability                                                                                                                 |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| CotEditor, `aac8206b5c0d0ee457639e35303479c8a94586c9`          | Separate package tests, an Xcode application test and a release launch check; ad-hoc CI signing | Supports distinct test layers and unsigned-release smoke checks; not proof of prompt-free local UI automation                 |
| Clipy, `f9ec5176d4ab9a4c2f6f74dba7e081872874cc8d`              | Pinned macOS/Xcode environment and package cache, no distribution identity for tests            | Supports avoiding private signing keys in CI; its `clean test` is not a reason to discard this project's incremental products |
| Stats, `681e6125322d2157bc41522a6e67735046aa9834`              | Unsigned release archive on macOS 15                                                            | Build evidence only; no comparable UI acceptance in that workflow                                                             |
| irgaly/xcode-cache, `4141f139f00e335c6e1031fb93e667181f86146f` | DerivedData, package-cache and input-timestamp restoration                                      | Relevant to the existing build-once UI matrix; preserve versioned keys and input matching                                     |

These examples do not establish a universal permission workaround. CotEditor's current `xcode-27` choice also does not
establish that this project's macOS 27 runtime requirement is satisfied. Adopt the supported build mechanics and retain
this project's stricter runtime and test-inventory
checks.<sup>[12](#source-12)</sup><sup>[13](#source-13)</sup><sup>[14](#source-14)</sup><sup>[15](#source-15)</sup>

## CI and acceptance

Keep GitHub-hosted CI. Standard hosted runners remain free for public repositories. The earlier service audit found no
qualified replacement that meets the required free macOS matrix. Cirrus Labs announced that its CI service would shut
down on June 1, 2026; an old pricing or runner page does not establish that a service still accepts builds. A CI
migration would not correct fixture isolation or native test
failures.<sup>[18](#source-18)</sup><sup>[19](#source-19)</sup>

Build application test products once per OS, architecture and exact toolchain, then reuse those products across
inventory-checked UI groups. Keep desktop tests serial within each runner. Use concurrency between independent hosted
jobs, not between tests competing for the same menu bar. Cache keys must include the build configuration and toolchain
so a stale Debug product cannot substitute for the optimized Verification build.

For a single diagnostic group, build and execute on the same runner to avoid a second allocation wait. The optional
`ui_test` input selects one method from that group; inventory validation rejects unknown or mismatched methods.
`ui_profile_startup` captures replacement-process stacks during lifecycle diagnosis. It does not establish timing
acceptance. Run the affected test without sampling after the fix, then require the full PR matrix.

The five-minute guidance applies after a job starts. Report cache restore, compilation, test execution and artifact
handling separately from queue time. Split work by measured scenario duration while retaining the complete inventory. Do
not drop tests, add retries or weaken an assertion to obtain a shorter green run.

Two reviews precede readiness. The first checks state and isolation: forced verification mode, relaunches, provider
boundaries, filesystem paths, process ownership, cancellation and negative result validation. The second checks native
behavior and performance: fixed tab positions, first-frame content, history dates, scroll geometry, resource choosers,
text, tooltips, keyboard access, memory and CPU. A build-only result cannot close an on-screen finding.

Readiness requires the complete applicable CI matrix to pass. The local launcher implementation does not close the
remaining application findings in `review.md`, and macOS 27 remains unverified until its actual runtime jobs execute.
Record native failures with the OS, Xcode build, selected method, first failure and artifact path. Fix the failure
locally when the runtime permits, then use CI for cross-runtime confirmation.

## Local validation record

On September 10, the guarded nonpresenting suite passed 1,304 tests and its 16 OCR checks. The 82 launcher tests passed
with 100% line coverage, including negative paths for unsafe products, memory pressure, cancellation and incomplete
results. The optimized application build and relocation preflight passed for the complete 36-method UI inventory.

The final nonpresenting run took 33.2 seconds including OCR, with a sampled owned-process peak RSS of 0.46 GiB. Native
package compilation took 52.3 seconds at 0.94 GiB; it executed no tests. The incremental application preflight took 8.0
seconds at 0.69 GiB. These are local observations, not cross-runtime performance acceptance.

The first relocated native run generated no `AUTHREQ_PROMPTING` entry for the app or runner. It nevertheless failed: the
initial accessibility query stalled, and the app crashed in `XCTAutomationSupport` while clearing element snapshots. The
watchdog then observed memory pressure and stopped the remaining workload. This establishes that moving the products
addressed the observed removable-volume prompt on this Mac, not that native acceptance passed or that the crash's root
cause is known.

The second attempt presented a stable window in 3.25 seconds, then stalled at the accessibility query. Its log and
kernel diagnostics established that the desktop was locked. The run was stopped, leaving the installed app running. The
launcher now rejects that condition before building and monitors it during execution. Cancellation retained the
verification files outside `.xcresult`.

After the desktop unlocked, `testLaunchStaysWithinBudget` passed its unchanged limit. The scenario including teardown
took 5.923 seconds; the full execution took 7.9 seconds with a sampled owned peak RSS of 0.57 GiB. A separate two-case
batch reported `testTabSwitchReturnsToIdle` passing in 8.105 seconds. Its Settings case failed during a status-item
screenshot, and the watchdog stopped the batch after a sustained memory warning. That batch is not a passing result.

The failed screenshot targeted a status item whose logged frame began at x = −9,282, outside the display. Check the full
frame against public Core Graphics display bounds before requesting pixels. An off-screen item remains a failed visual
prerequisite, not a skipped assertion. Do not change a user's menu-bar manager to make the test
pass.<sup>[23](#source-23)</sup>

The macOS 14 Settings artifact from run `34480593390` places `status-template` and the Template accessibility label on a
scroll container; the inner text view is unnamed and reported disabled. A native `NSTextView` wrapper now puts those
attributes on the editable child and binds edits directly to Settings. It retains plain text, newlines, undo, wrapping
and auto-hiding overlay scrollbars. AppKit uses TextKit 2 by default on the supported runtimes; the wrapper avoids APIs
that force a TextKit 1 fallback. Nonpresenting tests exercise editing and updates; actual macOS 14 interaction remains
required.<sup>[24](#source-24)</sup>

The new native regression found the named editor, then failed because XCTest reported it disabled. A nonpresenting
regression reproduced the discrepancy: `NSTextView.isEditable` was true while `isAccessibilityEnabled()` was false. The
wrapper now sets both from SwiftUI's enabled state. The regression fails before that change and passes afterward,
including enabled-to-disabled transitions. Keyboard editing remains a separate native assertion; the accessibility flag
does not establish that input works.<sup>[26](#source-26)</sup>

CI run `34480593390` remains red, including the post-tab-switch CPU budget and a macOS 14 Settings control assertion.
These application findings stay open; a successful launcher preflight cannot resolve them.

After the Template change, the nonpresenting suite passed 1,312 tests and 16 OCR checks in 33.6 seconds at 0.45 GiB
sampled peak owned RSS. The native Template case is part of the 31-method functional inventory; four benchmarks now live
in a separate target. An initial rebuild stopped for sustained warning pressure. A later successful build still linked
`TemplateEditor.o` from 08:56 rather than the new module-level object emitted at 09:01. This explained why the native
test kept executing the old editor.

With both serial compiler flags set, the linked per-file objects were regenerated. The optimized build passed in 54.0
seconds at 1.68 GiB sampled peak owned RSS. The native keyboard test then passed in 17.9 seconds, including multiline
input and restoration; test execution peaked at 0.57 GiB. Evidence is in `.build/local-ui-template-per-file.log`. macOS
14/15 interaction and the separate status-item pixel assertions remain open. These runs are not a controlled comparison
of compiler memory use.

A later incremental build updated the runner's test plug-in and its dSYM without updating the outer runner's resource
seal. `codesign --verify --deep --strict --verbose=4` identified those changed entries in the build products, before
relocation. The local launcher now checks the product layout and internal paths, verifies the plug-in, and signs the
outer runner after assembly. It then verifies the app and runner after relocation. It does not use `--deep` when signing
or preserve an obsolete CDHash requirement. This follows Apple's inside-out signing order; signature failures still stop
execution. The launcher has 84 synthetic tests with 100% line coverage.<sup>[27](#source-27)</sup>

## Sources

01. <a id="source-1"></a> GitHub, [runner image release policy](https://github.com/actions/runner-images#image-releases)
    and
    [Xcode 27 ARM64 image release, September 7, 2026](https://github.com/actions/runner-images/releases/tag/xcode-27-arm64%2F20260907.0173).
    Release metadata checked September 10, 2026; `prerelease` remained `true`.

02. <a id="source-2"></a> Apple,
    [NSRemovableVolumesUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremovablevolumesusagedescription).
    Accessed September 10, 2026.

03. <a id="source-3"></a> Apple DTS,
    [App does not appear in File and Folder permissions](https://developer.apple.com/forums/thread/125438), September
    2021 reply about development and ad-hoc signing.

04. <a id="source-4"></a> Apple,
    [User Interface Testing](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/09-ui_testing.html).
    Archived documentation; used for the testing model and Xcode Helper authorization, not current API availability.

05. <a id="source-5"></a> Apple, [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) and
    [Adding tests to your Xcode project](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project).
    Accessed September 10, 2026.

06. <a id="source-6"></a> Apple,
    [TN2339: Building from the Command Line with Xcode](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).
    Archived technical note; build-for-testing and test-without-building commands also checked against installed Xcode.

07. <a id="source-7"></a> Apple, installed `xcodebuild.xctestrun(5)` manual, Xcode 26.5; sections for TestHostPath,
    TestBundlePath and TestingEnvironmentVariables. Local source, accessed September 10, 2026.

08. <a id="source-8"></a> psutil, [process APIs and identity handling](https://psutil.io/7.2/#process-class).
    Implementation dependency 7.2.2, checked September 10, 2026.

09. <a id="source-9"></a> Apple, installed `sample(1)` manual, macOS 26.6.2. Local source; sampling behavior checked
    September 10, 2026.

10. <a id="source-10"></a> Apple,
    [Optimize CPU performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/308/), WWDC25.

11. <a id="source-11"></a> Apple,
    [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes).
    Compilation caching and Instruments features; accessed September 10, 2026.

12. <a id="source-12"></a> CotEditor,
    [test workflow](https://github.com/coteditor/CotEditor/blob/aac8206b5c0d0ee457639e35303479c8a94586c9/.github/workflows/test.yml),
    inspected September 10, 2026.

13. <a id="source-13"></a> Clipy,
    [CI workflow](https://github.com/Clipy/Clipy/blob/f9ec5176d4ab9a4c2f6f74dba7e081872874cc8d/.github/workflows/CI.yml),
    inspected September 10, 2026.

14. <a id="source-14"></a> Stats,
    [build workflow](https://github.com/exelban/stats/blob/681e6125322d2157bc41522a6e67735046aa9834/.github/workflows/build.yaml),
    inspected September 10, 2026.

15. <a id="source-15"></a> irgaly,
    [xcode-cache v1.9.2](https://github.com/irgaly/xcode-cache/tree/4141f139f00e335c6e1031fb93e667181f86146f), inspected
    September 9, 2026.

16. <a id="source-16"></a> Apple,
    [Improving code assessment by organizing tests into test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback).
    Automatic Screen Capture and Preferred Capture Format options; accessed September 10, 2026.

17. <a id="source-17"></a> XcodeGen,
    [Test Action options](https://github.com/yonaskolb/XcodeGen/blob/8445e778451c7e44237b90281bde622d764b0084/Docs/ProjectSpec.md#test-action).
    `captureScreenshotsAutomatically` and `preferredScreenCaptureFormat`; inspected September 10, 2026.

18. <a id="source-18"></a> Cirrus Labs, [Cirrus Labs to join OpenAI](https://cirruslabs.org/), April 7, 2026. Announces
    June 1, 2026 shutdown of Cirrus CI; accessed September 10, 2026.

19. <a id="source-19"></a> GitHub,
    [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions). Standard
    hosted runners for public repositories; accessed September 10, 2026.

20. <a id="source-20"></a> Apple,
    [XNU console diagnostic keys](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/iokit/IOKit/IOKitKeysPrivate.h).
    `IOConsoleLocked` and `IOConsoleUsers` are private registry diagnostics, inspected September 10, 2026.

21. <a id="source-21"></a> Xpra,
    [macOS display-access checks](https://github.com/Xpra-org/xpra/blob/d77c6729dc9640572498868b5543300623be012f/xpra/platform/darwin/gui.py#L630).
    Session ownership and screen-lock checks, inspected September 10, 2026.

22. <a id="source-22"></a> Apple,
    [XNU pressure-state conversion and sysctl implementation](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_memorystatus_notify.c#L1776).
    Inspected September 10, 2026.

23. <a id="source-23"></a> Apple,
    [CGGetDisplaysWithRect](<https://developer.apple.com/documentation/coregraphics/cggetdisplayswithrect(_:_:_:_:)>).
    Public display geometry, accessed September 10, 2026.

24. <a id="source-24"></a> Apple,
    [What's new in TextKit and text views](https://developer.apple.com/videos/play/wwdc2022/10090/), WWDC22. Default
    AppKit text engine and compatibility fallback, accessed September 10, 2026.

25. <a id="source-25"></a> Swift,
    [Swift Build whole-module thread selection](https://github.com/swiftlang/swift-build/blob/882cca0050195db6ed11a7a2eeb387b874be49df/Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift#L1382).
    Inspected September 10, 2026; the installed Xcode Swift specification exposes the same setting.

26. <a id="source-26"></a> Apple,
    [setAccessibilityEnabled](<https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/setaccessibilityenabled(_:)>).
    Accessibility event-response state, accessed September 10, 2026.

27. <a id="source-27"></a> Apple,
    [Code Signing In Depth: nested code and signing order](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

28. <a id="source-28"></a> Apple, installed `automationmodetool(1)` manual, macOS 26, read September 10, 2026.
    Device-wide authentication policy, read-only status query and administrator setup commands. See also the reported
    [Apple DTS response about repeated XCTest authentication](https://developer.apple.com/forums/thread/693850).
