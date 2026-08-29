import AppKit
import Testing
import TokenMenuBarCore
import UserNotifications

@testable import TokenMenuBarUI

@MainActor
private func makeDependencies(
  providers: [any UsageProvider] = [], updater: FakeUpdater? = FakeUpdater(), history: UsageHistoryStore? = nil
) throws -> (AppDependencies, Recorder) {
  let recorder = Recorder()
  let history = try history ?? UsageHistoryStore(url: nil)
  let settings = makeSettings()
  let dependencies = AppDependencies(
    appInfo: testAppInfo,
    settings: settings,
    state: AppState(),
    history: history,
    log: makeLog(),
    registry: ProviderRegistry(providers),
    notifier: Notifier(center: FakeNotificationCenter(), log: makeLog()),
    launchAtLogin: LaunchAtLoginBackend(
      status: { .notRegistered }, register: {}, unregister: {},
      openSettings: { MainActor.assumeIsolated { recorder.openedLoginItems += 1 } }),
    clock: sleepingClock,
    updater: updater,
    isSandboxed: true,
    openURL: { recorder.urls.append($0) },
    copyToPasteboard: { recorder.copied.append($0) },
    revealInFinder: { recorder.revealed.append($0) },
    chooseExportURL: { recorder.exportURL },
    chooseCodexHome: { recorder.codexHome },
    terminate: { recorder.terminated += 1 },
    rebuildProviders: { _ in
      recorder.rebuilt += 1
      return ProviderRegistry([
        StaticProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex))))
      ])
    },
    screenVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) }
  )
  return (dependencies, recorder)
}

@MainActor
final class Recorder {
  var urls: [URL] = []
  var copied: [String] = []
  var revealed: [URL] = []
  var exportURL: URL?
  var codexHome: URL?
  var terminated = 0
  var rebuilt = 0
  var openedLoginItems = 0
}

@Test @MainActor func appControllerStartsRefreshesAndStops() async throws {
  let provider = StaticProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, recorder) = try makeDependencies(providers: [provider])
  dependencies.settings.lastLaunchedVersion = "0.9"
  dependencies.settings.detailedLogging = true
  let controller = AppController(dependencies: dependencies)
  #expect(controller.environment.credentialDescriptions == [.claude: "static claude"])
  #expect(controller.environment.canCheckForUpdates)
  controller.start()
  #expect(controller.statusItem != nil)
  #expect(controller.popover != nil)
  #expect(dependencies.settings.lastLaunchedVersion == "1.2.3")
  #expect(dependencies.log.text.contains("updated from 0.9"))
  await controller.coordinator.refresh(RefreshRequest(force: true))
  try await Task.sleep(for: .milliseconds(50))
  #expect(dependencies.state.state(for: .claude).availability == .current)
  #expect(!dependencies.state.statusModel.cells.isEmpty)
  #expect(controller.statusItem?.model.cells.count == dependencies.state.statusModel.cells.count)
  controller.togglePopover()
  #expect(controller.popover?.isShown == true)
  #expect(dependencies.state.popoverVisible)
  controller.togglePopover()
  try await Task.sleep(for: .milliseconds(50))
  #expect(controller.popover?.isShown == false)
  controller.handleSleep()
  #expect(!controller.coordinator.isRunning)
  controller.handleWake()
  #expect(controller.coordinator.isRunning)
  controller.refreshNow()
  controller.settingsChanged()
  #expect((dependencies.updater as? FakeUpdater)?.automaticallyChecks == true)
  let menu = controller.contextMenu()
  #expect(menu.items.count == 8)
  _ = menu.items[0].target?.perform(menu.items[0].action, with: menu.items[0])
  _ = menu.items[2].target?.perform(menu.items[2].action, with: menu.items[2])
  #expect(recorder.urls == [ProviderID.claude.usagePage])
  _ = menu.items[5].target?.perform(menu.items[5].action, with: menu.items[5])
  #expect((dependencies.updater as? FakeUpdater)?.checks == 1)
  _ = menu.items[7].target?.perform(menu.items[7].action, with: menu.items[7])
  #expect(recorder.terminated == 1)
  let stray = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
  controller.menuTarget.openProvider(stray)
  #expect(recorder.urls.count == 1)
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
  await Task.yield()
  controller.stop()
  #expect(controller.statusItem == nil)
  #expect(!controller.coordinator.isRunning)
  #expect(dependencies.log.text.contains("stopped"))
}

@Test @MainActor func appControllerWithoutUpdaterHidesUpdateItems() throws {
  let (dependencies, _) = try makeDependencies(updater: nil)
  let controller = AppController(dependencies: dependencies)
  #expect(!controller.environment.canCheckForUpdates)
  #expect(controller.contextMenu().items.count == 6)
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
  actions.grantCodexAccess()
  #expect(recorder.rebuilt == 0)
  recorder.codexHome = FileManager.default.temporaryDirectory
  actions.grantCodexAccess()
  #expect(recorder.rebuilt == 1)
  #expect(dependencies.settings.codexHomeBookmark != nil)
  #expect(controller.environment.credentialDescriptions == [.codex: "static codex"])
  recorder.codexHome = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
  actions.grantCodexAccess()
  #expect(dependencies.log.text.contains("bookmark failed"))
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
  #expect(dependencies.registry.ids == [.claude, .codex])
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
  #expect(LiveDependencies.codexHome(paths: paths, bookmark: nil, log: log).path.hasSuffix(".codex"))
  #expect(LiveDependencies.codexHome(paths: paths, bookmark: Data([1, 2, 3]), log: log).path.hasSuffix(".codex"))
  #expect(log.text.contains("could not be resolved"))
  let bookmark = try (FileManager.default.temporaryDirectory as NSURL).bookmarkData(
    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  #expect(
    LiveDependencies.codexHome(paths: paths, bookmark: bookmark, log: log).path.contains(
      FileManager.default.temporaryDirectory.lastPathComponent))
  let home = LiveDependencies.Paths()
  #expect(home.userName == NSUserName())
  #expect(
    LiveDependencies.codexHome(
      paths: LiveDependencies.Paths(home: root, environment: ["CODEX_HOME": "/tmp/cx"]), bookmark: nil, log: log
    ).path == "/tmp/cx")
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
