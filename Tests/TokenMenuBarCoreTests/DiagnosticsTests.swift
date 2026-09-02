import Foundation
import Testing
import TokenMenuBarCore

@Test func appInfoReadsBundleWithFallbacks() {
  let info = AppInfo.from(bundle: Bundle(for: DateBox.self), isAppStore: true)
  #expect(!info.name.isEmpty)
  #expect(!info.version.isEmpty)
  #expect(info.isAppStore)
  #expect(info.repository == AppInfo.repositoryURL)
  #expect(info.releasesURL.path == "/tox-dev/token-menu-bar-macos/releases")
  let bare = AppInfo.from(bundle: Bundle(), isAppStore: false)
  #expect(bare.name == "Token Menu Bar")
  #expect(bare.version == "0.0.0")
  #expect(bare.build == "0")
  #expect(bare.bundleIdentifier == "dev.tox.token-menu-bar")
  #expect(bare.sourceVersion == bare.version)
  #expect(!bare.isPrerelease)
  #expect(!bare.canSelfUpdate)
}

@Test(arguments: [
  ("direct", DistributionChannel.direct),
  ("App Store", DistributionChannel.appStore),
  ("appstore", DistributionChannel.appStore),
  ("HOMEBREW", DistributionChannel.homebrew),
])
func distributionReadsBuildConfiguration(value: String, expected: DistributionChannel) {
  #expect(DistributionChannel(configurationValue: value) == expected)
}

@Test func distributionRejectsUnknownBuildConfiguration() {
  #expect(DistributionChannel(configurationValue: "nightly") == nil)
}

@Test(arguments: [
  (DistributionChannel.direct, "Direct", false, true),
  (DistributionChannel.appStore, "App Store", true, false),
  (DistributionChannel.homebrew, "Homebrew", false, false),
])
func distributionControlsRuntimeCapabilities(
  channel: DistributionChannel, name: String, appStore: Bool, selfUpdate: Bool
) {
  #expect(channel.displayName == name)
  #expect(channel.isAppStore == appStore)
  #expect(channel.allowsSelfUpdate == selfUpdate)
}

@Test(arguments: [
  (DistributionChannel.direct, true, true),
  (DistributionChannel.direct, false, false),
  (DistributionChannel.appStore, true, false),
  (DistributionChannel.homebrew, true, false),
])
func appInfoLimitsSelfUpdatesToEnabledDirectReleases(
  distribution: DistributionChannel, enabled: Bool, expected: Bool
) {
  let info = AppInfo(
    name: "Token Menu Bar", version: "1", build: "2", bundleIdentifier: "dev.tox.token-menu-bar",
    distribution: distribution, selfUpdateEnabled: enabled, repository: AppInfo.repositoryURL)
  #expect(info.canSelfUpdate == expected)
}

@Test func appInfoPreservesLegacyDistributionInitializer() {
  let appStore = AppInfo(
    name: "Token Menu Bar", version: "1", build: "2", bundleIdentifier: "dev.tox.token-menu-bar",
    isAppStore: true, repository: AppInfo.repositoryURL)
  #expect(appStore.distribution == .appStore)
}

@Test func appInfoPrefersTheBundledDistribution() throws {
  let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bundle")
  let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: bundleURL) }
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  let data = try PropertyListSerialization.data(
    fromPropertyList: [
      "CFBundleIdentifier": "dev.tox.token-menu-bar.test",
      "CFBundleName": "Test",
      "CFBundlePackageType": "BNDL",
      "TMBDistribution": "Homebrew",
      "TMBSelfUpdateEnabled": "YES",
    ],
    format: .xml, options: 0)
  try data.write(to: contents.appendingPathComponent("Info.plist"))
  let bundle = try #require(Bundle(url: bundleURL))

  let info = AppInfo.from(bundle: bundle, distribution: .direct)

  #expect(info.distribution == .homebrew)
  #expect(info.selfUpdateEnabled)
  #expect(!info.canSelfUpdate)
  #expect(info.bundleIdentifier == "dev.tox.token-menu-bar.test")
}

@Test(arguments: [
  ("1.2.3", false),
  ("1.2.4.dev5+gabc123", true),
  ("1.2.4.dev5+gabc123.d20260830", true),
])
func appInfoNamesPrereleaseBuilds(sourceVersion: String, prerelease: Bool) {
  let info = AppInfo(
    name: "Token Menu Bar", version: "1.2.3", sourceVersion: sourceVersion, build: "7",
    bundleIdentifier: "dev.tox.token-menu-bar", isAppStore: false, repository: AppInfo.repositoryURL)
  #expect(info.isPrerelease == prerelease)
  #expect(info.sourceVersion == sourceVersion)
}

@Test @MainActor func diagnosticsReportListsProvidersAndLog() throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "diag-\(UUID().uuidString)")!)
  let state = AppState()
  state.update(.claude) {
    $0.snapshot = ProviderSnapshot(
      provider: .claude, identity: ProviderIdentity(planName: "Max 20x"),
      windows: [QuotaWindow(id: "session", label: "S", group: .session, usedPercent: 36, resetsAt: nil)],
      fetchedAt: fixedNow)
    $0.availability = .current
    $0.lastError = "old error"
    $0.credentialState = .valid(expiresAt: nil)
  }
  state.update(.codex) { $0.availability = .authenticationRequired }
  state.setRefreshing(false, at: fixedNow.addingTimeInterval(-30))
  let log = makeLog()
  log.log("hello")
  let app = AppInfo(
    name: "Token Menu Bar", version: "1.0", build: "7", bundleIdentifier: "dev.tox.token-menu-bar", isAppStore: false,
    repository: AppInfo.repositoryURL)
  let report = Diagnostics.report(
    app: app, osVersion: "26.6", settings: settings, state: state, historyLocation: nil, log: log, now: fixedNow)
  #expect(report.hasPrefix("Token Menu Bar 1.0 (7) Direct\nmacOS 26.6"))
  #expect(report.contains("History: in memory"))
  #expect(report.contains("Last refresh: 30s ago"))
  #expect(report.contains("- Claude: current, plan Max 20x, windows session=36%"))
  #expect(report.contains("  error: old error"))
  #expect(report.contains("  credentials: Token present"))
  #expect(!report.contains("- Codex:"))
  #expect(report.hasSuffix("[info] hello"))
  let url = Diagnostics.issueURL(repository: app.repository, title: "Bug", report: report)
  #expect(url.absoluteString.hasPrefix("https://github.com/tox-dev/token-menu-bar-macos/issues/new?title=Bug&body="))
  #expect(url.absoluteString.count <= Diagnostics.maxIssueURLLength)
}

@Test func diagnosticsIssueURLTrimsLongReports() {
  let long = (0..<400).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
  let url = Diagnostics.issueURL(repository: AppInfo.repositoryURL, title: "Long", report: long)
  #expect(url.absoluteString.count <= Diagnostics.maxIssueURLLength)
  #expect(url.absoluteString.contains("line%200%20"))
  #expect(!url.absoluteString.contains("line%20399%20"))
  let single = Diagnostics.issueURL(
    repository: AppInfo.repositoryURL, title: "One", report: String(repeating: "y", count: 9000))
  #expect(single.absoluteString.count <= Diagnostics.maxIssueURLLength)
}

@Test @MainActor func diagnosticsRedactsPrivateReportFields() {
  let settings = Settings(defaults: UserDefaults(suiteName: "diag-private-\(UUID().uuidString)")!)
  settings.setProvider(.codex, enabled: true)
  let state = AppState()
  state.update(.codex) {
    $0.lastError = "Bearer secret user@example.com"
    $0.credentialHealth = .valid(source: ProviderID.codex.setup.credentialSources[0], expiresAt: nil)
  }
  let report = Diagnostics.report(
    app: AppInfo(
      name: "Token Menu Bar", version: "1", build: "1", bundleIdentifier: "dev.tox.token-menu-bar",
      isAppStore: false, repository: AppInfo.repositoryURL),
    osVersion: "26", settings: settings, state: state,
    historyLocation: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/history.sqlite"),
    log: makeLog(), now: fixedNow)
  #expect(report.contains("History: ~/Library/history.sqlite"))
  #expect(report.contains("Bearer <redacted>"))
  #expect(report.contains("<redacted-email>"))
  #expect(!report.contains("secret"))
}

@Test @MainActor func diagnosticsNamesHomebrewDistribution() {
  let settings = Settings(defaults: UserDefaults(suiteName: "diag-homebrew-\(UUID().uuidString)")!)
  let report = Diagnostics.report(
    app: AppInfo(
      name: "Token Menu Bar", version: "1", build: "1", bundleIdentifier: "dev.tox.token-menu-bar",
      distribution: .homebrew, repository: AppInfo.repositoryURL),
    osVersion: "15", settings: settings, state: AppState(), historyLocation: nil, log: makeLog(), now: fixedNow)
  #expect(report.hasPrefix("Token Menu Bar 1 (1) Homebrew\n"))
}
