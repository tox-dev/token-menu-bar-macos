import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func providerIDMetadata() {
  #expect(ProviderID.claude < .codex)
  #expect(ProviderID.claude.shortLabel == "CC")
  #expect(ProviderID.codex.displayName == "Codex")
  #expect(ProviderID.claude.usagePage.host == "claude.ai")
  #expect(ProviderID.codex.usagePage.host == "chatgpt.com")
  #expect(ProviderID.codex.loginHint.contains("codex login"))
  #expect(ProviderID.claude.loginHint.contains("claude"))
}

@Test(arguments: [("warning", Severity.warning), ("CRITICAL", .critical), ("limit_reached", .critical)])
func severityReadsVendorStrings(raw: String, expected: Severity) {
  #expect(Severity(raw: raw) == expected)
}

@Test func severityWithoutARawStringIsNormal() {
  #expect(Severity(raw: nil) == .normal)
}

@Test(arguments: [(74.0, Severity.normal), (75.0, .warning), (89.9, .warning), (90.0, .critical)])
func severityThresholdsOnPercent(percent: Double, expected: Severity) {
  #expect(Severity(percent: percent) == expected)
}

@Test func windowGroupsSortShortestFirst() {
  #expect([WindowGroup.other, .monthly, .weekly, .session].sorted() == [.session, .weekly, .monthly, .other])
}

@Test func quotaWindowClampsAndComputes() {
  let window = QuotaWindow(
    id: "w", label: "W", group: .session, usedPercent: 140, resetsAt: fixedNow.addingTimeInterval(3600), duration: 18000
  )
  #expect(window.usedPercent == 100)
  #expect(window.remainingPercent == 0)
  #expect(window.severity == .critical)
  #expect(window.windowStart(now: fixedNow) == fixedNow.addingTimeInterval(3600 - 18000))
  #expect(
    QuotaWindow(id: "w", label: "W", group: .session, usedPercent: -3, resetsAt: nil).windowStart(now: fixedNow) == nil)
  let earlier = QuotaWindow(id: "w", label: "W", group: .session, usedPercent: 90, resetsAt: fixedNow)
  #expect(window.hasReset(since: earlier))
  #expect(!earlier.hasReset(since: window))
  let noDates = QuotaWindow(id: "w", label: "W", group: .session, usedPercent: 5, resetsAt: nil)
  #expect(noDates.hasReset(since: QuotaWindow(id: "w", label: "W", group: .session, usedPercent: 50, resetsAt: nil)))
  #expect(!noDates.hasReset(since: QuotaWindow(id: "w", label: "W", group: .session, usedPercent: 5.5, resetsAt: nil)))
}

@Test func windowKeyStorageRoundTrip() {
  let key = WindowKey(provider: .codex, windowID: "additional:spark:session")
  #expect(key.storageKey == "codex:additional:spark:session")
  #expect(WindowKey(storageKey: key.storageKey) == key)
  #expect(WindowKey(storageKey: "nope") == nil)
  #expect(WindowKey(storageKey: "unknown:x") == nil)
  #expect(WindowKey(provider: .claude, windowID: "b") < WindowKey(provider: .claude, windowID: "c"))
  #expect(WindowKey(provider: .claude, windowID: "z") < WindowKey(provider: .codex, windowID: "a"))
  let window = QuotaWindow(id: "session", label: "S", group: .session, usedPercent: 1, resetsAt: nil)
  #expect(WindowKey(.claude, window).windowID == "session")
}

@Test func snapshotSortsWindowsAndFindsWorst() {
  let snapshot = ProviderSnapshot(
    provider: .claude,
    windows: [
      QuotaWindow(id: "weekly", label: "W", group: .weekly, usedPercent: 70, resetsAt: nil),
      QuotaWindow(id: "session", label: "S", group: .session, usedPercent: 20, resetsAt: nil),
      QuotaWindow(id: "other", label: "O", group: .other, usedPercent: 99, resetsAt: nil, isActive: false),
    ],
    fetchedAt: fixedNow
  )
  #expect(snapshot.windows.map(\.id) == ["session", "weekly", "other"])
  #expect(snapshot.worstWindow?.id == "weekly")
  #expect(snapshot.window("missing") == nil)
  #expect(ProviderSnapshot(provider: .codex, windows: [], fetchedAt: fixedNow).worstWindow == nil)
  #expect(Notice(kind: .info, text: "x").id == "info:x")
}

@Test func fetchOutcomeAccessors() {
  let snapshot = ProviderSnapshot(provider: .claude, windows: [], fetchedAt: fixedNow)
  #expect(ProviderFetchOutcome.success(snapshot).snapshot == snapshot)
  #expect(ProviderFetchOutcome.partial(snapshot, "why").snapshot == snapshot)
  #expect(ProviderFetchOutcome.notAuthenticated("x").snapshot == nil)
  #expect(ProviderFetchOutcome.success(snapshot).errorDescription == nil)
  #expect(ProviderFetchOutcome.networkUnavailable("down").errorDescription == "down")
  #expect(ProviderFetchOutcome.failed("boom").errorDescription == "boom")
  #expect(QuotaAvailability.allTitles.count == 8)
}

extension QuotaAvailability {
  static var allTitles: [String] {
    [
      QuotaAvailability.loading, .current, .stale, .authenticationRequired, .networkUnavailable, .rateLimited,
      .unavailable, .disabled,
    ].map(\.title)
  }
}

@Test func analyticsHelpers() {
  let analytics = ProviderAnalytics(
    provider: .codex,
    points: [
      AnalyticsPoint(day: "2026-08-01", metric: .turns, series: "b", value: 2),
      AnalyticsPoint(day: "2026-08-01", metric: .turns, series: "a", value: 3),
      AnalyticsPoint(day: "2026-08-01", metric: .credits, series: "a", value: 9),
    ],
    fetchedAt: fixedNow
  )
  #expect(analytics.total(.turns) == 5)
  #expect(analytics.series(for: .turns) == ["a", "b"])
  #expect(analytics.creditEvents.isEmpty)
  #expect(AnalyticsMetric.allCases.map(\.unit).contains("%"))
  #expect(AnalyticsMetric.allCases.allSatisfy { !$0.title.isEmpty })
  #expect(DayStamp.string(Date(timeIntervalSince1970: 0)) == "1970-01-01")
  #expect(DayStamp.date("not-a-day") == nil)
}

@Test func providerOutcomeBuilderMapsErrors() {
  #expect(ProviderOutcomeBuilder.outcome(for: .network("x"), hint: "h") == .networkUnavailable("x"))
  #expect(
    ProviderOutcomeBuilder.outcome(for: .http(status: 401, body: "no", retryAfter: nil), hint: "h")
      == .notAuthenticated("HTTP 401: no. h"))
  #expect(
    ProviderOutcomeBuilder.outcome(for: .http(status: 500, body: "", retryAfter: nil), hint: "h") == .failed("HTTP 500")
  )
  #expect(ProviderOutcomeBuilder.outcome(for: .decoding("bad"), hint: "h") == .failed("Unexpected response: bad"))
  #expect(
    ProviderOutcomeBuilder.outcome(for: .http(status: 429, body: "slow", retryAfter: 42), hint: "h")
      == .rateLimited("HTTP 429: slow", retryAfter: 42))
  #expect(ProviderFetchOutcome.rateLimited("x", retryAfter: nil).errorDescription == "x")
  let policy = PollingPolicy.defaults(for: .claude)
  #expect(policy.interval(active: true, requested: 300) == 120)
  #expect(policy.interval(active: true, requested: 60) == 120)
  #expect(policy.interval(active: false, requested: 60) == 120)
  #expect(policy.interval(active: false, requested: 600) == 600)
  #expect(PollingPolicy.defaults(for: .codex).defaultInterval == 120)
}

@Test func registryOrdersAndLooksUpProviders() {
  let registry = ProviderRegistry([scriptedProvider(.codex), scriptedProvider(.claude)])
  #expect(registry.ids == [.claude, .codex])
  #expect(registry[.codex]?.id == .codex)
  #expect(ProviderRegistry([])[.claude] == nil)
}

@Test func clockFixedNeverSleeps() async throws {
  let clock = Clock.fixed(fixedNow)
  #expect(clock.now() == fixedNow)
  try await clock.sleep(1000)
  #expect(Clock.system.now().timeIntervalSinceNow < 1)
  try await Clock.system.sleep(0.001)
}

@Test func usageColorInterpolatesGreenToRed() {
  #expect(
    UsageColor.color(percent: 0) == UsageColor.green)
  #expect(UsageColor.color(percent: 100) == UsageColor.red)
  #expect(UsageColor.color(percent: 150) == UsageColor.red)
  #expect(UsageColor.color(percent: 60) == UsageColor.orange)
  let mid = UsageColor.color(percent: 30)
  #expect(mid.hue > UsageColor.orange.hue && mid.hue < UsageColor.green.hue)
  #expect(mid.brightness > UsageColor.green.brightness && mid.brightness < UsageColor.orange.brightness)
  #expect(UsageColor.color(percent: 80).hue < UsageColor.orange.hue)
  #expect(UsageColor.color(pace: .ahead, percent: 10) == UsageColor.orange)
  #expect(UsageColor.color(pace: .exhausted, percent: 10) == UsageColor.red)
  #expect(UsageColor.color(pace: .onTrack, percent: 10) == UsageColor.color(percent: 10))
}

@Test func popoverDismissalGateRules() {
  var gate = PopoverDismissalGate()
  let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
  let button = CGRect(x: 200, y: 200, width: 20, height: 20)
  let far = CGPoint(x: 500, y: 500)
  let movedBeforeEntering = gate.shouldClose(mouseLocation: far, popoverFrame: frame, trigger: .mouseMoved)
  #expect(!movedBeforeEntering)
  let clickedOutside = gate.shouldClose(mouseLocation: far, popoverFrame: frame, trigger: .mouseDown)
  #expect(clickedOutside)
  let clickedButton = gate.shouldClose(
    mouseLocation: CGPoint(x: 205, y: 205), popoverFrame: frame, excludedFrame: button, trigger: .mouseDown)
  #expect(!clickedButton)
  let clickedInside = gate.shouldClose(mouseLocation: CGPoint(x: 10, y: 10), popoverFrame: frame, trigger: .mouseDown)
  #expect(!clickedInside)
  let movedAfterEntering = gate.shouldClose(mouseLocation: far, popoverFrame: frame, trigger: .mouseMoved)
  #expect(movedAfterEntering)
  let escaped = gate.shouldClose(mouseLocation: CGPoint(x: 10, y: 10), popoverFrame: nil, trigger: .keyEscape)
  #expect(escaped)
  let noFrame = gate.shouldClose(mouseLocation: CGPoint(x: 10, y: 10), popoverFrame: nil, trigger: .mouseDown)
  #expect(noFrame)
}

@Test func popoverGeometryClampsToScreen() {
  let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
  let centered = PopoverGeometry.maxSize(anchor: CGRect(x: 700, y: 880, width: 40, height: 20), visibleFrame: screen)
  #expect(centered.height == 880 - PopoverGeometry.margin)
  #expect(centered.width == 1440 - 2 * PopoverGeometry.margin)
  let edge = PopoverGeometry.maxSize(anchor: CGRect(x: 1400, y: 880, width: 40, height: 20), visibleFrame: screen)
  #expect(edge.width == 1440 - 2 * PopoverGeometry.margin)
  let tiny = PopoverGeometry.maxSize(
    anchor: CGRect(x: 10, y: 50, width: 40, height: 20), visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 100))
  #expect(tiny == CGSize(width: PopoverGeometry.minimumWidth, height: PopoverGeometry.minimumHeight))
  let clamped = PopoverGeometry.clamp(CGSize(width: 200, height: 5000), maximum: CGSize(width: 480, height: 400))
  #expect(clamped == CGSize(width: PopoverGeometry.minimumWidth, height: 400))
  #expect(PopoverGeometry.preferredWidth(visibleFrame: nil) == PopoverGeometry.minimumWidth)
  #expect(PopoverGeometry.preferredWidth(visibleFrame: screen) == PopoverGeometry.minimumWidth)
  let wide = CGRect(x: 0, y: 0, width: 3008, height: 1662)
  #expect(PopoverGeometry.preferredWidth(visibleFrame: wide) == 3008 * PopoverGeometry.viewportWidthShare)
  let narrow = CGRect(x: 0, y: 0, width: 600, height: 400)
  #expect(PopoverGeometry.preferredWidth(visibleFrame: narrow) == 600 - 2 * PopoverGeometry.margin)
  #expect(PopoverGeometry.stableCenterX(anchorMidX: 1500, visibleFrame: wide, widestWidth: 1274) == 1500)
  #expect(
    PopoverGeometry.stableCenterX(anchorMidX: 2900, visibleFrame: wide, widestWidth: 1274) == CGFloat(3008 - 12 - 637))
  #expect(PopoverGeometry.stableCenterX(anchorMidX: 10, visibleFrame: wide, widestWidth: 1274) == CGFloat(12 + 637))
  #expect(PopoverGeometry.stableCenterX(anchorMidX: 300, visibleFrame: narrow, widestWidth: 1274) == 300)
  #expect(PopoverGeometry.alignedOriginX(centerX: 1500, width: 1000, visibleFrame: wide) == 1000)
  #expect(PopoverGeometry.alignedOriginX(centerX: 100, width: 1000, visibleFrame: wide) == 0)
  #expect(PopoverGeometry.alignedOriginX(centerX: 2900, width: 1000, visibleFrame: wide) == 2008)
  #expect(PopoverGeometry.alignedOriginX(centerX: 300, width: 1000, visibleFrame: narrow) == 0)
  #expect(
    PopoverGeometry.tabWidth(for: .history) == PopoverGeometry.widestTabWidth + 2 * PopoverGeometry.contentPadding)
  #expect(PopoverGeometry.contentWidth(for: .settings) == PopoverGeometry.minimumWidth)
  #expect(PopoverGeometry.contentWidth(for: .usage) < PopoverGeometry.contentWidth(for: .settings))
  #expect(
    PopoverGeometry.clamp(CGSize(width: 900, height: 300), maximum: CGSize(width: 800, height: 900))
      == CGSize(width: 800, height: 300))
  #expect(
    PopoverGeometry.clamp(.zero, maximum: .zero)
      == CGSize(width: PopoverGeometry.minimumWidth, height: PopoverGeometry.minimumHeight))
  let origin = PopoverGeometry.pinnedOrigin(
    lastTopCenter: CGPoint(x: 1430, y: 890), size: CGSize(width: 400, height: 300), visibleFrame: screen)
  #expect(origin == CGPoint(x: 1040, y: 590))
  #expect(
    PopoverGeometry.pinnedOrigin(
      lastTopCenter: CGPoint(x: -100, y: 100), size: CGSize(width: 400, height: 300), visibleFrame: screen)
      == CGPoint(x: 0, y: 0))
}

@Test func launchAtLoginBackendReportsStatus() {
  #expect(LaunchAtLoginBackend.unsupported.status() == .unknown)
  #expect(LaunchAtLoginBackend.unsupported.setEnabled(true) == .unknown)
  #expect(!LaunchAtLoginBackend.Status.notRegistered.isEnabled)
  #expect(LaunchAtLoginBackend.Status.requiresApproval.explanation?.contains("Login Items") == true)
  #expect(LaunchAtLoginBackend.Status.notFound.explanation?.contains("/Applications") == true)
  #expect(LaunchAtLoginBackend.Status.enabled.explanation == nil)
  struct Boom: Error {}
  let failing = LaunchAtLoginBackend(
    status: { .notRegistered }, register: { throw Boom() }, unregister: { throw Boom() })
  #expect(failing.setEnabled(true) == .notRegistered)
  #expect(failing.setEnabled(false) == .notRegistered)
  let ok = LaunchAtLoginBackend(status: { .enabled }, register: {}, unregister: {})
  #expect(ok.setEnabled(true) == .enabled)
  ok.openSettings()
}

@Test(arguments: [
  ("claude.home", ["CLAUDE_CONFIG_DIR": "/cfg/claude"], "/cfg/claude"),
  ("codex.home", ["CODEX_HOME": "/cfg/codex"], "/cfg/codex"),
  ("gemini.home", ["GEMINI_CLI_HOME": "/cfg"], "/cfg/.gemini"),
  ("copilot.config", ["XDG_CONFIG_HOME": "/xdg"], "/xdg/github-copilot"),
  ("cursor.home", [:], "/home/.cursor"),
])
func sandboxResourcesFollowTheirConfiguredLocation(id: String, environment: [String: String], expected: String) {
  let resource = ProviderID.allSandboxResources.first { $0.id == id }!
  #expect(resource.configuredURL(environment: environment, home: URL(fileURLWithPath: "/home")).path == expected)
  #expect(resource.configuredURL(environment: [:], home: URL(fileURLWithPath: "/home")).path.hasPrefix("/home"))
}

@Test func sandboxResourcesDescribeEveryProviderPath() {
  #expect(ProviderID.allSandboxResources.count == 7)
  #expect(ProviderID.claude.sandboxResources.map(\.kind) == [.directory, .file])
  #expect(ProviderID.allSandboxResources.allSatisfy { $0.label.hasPrefix("~/") })
  #expect(Set(ProviderID.allSandboxResources.map(\.id)).count == 7)
}

@Test(
  arguments: [
    (["app", "--export-icon", "/tmp/a"], ExportCommand.icons), (["--export-menubar", "/tmp/a"], .menuBar),
    (["--export-popover", "/tmp/a"], .popover),
  ])
func exportCommandParsesItsFlag(arguments: [String], command: ExportCommand) {
  let parsed = ExportCommand.parse(arguments)
  #expect(parsed?.command == command)
  #expect(parsed?.directory.path == "/tmp/a")
  #expect(!command.failureMessage.isEmpty)
}

@Test(arguments: [["app"], ["app", "--export-icon"], []])
func exportCommandNeedsAFlagAndADirectory(arguments: [String]) {
  #expect(ExportCommand.parse(arguments) == nil)
}
