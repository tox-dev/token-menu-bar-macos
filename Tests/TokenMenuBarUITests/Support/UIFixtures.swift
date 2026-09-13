import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import TokenMenuBarTestSupport
import UserNotifications

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

let sleepingClock = Clock(now: { fixedNow }, sleep: { _ in try await CancellationSuspension.wait() })
let testKeychain = KeychainCredentialClient(load: { _, _ in nil }, save: { _, _, _ in })

final class CancellationSuspension: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var cancelled = false

  static func wait() async throws {
    let suspension = CancellationSuspension()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let cancelled = suspension.lock.withLock {
          guard !suspension.cancelled else { return true }
          suspension.continuation = continuation
          return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      let continuation = suspension.lock.withLock {
        suspension.cancelled = true
        defer { suspension.continuation = nil }
        return suspension.continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

@MainActor
func makeSettings() -> TokenMenuBarCore.Settings {
  TokenMenuBarCore.Settings(defaults: testDefaults())
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
      limitReached: false, balance: Money(amountMinor: 50, currency: "USD"), autoReload: true,
      canPurchaseCredits: true),
    resetCredits: ResetCredits(available: 1, applicable: 1, totalEarned: 2),
    notices: [Notice(kind: .promotion, text: "Boosted limits"), Notice(kind: .limitReached, text: "Limit reached")],
    localUsage: LocalUsage(
      windowTokens: 1_200_000, windowCost: 14.2, costPerHour: 5.5, todayTokens: 3_000_000, todayCost: 40,
      todayMessages: 120),
    fetchedAt: fixedNow.addingTimeInterval(-10)
  )
}

@MainActor
func makeEnvironment(
  settings: TokenMenuBarCore.Settings? = nil, populate: Bool = true, clock: Clock = testClock
) throws -> UIEnvironment {
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
    state: state, settings: settings, history: history, log: makeLog(), appInfo: testAppInfo, clock: clock,
    launchAtLoginStatus: .requiresApproval, credentialDescriptions: [.claude: "Keychain"], canCheckForUpdates: true,
    isSandboxed: true)
  return environment
}

@MainActor
func accessibilityDescendants(in root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
  (root.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }.flatMap {
    [$0] + accessibilityDescendants(in: $0)
  }
}

@MainActor
func prepareTestApp() {
  _ = NSApplication.shared
  #if NONPRESENTING_TESTS
    precondition(
      NSApp.activationPolicy() == .prohibited || NSApp.setActivationPolicy(.prohibited),
      "Local tests must prohibit application presentation")
  #endif
}

@MainActor
func host<Content: View>(_ view: Content, width: CGFloat = 520, height: CGFloat = 700) -> NSHostingView<Content> {
  prepareTestApp()
  let hosting = NSHostingView(rootView: view)
  hosting.sizingOptions = [.intrinsicContentSize]
  hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()
  precondition(hosting.window == nil, "Local rendering must not create a window")
  #if NONPRESENTING_TESTS
    precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "Local tests must not order windows on screen")
  #endif
  return hosting
}

@MainActor
func modelFilterField(in root: NSView) -> NSTextField? {
  if let field = root as? NSTextField, field.placeholderString == "Filter models…" { return field }
  return root.subviews.lazy.compactMap { modelFilterField(in: $0) }.first
}

@MainActor
func inkFraction<Content: View>(_ view: Content, width: CGFloat = 520, height: CGFloat = 700) -> Double {
  let hosting = host(view, width: width, height: height)
  guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
  hosting.cacheDisplay(in: hosting.bounds, to: rep)
  guard let image = rep.cgImage, image.width > 0, image.height > 0 else { return 0 }
  var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
  let context = CGContext(
    data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Double(stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 8 }) / Double(image.width * image.height)
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
  private(set) var requestedOptions: [UNAuthorizationOptions] = []
  weak var delegate: (any UNUserNotificationCenterDelegate)?

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    lock.withLock { requestedOptions.append(options) }
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

extension UsageHistoryStore {
  func breakDatabase() throws {
    try database.execute("DROP TABLE samples")
    try database.execute("DROP TABLE analytics")
  }
}

@MainActor
final class FakeUpdater: UpdaterHook {
  var canCheck = true { didSet { onCanCheckChange?(canCheck) } }
  var automaticallyChecks = false
  var onCanCheckChange: (@MainActor (Bool) -> Void)?
  var starts = 0
  var checks = 0

  func start() {
    starts += 1
    onCanCheckChange?(canCheck)
  }

  func checkForUpdates() {
    checks += 1
  }
}

struct ScriptedProvider: UsageProvider {
  let id: ProviderID
  let result: ProviderFetchResult
  let pollingPolicy = PollingPolicy(minimumInterval: 0, activeInterval: 0, defaultInterval: 0)

  var credentialDescription: String { "scripted \(id.rawValue)" }
  func credentialState(now: Date) -> CredentialState { .valid(expiresAt: nil) }
  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult { result }
}

@MainActor
final class Recorder {
  var relaunched = 0
  var reloadedWidgets = 0
  var urls: [URL] = []
  var copied: [String] = []
  var revealed: [URL] = []
  var exportURL: URL?
  var codexHome: URL?
  var terminated = 0
  var rebuilt = 0
  var openedLoginItems = 0
  var unregisteredLoginItem = 0
}

@MainActor
@discardableResult
func waitUntil(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition(), Date() < deadline {
    await mainActorTurn()
    try? await Task.sleep(for: .milliseconds(1))
  }
  return condition()
}

@MainActor
func mainActorTurn() async {
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }
}
