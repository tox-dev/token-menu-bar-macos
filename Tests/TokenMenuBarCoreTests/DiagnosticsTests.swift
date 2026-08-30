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
  #expect(report.contains("- Codex: authenticationRequired, plan -, windows -"))
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
