import AppKit
import Darwin
import Testing
import UserNotifications

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func appControllerStartInstallsTheStatusItemAndRecordsTheUpgrade() throws {
  let (controller, dependencies, _) = try startedController()
  defer { controller.stop() }
  #expect(controller.environment.credentialDescriptions == [.claude: "scripted claude"])
  #expect(controller.environment.canCheckForUpdates)
  #expect(controller.statusItem != nil)
  #expect(controller.popover != nil)
  #expect(dependencies.settings.lastLaunchedVersion == "1.2.3")
  #expect(dependencies.log.text.contains("updated from 0.9"))
}

@MainActor
private func startedController() throws -> (AppController, AppDependencies, Recorder) {
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, recorder) = try makeDependencies(providers: [provider])
  dependencies.settings.setProvider(.claude, enabled: true)
  dependencies.settings.lastLaunchedVersion = "0.9"
  dependencies.settings.detailedLogging = true
  let controller = AppController(dependencies: dependencies)
  controller.start()
  return (controller, dependencies, recorder)
}

@Test @MainActor func appControllerRefreshFeedsTheStatusItem() async throws {
  let (controller, dependencies, _) = try startedController()
  defer { controller.stop() }
  await controller.coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  await waitUntil { controller.statusItem?.model.cells.count == dependencies.state.statusModel.cells.count }
  #expect(dependencies.state.state(for: .claude).availability == .current)
  #expect(!dependencies.state.statusModel.cells.isEmpty)
  #expect(controller.statusItem?.model.cells.count == dependencies.state.statusModel.cells.count)
}

@Test @MainActor func appControllerRefreshesOnlyTheRequestedProvider() async throws {
  let providers = [
    ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude)))),
    ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex)))),
  ]
  let (dependencies, _) = try makeDependencies(providers: providers)
  let controller = AppController(dependencies: dependencies)

  controller.refreshNow(provider: .claude)

  await waitUntil { dependencies.state.state(for: .claude).snapshot != nil }
  #expect(dependencies.state.state(for: .claude).snapshot?.provider == .claude)
  #expect(dependencies.state.state(for: .codex).snapshot == nil)
}

@Test @MainActor func globalRefreshRediscoversBeforeFetching() async throws {
  let source = ProviderID.codex.setup.credentialSources[1]
  let probe = RediscoveryFetchProbe()
  let provider = RediscoveryProvider(
    id: .codex, health: .valid(source: source, expiresAt: nil),
    result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex))), probe: probe)
  let (dependencies, recorder) = try makeDependencies {
    _ in ProviderRegistry([provider])
  }
  let controller = AppController(dependencies: dependencies)

  controller.refreshNow()

  await waitUntil { dependencies.state.state(for: .codex).snapshot != nil }
  #expect(recorder.rebuilt == 1)
  #expect(dependencies.state.state(for: .codex).credentialHealth == .valid(source: source, expiresAt: nil))
  #expect(await probe.fetches == 1)
}

@Test @MainActor func applicationActivationRediscoversLocallyAndUsesExactProvenance() async throws {
  let source = ProviderID.claude.setup.credentialSources[1]
  let probe = RediscoveryFetchProbe()
  let provider = RediscoveryProvider(
    id: .claude, health: .valid(source: source, expiresAt: fixedNow),
    result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))), probe: probe)
  let (dependencies, recorder) = try makeDependencies {
    _ in ProviderRegistry([provider])
  }
  let controller = AppController(dependencies: dependencies)

  controller.handleApplicationActivation()

  await waitUntil { dependencies.state.state(for: .claude).credentialHealth.isUsable }
  #expect(recorder.rebuilt == 1)
  #expect(dependencies.state.state(for: .claude).credentialHealth == .valid(source: source, expiresAt: fixedNow))
  #expect(await probe.fetches == 0)

  controller.handleApplicationActivation()
  await mainActorTurn()
  #expect(recorder.rebuilt == 1)
}

@Test @MainActor func applicationActivationKeepsAnUnauthenticatedProviderHidden() async throws {
  let probe = RediscoveryFetchProbe()
  let provider = RediscoveryProvider(
    id: .gemini, health: .missing(expected: ProviderID.gemini.setup.credentialSources),
    result: ProviderFetchResult(outcome: .failed("fetch should not run")), probe: probe)
  let (dependencies, _) = try makeDependencies {
    _ in ProviderRegistry([provider])
  }
  let controller = AppController(dependencies: dependencies)

  controller.handleApplicationActivation()

  await waitUntil {
    dependencies.state.state(for: .gemini).credentialHealth
      == .missing(expected: ProviderID.gemini.setup.credentialSources)
  }
  #expect(
    ProviderSettingsVisibility.providers(
      states: dependencies.state.providers, configured: [], showAll: false
    ).isEmpty)
  #expect(await probe.fetches == 0)
}

@Test @MainActor func appControllerTogglesThePopover() async throws {
  let (controller, dependencies, _) = try startedController()
  defer { controller.stop() }
  controller.togglePopover()
  #expect(dependencies.state.popoverVisible == controller.popover?.isShown)
  #expect(controller.statusItem?.popoverVisible == controller.popover?.isShown)
  controller.popover?.close()
  await waitUntil { controller.popover?.isShown == false }
  #expect(controller.popover?.isShown == false)
  #expect(controller.statusItem?.popoverVisible == false)
}

@Test @MainActor func appControllerReanchorsThePopoverWhenScreenGeometryChanges() async throws {
  let (controller, _, _) = try startedController()
  defer { controller.stop() }
  await waitUntil { controller.statusItem?.buttonFrameOnScreen != nil }
  #expect(controller.popover?.maximum.height == CGFloat.greatestFiniteMagnitude)

  NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

  await waitUntil { controller.popover?.maximum.height.isFinite == true }
  #expect(controller.popover?.maximum.height.isFinite == true)
}

@Test @MainActor func appControllerDefersOpeningUntilTheStatusItemIsAttached() async throws {
  let providers = [
    ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude)))),
    ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex)))),
  ]
  let (dependencies, _) = try makeDependencies(providers: providers)
  let controller = AppController(dependencies: dependencies)

  controller.start()
  controller.statusItem?.visibleItemFrame = { _ in CGRect(x: 10, y: 10, width: 36, height: 24) }
  defer { controller.stop() }

  #expect(controller.popover?.isShown == false)
  await waitUntil { controller.popover?.isShown == true }
  #expect(controller.popover?.isShown == true)
}

@Test @MainActor func verificationCommandReopensAnOffscreenPopover() async throws {
  var (dependencies, _) = try makeDependencies()
  dependencies.verificationSession = "offscreen-status-item"
  dependencies.recoversOffscreenPopover = true
  let controller = AppController(dependencies: dependencies)
  controller.start()
  controller.statusItem?.visibleItemFrame = { _ in CGRect(x: -1_000, y: -1_000, width: 36, height: 24) }
  defer { controller.stop() }

  for _ in 0..<20 where controller.popover?.isShown != true {
    DistributedNotificationCenter.default().post(
      name: LaunchPolicy.verificationOpenPopoverNotification,
      object: dependencies.verificationSession,
      userInfo: nil)
    try await Task.sleep(for: .milliseconds(50))
  }

  await waitUntil { controller.popover?.isShown == true }
  #expect(controller.popover?.isShown == true)
}

@Test @MainActor func verificationSnapshotCommandFlushesProcessMetrics() async throws {
  var (dependencies, _) = try makeDependencies()
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("process-snapshot.json")
  let expected = ProcessPerformanceSnapshot(
    residentMemoryBytes: 12,
    physicalFootprintBytes: 10,
    cpuNanoseconds: 8)
  dependencies.verificationSession = "process-snapshot"
  dependencies.verificationSnapshotURL = url
  dependencies.captureProcessSnapshot = { expected }
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }

  DistributedNotificationCenter.default().post(
    name: LaunchPolicy.verificationSnapshotNotification,
    object: dependencies.verificationSession,
    userInfo: nil)

  await waitUntil { FileManager.default.fileExists(atPath: url.path) }
  let snapshot = try JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: Data(contentsOf: url))
  #expect(snapshot == expected)
}

@Test @MainActor func appControllerSuspendsPollingWhileTheMacSleeps() async throws {
  let (controller, dependencies, _) = try startedController()
  defer { controller.stop() }
  controller.handleSleep()
  #expect(!controller.coordinator.isRunning)
  controller.handleWake()
  #expect(controller.coordinator.isRunning)
  controller.refreshNow()
  controller.settingsChanged()
  #expect((dependencies.updater as? FakeUpdater)?.automaticallyChecks == true)
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
  await Task.yield()
}

@Test @MainActor func appControllerContextMenuItemsRunTheirCommands() throws {
  let (controller, dependencies, recorder) = try startedController()
  defer { controller.stop() }
  let menu = controller.contextMenu()
  #expect(menu.items.count == 5)
  _ = menu.items[0].target?.perform(menu.items[0].action, with: menu.items[0])
  _ = menu.items[2].target?.perform(menu.items[2].action, with: menu.items[2])
  #expect((dependencies.updater as? FakeUpdater)?.checks == 1)
  _ = menu.items[4].target?.perform(menu.items[4].action, with: menu.items[4])
  #expect(recorder.terminated == 1)
}

@Test @MainActor func appControllerStatusMenuDoesNotRemainAttachedAfterTracking() throws {
  let (controller, _, _) = try startedController()
  defer { controller.stop() }
  let item = try #require(controller.statusItem)
  let menu = NSMenu()

  item.show(menu)

  #expect(item.item.menu == nil)
}

@Test @MainActor func appControllerIgnoresCommandsItDoesNotKnow() throws {
  let (controller, _, recorder) = try startedController()
  defer { controller.stop() }
  controller.menuTarget.run(NSMenuItem(title: "x", action: nil, keyEquivalent: ""))
  controller.run("usage:nope")
  #expect(recorder.urls.isEmpty)
}

@Test @MainActor func appControllerAppliesSetupStateWhenProvidersAreRebuilt() throws {
  let (controller, dependencies, _) = try startedController()
  defer { controller.stop() }
  let setup = ProviderSetupState(
    enabled: true,
    credential: .unreadable(source: nil, detail: "Credential store is unavailable."))
  controller.replaceProviders(ProviderRegistry([], setupStates: [.claude: setup]))
  #expect(dependencies.state.state(for: .claude).credentialHealth == setup.credential)
}

@Test @MainActor func appControllerReleasesReplacedProviderRegistry() throws {
  weak var replacedLease: SecurityScopedResourceLease?
  let controller = try { () -> AppController in
    var dependencies = try makeDependencies().0
    let lease = SecurityScopedResourceLease(url: URL(fileURLWithPath: "/tmp/provider-registry")) { _ in }
    replacedLease = lease
    dependencies.registry = ProviderRegistry(dependencies.registry.providers, resourceLeases: [lease])
    return AppController(dependencies: dependencies)
  }()

  controller.replaceProviders(ProviderRegistry([]))

  #expect(replacedLease == nil)
}

@Test @MainActor func appControllerResetRestoresAllRuntimeState() async throws {
  let (dependencies, recorder) = try makeDependencies(isDemo: true)
  let controller = AppController(dependencies: dependencies)
  controller.environment.historyPresenter.setMetric(.analytics(.turns))
  controller.environment.historyPresenter.setPeriod(.range(.week))
  dependencies.settings.resetToDefaults()

  await controller.settingsReset()

  #expect(recorder.unregisteredLoginItem == 1)
  #expect(recorder.rebuilt == 1)
  #expect(controller.dependencies.registry.ids == [.codex])
  #expect(controller.environment.historyPresenter.selectedMetric == .windowUsagePercent)
  #expect(controller.environment.historyPresenter.followNow)
  #expect(recorder.relaunched == 1)
}

@Test @MainActor func appControllerPrunesHistoryWhenRetentionChanges() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.record(
    sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-10 * 86_400))
  let (dependencies, _) = try makeDependencies(history: history)
  let controller = AppController(dependencies: dependencies)
  dependencies.settings.historyRetentionDays = 7

  controller.settingsChanged()
  await waitUntil { dependencies.log.text.contains("history retention updated days=7") }

  #expect(try await history.stats().sampleCount == 0)
  await waitUntil { dependencies.state.sampleRevision == 1 }
  #expect(dependencies.log.text.contains("history retention updated days=7 removed=3"))
}

@Test @MainActor func appControllerDoesNotPruneForASupersededRetentionChange() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.record(
    sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-30 * 86_400))
  let (dependencies, _) = try makeDependencies(history: history)
  let controller = AppController(dependencies: dependencies)
  dependencies.settings.historyRetentionDays = 7
  controller.settingsChanged()

  dependencies.settings.historyRetentionDays = 60
  controller.settingsChanged()

  #expect(try await history.stats().sampleCount == 3)
  #expect(await history.retentionDays == 60)
}

@Test @MainActor func appControllerReportsHistoryRetentionFailures() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.breakDatabase()
  let (dependencies, _) = try makeDependencies(history: history)
  let controller = AppController(dependencies: dependencies)
  dependencies.settings.historyRetentionDays = 7

  controller.settingsChanged()

  await waitUntil { dependencies.log.text.contains("history retention update failed") }
  #expect(dependencies.log.text.contains("history retention update failed"))
}

@Test @MainActor func appControllerStopReleasesTheStatusItem() throws {
  let (controller, dependencies, _) = try startedController()
  controller.stop()
  #expect(controller.statusItem == nil)
  #expect(!controller.coordinator.isRunning)
  #expect(dependencies.log.text.contains("stopped"))
}

@Test @MainActor func appControllerWithoutUpdaterHidesUpdateItems() throws {
  let (dependencies, _) = try makeDependencies(updater: nil)
  let controller = AppController(dependencies: dependencies)
  #expect(!controller.environment.canCheckForUpdates)
  #expect(controller.contextMenu().items.map(\.title) == ["Refresh Now", "", "Quit Token Menu Bar"])
  controller.environment.actions.checkForUpdates()
  controller.environment.actions.quit()
}

@Test @MainActor func appControllerActionsRouteToDependencies() async throws {
  let (dependencies, recorder) = try makeDependencies()
  let controller = AppController(dependencies: dependencies)
  let actions = controller.environment.actions
  actions.showProviders(.codex)
  #expect(dependencies.settings.lastTab == .settings)
  #expect(controller.environment.providerFocusRequest?.provider == .codex)
  actions.openURL(URL(string: "https://example.com")!)
  actions.copy("text")
  #expect(recorder.urls.first?.host == "example.com")
  #expect(recorder.copied == ["text"])
  await controller.exportHistory().value
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-export-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  recorder.exportURL = directory.appendingPathComponent("history.csv")
  await controller.exportHistory().value
  #expect(try String(contentsOf: recorder.exportURL!, encoding: .utf8).hasPrefix("kind,timestamp,"))
  recorder.exportURL = URL(fileURLWithPath: "/dev/null/impossible.csv")
  await controller.exportHistory().value
  #expect(dependencies.log.text.contains("export failed"))
  try await dependencies.history.record(sampleSnapshot(.claude), now: fixedNow)
  await controller.clearHistory().value
  #expect(dependencies.log.text.contains("history cleared"))
  #expect(dependencies.state.sampleRevision == 1)
  actions.exportHistory()
  actions.clearHistory()
  actions.revealHistory()
  #expect(recorder.revealed.isEmpty)
  actions.copyDiagnostics()
  #expect(recorder.copied.last?.hasPrefix("Token Menu Bar 1.2.3") == true)
  actions.reportIssue()
  #expect(recorder.urls.last?.path == "/tox-dev/token-menu-bar-macos/issues/new")
  actions.showFullLog()
  actions.showFullLog()
  actions.setLaunchAtLogin(true)
  #expect(controller.environment.launchAtLoginStatus == .notRegistered)
  actions.openLoginItems()
  #expect(recorder.openedLoginItems == 1)
  let codexHome = ProviderID.codex.sandboxResources[0]
  actions.grantAccess(codexHome)
  #expect(recorder.rebuilt == 0)
  recorder.codexHome = FileManager.default.temporaryDirectory
  actions.grantAccess(codexHome)
  await waitUntil { recorder.rebuilt >= 1 }
  #expect(recorder.rebuilt >= 1)
  #expect(dependencies.settings.bookmark(for: codexHome) != nil)
  #expect(controller.environment.credentialDescriptions == [.codex: "scripted codex"])
  recorder.codexHome = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
  actions.grantAccess(codexHome)
  await waitUntil { dependencies.log.text.contains("bookmark for ~/.codex failed") }
  #expect(dependencies.log.text.contains("bookmark for ~/.codex failed"))
  actions.refresh()
  actions.settingsChanged()
}

@Test @MainActor func appControllerSurvivesHistoryFailures() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.breakDatabase()
  let (dependencies, _) = try makeDependencies(history: history)
  let controller = AppController(dependencies: dependencies)
  await controller.clearHistory().value
  #expect(dependencies.log.text.contains("history clear failed"))
  let located = try UsageHistoryStore(
    url: FileManager.default.temporaryDirectory.appendingPathComponent("tmb-\(UUID().uuidString)/usage.sqlite"))
  let (deps, recorder) = try makeDependencies(history: located)
  AppController(dependencies: deps).revealHistory()
  #expect(recorder.revealed.count == 1)
}

@Test @MainActor func appDelegateLifecycle() throws {
  let (dependencies, _) = try makeDependencies()
  let controller = AppController(dependencies: dependencies)
  let delegate = AppDelegate(controller: controller)
  delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
  #expect(controller.statusItem != nil)
  #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
  delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
  #expect(controller.statusItem == nil)
}

@Test @MainActor func deferredAppDelegateShowsTheStatusShellBeforeDependenciesFinish() async throws {
  quietTestApp()
  let (dependencies, _) = try makeDependencies()
  let gate = DeferredDependencyGate()
  var failure: String?
  let delegate = DeferredAppDelegate {
    try await gate.wait()
  } failureHandler: {
    failure = $0
  }
  let clock = ContinuousClock()
  let start = clock.now
  delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
  let statusShellDuration = start.duration(to: clock.now)
  #expect(statusShellDuration < .milliseconds(200))
  #expect(delegate.statusShellVisible)
  #expect(delegate.controller == nil)

  gate.resolve(dependencies)
  await waitUntil { delegate.controller != nil }
  #expect(!delegate.statusShellVisible)
  #expect(delegate.controller?.statusItem != nil)
  #expect(failure == nil)
  delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
}

@Test @MainActor func deferredAppDelegateDiscardsDependenciesReturnedAfterCancellation() async throws {
  let (dependencies, _) = try makeDependencies()
  let gate = DeferredDependencyGate()
  let delegate = DeferredAppDelegate {
    try await gate.wait()
  } failureHandler: { _ in
    Issue.record("cancelled loading reported a failure")
  }

  delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
  await waitUntil { gate.isWaiting }
  delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
  gate.resolve(dependencies)
  await waitUntil { !gate.isWaiting }
  await mainActorTurn()

  #expect(delegate.controller == nil)
  #expect(!delegate.statusShellVisible)
}

@Test @MainActor func deferredBootstrapDoesNotTouchStorageDuringConstruction() {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-deferred-\(UUID().uuidString)")
  let support = root.appendingPathComponent("support")
  let delegate = AppRunner.bootstrapDeferred(
    distribution: .appStore, notificationCenter: nil, updater: nil, isSandboxed: false,
    paths: LiveDependencies.Paths(home: root, supportDirectory: support, environment: [:], userName: "tester"),
    defaults: UserDefaults(suiteName: "deferred-\(UUID().uuidString)")!, transport: NoNetworkTransport(),
    keychain: testKeychain, launchAtLogin: .inMemory())
  #expect(!FileManager.default.fileExists(atPath: support.path))
  #expect(delegate.controller == nil)
}

@Test @MainActor func appControllerProbesCredentialStoresAwayFromTheMainThread() async throws {
  let probe = CredentialHealthThreadProbe()
  let provider = CredentialHealthProbeProvider(probe: probe)
  let (dependencies, _) = try makeDependencies(providers: [provider])
  let controller = AppController(dependencies: dependencies)
  controller.start()
  await waitUntil { dependencies.state.state(for: .claude).credentialHealth.isUsable }
  #expect(probe.wasMainThread == false)
  controller.stop()
}

@Test @MainActor func liveDependenciesResolveBookmarksAndBuildProvidersAwayFromTheMainThread() async {
  let resource = ProviderID.codex.sandboxResources[0]
  let settings = makeSettings()
  settings.setBookmark(Data([1]), for: resource)
  let resolverProbe = CredentialHealthThreadProbe()
  let builderProbe = CredentialHealthThreadProbe()
  let resolver = SecurityScopedResourceResolver(
    client: SecurityScopedBookmarkClient(
      resolve: { _ in
        resolverProbe.record(pthread_main_np() != 0)
        return SecurityScopedBookmarkResolution(url: FileManager.default.temporaryDirectory, isStale: false)
      },
      create: { _ in Data() },
      start: { _ in true },
      stop: { _ in }))

  _ = await LiveDependencies.providers(
    paths: LiveDependencies.Paths(environment: [:]),
    client: APIClient(transport: NoNetworkTransport(), log: makeLog()),
    log: makeLog(),
    settings: settings,
    isSandboxed: true,
    keychain: testKeychain,
    resolver: resolver,
    buildRegistry: { _, _, _ in
      builderProbe.record(pthread_main_np() != 0)
      return ProviderRegistry([])
    })

  #expect(resolverProbe.wasMainThread == false)
  #expect(builderProbe.wasMainThread == false)
}

@Test @MainActor func liveDependenciesBuildRealGraph() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-live-\(UUID().uuidString)")
  let paths = LiveDependencies.Paths(
    home: root.appendingPathComponent("home"), supportDirectory: root.appendingPathComponent("support"),
    environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path], userName: "tester")
  let defaults = UserDefaults(suiteName: "live-\(UUID().uuidString)")!
  var openedReplacement = false
  let dependencies = try await LiveDependencies.make(
    appInfo: testAppInfo, paths: paths, defaults: defaults, notificationCenter: nil, updater: nil, isSandboxed: false,
    transport: NoNetworkTransport(), keychain: testKeychain,
    launchAtLogin: .inMemory(),
    workspaceOpen: { _, _, _ in openedReplacement = true })
  #expect(dependencies.registry.ids == [.claude, .codex, .copilot, .cursor, .gemini])
  #expect(dependencies.history.location?.lastPathComponent == "usage.sqlite")
  #expect(dependencies.registry[.codex]?.credentialDescription.hasSuffix(".codex/auth.json") == true)
  #expect(dependencies.registry[.claude]?.credentialDescription.contains("Claude Code-credentials-") == true)
  #expect(dependencies.registry[.claude]?.credentialState(now: fixedNow).isUsable == false)
  #expect(dependencies.registry[.codex]?.credentialState(now: fixedNow).isUsable == false)
  _ = await dependencies.rebuildProviders(dependencies.settings)
  dependencies.relaunch()
  #expect(openedReplacement)
  let controller = AppController(dependencies: dependencies)
  #expect(controller.environment.isSandboxed == false)
  let sandboxed = try await LiveDependencies.make(
    appInfo: testAppInfo, paths: paths, defaults: defaults, notificationCenter: nil, isSandboxed: true,
    transport: NoNetworkTransport(), keychain: testKeychain, launchAtLogin: .inMemory())
  #expect(sandboxed.isSandboxed)
  let log = makeLog()
  let codexHome = ProviderID.codex.sandboxResources[0]
  let fallback = codexHome.configuredURL(environment: paths.environment, home: paths.home)
  #expect(LiveDependencies.resolve(bookmark: nil, fallback: fallback, log: log).path.hasSuffix(".codex"))
  #expect(LiveDependencies.resolve(bookmark: Data([1, 2, 3]), fallback: fallback, log: log) == fallback)
  #expect(log.text.contains("could not be resolved"))
  let bookmark = try (FileManager.default.temporaryDirectory as NSURL).bookmarkData(
    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  #expect(
    LiveDependencies.resolve(bookmark: bookmark, fallback: fallback, log: log).path.contains(
      FileManager.default.temporaryDirectory.lastPathComponent))
  let settings = makeSettings()
  #expect(
    LiveDependencies.directory(codexHome, paths: paths, settings: settings, isSandboxed: false, log: log) == fallback)
  settings.setBookmark(bookmark, for: codexHome)
  #expect(
    LiveDependencies.directory(codexHome, paths: paths, settings: settings, isSandboxed: true, log: log) != fallback)
  // an explicit CODEX_HOME still wins over the bookmark
  let configured = LiveDependencies.Paths(home: root, environment: ["CODEX_HOME": "/tmp/cx"], userName: "tester")
  let sandboxedGraph = try await LiveDependencies.make(
    appInfo: testAppInfo, paths: configured, defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!,
    notificationCenter: nil, isSandboxed: true, transport: NoNetworkTransport(), keychain: testKeychain,
    launchAtLogin: .inMemory())
  #expect(sandboxedGraph.registry[.codex]?.credentialDescription.contains("/tmp/cx/auth.json") == true)
  #expect(
    ProviderID.claude.sandboxResources[1].configuredURL(environment: [:], home: root).lastPathComponent
      == ".claude.json")
  // a stored bookmark replaces the configured path when the build is sandboxed
  let bookmarked = makeSettings()
  bookmarked.setBookmark(bookmark, for: codexHome)
  let redirected = await LiveDependencies.providers(
    paths: paths, client: APIClient(transport: NoNetworkTransport(), log: log), log: log, settings: bookmarked,
    isSandboxed: true, keychain: testKeychain)
  #expect(redirected[.codex]?.credentialDescription.hasSuffix("/auth.json") == true)
  #expect(redirected[.codex]?.credentialDescription.contains(paths.home.path) == false)
  let environmentTokenPaths = LiveDependencies.Paths(
    home: root.appendingPathComponent("environment-home"), supportDirectory: root.appendingPathComponent("support"),
    environment: ["COPILOT_GITHUB_TOKEN": "token"], userName: "tester")
  let environmentRegistry = await LiveDependencies.providers(
    paths: environmentTokenPaths, client: APIClient(transport: NoNetworkTransport(), log: log), log: log,
    settings: makeSettings(), isSandboxed: true, keychain: testKeychain)
  #expect(
    environmentRegistry.setupStates[.copilot]?.resources
      == ProviderID.copilot.sandboxResources.map(ResourceAccessState.notRequired))

  let bookmarkRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-stale-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: bookmarkRoot) }
  let original = bookmarkRoot.appendingPathComponent("original")
  let moved = bookmarkRoot.appendingPathComponent("moved")
  try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
  let staleBookmark = try (original as NSURL).bookmarkData(
    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  try FileManager.default.moveItem(at: original, to: moved)
  let staleSettings = makeSettings()
  staleSettings.setBookmark(staleBookmark, for: codexHome)

  _ = await LiveDependencies.providers(
    paths: paths, client: APIClient(transport: NoNetworkTransport(), log: log), log: log, settings: staleSettings,
    isSandboxed: true, keychain: testKeychain)

  #expect(staleSettings.bookmark(for: codexHome) != staleBookmark)
  #expect(log.text.contains("replaced stale bookmark for ~/.codex"))
  let home = LiveDependencies.Paths()
  #expect(home.userName == NSUserName())
  #expect(ProviderID.allSandboxResources.count >= ProviderID.allCases.count)
  #expect(ProviderID.cursor.sandboxResources.map(\.label).contains("~/.cursor"))
}

@Test @MainActor func appRunnerBootstrapsAgainstTemporaryDefaults() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-runner-\(UUID().uuidString)")
  let paths = LiveDependencies.Paths(
    home: root, supportDirectory: root.appendingPathComponent("support"), environment: [:], userName: "tester")
  let delegate = try await AppRunner.bootstrap(
    distribution: .appStore, notificationCenter: nil, updater: FakeUpdater(), isSandboxed: false, paths: paths,
    defaults: UserDefaults(suiteName: "runner-\(UUID().uuidString)")!, transport: NoNetworkTransport(),
    keychain: testKeychain, launchAtLogin: .inMemory())
  #expect(delegate.controller.dependencies.appInfo.isAppStore)
  #expect(delegate.controller.environment.canCheckForUpdates)
}

private actor RediscoveryFetchProbe {
  private(set) var fetches = 0

  func recordFetch() {
    fetches += 1
  }
}

private struct RediscoveryProvider: UsageProvider {
  let id: ProviderID
  let health: ProviderCredentialHealth
  let result: ProviderFetchResult
  let probe: RediscoveryFetchProbe
  let pollingPolicy = PollingPolicy(minimumInterval: 0, activeInterval: 0, defaultInterval: 0)

  var credentialDescription: String { "rediscovered \(id.rawValue)" }

  func credentialState(now: Date) -> CredentialState {
    switch health {
    case .unchecked, .missing, .unreadable: .missing(id.setup.signInDetail)
    case .valid(_, let expiresAt): .valid(expiresAt: expiresAt)
    case .expired(_, let date): .expired(date)
    }
  }

  func credentialHealth(now: Date) async -> ProviderCredentialHealth { health }

  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    await probe.recordFetch()
    return result
  }
}

@MainActor
private final class DeferredDependencyGate {
  private var result: Result<AppDependencies, any Error>?
  private var continuation: CheckedContinuation<AppDependencies, any Error>?
  private(set) var isWaiting = false

  func wait() async throws -> AppDependencies {
    if let result { return try result.get() }
    isWaiting = true
    defer { isWaiting = false }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func resolve(_ dependencies: AppDependencies) {
    if let continuation {
      self.continuation = nil
      continuation.resume(returning: dependencies)
    } else {
      result = .success(dependencies)
    }
  }
}

private struct CredentialHealthProbeProvider: UsageProvider {
  let probe: CredentialHealthThreadProbe
  let id = ProviderID.claude
  let pollingPolicy = PollingPolicy(minimumInterval: 3_600, activeInterval: 3_600, defaultInterval: 3_600)

  var credentialDescription: String { "probe" }

  func credentialState(now: Date) -> CredentialState {
    .valid(expiresAt: nil)
  }

  func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    probe.record(pthread_main_np() != 0)
    return .valid(source: id.setup.credentialSources[0], expiresAt: nil)
  }

  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    ProviderFetchResult(outcome: .failed("unused"))
  }
}

private final class CredentialHealthThreadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?

  var wasMainThread: Bool? { lock.withLock { value } }

  func record(_ value: Bool) {
    lock.withLock { self.value = value }
  }
}
