# Contributing

The architecture, the house style, the release pipeline and every workflow live at
<https://token-menu-bar-macos.readthedocs.io/en/latest/contributing/>.

The short version, from a fresh checkout:

```sh
mise install   # hugo, just, pre-commit, xcodegen
brew install jq tesseract webp
just           # the list of workflows
just check     # build, nonpresenting tests, lint
```

`just test` and `just check` run nonpresenting tests on the local OS. Their fixtures render views without an `NSWindow`
and use generated data with injected credential, network, and preference boundaries. Native tests live in
`Tests/TokenMenuBarUITests/Native`; the default package manifest excludes those sources from the test executable.

Use `just test` for the complete local check. Its wrapper creates a fresh render directory, runs the package suite, then
checks captured text with Tesseract. Bare `swift test` still excludes native tests, but lacks the required render
directory and post-test text checks. Pass a test-name filter to `just test FILTER` for a focused run.

`jq` and Tesseract support those text checks; `webp` supplies `cwebp` for documentation screenshots. The tools pinned in
mise do not include these Homebrew packages. CI pins the OCR engine and English model separately.

The build, test, coverage and local-bundle commands use two compiler jobs to limit concurrent compiler memory. Override
this with `TOKEN_MENU_BAR_BUILD_JOBS=4 just test` if the machine has memory to spare. Bare `swift build` and
`swift test` retain SwiftPM's own concurrency defaults.

CI also requires `just test-native`, the complete coverage gate (`just coverage`), and the application control audit
(`just ui`). These commands refuse execution outside a GitHub-hosted runner. A constructor in the native package test
executable rejects local execution, including cached `--skip-build` runs. Do not set CI environment variables to bypass
this guard on a developer desktop. Build-only commands remain safe to run locally.

For a cross-version failure, run one hosted UI group against the branch under investigation:

```sh
gh workflow run ci.yml --ref feat/token-menu-bar -f ui_group=lifecycle -f ui_runtime=14
```

Choose a group from `.github/ui-test-groups.json`. This diagnostic run builds the isolated test products and executes
that group on the selected deployed runtime, without package tests or distribution builds. It does not replace full PR
acceptance. Omit `ui_group` to run the full matrix.

For application UI checks on the current desktop, use the separate local route:

```sh
bash Scripts/test-local-ui-runner.sh
just ui-local --prepare-only all
just ui-local TokenMenuBarApplicationUITests/TokenMenuBarApplicationUITests/testEveryTabExposesNamedControls
```

The first command tests the launcher with synthetic bundles and disposable subprocesses. The second builds the
verification-only app and validates its relocated test products without opening a window. The third runs the named
native UI test and uses the desktop and pointer. Pass `all` to run the functional application inventory; local native
package execution remains forbidden.

Performance measurements live in `App/Benchmarks`, in the separate `TokenMenuBarPerformanceTests` target and
`TokenMenuBar-Benchmarks` scheme. They use their own test plan, derived data and runner identity. Normal CI and
`just ui-local all` exclude them.

`just benchmark` runs the mock-only benchmark suite on the latest deployed macOS. To compile without running, use
`just ui-local --suite performance --prepare-only all`. To request a hosted run, dispatch CI with
`ui_group=performance`; the runtime selector chooses the newest deployed macOS and ignores `ui_runtime`. The reports
contain latency, CPU and memory measurements without pass/fail performance budgets.

The launcher copies the app, runner and dependencies to internal temporary storage, avoiding removable-volume permission
requests caused by executing rebuilt ad-hoc apps from an external checkout. It does not change macOS privacy permissions
or use live provider credentials.

XCTest also requires Automation Mode. A previous successful run does not establish unattended access: temporary
authorization can expire. The launcher reads `automationmodetool` before building and before starting XCTest. It
requires the `DOES NOT REQUIRE user authentication` status and exits before launch if authentication is required or the
query fails. It does not approve dialogs or disable UI tests.

An administrator can configure a Mac for unattended UI testing once:

```sh
sudo /usr/bin/automationmodetool enable-automationmode-without-authentication
/usr/bin/automationmodetool
```

This device-wide setting allows XCTest to enable UI automation without a password dialog; it does not grant the app
access to Keychain, provider files or removable volumes. Restore authentication with
`sudo /usr/bin/automationmodetool disable-automationmode-without-authentication`. Apple documents both commands in the
installed `automationmodetool(1)` manual; see also the
[Apple DTS response about repeated XCTest authentication](https://developer.apple.com/forums/thread/693850). A fresh Mac
may need Xcode Helper authorization as well. Do not approve repeated app permission requests as a test workaround.

Native input requires your unlocked desktop. The launcher refuses a locked or switched-away session before building and
stops its owned processes if the session locks during a test. It does not unlock the screen or change sleep settings.
`--prepare-only` and nonpresenting tests remain available while the desktop is locked.

Local runs use one compiler job and one Swift backend thread, an exclusive lock and a watchdog: 4 GiB owned RSS and 1
GiB additional swap. A memory-pressure warning does not stop the run; critical pressure or an unknown pressure level
does. Cancellation stops owned processes without terminating an installed copy. Temporary binaries are removed after the
run. Results stay in `.build/local-ui-results.*`; review screenshots before sharing them because native captures can
include desktop material. The launcher does not upload them.

Automatic video and screenshots are off. Scenarios retain their checkpoint captures; plain logs and process snapshots
also survive outside `.xcresult` when a runner crash prevents Xcode from finishing the bundle.

Status-item pixel checks require the verification item's full frame to be on a display. A menu-bar manager can move it
off-screen even while accessibility reports it as visible. The check fails before requesting an invalid screenshot; it
does not skip the assertion or change the manager's settings.

The [macOS verification audit](mockups/macos-verification.md) records the supporting sources, permission diagnosis and
acceptance requirements. Compiling or preparing products does not close on-screen findings in `review.md`.

The benchmark suite uses a separate verification app with mock providers and isolated preferences. Its profiler samples
the process identified by that app after checking the verification launch argument. XCTest retains the CPU report
separately from tab latency measurements. The wrapper uses Apple's
[`TEST_RUNNER_` environment forwarding](https://developer.apple.com/documentation/xcode/environment-variable-reference).

CI requires macOS 14, 15 and 26 on hosted runners. A Linux preparation job checks the
[macOS 27 image release](https://github.com/actions/runner-images/releases/tag/xcode-27-arm64%2F20260907.0173). Until
GitHub completes that rollout, CI omits macOS 27 package tests, UI audits and distribution builds. The job summary
records the omission. After GitHub converts the prerelease to a release, CI adds macOS 27 to those matrices and the
rendered-text checks. GitHub documents this signal in its
[image release policy](https://github.com/actions/runner-images#image-releases).

Each selected job checks the actual runtime version, including jobs using the `xcode-27` label. An image with Xcode 27
on macOS 26 fails the macOS 27 runtime check. API errors or invalid rollout metadata fail preparation; they do not
silently disable coverage. The deployment gate does not pin a hosted image version. Release UI tests require macOS 26
and add macOS 27 after the same rollout check.

To run the package suites and coverage on hosted desktops without the application audits or distribution builds:

```sh
gh workflow run ci.yml --ref YOUR_BRANCH -F package_only=true
```

This manual route uses the same rollout gate and runtime checks. Pull requests and pushes to `main` also run
distribution builds and application audits for the selected runtimes.

Report bugs through **Report Issue** in the popover footer. For vulnerabilities, read [SECURITY.md](SECURITY.md) first.
