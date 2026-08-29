import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

let fixedNow = Date(timeIntervalSince1970: 1_788_030_000)
let testClock = Clock.fixed(fixedNow)
let sleepingClock = Clock(now: { fixedNow }, sleep: { try await Task.sleep(for: .seconds($0)) })

@MainActor
func makeSettings() -> TokenMenuBarCore.Settings {
  TokenMenuBarCore.Settings(defaults: UserDefaults(suiteName: "ui-tests-\(UUID().uuidString)")!)
}

func makeLog() -> LogBuffer {
  LogBuffer(fileURL: nil, clock: testClock)
}

let testAppInfo = AppInfo(
  name: "Token Menu Bar", version: "1.2.3", build: "4", bundleIdentifier: "dev.tox.token-menu-bar", isAppStore: false,
  repository: AppInfo.repositoryURL)

func sampleSnapshot(_ provider: ProviderID, percent: Double = 36) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: provider,
    identity: ProviderIdentity(
      planName: provider == .claude ? "Max 20x" : "Pro", email: "user@example.com",
      subscriptionActiveUntil: provider == .codex ? fixedNow.addingTimeInterval(86400) : nil),
    windows: [
      QuotaWindow(
        id: "session", label: "Current session", group: .session, usedPercent: percent,
        resetsAt: fixedNow.addingTimeInterval(4 * 3600), duration: 18000),
      QuotaWindow(
        id: "weekly:fable", label: "Fable", group: .weekly, usedPercent: 61,
        resetsAt: fixedNow.addingTimeInterval(3 * 86400), duration: 604_800, scope: "Fable"),
      QuotaWindow(id: "extra", label: "Inactive", group: .other, usedPercent: 0, resetsAt: nil, isActive: false),
    ],
    credits: CreditBalance(
      balance: 12.5, currency: "USD", hasCredits: true, overageLimitReached: true, approxLocalMessages: 1...3,
      approxCloudMessages: 2...4),
    spend: SpendControl(
      enabled: true, canToggle: true, used: Money(amountMinor: 100, currency: "USD"),
      limit: Money(amountMinor: 1000, currency: "USD"), percent: 10, resetsAt: fixedNow.addingTimeInterval(86400 * 3),
      limitReached: false, balance: Money(amountMinor: 50, currency: "USD"), autoReload: true, canPurchaseCredits: true),
    resetCredits: ResetCredits(available: 1, applicable: 1, totalEarned: 2),
    notices: [Notice(kind: .promotion, text: "Boosted limits"), Notice(kind: .limitReached, text: "Limit reached")],
    localUsage: LocalUsage(
      windowTokens: 1_200_000, windowCost: 14.2, costPerHour: 5.5, todayTokens: 3_000_000, todayCost: 40,
      todayMessages: 120),
    fetchedAt: fixedNow.addingTimeInterval(-10)
  )
}

@MainActor
func makeEnvironment(settings: TokenMenuBarCore.Settings? = nil, populate: Bool = true) throws -> UIEnvironment {
  let settings = settings ?? makeSettings()
  let state = AppState()
  if populate {
    state.update(.claude) {
      $0.snapshot = sampleSnapshot(.claude)
      $0.availability = .stale
      $0.lastError = "network down https://example.com/help"
      $0.warnings = ["Profile unavailable"]
      $0.credentialState = .valid(expiresAt: nil)
      $0.isRefreshing = true
    }
    state.update(.codex) {
      $0.snapshot = sampleSnapshot(.codex, percent: 80)
      $0.availability = .current
      $0.analytics = ProviderAnalytics(
        provider: .codex,
        points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .codeReviews, series: "reviews", value: 3)],
        fetchedAt: fixedNow)
    }
    state.setRefreshing(true, at: fixedNow.addingTimeInterval(-60))
  }
  let history = try UsageHistoryStore(url: nil)
  let environment = UIEnvironment(
    state: state, settings: settings, history: history, log: makeLog(), appInfo: testAppInfo, clock: testClock,
    launchAtLoginStatus: .requiresApproval, credentialDescriptions: [.claude: "Keychain"], canCheckForUpdates: true,
    isSandboxed: true)
  return environment
}

@MainActor
private var hostingWindows: [NSWindow] = []

@MainActor
func host<V: View>(_ view: V, width: CGFloat = 520, height: CGFloat = 700) -> NSHostingView<V> {
  let hosting = NSHostingView(rootView: view)
  hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
  let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()
  hostingWindows.append(window)
  return hosting
}

@MainActor
func statusModel(format: StatusFormat = .stacked) -> StatusItemModel {
  let snapshots: [ProviderID: ProviderSnapshot] = [
    .claude: sampleSnapshot(.claude), .codex: sampleSnapshot(.codex, percent: 80),
  ]
  return StatusItemBuilder.build(
    StatusItemInput(
      snapshots: snapshots,
      availability: [.claude: .current, .codex: .current],
      selectedKeys: StatusItemBuilder.defaultSelection(snapshots),
      format: format,
      customTemplate: "{label} {pct} {reset}",
      decimals: 0,
      hideZeroCells: true,
      order: .provider,
      labels: [:],
      now: fixedNow
    )
  )
}

final class FakeNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
  private let lock = NSLock()
  var authorize: Bool = true
  var authorizationError: (any Error)?
  var addError: (any Error)?
  private(set) var requests: [UNNotificationRequest] = []
  private(set) var removed: [String] = []

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    if let authorizationError { throw authorizationError }
    return authorize
  }

  func add(_ request: UNNotificationRequest) async throws {
    if let addError { throw addError }
    lock.withLock { requests.append(request) }
  }

  func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
    lock.withLock { removed += identifiers }
  }
}

struct TestError: Error {}

extension UsageHistoryStore {
  func breakDatabase() throws {
    try database.execute("DROP TABLE samples")
    try database.execute("DROP TABLE analytics")
  }
}

@MainActor
final class FakeUpdater: UpdaterHook {
  var canCheck = true
  var automaticallyChecks = false
  var checks = 0

  func checkForUpdates() {
    checks += 1
  }
}

struct StaticProvider: UsageProvider {
  let id: ProviderID
  let result: ProviderFetchResult
  let pollingPolicy = PollingPolicy(minimumInterval: 0, activeInterval: 0, defaultInterval: 0)

  var credentialDescription: String { "static \(id.rawValue)" }
  func credentialState(now: Date) -> CredentialState { .valid(expiresAt: nil) }
  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult { result }
}
