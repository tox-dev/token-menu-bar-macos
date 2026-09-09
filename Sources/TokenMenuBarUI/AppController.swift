import AppKit
import SwiftUI
import TokenMenuBarCore

@MainActor
public protocol UpdaterHook: AnyObject {
  var canCheck: Bool { get }
  var automaticallyChecks: Bool { get set }
  var onCanCheckChange: (@MainActor (Bool) -> Void)? { get set }
  func start()
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
  public var demoSeedTask: Task<Void, Never>?
  public var increaseContrast: @MainActor () -> Bool
  public var openURL: @MainActor (URL) -> Void
  public var copyToPasteboard: @MainActor (String) -> Void
  public var revealInFinder: @MainActor (URL) -> Void
  public var chooseExportURL: () -> URL?
  public var chooseDirectory: (SandboxResource) -> URL?
  public var terminate: @MainActor () -> Void
  public var relaunch: @MainActor @Sendable () -> Void
  public var widgetStore: WidgetSnapshotStore?
  public var snapshotCache: SnapshotCache
  public var persistence: SnapshotPersistence
  public var reloadWidgets: @MainActor @Sendable () -> Void
  public var rebuildProviders: @MainActor @Sendable (TokenMenuBarCore.Settings) async -> ProviderRegistry
  public var screenVisibleFrame: () -> CGRect?
  public var openPopoverOnLaunch: Bool
  public var presentsWindows: Bool
  public var beginPopoverActivation: PopoverActivationHandler?
  public var persistsStatusItemPosition: Bool
  public var recoversOffscreenPopover: Bool
  public var verificationSession: String?
  public var verificationSnapshotURL: URL?
  public var captureProcessSnapshot: @Sendable () -> ProcessPerformanceSnapshot?

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
    demoSeedTask: Task<Void, Never>? = nil,
    increaseContrast: @escaping @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    },
    openURL: @escaping @MainActor (URL) -> Void,
    copyToPasteboard: @escaping @MainActor (String) -> Void,
    revealInFinder: @escaping @MainActor (URL) -> Void,
    chooseExportURL: @escaping () -> URL?,
    chooseDirectory: @escaping (SandboxResource) -> URL?,
    terminate: @escaping @MainActor () -> Void,
    relaunch: @escaping @MainActor @Sendable () -> Void = {},
    widgetStore: WidgetSnapshotStore? = nil,
    snapshotCache: SnapshotCache = SnapshotCache(url: nil),
    persistence: SnapshotPersistence? = nil,
    reloadWidgets: @escaping @MainActor @Sendable () -> Void = {},
    rebuildProviders: @escaping @MainActor @Sendable (TokenMenuBarCore.Settings) async -> ProviderRegistry,
    screenVisibleFrame: @escaping () -> CGRect?,
    openPopoverOnLaunch: Bool = false,
    presentsWindows: Bool = true,
    beginPopoverActivation: PopoverActivationHandler? = nil,
    persistsStatusItemPosition: Bool = true,
    recoversOffscreenPopover: Bool = false,
    verificationSession: String? = nil,
    verificationSnapshotURL: URL? = nil,
    captureProcessSnapshot: @escaping @Sendable () -> ProcessPerformanceSnapshot? = ProcessPerformanceSnapshot.current
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
    self.demoSeedTask = demoSeedTask
    self.increaseContrast = increaseContrast
    self.openURL = openURL
    self.copyToPasteboard = copyToPasteboard
    self.revealInFinder = revealInFinder
    self.chooseExportURL = chooseExportURL
    self.chooseDirectory = chooseDirectory
    self.terminate = terminate
    self.relaunch = relaunch
    self.widgetStore = widgetStore
    self.snapshotCache = snapshotCache
    self.persistence =
      persistence
      ?? SnapshotPersistence(
        cache: snapshotCache,
        widgetStore: widgetStore,
        usageFileURL: snapshotCache.url.map {
          $0.deletingLastPathComponent().appendingPathComponent(UsageExport.fileName)
        },
        failureHandler: { failure in log.logError(failure.message) },
        reloadWidgets: reloadWidgets)
    self.reloadWidgets = reloadWidgets
    self.rebuildProviders = rebuildProviders
    self.screenVisibleFrame = screenVisibleFrame
    self.openPopoverOnLaunch = openPopoverOnLaunch
    self.presentsWindows = presentsWindows
    self.beginPopoverActivation = beginPopoverActivation
    self.persistsStatusItemPosition = persistsStatusItemPosition
    self.recoversOffscreenPopover = recoversOffscreenPopover
    self.verificationSession = verificationSession
    self.verificationSnapshotURL = verificationSnapshotURL
    self.captureProcessSnapshot = captureProcessSnapshot
  }
}

@MainActor
public final class AppController {
  public private(set) var dependencies: AppDependencies
  public let environment: UIEnvironment
  public let coordinator: RefreshCoordinator
  public private(set) var statusItem: StatusItemController?
  private var stopped = false
  private var launchPopoverTask: Task<Void, Never>?
  public private(set) var popover: PopoverController?
  private var logWindow: LogWindowController?
  private var workspaceObservers: [Any] = []
  private var applicationObservers: [Any] = []
  private var distributedObservers: [Any] = []
  private var lastPopoverVisibleFrame: CGRect?
  private var registry: ProviderRegistry
  private var appliedRetentionDays: Int
  private var retentionTask: Task<Void, Never>?
  private var retentionGeneration = 0
  private var widgetSubmissionTask: Task<Void, Never>?
  private var providerHealthTask: Task<Void, Never>?
  private var providerRediscoveryTask: Task<Void, Never>?
  private var lifecycleFlushTask: Task<Void, Never>?
  private var providerGeneration = 0
  private var providerRediscoveryGeneration = 0
  private var providerRediscoveryPolicy = ProviderRediscoveryPolicy()
  private var notificationsEnabled: Bool
  private var firstRunCardPending = false
  private let initialStatusItem: NSStatusItem?

  public init(dependencies: AppDependencies, initialStatusItem: NSStatusItem? = nil) {
    self.dependencies = dependencies
    self.initialStatusItem = initialStatusItem
    registry = dependencies.registry
    appliedRetentionDays = dependencies.settings.historyRetentionDays
    notificationsEnabled = dependencies.settings.notifications.enabled
    let notifier = dependencies.notifier
    let state = dependencies.state
    coordinator = RefreshCoordinator(
      registry: dependencies.registry,
      settings: dependencies.settings,
      state: state,
      history: dependencies.history,
      log: dependencies.log,
      clock: dependencies.clock,
      cache: dependencies.snapshotCache,
      persistence: dependencies.persistence
    ) { [settings = dependencies.settings] events in
      notifier.playSound = settings.notifications.playSound
      Task { await notifier.deliver(events) }
    }
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
      isDemo: dependencies.isDemo,
      increaseContrast: dependencies.increaseContrast()
    )
    environment.actions = actions()
    dependencies.log.debugEnabled = dependencies.settings.detailedLogging
    coordinator.widgetSink = { [weak self] in self?.publishWidget($0) }
  }

  public func publishWidget(_ snapshot: WidgetSnapshot) {
    let previous = widgetSubmissionTask
    widgetSubmissionTask = Task { [persistence = dependencies.persistence] in
      await previous?.value
      await persistence.submitWidget(snapshot)
    }
  }

  public func flushPersistence() async {
    await widgetSubmissionTask?.value
    await coordinator.flushPersistence()
  }

  public func prepareToTerminate() async {
    cancelBackgroundTasks()
    coordinator.stop()
    _ = await ShutdownPolicy.waitForCompletion { [weak self] in await self?.flushPersistence() }
  }

  func actions() -> UIActions {
    UIActions(
      refresh: { [weak self] in self?.refreshNow() },
      refreshProvider: { [weak self] in self?.refreshNow(provider: $0) },
      showProviders: { [weak self] in self?.showProviders($0) },
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
      grantAccess: { [weak self] resource in Task { await self?.grantAccess(to: resource) } },
      checkForUpdates: { [weak self] in self?.dependencies.updater?.checkForUpdates() },
      quit: { [weak self] in self?.dependencies.terminate() },
      setDemoMode: { [weak self] in self?.setDemoMode($0) },
      settingsChanged: { [weak self] in self?.settingsChanged() },
      settingsReset: { [weak self] in Task { await self?.settingsReset() } }
    )
  }

  public func start() {
    let log = dependencies.log
    if let previous = dependencies.settings.lastLaunchedVersion, previous != dependencies.appInfo.version {
      log.log("updated from \(previous) to \(dependencies.appInfo.version)")
    }
    firstRunCardPending =
      dependencies.settings.lastLaunchedVersion == nil && dependencies.settings.configuredProviders.isEmpty
      && !dependencies.settings.firstRunCardDismissed
    dependencies.settings.lastLaunchedVersion = dependencies.appInfo.version
    log.log("launch \(dependencies.appInfo.name) \(dependencies.appInfo.version) (\(dependencies.appInfo.build))")
    let item = StatusItemController(
      statusBar: dependencies.statusBar, item: initialStatusItem, log: log,
      autosaveName: dependencies.persistsStatusItemPosition
        ? StatusItemController.autosaveName(bundleIdentifier: Bundle.main.bundleIdentifier) : nil
    ) {
      $0.performClick(nil)
    }
    item.onClick = { [weak self] in self?.togglePopover() }
    item.onCountdownTick = { [weak self] in self?.coordinator.rebuildStatus() }
    item.menuProvider = menuTarget.menu
    item.adaptive = dependencies.settings.adaptiveWidth
    item.detailedLoggingEnabled = dependencies.settings.detailedLogging
    item.update(ladder: dependencies.state.statusLadder)
    statusItem = item
    let popover = PopoverController(
      content: AnyView(EmptyView()), log: log, presentsWindow: dependencies.presentsWindows,
      recoversOffscreenAnchor: dependencies.recoversOffscreenPopover,
      beginActivation: dependencies.beginPopoverActivation)
    popover.setContent(rootView(popover))
    popover.select(tab: dependencies.settings.lastTab)
    popover.excludedFrame = { [weak self] in self?.statusItem?.buttonFrameOnScreen }
    popover.onRefresh = { [weak self] in self?.refreshNow() }
    popover.onVisibilityChange = { [weak self] visible in
      self?.statusItem?.popoverVisible = visible
      self?.dependencies.state.popoverVisible = visible
      if visible {
        self?.refreshIfStale()
      }
    }
    self.popover = popover
    installObservers()
    if dependencies.verificationSession != nil { writeVerificationSnapshot() }
    if let updater = dependencies.updater {
      updater.automaticallyChecks = dependencies.settings.automaticUpdates
      updater.onCanCheckChange = { [weak self] in self?.environment.canCheckForUpdates = $0 }
      updater.start()
      environment.canCheckForUpdates = updater.canCheck
    }
    dependencies.notifier.onResponse = { [weak self] in self?.handleNotificationResponse() }
    probeProviderHealth()
    providerRediscoveryPolicy.recordDiscovery(at: dependencies.clock.now())
    Task { [coordinator] in await coordinator.restoreCachedSnapshots() }
    coordinator.start()
    if notificationsEnabled { Task { await dependencies.notifier.requestAuthorization(provisional: true) } }
    observeStatusModel()
    if dependencies.openPopoverOnLaunch {
      launchPopoverTask = Task { [weak self, clock = dependencies.clock] in
        guard (try? await clock.sleep(Self.launchPopoverDelay)) != nil else { return }
        self?.openPopoverAfterStatusItemAttachment()
      }
    }
  }

  static let launchPopoverDelay: TimeInterval = 0.2
  static let attachmentPollInterval: TimeInterval = 0.05
  static let retentionDebounce: TimeInterval = 0.15

  private func openPopoverAfterStatusItemAttachment(
    remainingAttempts: Int = 20, previousButtonFrame: CGRect? = nil, forcedNarrowest: Bool = false
  ) {
    launchPopoverTask = Task { [weak self, clock = dependencies.clock] in
      guard (try? await clock.sleep(Self.attachmentPollInterval)) != nil, let self, !stopped,
        popover?.isShown != true
      else { return }
      dependencies.log.logDebug(
        "popover attachment remaining=\(remainingAttempts) frame=\(String(describing: statusItem?.buttonFrameOnScreen)) "
          + "previous=\(String(describing: previousButtonFrame)) fits=\(statusItem?.fits() == true)")
      guard let buttonFrame = statusItem?.buttonFrameOnScreen, statusItem?.fits() == true, !buttonFrame.isEmpty,
        buttonFrame.minX.isFinite, buttonFrame.minY.isFinite,
        buttonFrame.width.isFinite, buttonFrame.height.isFinite
      else {
        retryOpening(
          remainingAttempts: remainingAttempts, previousButtonFrame: nil, forcedNarrowest: forcedNarrowest)
        return
      }
      guard buttonFrame == previousButtonFrame else {
        retryOpening(
          remainingAttempts: remainingAttempts, previousButtonFrame: buttonFrame, forcedNarrowest: forcedNarrowest)
        return
      }
      togglePopover()
    }
  }

  @discardableResult
  func retryOpening(remainingAttempts: Int, previousButtonFrame: CGRect?, forcedNarrowest: Bool) -> Bool {
    if remainingAttempts == 12, !forcedNarrowest, statusItem?.collapseToNarrowest() == true {
      statusItem?.reattach()
      openPopoverAfterStatusItemAttachment(remainingAttempts: 8, forcedNarrowest: true)
      return false
    }
    guard remainingAttempts > 1 else {
      guard forcedNarrowest, dependencies.recoversOffscreenPopover else { return false }
      togglePopover()
      return true
    }
    openPopoverAfterStatusItemAttachment(
      remainingAttempts: remainingAttempts - 1, previousButtonFrame: previousButtonFrame,
      forcedNarrowest: forcedNarrowest)
    return false
  }

  func rootView(_ popover: PopoverController) -> AnyView {
    AnyView(
      RootView(
        environment: environment, onMeasure: { [weak popover] in popover?.measure($0) },
        onTabChange: { [weak popover] tab in popover?.select(tab: tab) },
        chooseHistoryExportURL: { [weak self] in self?.dependencies.chooseExportURL() }))
  }

  func observeStatusModel() {
    // The tracking closure re-registers itself after every change, so capturing self strongly here would leave the
    // registrar holding the controller, its state and its history store for good.
    withObservationTracking { [weak self] in
      _ = self?.dependencies.state.statusLadder
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, !self.stopped else { return }
        self.statusItem?.update(ladder: self.dependencies.state.statusLadder)
        self.observeStatusModel()
      }
    }
  }

  public func stop() {
    cancelBackgroundTasks()
    coordinator.stop()
    popover?.close()
    logWindow?.close()
    logWindow = nil
    statusItem?.remove(from: dependencies.statusBar)
    statusItem = nil
    for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    workspaceObservers.removeAll()
    for observer in applicationObservers { NotificationCenter.default.removeObserver(observer) }
    applicationObservers.removeAll()
    for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    distributedObservers.removeAll()
    dependencies.updater?.onCanCheckChange = nil
    stopped = true
    dependencies.log.log("stopped")
    dependencies.log.flush()
  }

  private func cancelBackgroundTasks() {
    launchPopoverTask?.cancel()
    launchPopoverTask = nil
    retentionTask?.cancel()
    retentionTask = nil
    providerHealthTask?.cancel()
    providerHealthTask = nil
    providerRediscoveryTask?.cancel()
    providerRediscoveryTask = nil
  }

  func installObservers() {
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      applicationObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
          let window = notification.object as? NSWindow
          Task { @MainActor [weak self] in
            guard let self, self.popover?.isShown == true, let window, window === self.statusItem?.item.button?.window
            else {
              return
            }
            self.updatePopoverGeometry()
          }
        })
    }
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleSleep() }
      })
    workspaceObservers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleWake() }
      })
    workspaceObservers.append(
      center.addObserver(
        forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshIncreaseContrast() }
      })
    applicationObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.updatePopoverGeometry() }
      })
    applicationObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleApplicationActivation() }
      })
    if let session = dependencies.verificationSession {
      distributedObservers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: LaunchPolicy.verificationOpenPopoverNotification,
          object: session,
          queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.openPopoverForVerification() }
        })
      distributedObservers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: LaunchPolicy.verificationSnapshotNotification,
          object: session,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.writeVerificationSnapshot() }
        })
    }
  }

  private func refreshIncreaseContrast() {
    environment.increaseContrast = dependencies.increaseContrast()
  }

  private func writeVerificationSnapshot() {
    for window in NSApplication.shared.windows where window.isVisible {
      guard let root = window.contentView else { continue }
      dependencies.log.logInfo(
        "hit.window class=\(type(of: window)) frame=\(window.frame) key=\(window.isKeyWindow) main=\(window.isMainWindow) active=\(NSApplication.shared.isActive)"
      )
      var pending = [root]
      while let view = pending.popLast() {
        pending.append(contentsOf: view.subviews)
        guard view is NSDatePicker || view is NSPopUpButton || view is NSStepper || view is NSSegmentedControl else {
          continue
        }
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: root.superview)
        let hit = root.hitTest(point)
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screenPoint = CGPoint(x: frame.midX, y: frame.midY)
        let windowHit = view.isHiddenOrHasHiddenAncestor ? nil : window.accessibilityHitTest(screenPoint)
        let applicationHit =
          view.isHiddenOrHasHiddenAncestor ? nil : NSApplication.shared.accessibilityHitTest(screenPoint)
        dependencies.log.logInfo(
          "hit.control class=\(type(of: view)) id=\(view.accessibilityIdentifier()) frame=\(frame) enabled=\((view as? NSControl)?.isEnabled ?? false) axEnabled=\(view.isAccessibilityEnabled()) hidden=\(view.isHiddenOrHasHiddenAncestor) point=\(point) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") axWindow=\(windowHit.map { String(describing: type(of: $0)) } ?? "nil") axApplication=\(applicationHit.map { String(describing: type(of: $0)) } ?? "nil") responder=\(String(describing: window.firstResponder))"
        )
        if !view.isHiddenOrHasHiddenAncestor {
          for element in [windowHit, applicationHit].compactMap({ $0 }) + (view.accessibilityChildren() ?? []) {
            recordAccessibilityState(element)
          }
        }
        if let picker = view as? NSDatePicker, !picker.isHiddenOrHasHiddenAncestor,
          let cell = picker.cell
        {
          dependencies.log.logInfo(
            "hit.date value=\(picker.dateValue) cellEnabled=\(cell.isEnabled) editable=\(cell.isEditable) selectable=\(cell.isSelectable) axEnabled=\(cell.isAccessibilityEnabled()) axFrame=\(cell.accessibilityFrame()) axPoint=\(cell.accessibilityActivationPoint()) axValue=\(String(describing: cell.accessibilityValue())) parent=\(String(describing: cell.accessibilityParent()))"
          )
        }
      }
    }
    dependencies.log.flush()
    guard let url = dependencies.verificationSnapshotURL, let snapshot = dependencies.captureProcessSnapshot()
    else { return }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    } catch {
      dependencies.log.logWarning("Could not write verification process snapshot: \(error.localizedDescription)")
    }
  }

  private func recordAccessibilityState(_ value: Any) {
    var element = value as? any NSAccessibilityProtocol
    for depth in 0..<6 {
      guard let current = element else { break }
      dependencies.log.logInfo(
        "hit.ax depth=\(depth) class=\(type(of: current)) role=\(String(describing: current.accessibilityRole())) label=\(String(describing: current.accessibilityLabel())) enabled=\(current.isAccessibilityEnabled()) frame=\(current.accessibilityFrame()) point=\(current.accessibilityActivationPoint()) value=\(String(describing: current.accessibilityValue()))"
      )
      element = current.accessibilityParent() as? any NSAccessibilityProtocol
    }
  }

  public func handleSleep() {
    dependencies.log.logDebug("sleep: pausing refresh loop")
    coordinator.stop()
    let previous = lifecycleFlushTask
    lifecycleFlushTask = Task { [weak self] in
      await previous?.value
      await self?.flushPersistence()
    }
  }

  public func handleWake() {
    dependencies.log.logDebug("wake: resuming refresh loop after its network grace period")
    coordinator.resume()
  }

  public func togglePopover() {
    let geometry = popoverGeometry()
    popover?.toggle(
      relativeTo: statusItem?.item.button,
      anchorFrame: geometry.anchorFrame,
      visibleFrame: geometry.visibleFrame,
      screenID: geometry.screenID,
      screenFrame: geometry.screenFrame)
  }

  public func reopen() {
    statusItem?.restoreVisibility()
    guard popover?.isShown != true else { return }
    openPopoverAfterStatusItemAttachment()
  }

  private func openPopoverForVerification() {
    guard popover?.isShown != true else { return }
    let geometry = popoverGeometry()
    popover?.show(
      relativeTo: statusItem?.item.button,
      anchorFrame: geometry.anchorFrame,
      visibleFrame: geometry.visibleFrame,
      screenID: geometry.screenID,
      screenFrame: geometry.screenFrame)
  }

  func updatePopoverGeometry() {
    let geometry = popoverGeometry()
    popover?.updateGeometry(
      anchorFrame: geometry.anchorFrame,
      visibleFrame: geometry.visibleFrame,
      screenID: geometry.screenID,
      screenFrame: geometry.screenFrame,
      relativeTo: statusItem?.item.button)
  }

  func popoverGeometry() -> (
    anchorFrame: CGRect?, visibleFrame: CGRect?, screenID: String?, screenFrame: CGRect?
  ) {
    let anchorFrame = statusItem?.buttonFrameOnScreen
    let screens = NSScreen.screens
    let anchorScreen = Self.screen(
      near: anchorFrame, preferred: statusItem?.item.button?.window?.screen, among: screens)
    let previousScreen = lastPopoverVisibleFrame.flatMap { previous in
      screens.first { $0.frame.intersects(previous) }
    }
    let visibleFrame = Self.resolveVisibleFrame(
      dependencies.screenVisibleFrame(), anchorScreen: anchorScreen?.visibleFrame,
      previousScreen: previousScreen?.visibleFrame)
    if anchorScreen != nil || visibleFrame != nil { lastPopoverVisibleFrame = visibleFrame }
    let screen = anchorScreen ?? previousScreen
    let screenID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    return (anchorFrame, visibleFrame, screenID, screen?.frame)
  }

  static func screen(near anchor: CGRect?, preferred: NSScreen?, among screens: [NSScreen]) -> NSScreen? {
    if let preferred { return preferred }
    guard let anchor else { return nil }
    return screens.first { $0.frame.intersects(anchor) }
      ?? screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY - 100)) }
  }

  static func resolveVisibleFrame(
    _ explicit: CGRect?, anchorScreen: CGRect?, previousScreen: CGRect?
  ) -> CGRect? {
    if let explicit { return explicit }
    if let anchorScreen { return anchorScreen }
    return previousScreen
  }

  public func refreshNow() {
    Task { [weak self] in
      guard let self else { return }
      await rediscoverProviders(.userInitiated)
      await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force, analytics: .ifDue))
    }
  }

  public func refreshNow(provider: ProviderID) {
    Task {
      registry.retryCredentialReads([provider])
      await coordinator.refresh(
        RefreshRequest(reason: .userInitiated, usage: .force, analytics: .ifDue, providers: [provider]))
    }
  }

  public func refreshIfStale() {
    Task { await coordinator.refresh(RefreshRequest(reason: .popoverOpened)) }
  }

  public func handleApplicationActivation() {
    Task { [weak self] in await self?.rediscoverProviders(.applicationActivated) }
  }

  func handleNotificationResponse() {
    dependencies.log.logDebug("notification opened")
    dependencies.settings.lastTab = .usage
    popover?.select(tab: .usage)
    reopen()
  }

  public func showProviders(_ provider: ProviderID?) {
    environment.providerFocusRequest = ProviderSettingsFocusRequest(provider: provider)
    dependencies.settings.lastTab = .settings
    popover?.select(tab: .settings)
  }

  public func settingsChanged() {
    dependencies.log.debugEnabled = dependencies.settings.detailedLogging
    statusItem?.detailedLoggingEnabled = dependencies.settings.detailedLogging
    dependencies.updater?.automaticallyChecks = dependencies.settings.automaticUpdates
    let shouldRequestNotifications = dependencies.settings.notifications.enabled && !notificationsEnabled
    notificationsEnabled = dependencies.settings.notifications.enabled
    if shouldRequestNotifications { Task { await dependencies.notifier.requestAuthorization() } }
    statusItem?.adaptive = dependencies.settings.adaptiveWidth
    coordinator.rebuildStatus()
    let retentionDays = dependencies.settings.historyRetentionDays
    retentionTask?.cancel()
    retentionGeneration += 1
    let generation = retentionGeneration
    guard retentionDays != appliedRetentionDays else {
      retentionTask = nil
      return
    }
    let clock = dependencies.clock
    let now = clock.now()
    retentionTask = Task { @MainActor [weak self, history = dependencies.history, log = dependencies.log] in
      do {
        try await clock.sleep(Self.retentionDebounce)
      } catch {
        return
      }
      guard !Task.isCancelled, let self, retentionGeneration == generation,
        dependencies.settings.historyRetentionDays == retentionDays
      else { return }
      do {
        let removed = try await history.setRetentionDays(retentionDays, now: now)
        guard !Task.isCancelled, retentionGeneration == generation,
          dependencies.settings.historyRetentionDays == retentionDays
        else { return }
        appliedRetentionDays = retentionDays
        if removed.samples > 0 { dependencies.state.markSamplesChanged() }
        environment.historyPresenter.invalidateData()
        log.log("history retention updated days=\(retentionDays) removed=\(removed.total)")
      } catch {
        log.logError("history retention update failed: \(error)")
      }
    }
  }

  public func settingsReset() async {
    setLaunchAtLogin(false)
    replaceProviders(await dependencies.rebuildProviders(dependencies.settings))
    environment.historyPresenter.reset()
    if environment.isDemo {
      dependencies.log.log("demo mode reset; relaunching")
      dependencies.relaunch()
    }
  }

  public func contextMenu() -> NSMenu {
    let menu = NSMenu()
    let commands = MenuCommand.menu(
      canCheckForUpdates: dependencies.updater?.canCheck == true, appName: dependencies.appInfo.name)
    for command in commands {
      guard command != .separator else {
        menu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(
        title: command.title, action: #selector(MenuTarget.run(_:)), keyEquivalent: command.keyEquivalent)
      item.representedObject = command.id
      item.target = menuTarget
      menu.addItem(item)
    }
    return menu
  }

  public func run(_ commandID: String) {
    switch commandID {
    case MenuCommand.refresh.id: refreshNow()
    case MenuCommand.checkForUpdates.id: dependencies.updater?.checkForUpdates()
    case MenuCommand.quit(appName: "").id: dependencies.terminate()
    default: return
    }
  }

  lazy var menuTarget = MenuTarget(controller: self)

  @discardableResult
  public func exportHistory() -> Task<Void, Never> {
    guard let url = dependencies.chooseExportURL() else { return Task {} }
    return Task {
      do {
        try await dependencies.history.exportCSV(
          to: url, hidePersonalInformation: dependencies.settings.hidePersonalInformation)
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
        let removed = try await coordinator.clearHistory()
        dependencies.log.log("history cleared rows=\(removed)")
        environment.historyPresenter.invalidateData()
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
    popover?.close(restoringActivation: false)
    if logWindow == nil {
      logWindow = LogWindowController(log: dependencies.log, presentsWindow: dependencies.presentsWindows)
    }
    logWindow?.showWindow(nil)
  }

  public func setLaunchAtLogin(_ enabled: Bool) {
    environment.launchAtLoginStatus = dependencies.launchAtLogin.setEnabled(enabled)
    dependencies.log.log("launch at login \(enabled ? "on" : "off") -> \(environment.launchAtLoginStatus.rawValue)")
  }

  public func grantAccess(to resource: SandboxResource) async {
    guard let url = dependencies.chooseDirectory(resource) else { return }
    do {
      let bookmark = try await Task.detached(priority: .userInitiated) {
        try SecurityScopedBookmarkClient.live.create(url)
      }.value
      dependencies.settings.setBookmark(bookmark, for: resource)
      dependencies.settings.flush()
      dependencies.log.log("\(resource.label) access granted: \(url.lastPathComponent)")
      replaceProviders(await dependencies.rebuildProviders(dependencies.settings))
      refreshNow()
    } catch {
      dependencies.log.logError("bookmark for \(resource.label) failed: \(error)")
    }
  }

  public func setDemoMode(_ enabled: Bool) {
    dependencies.settings.demoMode = enabled
    dependencies.settings.flush()
    dependencies.isDemo = enabled
    environment.isDemo = enabled
    dependencies.log.log("demo mode \(enabled ? "on" : "off"); relaunching")
    dependencies.relaunch()
  }

  public func replaceProviders(_ registry: ProviderRegistry) {
    replaceProviderRegistry(registry)
    probeProviderHealth()
  }

  private func replaceProviderRegistry(_ registry: ProviderRegistry) {
    providerGeneration &+= 1
    self.registry = registry
    dependencies.registry = registry
    coordinator.replaceRegistry(registry)
    dependencies.state.applySetupStates(registry.setupStates)
    environment.credentialDescriptions = Dictionary(
      uniqueKeysWithValues: registry.providers.map { ($0.id, $0.credentialDescription) })
  }

  private func probeProviderHealth() {
    providerHealthTask?.cancel()
    let registry = registry
    let generation = providerGeneration
    let now = dependencies.clock.now()
    providerHealthTask = Task { @MainActor [weak self] in
      let discovery = await ProviderDiscoverySnapshot.inspect(registry, now: now)
      guard let self, !Task.isCancelled, generation == providerGeneration else { return }
      apply(discovery, to: registry)
    }
  }

  private func rediscoverProviders(_ trigger: ProviderRediscoveryTrigger) async {
    let now = dependencies.clock.now()
    if let task = providerRediscoveryTask {
      await task.value
      if trigger == .userInitiated { await rediscoverProviders(trigger) }
      return
    }
    guard providerRediscoveryPolicy.begin(trigger, at: now) else { return }
    providerRediscoveryGeneration &+= 1
    let generation = providerRediscoveryGeneration
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if generation == providerRediscoveryGeneration { providerRediscoveryTask = nil }
      }
      let candidate = await dependencies.rebuildProviders(dependencies.settings)
      if trigger == .userInitiated { candidate.retryCredentialReads(Set(candidate.ids)) }
      let discovery = await ProviderDiscoverySnapshot.inspect(candidate, now: now)
      guard !Task.isCancelled, generation == providerRediscoveryGeneration else { return }
      if trigger == .userInitiated
        || discovery.differs(from: dependencies.state.providers, providerIDs: registry.ids)
      {
        providerHealthTask?.cancel()
        replaceProviderRegistry(candidate)
        apply(discovery, to: candidate)
      }
    }
    providerRediscoveryTask = task
    await task.value
  }

  private func apply(_ discovery: ProviderDiscoverySnapshot, to registry: ProviderRegistry) {
    let setups = Dictionary(
      uniqueKeysWithValues: registry.providers.map { provider in
        let health = Self.credentialHealth(discovery.credentials, provider: provider.id)
        var state = dependencies.state.state(for: provider.id)
        state.credentialHealth = health
        return (
          provider.id,
          ProviderSetupState.from(
            provider: provider.id,
            enabled: dependencies.settings.isProviderActive(provider.id, state: state),
            credential: health,
            resources: discovery.resources[provider.id] ?? [])
        )
      })
    dependencies.state.applySetupStates(setups)
    coordinator.reschedule()
    guard firstRunCardPending else { return }
    firstRunCardPending = false
    environment.firstRunCard = FirstRunCard(
      detected: registry.ids.filter { Self.credentialHealth(discovery.credentials, provider: $0).isUsable })
    dependencies.settings.lastTab = .usage
    popover?.select(tab: .usage)
    dependencies.log.log("first run: opening the usage tab with the detected providers")
    openPopoverAfterStatusItemAttachment()
  }

  static func credentialHealth(
    _ credentials: [ProviderID: ProviderCredentialHealth], provider: ProviderID
  ) -> ProviderCredentialHealth {
    if let health = credentials[provider] { return health }
    return .unchecked
  }
}

/// Renders the popover tabs straight to PNG for the website. A screen capture of the live popover picks up its shadow
/// and whatever sits behind it, so the export hosts the same view offscreen and keeps the content alone.
@MainActor
public enum PopoverExporter {
  /// Renders a view offscreen at the size the popover would give it, so the shot shows what a viewer would see
  /// rather than the whole scrolled content unrolled.
  public static func image(_ view: some View, dark: Bool, size: CGSize? = nil) -> NSImage? {
    let hosting = NSHostingView(rootView: view)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    hosting.appearance = appearance
    // The popover paints on a translucent material with no window behind it here, so back it with the colour the
    // website draws behind the shot. windowBackgroundColor would resolve against whatever appearance the exporting
    // process happens to run under, which is how light shots ended up grey.
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = Brand.card(dark: dark).cgColor
    hosting.frame = CGRect(origin: .zero, size: size ?? hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    guard hosting.bounds.width > 0, hosting.bounds.height > 0,
      let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    else { return nil }
    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: rep) }
    let image = NSImage(size: hosting.bounds.size)
    image.addRepresentation(rep)
    return image
  }

  public static func png(_ view: some View, dark: Bool, size: CGSize? = nil) -> Data? {
    guard let image = image(view, dark: dark, size: size), let rep = image.representations.first as? NSBitmapImageRep
    else {
      return nil
    }
    return rep.representation(using: .png, properties: [:])
  }
}

@MainActor
final class MenuTarget: NSObject {
  private weak var controller: AppController?

  init(controller: AppController) {
    self.controller = controller
  }

  func menu() -> NSMenu {
    controller?.contextMenu() ?? NSMenu()
  }

  @objc func run(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    controller?.run(id)
  }
}

@MainActor
public final class LogWindowController: NSWindowController {
  public let log: LogBuffer
  private let present: @MainActor (NSWindow, Any?) -> Void

  public convenience init(log: LogBuffer, presentsWindow: Bool = true) {
    self.init(log: log, present: LiveDependencies.windowPresentation(enabled: presentsWindow))
  }

  init(log: LogBuffer, present: @escaping @MainActor (NSWindow, Any?) -> Void) {
    self.log = log
    self.present = present
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 480), styleMask: [.titled, .closable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Token Menu Bar Log"
    window.contentView = NSHostingView(rootView: FullLogView(log: log))
    window.center()
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  public override func showWindow(_ sender: Any?) {
    guard let window else { return }
    present(window, sender)
  }
}
