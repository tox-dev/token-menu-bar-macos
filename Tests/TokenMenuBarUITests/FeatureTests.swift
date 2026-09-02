import AppKit
import SwiftUI
import Testing
import WidgetKit

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func demoModeTogglesSettingsAndRelaunches() throws {
  let (dependencies, recorder) = try makeDependencies(isDemo: true)
  let controller = AppController(dependencies: dependencies)
  #expect(controller.environment.isDemo)
  controller.environment.actions.setDemoMode(false)
  #expect(dependencies.settings.demoMode == false)
  #expect(!controller.environment.isDemo)
  #expect(recorder.relaunched == 1)
  #expect(dependencies.log.text.contains("demo mode off"))
  #expect(inkFraction(SettingsTab(environment: controller.environment), width: 760, height: 900) > 0)
  let usage = UsageTab(environment: controller.environment)
  #expect(inkFraction(usage, width: 760, height: 600) > 0)
}

@Test @MainActor func widgetSnapshotsArePublishedOnStatusRebuild() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-widget-\(UUID().uuidString)")
  let store = WidgetSnapshotStore(url: root.appendingPathComponent("widget.json"))
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, recorder) = try makeDependencies(providers: [provider], widgetStore: store)
  dependencies.settings.setProvider(.claude, enabled: true)
  let controller = AppController(dependencies: dependencies)
  // one publish when the sink attaches to the empty model, one when the refresh lands
  await controller.flushPersistence()
  #expect(recorder.reloadedWidgets == 1)
  await controller.coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  await controller.flushPersistence()
  #expect(store.read()?.rows.isEmpty == false)
  #expect(recorder.reloadedWidgets == 2)
  controller.coordinator.rebuildStatus()
  await controller.flushPersistence()
  #expect(recorder.reloadedWidgets == 2)
  controller.publishWidget(WidgetSnapshot(rows: [], attention: false, updatedAt: fixedNow))
  await controller.flushPersistence()
  #expect(store.read()?.rows.isEmpty == true)
  let unwritable = WidgetSnapshotStore(url: URL(fileURLWithPath: "/dev/null/widget.json"))
  let (failing, _) = try makeDependencies(widgetStore: unwritable)
  let failingController = AppController(dependencies: failing)
  failingController.publishWidget(.placeholder)
  await failingController.flushPersistence()
  #expect(failing.log.text.contains("widget snapshot write failed"))
  let (none, noneRecorder) = try makeDependencies()
  AppController(dependencies: none).publishWidget(.placeholder)
  #expect(noneRecorder.reloadedWidgets == 0)
}

@Test @MainActor func lifecycleFlushesTheFinalCacheAndWidgetOffMain() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-lifecycle-\(UUID().uuidString)")
  let cache = SnapshotCache(url: root.appendingPathComponent("snapshots.json"))
  let widget = WidgetSnapshotStore(url: root.appendingPathComponent("widget.json"))
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, recorder) = try makeDependencies(
    providers: [provider], widgetStore: widget, snapshotCache: cache)
  dependencies.settings.setProvider(.claude, enabled: true)
  let controller = AppController(dependencies: dependencies)
  await controller.coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  controller.handleSleep()
  await controller.prepareToTerminate()
  #expect(cache.load()[.claude]?.windows.isEmpty == false)
  #expect(widget.read()?.rows.isEmpty == false)
  #expect(recorder.reloadedWidgets == 2)
}

@Test @MainActor func statusItemLadderStepsDownWhenHidden() async throws {
  let controller = StatusItemController(log: makeLog(), diagnosticProbeInterval: 0.01) { _ in }
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
  #expect(
    controller.ladder.count
      == AdaptiveWidthPlanner.ladder(
        ladder,
        widths: ladder.map {
          Double(
            StatusItemRenderer.attributedTitle(for: $0, height: controller.barHeight, dark: controller.isDark).size()
              .width)
        }
      ).count)
  #expect(controller.model == ladder[0])
  // each failed fit schedules the next check, so wait for the ladder to settle rather than a single tick
  for _ in 0..<50 where controller.model == ladder[0] { await controller.settleFitCheck() }
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
  window.alphaValue = 0
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
  let dependencies = try await LiveDependencies.make(
    appInfo: testAppInfo, paths: paths, defaults: defaults, notificationCenter: nil, updater: nil, isSandboxed: false,
    transport: NoNetworkTransport(), keychain: testKeychain, launchAtLogin: .inMemory())
  #expect(dependencies.isDemo)
  #expect(dependencies.widgetStore == nil)
  #expect(dependencies.history.location?.lastPathComponent == "usage-demo.sqlite")
  #expect(dependencies.registry.providers.allSatisfy { $0.credentialDescription == "Demo data" })
  #expect(await dependencies.rebuildProviders(dependencies.settings).ids == ProviderID.allCases.sorted())
  #expect(dependencies.settings.enabledProviders == Set(ProviderID.allCases))
  while try await dependencies.history.stats().sampleCount == 0 { await Task.yield() }
  #expect(try await dependencies.history.stats().sampleCount > 0)
  await LiveDependencies.seedDemo(dependencies.history, log: dependencies.log).value
  let broken = try UsageHistoryStore(url: nil)
  try await broken.breakDatabase()
  await LiveDependencies.seedDemo(broken, log: dependencies.log).value
  #expect(dependencies.log.text.contains("demo history seeding failed"))
  let settings = makeSettings()
  settings.demoMode = true
  let viaSetting = try await LiveDependencies.make(
    appInfo: testAppInfo,
    paths: LiveDependencies.Paths(
      home: root, supportDirectory: root, environment: [:], userName: "tester", arguments: []),
    defaults: UserDefaults(suiteName: "demo-\(UUID().uuidString)")!, notificationCenter: nil, updater: nil,
    isSandboxed: false, transport: NoNetworkTransport(), keychain: testKeychain, launchAtLogin: .inMemory())
  #expect(!viaSetting.isDemo)
}

@Test @MainActor func liveDependenciesBuildIsolatedControlAuditGraph() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-control-audit-\(UUID().uuidString)")
  let support = root.appendingPathComponent("support")
  let dependencies = try await LiveDependencies.make(
    appInfo: testAppInfo,
    paths: LiveDependencies.Paths(
      home: root, supportDirectory: support, environment: ["TOKEN_MENU_BAR_DEMO": "1"], userName: "verification",
      arguments: [], verificationProfile: VerificationProfile(fixture: .controlAudit)),
    defaults: UserDefaults(suiteName: "control-audit-\(UUID().uuidString)")!, notificationCenter: nil, updater: nil,
    isSandboxed: false, transport: NoNetworkTransport(), keychain: testKeychain, launchAtLogin: .inMemory())

  #expect(dependencies.isDemo)
  #expect(dependencies.isSandboxed)
  #expect(
    dependencies.registry.setupStates.values.flatMap(\.resources).count
      == ProviderID.allCases.flatMap(\.sandboxResources).count)
  #expect(dependencies.launchAtLogin.status() == .notRegistered)
  #expect(dependencies.launchAtLogin.setEnabled(true) == .enabled)
  #expect(dependencies.launchAtLogin.setEnabled(false) == .notRegistered)
  #expect(dependencies.chooseDirectory(ProviderID.codex.sandboxResources[0]) == nil)
  #expect(dependencies.chooseExportURL() == support.appendingPathComponent("verification-history.csv"))
}

@Test @MainActor func widgetStoreAndRelaunchHelpers() async {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-helpers-\(UUID().uuidString)")
  #expect(
    LiveDependencies.widgetStore(supportDirectory: root, containerURL: { _ in nil }).url
      == root.appendingPathComponent("widget.json"))
  #expect(LiveDependencies.widgetStore(supportDirectory: root).url.lastPathComponent == "widget.json")
  // a stub launcher, so the test never asks macOS to open a bundle
  let terminated = await withCheckedContinuation { continuation in
    LiveDependencies.relaunch(
      bundle: .main,
      open: { url, configuration, done in
        #expect(url == Bundle.main.bundleURL)
        #expect(configuration.createsNewApplicationInstance)
        #expect(configuration.environment["TOKEN_MENU_BAR_DEMO"] == nil)
        done()
      },
      then: { continuation.resume(returning: true) })
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
  // Opening the popover only refreshes what is due, so with nothing registered it reports nothing.
  controller.refreshIfStale()
  await waitUntil(within: 0.5) { dependencies.state.lastRefresh != nil }
  #expect(dependencies.state.lastRefresh == nil)
  controller.refreshNow()
  await Task.yield()
  #expect(dependencies.state.lastRefresh == nil)
}

@Test @MainActor func helperViewsHost() {
  #expect(
    inkFraction(
      HelpText("A fairly long explanation that needs to wrap across several lines inside the popover."), width: 300,
      height: 100) > 0)
  #expect(
    inkFraction(
      EmptyStateView(title: "Nothing", systemImage: "hourglass", description: "Waiting"), width: 300, height: 100) > 0)
  var measured: [PopoverMeasurement] = []
  let environment = try! makeEnvironment()
  let root = RootView(environment: environment, onMeasure: { measured.append($0) }, onTabChange: { _ in })
  root.measured(PopoverMeasurement(tab: .usage, size: .zero))
  #expect(measured.isEmpty)
  root.select(.settings)
  root.measured(PopoverMeasurement(tab: .history, size: CGSize(width: 10, height: 20)))
  #expect(measured.last?.tab == .history)
  #expect(
    measured.last?.size.height
      == 20 + PopoverGeometry.tabBarHeight + PopoverGeometry.footerHeight)
  #expect(PopoverMeasurementKey.defaultValue == nil)
}

@Test @MainActor func exportRunnerWritesIconsAndMenuBarStrips() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-export-\(UUID().uuidString)")
  let icons = try await ExportRunner.run(.icons, directory: directory)
  #expect(icons.contains { $0.lastPathComponent == "icon_512x512@2x.png" })
  let strips = try await ExportRunner.run(.menuBar, directory: directory, now: fixedNow)
  #expect(strips.map(\.lastPathComponent) == ["menubar-light.png", "menubar-dark.png"])
  #expect(try Data(contentsOf: strips[0]).isEmpty == false)
  try FileManager.default.removeItem(at: directory)
}

@Test @MainActor func exportRunnerWritesOnePopoverShotPerTabAndAppearance() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-export-\(UUID().uuidString)")
  #expect(
    try await ExportRunner.run(.popover, directory: directory, settle: .zero).map(\.lastPathComponent)
      == PopoverTab.allCases.flatMap {
        ["popover-\($0.rawValue.lowercased())-light.png", "popover-\($0.rawValue.lowercased())-dark.png"]
      })
  try FileManager.default.removeItem(at: directory)
}
