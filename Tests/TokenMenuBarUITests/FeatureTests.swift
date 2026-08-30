import AppKit
import SwiftUI
import Testing
import WidgetKit

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@MainActor
private final class FeatureRecorder {
  var relaunched = 0
  var reloadedWidgets = 0
}

@MainActor
private func makeFeatureDependencies(
  providers: [any UsageProvider] = [], widgetStore: WidgetSnapshotStore? = nil, isDemo: Bool = false
) throws -> (AppDependencies, FeatureRecorder) {
  let recorder = FeatureRecorder()
  let dependencies = AppDependencies(
    appInfo: testAppInfo,
    settings: makeSettings(),
    state: AppState(),
    history: try UsageHistoryStore(url: nil),
    log: makeLog(),
    registry: ProviderRegistry(providers),
    notifier: Notifier(center: nil, log: makeLog()),
    launchAtLogin: LaunchAtLoginBackend(status: { .notRegistered }, register: {}, unregister: {}),
    clock: sleepingClock,
    isDemo: isDemo,
    openURL: { _ in },
    copyToPasteboard: { _ in },
    revealInFinder: { _ in },
    chooseExportURL: { nil },
    chooseDirectory: { _ in nil },
    terminate: {},
    relaunch: { recorder.relaunched += 1 },
    widgetStore: widgetStore,
    reloadWidgets: { recorder.reloadedWidgets += 1 },
    rebuildProviders: { _ in ProviderRegistry([]) },
    screenVisibleFrame: { nil }
  )
  return (dependencies, recorder)
}

@Test @MainActor func demoModeTogglesSettingsAndRelaunches() throws {
  let (dependencies, recorder) = try makeFeatureDependencies(isDemo: true)
  let controller = AppController(dependencies: dependencies)
  #expect(controller.environment.isDemo)
  controller.environment.actions.setDemoMode(true)
  #expect(dependencies.settings.demoMode)
  #expect(recorder.relaunched == 1)
  #expect(dependencies.log.text.contains("demo mode on"))
  let tab = SettingsTab(environment: controller.environment)
  _ = host(tab, width: 760, height: 900)
  let usage = UsageTab(environment: controller.environment)
  _ = host(usage, width: 760, height: 600)
}

@Test @MainActor func widgetSnapshotsArePublishedOnStatusRebuild() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-widget-\(UUID().uuidString)")
  let store = WidgetSnapshotStore(url: root.appendingPathComponent("widget.json"))
  let provider = StaticProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, recorder) = try makeFeatureDependencies(providers: [provider], widgetStore: store)
  let controller = AppController(dependencies: dependencies)
  // one publish when the sink attaches to the empty model, one when the refresh lands
  #expect(recorder.reloadedWidgets == 1)
  await controller.coordinator.refresh(RefreshRequest(force: true))
  #expect(store.read()?.rows.isEmpty == false)
  #expect(recorder.reloadedWidgets == 2)
  controller.coordinator.rebuildStatus()
  #expect(recorder.reloadedWidgets == 2)
  controller.publishWidget(WidgetSnapshot(rows: [], attention: false, updatedAt: fixedNow))
  #expect(store.read()?.rows.isEmpty == true)
  let unwritable = WidgetSnapshotStore(url: URL(fileURLWithPath: "/dev/null/widget.json"))
  let (failing, _) = try makeFeatureDependencies(widgetStore: unwritable)
  let failingController = AppController(dependencies: failing)
  failingController.publishWidget(.placeholder)
  #expect(failing.log.text.contains("widget snapshot write failed"))
  let (none, noneRecorder) = try makeFeatureDependencies()
  AppController(dependencies: none).publishWidget(.placeholder)
  #expect(noneRecorder.reloadedWidgets == 0)
}

@Test @MainActor func statusItemLadderStepsDownWhenHidden() async throws {
  let controller = StatusItemController(log: makeLog(), tickInterval: 0.01) { _ in }
  defer { controller.remove() }
  let ladder = StatusItemBuilder.candidates(
    StatusItemInput(
      snapshots: [.claude: sampleSnapshot(.claude), .codex: sampleSnapshot(.codex, percent: 80)],
      availability: [.claude: .current, .codex: .current],
      selectedKeys: StatusItemBuilder.defaultSelection([
        .claude: sampleSnapshot(.claude), .codex: sampleSnapshot(.codex),
      ]),
      format: .stacked, customTemplate: "", decimals: 0, hideZeroCells: true, order: .provider, labels: [:],
      now: fixedNow))
  controller.frontmostContext = { "test.app" }
  controller.fitCheckDelay = .milliseconds(5)
  controller.visibleItemFrame = { _ in CGRect(x: 500, y: 0, width: 80, height: 30) }
  controller.notchAreas = {
    (CGRect(x: 0, y: 0, width: 10, height: 30), CGRect(x: 100_000, y: 0, width: 10, height: 30))
  }
  controller.update(ladder: ladder)
  #expect(controller.ladder.count == ladder.count)
  #expect(controller.model == ladder[0])
  await controller.settleFitCheck()
  #expect(controller.model == controller.ladder[1])
  controller.update(ladder: ladder)
  #expect(!controller.checkFit())
  #expect(controller.model == controller.ladder[1])
  while controller.checkFit() == false, controller.model != controller.ladder.last! {}
  #expect(controller.model.cells.isEmpty)
  #expect(!controller.checkFit())
  controller.notchAreas = { (nil, nil) }
  controller.update(ladder: ladder)
  #expect(controller.model == ladder[0])
  #expect(controller.checkFit())
  controller.visibleItemFrame = { _ in nil }
  controller.layoutChanged(forgetting: false)
  // each failed fit schedules the next check, so wait for the ladder to settle rather than a single tick
  for _ in 0..<50 where controller.model == ladder[0] { await controller.settleFitCheck() }
  #expect(controller.model != ladder[0])
  // space came back, so the next layout pass probes a wider tier again
  controller.visibleItemFrame = { _ in CGRect(x: 500, y: 0, width: 80, height: 30) }
  controller.layoutChanged(forgetting: false)
  #expect(controller.checkFit())
  controller.layoutChanged(forgetting: true)
  #expect(controller.model == ladder[0])
  await controller.settleFitCheck()
  controller.adaptive = false
  controller.update(ladder: ladder)
  #expect(controller.model == ladder[0])
  controller.update(.empty)
  #expect(controller.ladder == [.empty])
  NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
  await Task.yield()
}

@Test @MainActor func onScreenFrameRequiresAVisibleWindowInsideAScreen() {
  #expect(StatusItemController.onScreenFrame(of: nil) == nil)
  let window = NSWindow(
    contentRect: NSRect(x: 10, y: 10, width: 50, height: 20), styleMask: [.borderless], backing: .buffered, defer: false
  )
  window.isReleasedWhenClosed = false
  #expect(StatusItemController.onScreenFrame(of: window) == nil)
  window.orderFrontRegardless()
  let screens = NSScreen.screens
  #expect(StatusItemController.onScreenFrame(of: window, screens: screens) == window.frame)
  window.setFrameOrigin(NSPoint(x: 100_000, y: 10))
  #expect(StatusItemController.onScreenFrame(of: window, screens: screens) == nil)
  window.setFrameOrigin(NSPoint(x: (screens.first?.frame.maxX ?? 0) - 10, y: 10))
  #expect(StatusItemController.onScreenFrame(of: window, screens: screens) == window.frame)
  window.setFrame(NSRect(x: 10, y: 10, width: 0, height: 20), display: false)
  #expect(StatusItemController.onScreenFrame(of: window, screens: screens) == nil)
  window.orderOut(nil)
}

@Test @MainActor func liveDependenciesBuildDemoGraph() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-demo-\(UUID().uuidString)")
  let paths = LiveDependencies.Paths(
    home: root.appendingPathComponent("home"), supportDirectory: root.appendingPathComponent("support"),
    environment: ["TOKEN_MENU_BAR_DEMO": "1"], userName: "tester", arguments: [])
  #expect(paths.demoRequested)
  #expect(LiveDependencies.Paths(environment: [:], arguments: ["app", "--demo"]).demoRequested)
  #expect(!LiveDependencies.Paths(environment: [:], arguments: ["app"]).demoRequested)
  let defaults = UserDefaults(suiteName: "demo-\(UUID().uuidString)")!
  let dependencies = try LiveDependencies.make(
    appInfo: testAppInfo, paths: paths, defaults: defaults, notificationCenter: nil, updater: nil, isSandboxed: false)
  #expect(dependencies.isDemo)
  #expect(dependencies.widgetStore == nil)
  #expect(dependencies.history.location?.lastPathComponent == "usage-demo.sqlite")
  #expect(dependencies.registry.providers.allSatisfy { $0.credentialDescription == "Demo data" })
  #expect(dependencies.rebuildProviders(dependencies.settings).ids == ProviderID.allCases.sorted())
  #expect(dependencies.settings.enabledProviders == Set(ProviderID.allCases))
  for _ in 0..<200 where try await dependencies.history.stats().sampleCount == 0 {
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(try await dependencies.history.stats().sampleCount > 0)
  LiveDependencies.seedDemo(dependencies.history, log: dependencies.log)
  try await Task.sleep(for: .milliseconds(100))
  let broken = try UsageHistoryStore(url: nil)
  try await broken.breakDatabase()
  LiveDependencies.seedDemo(broken, log: dependencies.log)
  try await Task.sleep(for: .milliseconds(100))
  #expect(dependencies.log.text.contains("demo history seeding failed"))
  let settings = makeSettings()
  settings.demoMode = true
  let viaSetting = try LiveDependencies.make(
    appInfo: testAppInfo,
    paths: LiveDependencies.Paths(
      home: root, supportDirectory: root, environment: [:], userName: "tester", arguments: []),
    defaults: UserDefaults(suiteName: "demo-\(UUID().uuidString)")!, notificationCenter: nil, updater: nil,
    isSandboxed: false)
  #expect(!viaSetting.isDemo)
}

@Test @MainActor func widgetStoreAndRelaunchHelpers() async {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-helpers-\(UUID().uuidString)")
  #expect(
    LiveDependencies.widgetStore(supportDirectory: root, containerURL: { _ in nil }).url
      == root.appendingPathComponent("widget.json"))
  #expect(LiveDependencies.widgetStore(supportDirectory: root).url.lastPathComponent == "widget.json")
  let fake = root.appendingPathComponent("Fake.app")
  try? FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
  let bundle = Bundle(url: fake)!
  let terminated = await withCheckedContinuation { continuation in
    LiveDependencies.relaunch(bundle: bundle, workspace: NSWorkspace.shared) { continuation.resume(returning: true) }
  }
  #expect(terminated)
}

@Test @MainActor func dependencyDefaultsAreInert() async throws {
  let dependencies = AppDependencies(
    appInfo: testAppInfo, settings: makeSettings(), state: AppState(), history: try UsageHistoryStore(url: nil),
    log: makeLog(), registry: ProviderRegistry([]), notifier: Notifier(center: nil, log: makeLog()),
    launchAtLogin: LaunchAtLoginBackend(status: { .notRegistered }, register: {}, unregister: {}),
    openURL: { _ in }, copyToPasteboard: { _ in }, revealInFinder: { _ in }, chooseExportURL: { nil },
    chooseDirectory: { _ in nil }, terminate: {}, rebuildProviders: { _ in ProviderRegistry([]) },
    screenVisibleFrame: { nil })
  dependencies.relaunch()
  dependencies.reloadWidgets()
  #expect(dependencies.widgetStore == nil)
  UIActions().setDemoMode(true)
  let controller = AppController(dependencies: dependencies)
  controller.refreshIfStale()
  for _ in 0..<100 where dependencies.state.lastRefresh == nil { try await Task.sleep(for: .milliseconds(20)) }
  #expect(dependencies.state.lastRefresh != nil)
}

@Test @MainActor func helperViewsHost() {
  _ = host(
    HelpText("A fairly long explanation that needs to wrap across several lines inside the popover."), width: 300,
    height: 100)
  _ = host(EmptyStateView(title: "Nothing", systemImage: "hourglass", description: "Waiting"), width: 300, height: 100)
  var measured: [(String, CGSize)] = []
  let environment = try! makeEnvironment()
  let root = RootView(environment: environment, onMeasure: { measured.append(($0, $1)) }, onTabChange: { _ in })
  root.measured(.zero)
  #expect(measured.isEmpty)
  root.measured(CGSize(width: 10, height: 20))
  #expect(measured.last?.1.height == 20 + PopoverGeometry.chromeHeight)
  #expect(ChromeSizeKey.defaultValue == .zero)
  var value = CGSize(width: 1, height: 1)
  ChromeSizeKey.reduce(value: &value) { .zero }
  #expect(value == CGSize(width: 1, height: 1))
  ChromeSizeKey.reduce(value: &value) { CGSize(width: 2, height: 2) }
  #expect(value == CGSize(width: 2, height: 2))
}
