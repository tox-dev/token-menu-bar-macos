import AppKit
import Foundation
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Suite(.serialized)
struct StartupClosureCoverageTests {
  @Test @MainActor func startupClosureControllerCallbacksDriveTheirPublicBehaviors() async throws {
    let center = FakeNotificationCenter()
    let provider = StartupSequenceProvider(
      id: .claude,
      results: [ProviderFetchResult(outcome: .notAuthenticated("expired session"))])
    var (dependencies, recorder) = try makeDependencies(providers: [provider])
    dependencies.notifier = Notifier(center: center, log: dependencies.log)
    dependencies.persistsStatusItemPosition = false
    dependencies.openPopoverOnLaunch = false
    dependencies.settings.configuredProviders = [.claude]
    dependencies.settings.enabledProviders = [.claude]
    dependencies.state.update(.claude) {
      $0.snapshot = sampleSnapshot(.claude, percent: 70)
      $0.availability = .current
    }
    let processSnapshot = try #require(dependencies.captureProcessSnapshot())
    #expect(processSnapshot.residentMemoryBytes > 0)
    await dependencies.notifier.requestAuthorization()
    let controller = AppController(dependencies: dependencies)
    await controller.coordinator.refresh(
      RefreshRequest(reason: .userInitiated, usage: .force, analytics: .skip, providers: [.claude]))
    await waitUntil { center.requests.contains { $0.identifier.contains(":auth:") } }
    controller.start()
    defer { controller.stop() }
    let statusItem = try #require(controller.statusItem)
    let popover = try #require(controller.popover)
    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 36, height: 24), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let button = try #require(statusItem.item.button)
    button.removeFromSuperview()
    window.contentView?.addSubview(button)
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    #expect(statusItem.item.autosaveName != StatusItemController.autosaveName(bundleIdentifier: nil))
    statusItem.onCountdownTick?()
    #expect(statusItem.model == dependencies.state.statusModel)
    #expect(statusItem.menuProvider?().items.isEmpty == false)
    #expect(popover.excludedFrame?() == statusItem.buttonFrameOnScreen)
    let wasShown = popover.isShown
    statusItem.onClick?()
    #expect(popover.isShown != wasShown)

    #expect(center.requests.contains { $0.identifier.contains(":auth:") })

    controller.environment.actions.refreshProvider(.claude)
    await waitUntil { dependencies.state.state(for: .claude).snapshot != nil }
    popover.onRefresh?()
    let rebuilds = recorder.rebuilt
    controller.environment.actions.settingsReset()
    await waitUntil { recorder.rebuilt > rebuilds }
    #expect(recorder.rebuilt > rebuilds)
  }

  @Test @MainActor func startupClosureControllerRootCallbacksSelectAndExportHistory() async throws {
    var (dependencies, recorder) = try makeDependencies()
    dependencies.openPopoverOnLaunch = false
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    recorder.exportURL = directory.appendingPathComponent("history.csv")
    let controller = AppController(dependencies: dependencies)
    let popover = PopoverController(content: AnyView(EmptyView()), presentsWindow: false)
    let root = try #require(startupClosureRootView(in: controller.rootView(popover)))

    root.select(.history)
    #expect(popover.activeTab == .history)
    #expect(root.chooseHistoryExportURL() == recorder.exportURL)
  }

  @Test @MainActor func startupClosureReleasedControllerActionsRemainSafe() async throws {
    let (dependencies, _) = try makeDependencies()
    var controller: AppController? = AppController(dependencies: dependencies)
    let actions = try #require(controller?.environment.actions)
    let released = WeakReference(controller)

    controller = nil
    actions.refreshProvider(.claude)
    actions.settingsReset()
    await mainActorTurn()

    #expect(released.value == nil)
    #expect(AppControllerMenuSource(nil).menu().items.isEmpty)
  }

  @Test @MainActor func startupClosureAppFallbacksUseAvailableGeometryAndCredentialState() throws {
    var (dependencies, _) = try makeDependencies()
    dependencies.recoversOffscreenPopover = true
    let controller = AppController(dependencies: dependencies)
    let explicit = CGRect(x: 1, y: 2, width: 3, height: 4)
    let anchor = CGRect(x: 5, y: 6, width: 7, height: 8)
    let previous = CGRect(x: 9, y: 10, width: 11, height: 12)

    #expect(AppController.resolveVisibleFrame(explicit, anchorScreen: anchor, previousScreen: previous) == explicit)
    #expect(AppController.resolveVisibleFrame(nil, anchorScreen: anchor, previousScreen: previous) == anchor)
    #expect(AppController.resolveVisibleFrame(nil, anchorScreen: nil, previousScreen: previous) == previous)
    #expect(AppController.credentialHealth([:], provider: .claude) == .unchecked)
    #expect(
      AppController.credentialHealth([.claude: .missing(expected: [])], provider: .claude)
        == .missing(expected: []))
    #expect(!controller.retryOpening(remainingAttempts: 1, previousButtonFrame: nil, forcedNarrowest: false))
    #expect(controller.retryOpening(remainingAttempts: 1, previousButtonFrame: nil, forcedNarrowest: true))
  }

  @Test @MainActor func startupClosureVerificationSnapshotFailureIsLogged() async throws {
    var (dependencies, _) = try makeDependencies()
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }
    dependencies.verificationSession = "snapshot-write-failure"
    dependencies.verificationSnapshotURL = blocker.appendingPathComponent("process-snapshot.json")
    dependencies.captureProcessSnapshot = {
      ProcessPerformanceSnapshot(residentMemoryBytes: 1, physicalFootprintBytes: 1, cpuNanoseconds: 1)
    }
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }

    DistributedNotificationCenter.default().post(
      name: LaunchPolicy.verificationSnapshotNotification,
      object: dependencies.verificationSession,
      userInfo: nil)
    await waitUntil { dependencies.log.text.contains("Could not write verification process snapshot") }

    #expect(dependencies.log.text.contains("Could not write verification process snapshot"))
  }

  @Test @MainActor func startupClosureLogWindowPresentsWhenEnabled() {
    let presented = StartupClosureLockedValue<Bool>()
    #expect(LogWindowController(log: makeLog()).window != nil)
    let controller = LogWindowController(log: makeLog()) { _, _ in presented.set(true) }
    controller.showWindow(nil)

    #expect(presented.value == true)
    #expect(controller.window?.isVisible == false)
  }

  @Test @MainActor func startupClosureDeferredGraphUsesInjectedLaunchAndVerificationHooks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = NSApplication.shared
    let previousDelegate = application.delegate
    let terminator = StartupClosureTerminationDelegate()
    application.delegate = terminator
    defer { application.delegate = previousDelegate }
    var opened = false
    let dependencies = try await LiveDependencies.makeDeferred(
      appInfo: testAppInfo,
      paths: LiveDependencies.Paths(
        home: root, supportDirectory: root.appendingPathComponent("support"),
        environment: ["TOKEN_MENU_BAR_DEMO": "1"], userName: "tester", arguments: [],
        verificationProfile: VerificationProfile(fixture: .standard)),
      defaults: UserDefaults(suiteName: "startup-closure-deferred-\(UUID().uuidString)")!, notificationCenter: nil,
      updater: nil, isSandboxed: false, transport: NoNetworkTransport(), keychain: testKeychain,
      launchAtLogin: .inMemory(),
      workspaceOpen: { _, configuration, completion in
        opened = configuration.createsNewApplicationInstance
        completion()
      })

    dependencies.launchAtLogin.openSettings()
    let visibleFrame = try #require(dependencies.screenVisibleFrame())
    dependencies.relaunch()
    await waitUntil { terminator.requests == 1 }

    #expect(opened)
    #expect(terminator.requests == 1)
    #expect(visibleFrame == NSScreen.main?.visibleFrame)
  }

  @Test @MainActor func startupClosureProviderBuildReportsDeniedAndStaleGrants() async throws {
    let settings = makeSettings()
    settings.allowTokenRefresh = true
    let resources = Array(ProviderID.allSandboxResources.prefix(2))
    settings.setBookmark(Data([1]), for: resources[0])
    settings.setBookmark(Data([2]), for: resources[1])
    let log = makeLog()
    let captured = StartupClosureLockedValue<ProviderRegistryFactory.Configuration>()
    let resolver = SecurityScopedResourceResolver(
      client: SecurityScopedBookmarkClient(
        resolve: { data in
          SecurityScopedBookmarkResolution(
            url: URL(fileURLWithPath: data == Data([1]) ? "/tmp/denied" : "/tmp/stale"),
            isStale: data == Data([2]))
        },
        create: { _ in throw TestError() },
        start: { $0.lastPathComponent != "denied" },
        stop: { _ in }))

    _ = await LiveDependencies.providers(
      paths: LiveDependencies.Paths(environment: [:]),
      client: APIClient(transport: NoNetworkTransport(), log: log), log: log, settings: settings, isSandboxed: true,
      keychain: testKeychain, resolver: resolver,
      buildRegistry: { configuration, _, _ in
        captured.set(configuration)
        return ProviderRegistry([])
      })
    let configuration = try #require(captured.value)

    #expect(configuration.allowTokenRefresh())
    #expect(log.text.contains("access failed"))
    #expect(log.text.contains("access grant is stale"))
  }

  @Test @MainActor func startupClosureStaleDirectBookmarkResolutionIsLogged() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("original")
    let moved = root.appendingPathComponent("moved")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    let bookmark = try (original as NSURL).bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    try FileManager.default.moveItem(at: original, to: moved)
    let log = makeLog()

    _ = LiveDependencies.resolve(bookmark: bookmark, fallback: root, log: log)

    #expect(log.text.contains("is stale"))
  }

  @Test @MainActor func startupClosureEnvironmentFallbacksRemainObservable() async throws {
    let settings = makeSettings()
    settings.historyMetricID = "invalid-metric"
    settings.hasCustomSelection = false
    let history = try UsageHistoryStore(url: nil)
    let state = AppState()
    state.update(.claude) {
      $0.snapshot = sampleSnapshot(.claude)
      $0.availability = .current
    }
    let environment = UIEnvironment(
      state: state, settings: settings, history: history, log: makeLog(), appInfo: testAppInfo, clock: testClock)
    #expect(environment.historyPresenter.selectedMetric == .windowUsagePercent)
    #expect(!environment.advanceUsageDeadlines())
    #expect(environment.cards.isEmpty == false)
    try await history.breakDatabase()

    await environment.loadRecentSamples(force: true)
    let request = SettingsActivityRequest(
      keys: [WindowKey(.claude, sampleSnapshot(.claude).windows[0])], sampleRevision: state.sampleRevision,
      retentionDays: 30, rangeHour: 1)
    async let first = environment.settingsActivity(for: request)
    async let second = environment.settingsActivity(for: request)
    let results = await (first, second)

    #expect(environment.samples.values.allSatisfy { $0.isEmpty })
    #expect(results.0.isEmpty)
    #expect(results.1.isEmpty)
  }

  @Test @MainActor func startupClosureEnvironmentObservationDoesNotRetainIt() async throws {
    let settings = makeSettings()
    var environment: UIEnvironment? = try makeEnvironment(settings: settings)
    let released = WeakReference(environment)

    environment = nil
    settings.hasCustomSelection.toggle()
    await mainActorTurn()
    await mainActorTurn()

    #expect(released.value == nil)
  }
}

private final class WeakReference<Value: AnyObject> {
  weak var value: Value?

  init(_ value: Value?) {
    self.value = value
  }
}

private final class StartupSequenceProvider: UsageProvider, @unchecked Sendable {
  let id: ProviderID
  let pollingPolicy = PollingPolicy(minimumInterval: 0, activeInterval: 0, defaultInterval: 0)
  private let lock = NSLock()
  private let results: [ProviderFetchResult]
  private var index = 0

  init(id: ProviderID, results: [ProviderFetchResult]) {
    self.id = id
    self.results = results
  }

  var credentialDescription: String { "sequence \(id.rawValue)" }

  func credentialState(now: Date) -> CredentialState {
    .valid(expiresAt: nil)
  }

  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    lock.withLock {
      defer { index += 1 }
      return results[min(index, results.count - 1)]
    }
  }
}

@MainActor
private final class StartupClosureTerminationDelegate: NSObject, NSApplicationDelegate {
  private(set) var requests = 0

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    requests += 1
    return .terminateCancel
  }
}

private final class StartupClosureLockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?

  var value: Value? {
    lock.withLock { stored }
  }

  func set(_ value: Value) {
    lock.withLock { stored = value }
  }
}

private func startupClosureRootView(in value: Any, depth: Int = 0) -> RootView? {
  if let root = value as? RootView { return root }
  guard depth < 48 else { return nil }
  for child in Mirror(reflecting: value).children {
    if let root = startupClosureRootView(in: child.value, depth: depth + 1) { return root }
  }
  return nil
}
