# Contributing

The architecture, the house style, the release pipeline and every workflow live at
<https://token-menu-bar-macos.readthedocs.io/en/latest/contributing/>.

The short version, from a fresh checkout:

```sh
mise install   # hugo, just, pre-commit, xcodegen
just           # the list of workflows
just check     # build, nonpresenting tests, lint
```

`just test`, `swift test`, and `just check` run nonpresenting tests on the local OS. Their fixtures render views without
an `NSWindow` and use generated data with injected credential, network, and preference boundaries. Native tests live in
`Tests/TokenMenuBarUITests/Native`; the default package manifest excludes those sources from the test executable.

CI also requires `just test-native`, the complete coverage gate (`just coverage`), and the application control audit
(`just ui`). These commands refuse execution outside a GitHub-hosted runner. A constructor in the native package test
executable and the Xcode UI-test bundle rejects local execution, including cached `--skip-build` runs. Do not set CI
environment variables to bypass this guard on a developer desktop. Build-only commands remain safe to run locally.

The control audit uses a separate verification app with mock providers and isolated preferences. Its profiler samples
the process identified by that app after checking the verification launch argument. XCTest retains the CPU report
separately from tab latency measurements. The wrapper uses Apple's
[`TEST_RUNNER_` environment forwarding](https://developer.apple.com/documentation/xcode/environment-variable-reference).

CI checks macOS 14, 15, 26, and 27 on hosted runners. Each job checks the actual runtime version, including jobs using
the `xcode-27` label. An image with Xcode 27 on macOS 26 cannot satisfy macOS 27 acceptance. Distribution builds and UI
audits run in addition to package checks.

To run the package suites and coverage on hosted desktops without the application audits or distribution builds:

```sh
gh workflow run ci.yml --ref YOUR_BRANCH -F package_only=true
```

This manual route retains all four runtime checks. Pull requests and pushes to `main` still run the full CI matrix.

Report bugs through **Report Issue** in the popover footer. For vulnerabilities, read [SECURITY.md](SECURITY.md) first.
