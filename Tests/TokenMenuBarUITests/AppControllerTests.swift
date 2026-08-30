import AppKit
import Testing
import TokenMenuBarCore
import UserNotifications

@testable import TokenMenuBarUI

@MainActor
private func startedController() throws -> (AppController, AppDependencies, Recorder) {
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, recorder) = try makeDependencies(providers: [provider])
  dependencies.settings.lastLaunchedVersion = "0.9"
  dependencies.settings.detailedLogging = true
  let controller = AppController(dependencies: dependencies)
  controller.start()
  return (controller, dependencies, recorder)
}

@Test @MainActor func appControllerStartInstallsTheStatusItemAndRecordsTheUpgrade() throws {
  let (controller, dependencies, _) = try startedController()
  #expect(controller.environment.credentialDescriptions == [.claude: "scripted claude"])
  #expect(controller.environment.canCheckForUpdates)
  #expect(controller.statusItem != nil)
  #expect(controller.popover != nil)
  #expect(dependencies.settings.lastLaunchedVersion == "1.2.3")
  #expect(dependencies.log.text.contains("updated from 0.9"))
}

@Test @MainActor func appControllerRefreshFeedsTheStatusItem() async throws {
  let (controller, dependencies, _) = try startedController()
  await controller.coordinator.refresh(RefreshRequest(force: true))
  try await Task.sleep(for: .milliseconds(50))
  #expect(dependencies.state.state(for: .claude).availability == .current)
  #expect(!dependencies.state.statusModel.cells.isEmpty)
  #expect(controller.statusItem?.model.cells.count == dependencies.state.statusModel.cells.count)
}

@Test @MainActor func appControllerTogglesThePopover() async throws {
  let (controller, dependencies, _) = try startedController()
  controller.togglePopover()
  #expect(dependencies.state.popoverVisible == controller.popover?.isShown)
  controller.popover?.close()
  try await Task.sleep(for: .milliseconds(50))
  #expect(controller.popover?.isShown == false)
}

@Test @MainActor func appControllerSuspendsPollingWhileTheMacSleeps() async throws {
  let (controller, dependencies, _) = try startedController()
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
  let menu = controller.contextMenu()
  #expect(menu.items.count == 7)
  _ = menu.items[0].target?.perform(menu.items[0].action, with: menu.items[0])
  _ = menu.items[2].target?.perform(menu.items[2].action, with: menu.items[2])
  #expect(recorder.urls == [ProviderID.claude.usagePage])
  _ = menu.items[4].target?.perform(menu.items[4].action, with: menu.items[4])
  #expect((dependencies.updater as? FakeUpdater)?.checks == 1)
  _ = menu.items[6].target?.perform(menu.items[6].action, with: menu.items[6])
  #expect(recorder.terminated == 1)
}

@Test @MainActor func appControllerIgnoresCommandsItDoesNotKnow() throws {
  let (controller, _, recorder) = try startedController()
  controller.menuTarget.run(NSMenuItem(title: "x", action: nil, keyEquivalent: ""))
  controller.run("usage:nope")
  #expect(recorder.urls.isEmpty)
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
  #expect(controller.contextMenu().items.count == 4)
  controller.environment.actions.checkForUpdates()
  controller.environment.actions.quit()
}

@Test @MainActor func appControllerActionsRouteToDependencies() async throws {
  let (dependencies, recorder) = try makeDependencies()
  let controller = AppController(dependencies: dependencies)
  let actions = controller.environment.actions
  actions.openURL(URL(string: "https://example.com")!)
  actions.copy("text")
  #expect(recorder.urls.first?.host == "example.com")
  #expect(recorder.copied == ["text"])
  await controller.exportHistory().value
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-export-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  recorder.exportURL = directory.appendingPathComponent("history.csv")
  await controller.exportHistory().value
  #expect(try String(contentsOf: recorder.exportURL!, encoding: .utf8).hasPrefix("timestamp,"))
  recorder.exportURL = URL(fileURLWithPath: "/dev/null/impossible.csv")
  await controller.exportHistory().value
  #expect(dependencies.log.text.contains("export failed"))
  await controller.clearHistory().value
  #expect(dependencies.log.text.contains("history cleared"))
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
  #expect(recorder.rebuilt == 1)
  #expect(dependencies.settings.bookmark(for: codexHome) != nil)
  #expect(controller.environment.credentialDescriptions == [.codex: "scripted codex"])
  recorder.codexHome = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
  actions.grantAccess(codexHome)
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

@Test @MainActor func liveDependenciesBuildRealGraph() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-live-\(UUID().uuidString)")
  let paths = LiveDependencies.Paths(
    home: root.appendingPathComponent("home"), supportDirectory: root.appendingPathComponent("support"),
    environment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path], userName: "tester")
  let defaults = UserDefaults(suiteName: "live-\(UUID().uuidString)")!
  let dependencies = try LiveDependencies.make(
    appInfo: testAppInfo, paths: paths, defaults: defaults, notificationCenter: nil, updater: nil, isSandboxed: false)
  #expect(dependencies.registry.ids == [.claude, .codex, .copilot, .cursor, .gemini])
  #expect(dependencies.history.location?.lastPathComponent == "usage.sqlite")
  #expect(dependencies.registry[.codex]?.credentialDescription.hasSuffix(".codex/auth.json") == true)
  #expect(dependencies.registry[.claude]?.credentialDescription.contains("Claude Code-credentials-") == true)
  #expect(dependencies.registry[.claude]?.credentialState(now: fixedNow).isUsable == false)
  #expect(dependencies.registry[.codex]?.credentialState(now: fixedNow).isUsable == false)
  _ = dependencies.rebuildProviders(dependencies.settings)
  let controller = AppController(dependencies: dependencies)
  #expect(controller.environment.isSandboxed == false)
  let sandboxed = try LiveDependencies.make(
    appInfo: testAppInfo, paths: paths, defaults: defaults, notificationCenter: nil, isSandboxed: true)
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
  let sandboxedGraph = try LiveDependencies.make(
    appInfo: testAppInfo, paths: configured, defaults: UserDefaults(suiteName: "cfg-\(UUID().uuidString)")!,
    notificationCenter: nil, isSandboxed: true)
  #expect(sandboxedGraph.registry[.codex]?.credentialDescription == "/tmp/cx/auth.json")
  #expect(
    ProviderID.claude.sandboxResources[1].configuredURL(environment: [:], home: root).lastPathComponent
      == ".claude.json")
  // a stored bookmark replaces the configured path when the build is sandboxed
  let bookmarked = makeSettings()
  bookmarked.setBookmark(bookmark, for: codexHome)
  let redirected = LiveDependencies.providers(
    paths: paths, client: APIClient(transport: URLSession.shared, log: log), log: log, settings: bookmarked,
    isSandboxed: true)
  #expect(redirected[.codex]?.credentialDescription.hasSuffix("/auth.json") == true)
  #expect(redirected[.codex]?.credentialDescription.contains(paths.home.path) == false)
  let home = LiveDependencies.Paths()
  #expect(home.userName == NSUserName())
  #expect(ProviderID.allSandboxResources.count >= ProviderID.allCases.count)
  #expect(ProviderID.cursor.sandboxResources.map(\.label).contains("~/.cursor"))
}

@Test @MainActor func appRunnerBootstrapsAgainstTemporaryDefaults() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-runner-\(UUID().uuidString)")
  let paths = LiveDependencies.Paths(
    home: root, supportDirectory: root.appendingPathComponent("support"), environment: [:], userName: "tester")
  let delegate = try AppRunner.bootstrap(
    isAppStore: true, notificationCenter: nil, updater: FakeUpdater(), isSandboxed: false, paths: paths,
    defaults: UserDefaults(suiteName: "runner-\(UUID().uuidString)")!)
  #expect(delegate.controller.dependencies.appInfo.isAppStore)
  #expect(delegate.controller.environment.canCheckForUpdates)
}
