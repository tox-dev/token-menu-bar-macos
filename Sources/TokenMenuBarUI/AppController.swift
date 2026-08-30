import AppKit
import SwiftUI
import TokenMenuBarCore

@MainActor
public protocol UpdaterHook: AnyObject {
  var canCheck: Bool { get }
  var automaticallyChecks: Bool { get set }
  func checkForUpdates()
}

@MainActor
public struct AppDependencies {
  public var appInfo: AppInfo
  public var settings: TokenMenuBarCore.Settings
  public var state: AppState
  public var history: UsageHistoryStore
  public var log: LogBuffer
  public var registry: ProviderRegistry
  public var notifier: Notifier
  public var launchAtLogin: LaunchAtLoginBackend
  public var clock: Clock
  public var updater: (any UpdaterHook)?
  public var statusBar: NSStatusBar
  public var isSandboxed: Bool
  public var isDemo: Bool
  public var openURL: (URL) -> Void
  public var copyToPasteboard: (String) -> Void
  public var revealInFinder: (URL) -> Void
  public var chooseExportURL: () -> URL?
  public var chooseDirectory: (SandboxResource) -> URL?
  public var terminate: () -> Void
  public var relaunch: () -> Void
  public var widgetStore: WidgetSnapshotStore?
  public var snapshotCache: SnapshotCache
  public var reloadWidgets: () -> Void
  public var rebuildProviders: (TokenMenuBarCore.Settings) -> ProviderRegistry
  public var screenVisibleFrame: () -> CGRect?
  public var openPopoverOnLaunch: Bool

  public init(
    appInfo: AppInfo,
    settings: TokenMenuBarCore.Settings,
    state: AppState,
    history: UsageHistoryStore,
    log: LogBuffer,
    registry: ProviderRegistry,
    notifier: Notifier,
    launchAtLogin: LaunchAtLoginBackend,
    clock: Clock = .system,
    updater: (any UpdaterHook)? = nil,
    statusBar: NSStatusBar = .system,
    isSandboxed: Bool = false,
    isDemo: Bool = false,
    openURL: @escaping (URL) -> Void,
    copyToPasteboard: @escaping (String) -> Void,
    revealInFinder: @escaping (URL) -> Void,
    chooseExportURL: @escaping () -> URL?,
    chooseDirectory: @escaping (SandboxResource) -> URL?,
    terminate: @escaping () -> Void,
    relaunch: @escaping () -> Void = {},
    widgetStore: WidgetSnapshotStore? = nil,
    snapshotCache: SnapshotCache = SnapshotCache(url: nil),
    reloadWidgets: @escaping () -> Void = {},
    rebuildProviders: @escaping (TokenMenuBarCore.Settings) -> ProviderRegistry,
    screenVisibleFrame: @escaping () -> CGRect?,
    openPopoverOnLaunch: Bool = false
  ) {
    self.appInfo = appInfo
    self.settings = settings
    self.state = state
    self.history = history
    self.log = log
    self.registry = registry
    self.notifier = notifier
    self.launchAtLogin = launchAtLogin
    self.clock = clock
    self.updater = updater
    self.statusBar = statusBar
    self.isSandboxed = isSandboxed
    self.isDemo = isDemo
    self.openURL = openURL
    self.copyToPasteboard = copyToPasteboard
    self.revealInFinder = revealInFinder
    self.chooseExportURL = chooseExportURL
    self.chooseDirectory = chooseDirectory
    self.terminate = terminate
    self.relaunch = relaunch
    self.widgetStore = widgetStore
    self.snapshotCache = snapshotCache
    self.reloadWidgets = reloadWidgets
    self.rebuildProviders = rebuildProviders
    self.screenVisibleFrame = screenVisibleFrame
    self.openPopoverOnLaunch = openPopoverOnLaunch
  }
}

@MainActor
public final class AppController {
  public let dependencies: AppDependencies
  public let environment: UIEnvironment
  public let coordinator: RefreshCoordinator
  public private(set) var statusItem: StatusItemController?
  public private(set) var popover: PopoverController?
  private var logWindow: LogWindowController?
  private var workspaceObservers: [Any] = []
  private var registry: ProviderRegistry

  public init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    registry = dependencies.registry
    let notifier = dependencies.notifier
    let state = dependencies.state
    coordinator = RefreshCoordinator(
      registry: dependencies.registry,
      settings: dependencies.settings,
      state: state,
      history: dependencies.history,
      log: dependencies.log,
      clock: dependencies.clock,
      cache: dependencies.snapshotCache
    ) { events in Task { await notifier.deliver(events) } }
    environment = UIEnvironment(
      state: state,
      settings: dependencies.settings,
      history: dependencies.history,
      log: dependencies.log,
      appInfo: dependencies.appInfo,
      clock: dependencies.clock,
      launchAtLoginStatus: dependencies.launchAtLogin.status(),
      credentialDescriptions: Dictionary(
        uniqueKeysWithValues: dependencies.registry.providers.map { ($0.id, $0.credentialDescription) }),
      canCheckForUpdates: dependencies.updater?.canCheck ?? false,
      isSandboxed: dependencies.isSandboxed,
      isDemo: dependencies.isDemo
    )
    environment.actions = actions()
    dependencies.log.debugEnabled = dependencies.settings.detailedLogging
    coordinator.widgetSink = { [weak self] in self?.publishWidget($0) }
  }

  public func publishWidget(_ snapshot: WidgetSnapshot) {
    guard let store = dependencies.widgetStore else { return }
    do {
      try store.write(snapshot)
      dependencies.reloadWidgets()
    } catch {
      dependencies.log.logError("widget snapshot write failed: \(error)")
    }
  }

  func actions() -> UIActions {
    UIActions(
      refresh: { [weak self] in self?.refreshNow() },
      openURL: { [weak self] in self?.dependencies.openURL($0) },
      copy: { [weak self] in self?.dependencies.copyToPasteboard($0) },
      exportHistory: { [weak self] in self?.exportHistory() },
      clearHistory: { [weak self] in self?.clearHistory() },
      revealHistory: { [weak self] in self?.revealHistory() },
      copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
      reportIssue: { [weak self] in self?.reportIssue() },
      showFullLog: { [weak self] in self?.showFullLog() },
      setLaunchAtLogin: { [weak self] in self?.setLaunchAtLogin($0) },
      openLoginItems: { [weak self] in self?.dependencies.launchAtLogin.openSettings() },
      grantAccess: { [weak self] in self?.grantAccess(to: $0) },
      checkForUpdates: { [weak self] in self?.dependencies.updater?.checkForUpdates() },
      quit: { [weak self] in self?.dependencies.terminate() },
      setDemoMode: { [weak self] in self?.setDemoMode($0) },
      settingsChanged: { [weak self] in self?.settingsChanged() }
    )
  }

  public func start() {
    let log = dependencies.log
    if let previous = dependencies.settings.lastLaunchedVersion, previous != dependencies.appInfo.version {
      log.log("updated from \(previous) to \(dependencies.appInfo.version)")
    }
    dependencies.settings.lastLaunchedVersion = dependencies.appInfo.version
    log.log("launch \(dependencies.appInfo.name) \(dependencies.appInfo.version) (\(dependencies.appInfo.build))")
    let item = StatusItemController(statusBar: dependencies.statusBar, log: log) { $0.performClick(nil) }
    item.onClick = { [weak self] in self?.togglePopover() }
    item.onCountdownTick = { [weak self] in self?.coordinator.rebuildStatus() }
    item.menuProvider = { [weak self] in self?.contextMenu() ?? NSMenu() }
    item.adaptive = dependencies.settings.adaptiveWidth
    item.update(ladder: dependencies.state.statusLadder)
    statusItem = item
    let popover = PopoverController(content: AnyView(EmptyView()))
    popover.setContent(rootView(popover))
    popover.excludedFrame = { [weak self] in self?.statusItem?.buttonFrameOnScreen }
    popover.onVisibilityChange = { [weak self] visible in
      self?.dependencies.state.popoverVisible = visible
      self?.statusItem?.probing = visible || self?.dependencies.settings.detailedLogging == true
      if visible { self?.refreshIfStale() }
    }
    self.popover = popover
    installObservers()
    dependencies.updater?.automaticallyChecks = dependencies.settings.automaticUpdates
    coordinator.start()
    Task { await dependencies.notifier.requestAuthorization() }
    observeStatusModel()
    if dependencies.openPopoverOnLaunch { togglePopover() }
  }

  func rootView(_ popover: PopoverController) -> AnyView {
    AnyView(
      RootView(
        environment: environment, onMeasure: { [weak popover] tab, size in popover?.measure(tab: tab, size: size) },
        onTabChange: { [weak popover] tab in popover?.select(tab: tab) }))
  }

  func observeStatusModel() {
    withObservationTracking {
      _ = dependencies.state.statusLadder
    } onChange: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        statusItem?.update(ladder: dependencies.state.statusLadder)
        observeStatusModel()
      }
    }
  }

  public func stop() {
    coordinator.stop()
    popover?.close()
    statusItem?.remove(from: dependencies.statusBar)
    statusItem = nil
    for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    workspaceObservers.removeAll()
    dependencies.log.log("stopped")
  }

  func installObservers() {
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleSleep() }
      })
    workspaceObservers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleWake() }
      })
  }

  public func handleSleep() {
    dependencies.log.logDebug("sleep: pausing refresh loop")
    coordinator.stop()
  }

  public func handleWake() {
    dependencies.log.logDebug("wake: resuming refresh loop")
    coordinator.start()
  }

  public func togglePopover() {
    popover?.toggle(
      relativeTo: statusItem?.item.button, anchorFrame: statusItem?.buttonFrameOnScreen,
      visibleFrame: statusItem?.item.button?.window?.screen?.visibleFrame ?? dependencies.screenVisibleFrame())
  }

  public func refreshNow() {
    Task { await coordinator.refresh(RefreshRequest(interactive: true, force: true)) }
  }

  public func refreshIfStale() {
    Task { await coordinator.refresh(RefreshRequest(interactive: true)) }
  }

  public func settingsChanged() {
    dependencies.log.debugEnabled = dependencies.settings.detailedLogging
    dependencies.updater?.automaticallyChecks = dependencies.settings.automaticUpdates
    statusItem?.adaptive = dependencies.settings.adaptiveWidth
    coordinator.rebuildStatus()
  }

  public func contextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: "Refresh Now", action: #selector(MenuTarget.refresh), keyEquivalent: "r").target =
      menuTarget
    menu.addItem(.separator())
    for provider in registry.ids where dependencies.settings.enabledProviders.contains(provider) {
      let item = NSMenuItem(
        title: "Open \(provider.displayName) usage page", action: #selector(MenuTarget.openProvider(_:)),
        keyEquivalent: "")
      item.representedObject = provider.rawValue
      item.target = menuTarget
      menu.addItem(item)
    }
    if dependencies.updater?.canCheck == true {
      menu.addItem(.separator())
      menu.addItem(withTitle: "Check for Updates…", action: #selector(MenuTarget.checkForUpdates), keyEquivalent: "")
        .target = menuTarget
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit \(dependencies.appInfo.name)", action: #selector(MenuTarget.quit), keyEquivalent: "q")
      .target = menuTarget
    return menu
  }

  lazy var menuTarget = MenuTarget(controller: self)

  @discardableResult
  public func exportHistory() -> Task<Void, Never> {
    guard let url = dependencies.chooseExportURL() else { return Task {} }
    return Task {
      do {
        let csv = try await dependencies.history.exportCSV()
        try csv.write(to: url, atomically: true, encoding: .utf8)
        dependencies.log.log("history exported to \(url.lastPathComponent)")
      } catch {
        dependencies.log.logError("history export failed: \(error)")
      }
    }
  }

  @discardableResult
  public func clearHistory() -> Task<Void, Never> {
    Task {
      do {
        let removed = try await dependencies.history.clear()
        dependencies.log.log("history cleared rows=\(removed)")
        environment.historyPresenter.reload()
      } catch {
        dependencies.log.logError("history clear failed: \(error)")
      }
    }
  }

  public func revealHistory() {
    guard let location = dependencies.history.location else { return }
    dependencies.revealInFinder(location)
  }

  public func diagnosticsReport() -> String {
    Diagnostics.report(
      app: dependencies.appInfo,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      settings: dependencies.settings,
      state: dependencies.state,
      historyLocation: dependencies.history.location,
      log: dependencies.log,
      now: dependencies.clock.now()
    )
  }

  public func copyDiagnostics() {
    dependencies.copyToPasteboard(diagnosticsReport())
  }

  public func reportIssue() {
    dependencies.openURL(
      Diagnostics.issueURL(
        repository: dependencies.appInfo.repository, title: "Issue report", report: diagnosticsReport()))
  }

  public func showFullLog() {
    if logWindow == nil { logWindow = LogWindowController(log: dependencies.log) }
    logWindow?.showWindow(nil)
  }

  public func setLaunchAtLogin(_ enabled: Bool) {
    environment.launchAtLoginStatus = dependencies.launchAtLogin.setEnabled(enabled)
    dependencies.log.log("launch at login \(enabled ? "on" : "off") -> \(environment.launchAtLoginStatus.rawValue)")
  }

  public func grantAccess(to resource: SandboxResource) {
    guard let url = dependencies.chooseDirectory(resource) else { return }
    do {
      let bookmark = try (url as NSURL).bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      dependencies.settings.setBookmark(bookmark, for: resource)
      dependencies.settings.flush()
      dependencies.log.log("\(resource.label) access granted: \(url.lastPathComponent)")
      replaceProviders(dependencies.rebuildProviders(dependencies.settings))
      refreshNow()
    } catch {
      dependencies.log.logError("bookmark for \(resource.label) failed: \(error)")
    }
  }

  public func setDemoMode(_ enabled: Bool) {
    dependencies.settings.demoMode = enabled
    dependencies.settings.flush()
    dependencies.log.log("demo mode \(enabled ? "on" : "off"); relaunching")
    dependencies.relaunch()
  }

  public func replaceProviders(_ registry: ProviderRegistry) {
    self.registry = registry
    coordinator.registry = registry
    environment.credentialDescriptions = Dictionary(
      uniqueKeysWithValues: registry.providers.map { ($0.id, $0.credentialDescription) })
  }
}

/// Renders the popover tabs straight to PNG for the website. A screen capture of the live popover picks up its
/// shadow and whatever sits behind it; hosting the same view offscreen yields exactly the content and nothing else.
@MainActor
public enum PopoverExporter {
  /// Renders a view at its own natural size. A screen capture of the live popover picks up its shadow and whatever
  /// sits behind it; hosting the view offscreen yields the content and nothing else.
  public static func image(_ view: some View, dark: Bool) -> NSImage? {
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // The popover paints on a translucent material with no window behind it here, so give it an opaque backing
    // the same size as the content rather than a larger canvas that would show through at the edges.
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    guard hosting.bounds.width > 0, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      return nil
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = NSImage(size: hosting.bounds.size)
    image.addRepresentation(rep)
    return image
  }

  public static func png(_ view: some View, dark: Bool) -> Data? {
    guard let image = image(view, dark: dark), let rep = image.representations.first as? NSBitmapImageRep else {
      return nil
    }
    return rep.representation(using: .png, properties: [:])
  }
}

@MainActor
final class MenuTarget: NSObject {
  weak var controller: AppController?

  init(controller: AppController) {
    self.controller = controller
  }

  @objc func refresh() {
    controller?.refreshNow()
  }

  @objc func openProvider(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let provider = ProviderID(rawValue: raw) else { return }
    controller?.dependencies.openURL(provider.usagePage)
  }

  @objc func checkForUpdates() {
    controller?.dependencies.updater?.checkForUpdates()
  }

  @objc func quit() {
    controller?.dependencies.terminate()
  }
}

@MainActor
public final class LogWindowController: NSWindowController {
  public let log: LogBuffer

  public init(log: LogBuffer) {
    self.log = log
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Token Menu Bar Log"
    window.contentView = NSHostingView(rootView: LogTextView(entries: log.snapshot, height: 480))
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  public override func showWindow(_ sender: Any?) {
    window?.contentView = NSHostingView(
      rootView: LogTextView(entries: log.snapshot, height: window?.frame.height ?? 480))
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
  }
}
