import AppKit
import Darwin
import Testing
import TokenMenuBarTestSupport
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
  controller.statusItem?.adaptive = false
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

@Test @MainActor func openingTheFullLogDismissesThePopover() throws {
  let (controller, dependencies, _) = try startedController()
  defer { controller.stop() }
  let window = detachedStatusWindow(holding: try #require(controller.statusItem?.item.button))
  defer { window.orderOut(nil) }
  controller.togglePopover()
  try #require(controller.popover?.isShown == true)

  controller.showFullLog()

  #expect(controller.popover?.isShown == false)
  #expect(!dependencies.state.popoverVisible)
}

@Test @MainActor func stoppingTheControllerClosesItsLogWindow() throws {
  let (dependencies, _) = try makeDependencies()
  let controller = AppController(dependencies: dependencies)
  defer { controller.stop() }
  let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
  controller.showFullLog()
  let window = try #require(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible })

  controller.stop()

  #expect(!window.isVisible)
}

@Test @MainActor func appControllerReanchorsThePopoverWhenScreenGeometryChanges() async throws {
  var (dependencies, _) = try makeDependencies()
  var screen = CGRect(x: 0, y: 0, width: 700, height: 900)
  dependencies.screenVisibleFrame = { screen }
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }
  #expect(controller.popover?.maximum.height == CGFloat.greatestFiniteMagnitude)

  NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

  await waitUntil { controller.popover?.maximum.width == 676 }
  #expect(controller.popover?.maximum.width == 676)

  screen.size.width = 800
  NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  await waitUntil { controller.popover?.maximum.width == 776 }

  #expect(controller.popover?.maximum.width == 776)
}

@Test @MainActor func appControllerDefersOpeningUntilTheStatusItemIsAttached() async throws {
  let clock = ManualClock()
  var (dependencies, _) = try makeDependencies(clock: clock.clock)
  dependencies.openPopoverOnLaunch = true
  dependencies.settings.detailedLogging = true
  dependencies.settings.lastLaunchedVersion = dependencies.appInfo.version
  let controller = AppController(dependencies: dependencies)

  controller.start()
  let window = detachedStatusWindow(holding: try #require(controller.statusItem?.item.button))
  var attached = false
  controller.statusItem?.visibleItemFrame = { _ in attached ? window.frame : nil }
  defer {
    controller.stop()
    window.orderOut(nil)
  }

  #expect(controller.popover?.isShown == false)
  await clock.advance(by: AppController.launchPopoverDelay) {
    clock.sleeps.contains(AppController.attachmentPollInterval)
  }
  #expect(controller.popover?.isShown == false)
  attached = true
  await clock.advance(by: AppController.attachmentPollInterval) { controller.popover?.isShown == true }
  #expect(controller.popover?.isShown == true, "\(dependencies.log.text)")
  let polls = clock.sleeps.count(where: { $0 == AppController.attachmentPollInterval })
  for _ in 0..<5 {
    clock.advance(by: AppController.attachmentPollInterval)
    await mainActorTurn()
  }
  #expect(clock.sleeps.count(where: { $0 == AppController.attachmentPollInterval }) == polls)
}

@Test @MainActor func openPopoverFollowsItsStatusWindowMovement() async throws {
  var (dependencies, _) = try makeDependencies()
  dependencies.settings.lastLaunchedVersion = dependencies.appInfo.version
  dependencies.screenVisibleFrame = { NSScreen.main?.visibleFrame }
  let controller = AppController(dependencies: dependencies)
  controller.start()
  let button = try #require(controller.statusItem?.item.button)
  let window = detachedStatusWindow(holding: button)
  defer {
    controller.stop()
    window.orderOut(nil)
  }
  controller.togglePopover()
  let popover = try #require(controller.popover)
  #expect(popover.isShown)
  let maximum = popover.maximum

  window.setFrameOrigin(CGPoint(x: window.frame.minX + 60, y: window.frame.minY - 80))
  NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
  await waitUntil { abs(popover.maximum.height - (maximum.height - 80)) < 1 }

  #expect(abs(popover.maximum.height - (maximum.height - 80)) < 1)
  #expect(popover.maximum.width == maximum.width)
  #expect(popover.popover.positioningRect == button.bounds)
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

  #expect(try JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: Data(contentsOf: url)) == expected)
  try FileManager.default.removeItem(at: url)

  DistributedNotificationCenter.default().post(
    name: LaunchPolicy.verificationSnapshotNotification,
    object: dependencies.verificationSession,
    userInfo: nil)

  await waitUntil { FileManager.default.fileExists(atPath: url.path) }
  let snapshot = try JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: Data(contentsOf: url))
  #expect(snapshot == expected)
}

@Test @MainActor func workspaceSleepAndWakeSuspendThenResumePolling() async throws {
  let probe = RediscoveryFetchProbe()
  let provider = RediscoveryProvider(
    id: .claude, health: .valid(source: ProviderID.claude.setup.credentialSources[0], expiresAt: nil),
    result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))), probe: probe)
  let clock = ManualClock()
  let (dependencies, _) = try makeDependencies(providers: [provider], clock: clock.clock)
  dependencies.settings.detailedLogging = true
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }

  await waitUntil { dependencies.state.state(for: .claude).lastAttempt != nil }
  let fetchesBeforeSleep = await probe.fetches

  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
  await waitUntil { !controller.coordinator.isRunning }
  #expect(!controller.coordinator.isRunning)

  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
  await waitUntil { controller.coordinator.isRunning }
  #expect(await probe.fetches == fetchesBeforeSleep)
  await clock.advance(by: RefreshCoordinator.wakeDelay) {
    dependencies.state.state(for: .claude).lastAttempt.map { $0 > fixedNow } == true
  }
  for _ in 0..<100 {
    if await probe.fetches > fetchesBeforeSleep { break }
    await mainActorTurn()
  }

  #expect(controller.coordinator.isRunning)
  #expect(await probe.fetches == fetchesBeforeSleep + 1)
  #expect(dependencies.log.text.contains("sleep: pausing refresh loop"))
  #expect(dependencies.log.text.contains("wake: resuming refresh loop"))
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
  let clock = ManualClock()
  let (dependencies, _) = try makeDependencies(history: history, clock: clock.clock)
  let controller = AppController(dependencies: dependencies)
  dependencies.settings.historyRetentionDays = 7

  controller.settingsChanged()
  await mainActorTurn()
  #expect(try await history.stats().sampleCount == 3)
  await clock.advance(by: AppController.retentionDebounce) {
    dependencies.log.text.contains("history retention updated days=7")
  }

  #expect(try await history.stats().sampleCount == 0)
  await waitUntil { dependencies.state.sampleRevision == 1 }
  #expect(dependencies.log.text.contains("history retention updated days=7 removed=3"))
}

@Test @MainActor func appControllerDoesNotPruneForASupersededRetentionChange() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.record(
    sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-30 * 86_400))
  let clock = ManualClock()
  let (dependencies, _) = try makeDependencies(history: history, clock: clock.clock)
  let controller = AppController(dependencies: dependencies)
  dependencies.settings.historyRetentionDays = 7
  controller.settingsChanged()

  dependencies.settings.historyRetentionDays = 60
  controller.settingsChanged()
  await mainActorTurn()
  clock.advance(by: AppController.retentionDebounce)
  await mainActorTurn()

  #expect(try await history.stats().sampleCount == 3)
  #expect(await history.retentionDays == 60)
  #expect(!dependencies.log.text.contains("history retention updated"))
}

@Test @MainActor func appControllerReportsHistoryRetentionFailures() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.breakDatabase()
  let clock = ManualClock()
  let (dependencies, _) = try makeDependencies(history: history, clock: clock.clock)
  let controller = AppController(dependencies: dependencies)
  dependencies.settings.historyRetentionDays = 7

  controller.settingsChanged()

  await clock.advance(by: AppController.retentionDebounce) {
    dependencies.log.text.contains("history retention update failed")
  }
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
  defer { controller.stop() }
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
  prepareTestApp()
  let (dependencies, _) = try makeDependencies()
  let gate = DeferredDependencyGate()
  var failure: String?
  let delegate = DeferredAppDelegate(presentsWindows: false, persistsStatusItemPosition: false) {
    try await gate.wait()
  } failureHandler: {
    failure = $0
  }
  delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
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
  let delegate = DeferredAppDelegate(presentsWindows: false, persistsStatusItemPosition: false) {
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
    defaults: testDefaults(), transport: NoNetworkTransport(),
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
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
    paths: LiveDependencies.Paths(home: root, supportDirectory: root, environment: [:], userName: "tester"),
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
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = LiveDependencies.Paths(
    home: root.appendingPathComponent("home"), supportDirectory: root.appendingPathComponent("support"),
    environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path], userName: "tester")
  let defaults = testDefaults()
  var openedReplacement = false
  let dependencies = try await LiveDependencies.make(
    appInfo: testAppInfo, paths: paths, defaults: defaults, notificationCenter: nil, updater: nil, isSandboxed: false,
    transport: NoNetworkTransport(), keychain: testKeychain,
    launchAtLogin: .inMemory(),
    workspaceOpen: { _, _, _ in openedReplacement = true })
  #expect(dependencies.registry.ids == [.antigravity, .claude, .codex, .copilot, .cursor, .gemini])
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
  let grantedDirectory = root.appendingPathComponent("granted")
  try FileManager.default.createDirectory(at: grantedDirectory, withIntermediateDirectories: true)
  let bookmark = try (grantedDirectory as NSURL).bookmarkData(
    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  #expect(
    LiveDependencies.resolve(bookmark: bookmark, fallback: fallback, log: log).resolvingSymlinksInPath()
      == grantedDirectory.resolvingSymlinksInPath())
  let settings = makeSettings()
  #expect(
    LiveDependencies.directory(codexHome, paths: paths, settings: settings, isSandboxed: false, log: log) == fallback)
  settings.setBookmark(bookmark, for: codexHome)
  #expect(
    LiveDependencies.directory(codexHome, paths: paths, settings: settings, isSandboxed: true, log: log) != fallback)
  // an explicit CODEX_HOME still wins over the bookmark
  let configuredCodex = root.appendingPathComponent("configured-codex")
  let configured = LiveDependencies.Paths(
    home: root, supportDirectory: root.appendingPathComponent("configured-support"),
    environment: ["CODEX_HOME": configuredCodex.path], userName: "tester")
  let sandboxedGraph = try await LiveDependencies.make(
    appInfo: testAppInfo, paths: configured, defaults: testDefaults(),
    notificationCenter: nil, isSandboxed: true, transport: NoNetworkTransport(), keychain: testKeychain,
    launchAtLogin: .inMemory())
  #expect(sandboxedGraph.registry[.codex]?.credentialDescription.contains(configuredCodex.path + "/auth.json") == true)
  #expect(sandboxedGraph.history.location == root.appendingPathComponent("configured-support/usage.sqlite"))
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
    defaults: testDefaults(), transport: NoNetworkTransport(),
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

/// Sleeps park on this clock until a test moves its reading past their deadline, so timers under test run without
/// wall-clock waits and everything else the controller schedules stays parked.
final class ManualClock: @unchecked Sendable {
  private struct Sleeper {
    let deadline: Date
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private var date = fixedNow
  private var sleepers: [UUID: Sleeper] = [:]
  private var cancelled: Set<UUID> = []
  private var recorded: [TimeInterval] = []

  var now: Date { lock.withLock { date } }
  var sleeps: [TimeInterval] { lock.withLock { recorded } }
  var clock: Clock { Clock(now: { self.now }, sleep: { try await self.sleep($0) }) }

  func sleep(_ interval: TimeInterval) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let parked = lock.withLock {
          recorded.append(interval)
          guard cancelled.remove(id) == nil else { return false }
          sleepers[id] = Sleeper(deadline: date.addingTimeInterval(interval), continuation: continuation)
          return true
        }
        if !parked { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      let sleeper = lock.withLock {
        guard let sleeper = sleepers.removeValue(forKey: id) else {
          cancelled.insert(id)
          return Sleeper?.none
        }
        return sleeper
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by interval: TimeInterval) {
    let ready = lock.withLock {
      date.addTimeInterval(interval)
      let ready = sleepers.filter { $0.value.deadline <= date }
      for id in ready.keys { sleepers.removeValue(forKey: id) }
      return ready.values.sorted { $0.deadline < $1.deadline }
    }
    for sleeper in ready { sleeper.continuation.resume() }
  }

  /// Keeps stepping the clock until the condition holds, because a sleeper only registers its deadline once the task
  /// that owns it has reached the sleep call.
  @MainActor
  @discardableResult
  func advance(by interval: TimeInterval, until condition: () -> Bool) async -> Bool {
    await waitUntil {
      advance(by: interval)
      return condition()
    }
  }
}

@Test @MainActor func reopenWaitsForTheStatusItemBeforeShowingThePopover() async throws {
  let clock = ManualClock()
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, _) = try makeDependencies(providers: [provider], clock: clock.clock)
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }

  controller.reopen()

  await clock.advance(by: AppController.attachmentPollInterval) {
    clock.sleeps.contains(AppController.attachmentPollInterval)
  }
  #expect(controller.popover?.isShown == false)
}

@Test @MainActor func openingANotificationSelectsTheUsageTabAndReopens() throws {
  let (controller, dependencies, _) = try startedController()
  defer { controller.stop() }
  dependencies.settings.lastTab = .history

  dependencies.notifier.onResponse?()

  #expect(dependencies.settings.lastTab == .usage)
  #expect(dependencies.log.text.contains("notification opened"))
}

@Test @MainActor func popoverScreenLookupPrefersTheWindowThenTheAnchor() throws {
  let screen = try #require(NSScreen.screens.first)
  let inside = screen.frame.insetBy(dx: 10, dy: 10)
  let justAbove = CGRect(x: screen.frame.midX, y: screen.frame.maxY + 50, width: 10, height: 10)
  let far = CGRect(x: -100_000, y: -100_000, width: 10, height: 10)

  #expect(AppController.screen(near: nil, preferred: screen, among: []) === screen)
  #expect(AppController.screen(near: nil, preferred: nil, among: [screen]) == nil)
  #expect(AppController.screen(near: inside, preferred: nil, among: [screen]) === screen)
  #expect(AppController.screen(near: justAbove, preferred: nil, among: [screen]) === screen)
  #expect(AppController.screen(near: far, preferred: nil, among: [screen]) == nil)
}

@Test @MainActor func enablingNotificationsLaterRequestsAuthorization() async throws {
  let (dependencies, _) = try makeDependencies()
  dependencies.settings.notifications.enabled = false
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }
  await mainActorTurn()
  #expect(!dependencies.notifier.authorized)

  dependencies.settings.notifications.enabled = true
  controller.settingsChanged()

  await waitUntil { dependencies.notifier.authorized }
  #expect(dependencies.notifier.authorized)
}

@MainActor
private final class ContrastFlag {
  var value = false
}

@Test @MainActor func appControllerFollowsTheIncreaseContrastSetting() async throws {
  var (dependencies, _) = try makeDependencies()
  let flag = ContrastFlag()
  dependencies.increaseContrast = { flag.value }
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }
  #expect(!controller.environment.increaseContrast)

  flag.value = true
  NSWorkspace.shared.notificationCenter.post(
    name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

  #expect(await waitUntil { controller.environment.increaseContrast })
}

@Test @MainActor func appControllerDeliversNotificationsWithTheCurrentSoundSetting() async throws {
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .notAuthenticated("expired")))
  let (dependencies, _) = try makeDependencies(providers: [provider])
  dependencies.settings.notifications.playSound = false
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }

  #expect(await waitUntil { dependencies.notifier.delivered.contains { $0.kind == .authentication } })
  #expect(!dependencies.notifier.playSound)
}

@Test @MainActor func retryOpeningCollapsesTheStatusItemOnTheTwelfthAttempt() throws {
  let (controller, _, _) = try startedController()
  defer { controller.stop() }

  #expect(!controller.retryOpening(remainingAttempts: 12, previousButtonFrame: nil, forcedNarrowest: false))
}
