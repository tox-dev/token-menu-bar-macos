import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

let fixedNow = Date(timeIntervalSince1970: 1_788_030_000)
let testClock = Clock.fixed(fixedNow)
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
private var hostingWindows: [NSWindow] = []

/// Keeps the suite off the screen it is running on. These tests put real NSWindows up, and without this they steal
/// focus and flash over whatever the developer is doing.
@MainActor
func quietTestApp() {
  guard !preparedTestApp else { return }
  preparedTestApp = true
  NSApplication.shared.setActivationPolicy(.prohibited)
}

@MainActor private var preparedTestApp = false

@MainActor
func host<Content: View>(_ view: Content, width: CGFloat = 520, height: CGFloat = 700) -> NSHostingView<Content> {
  quietTestApp()
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

struct ScriptedProvider: UsageProvider {
  let id: ProviderID
  let result: ProviderFetchResult
  let pollingPolicy = PollingPolicy(minimumInterval: 0, activeInterval: 0, defaultInterval: 0)

  var credentialDescription: String { "scripted \(id.rawValue)" }
  func credentialState(now: Date) -> CredentialState { .valid(expiresAt: nil) }
  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult { result }
}

@MainActor
func makeDependencies(
  providers: [any UsageProvider] = [], updater: FakeUpdater? = FakeUpdater(), history: UsageHistoryStore? = nil,
  widgetStore: WidgetSnapshotStore? = nil, snapshotCache: SnapshotCache = SnapshotCache(url: nil),
  isDemo: Bool = false, clock: Clock = sleepingClock,
  rebuildProviders: (@MainActor @Sendable (TokenMenuBarCore.Settings) async -> ProviderRegistry)? = nil
) throws -> (AppDependencies, Recorder) {
  quietTestApp()
  let recorder = Recorder()
  let history = try history ?? UsageHistoryStore(url: nil)
  let settings = makeSettings()
  let state = AppState()
  for provider in providers {
    state.update(provider.id) { $0.credentialState = .valid(expiresAt: nil) }
  }
  let dependencies = AppDependencies(
    appInfo: testAppInfo,
    settings: settings,
    state: state,
    history: history,
    log: makeLog(),
    registry: ProviderRegistry(providers),
    notifier: Notifier(center: FakeNotificationCenter(), log: makeLog()),
    launchAtLogin: LaunchAtLoginBackend(
      status: { .notRegistered }, register: {},
      unregister: { MainActor.assumeIsolated { recorder.unregisteredLoginItem += 1 } },
      openSettings: { MainActor.assumeIsolated { recorder.openedLoginItems += 1 } }),
    clock: clock,
    updater: updater,
    isSandboxed: true,
    isDemo: isDemo,
    openURL: { recorder.urls.append($0) },
    copyToPasteboard: { recorder.copied.append($0) },
    revealInFinder: { recorder.revealed.append($0) },
    chooseExportURL: { recorder.exportURL },
    chooseDirectory: { _ in recorder.codexHome },
    terminate: { recorder.terminated += 1 },
    relaunch: { recorder.relaunched += 1 },
    widgetStore: widgetStore,
    snapshotCache: snapshotCache,
    reloadWidgets: { recorder.reloadedWidgets += 1 },
    rebuildProviders: { settings in
      recorder.rebuilt += 1
      if let rebuildProviders { return await rebuildProviders(settings) }
      return ProviderRegistry([
        ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex))))
      ])
    },
    screenVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
    openPopoverOnLaunch: providers.count > 1,
    presentsWindows: false
  )
  return (dependencies, recorder)
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

/// Waits for work the controller schedules onto the main actor, so a loaded machine does not decide the outcome.
/// Spinning the run loop as well lets hosted SwiftUI views take the render pass their `.task` modifiers depend on.
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
