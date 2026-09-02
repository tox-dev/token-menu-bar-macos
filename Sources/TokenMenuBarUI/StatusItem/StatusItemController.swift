import AppKit
import TokenMenuBarCore

public struct StatusItemProbe: Equatable, Sendable {
  public let isVisible: Bool
  public let buttonHidden: Bool
  public let windowVisible: Bool?
  public let occlusionVisible: Bool?
  public let length: Double
  public let buttonWidth: Double
  public let frontmostApp: String?

  public init(
    isVisible: Bool, buttonHidden: Bool, windowVisible: Bool?, occlusionVisible: Bool?, length: Double,
    buttonWidth: Double, frontmostApp: String?
  ) {
    self.isVisible = isVisible
    self.buttonHidden = buttonHidden
    self.windowVisible = windowVisible
    self.occlusionVisible = occlusionVisible
    self.length = length
    self.buttonWidth = buttonWidth
    self.frontmostApp = frontmostApp
  }

  public var summary: String {
    """
    visible=\(isVisible) buttonHidden=\(buttonHidden) window=\(windowVisible.map(String.init) ?? "-") \
    occlusion=\(occlusionVisible.map(String.init) ?? "-") length=\(Int(length)) width=\(Int(buttonWidth)) \
    front=\(frontmostApp ?? "-")
    """
  }
}

@MainActor
final class MenuCloseObserver: NSObject, NSMenuDelegate {
  private let onClose: () -> Void

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
  }

  func menuDidClose(_ menu: NSMenu) {
    onClose()
  }
}

@MainActor
public final class StatusItemController {
  public let item: NSStatusItem
  private let log: LogBuffer
  private var lastSignature: StatusRenderSignature?
  private var countdownTask: Task<Void, Never>?
  private var probeTask: Task<Void, Never>?
  private var lastProbe: StatusItemProbe?
  private var planner = AdaptiveWidthPlanner()
  private var fitTask: Task<Void, Never>?
  private var deferredForget = false
  private var frozenLength: CGFloat?
  private var countdownGeneration = 0
  private(set) var ladder: [StatusItemModel] = [.empty]
  public var adaptive = true
  public var notchAreas: (() -> (CGRect?, CGRect?))?
  public var frontmostContext: () -> String = {
    normalizedContext(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }
  public var visibleItemFrame: (NSStatusItem) -> CGRect? = { StatusItemController.onScreenFrame(of: $0.button?.window) }
  private var lastForeignContext = ""
  public var fitCheckDelay: Duration = .milliseconds(30)
  private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
  private var appearanceObservation: NSKeyValueObservation?
  private(set) var model: StatusItemModel = .empty
  public var onClick: (() -> Void)?
  public var onCountdownTick: (() -> Void)?
  public var onProbeChange: ((StatusItemProbe) -> Void)?
  public var menuProvider: (() -> NSMenu)?
  public var popoverVisible = false {
    didSet {
      guard popoverVisible != oldValue else { return }
      if popoverVisible {
        if let width = item.button?.frame.width, width > 0 {
          frozenLength = width
          item.length = width
        }
        fitTask?.cancel()
        fitTask = nil
      } else {
        frozenLength = nil
        item.length = NSStatusItem.variableLength
        if deferredForget { planner.forget() }
        deferredForget = false
        restart(trigger: "popover-close")
      }
    }
  }
  public var detailedLoggingEnabled = false {
    didSet { updateProbeTimer() }
  }
  private let presentMenu: (NSStatusBarButton) -> Void
  private let clock: Clock
  private let diagnosticProbeInterval: TimeInterval

  public init(
    statusBar: NSStatusBar = .system,
    item existingItem: NSStatusItem? = nil,
    log: LogBuffer,
    clock: Clock = .system,
    diagnosticProbeInterval: TimeInterval = 60,
    autosaveName: String? = StatusItemController.autosaveName(bundleIdentifier: Bundle.main.bundleIdentifier),
    presentMenu: @escaping (NSStatusBarButton) -> Void
  ) {
    self.log = log
    self.clock = clock
    self.diagnosticProbeInterval = diagnosticProbeInterval
    self.presentMenu = presentMenu
    item = existingItem ?? statusBar.statusItem(withLength: NSStatusItem.variableLength)
    item.length = NSStatusItem.variableLength
    item.autosaveName = autosaveName
    item.button?.target = self
    item.button?.action = #selector(buttonClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in self?.appearanceChanged()
    }
    let center = NotificationCenter.default
    for name in [
      NSApplication.didChangeScreenParametersNotification, NSWorkspace.didWakeNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      let sender: NotificationCenter =
        name == NSApplication.didChangeScreenParametersNotification ? center : NSWorkspace.shared.notificationCenter
      let token = sender.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.layoutChanged(
            forgetting: name != NSWorkspace.didActivateApplicationNotification,
            trigger: name.rawValue)
        }
      }
      // Two of these live on the workspace's own centre, so each token has to go back to the centre it came from.
      observers.append((sender, token))
    }
  }

  public static func autosaveName(bundleIdentifier: String?) -> String {
    "\(bundleIdentifier ?? "dev.tox.token-menu-bar").status"
  }

  nonisolated static func normalizedContext(_ bundleIdentifier: String?) -> String {
    bundleIdentifier ?? ""
  }

  /// Which app's menu bar the item is competing with. Opening the popover activates this app, and remembering a
  /// tier against ourselves would re-tier the item every time it opens, so the app underneath keeps the context.
  func layoutContext() -> String {
    let frontmost = frontmostContext()
    if !frontmost.isEmpty, frontmost != Bundle.main.bundleIdentifier { lastForeignContext = frontmost }
    return lastForeignContext
  }

  func layoutChanged(forgetting: Bool, trigger: String = "layout-change") {
    if detailedLoggingEnabled { probe() }
    guard !popoverVisible else {
      deferredForget = deferredForget || forgetting
      recordStatus(action: .deferred, trigger: trigger)
      return
    }
    if forgetting { planner.forget() }
    restart(trigger: trigger)
  }

  nonisolated func appearanceChanged() {
    Task { @MainActor in render(force: true) }
  }

  public var isDark: Bool {
    let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
    return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }

  public var barHeight: CGFloat {
    max(NSStatusBar.system.thickness, 22)
  }

  public func update(_ model: StatusItemModel) {
    update(ladder: [model])
  }

  public func update(ladder: [StatusItemModel]) {
    let height = barHeight
    let dark = isDark
    let candidates = ladder.isEmpty ? [.empty] : ladder
    let widths = candidates.map {
      Double(StatusItemRenderer.attributedTitle(for: $0, height: height, dark: dark).size().width)
    }
    self.ladder = AdaptiveWidthPlanner.ladder(candidates, widths: widths)
    if popoverVisible {
      let index = adaptive ? planner.index : 0
      apply(self.ladder[min(index, self.ladder.count - 1)])
      recordStatus(action: .deferred, trigger: "model-update")
      return
    }
    restart(trigger: "model-update")
  }

  func restart(trigger: String = "restart") {
    guard !popoverVisible else {
      recordStatus(action: .deferred, trigger: trigger)
      return
    }
    let count = adaptive ? self.ladder.count : 1
    let context = layoutContext()
    let oldIndex = planner.index
    let index = planner.begin(context: context, ladderCount: count)
    apply(self.ladder[min(index, self.ladder.count - 1)])
    recordStatus(action: .retier, trigger: trigger, oldTier: oldIndex, newTier: index, context: context)
    scheduleFitCheck()
  }

  func apply(_ model: StatusItemModel) {
    self.model = model
    render(force: false)
    updateCountdownTimer()
  }

  func scheduleFitCheck() {
    fitTask?.cancel()
    guard !popoverVisible, adaptive, ladder.count > 1 else { return }
    fitTask = Task { @MainActor [weak self, fitCheckDelay] in
      guard (try? await Task.sleep(for: fitCheckDelay)) != nil else { return }
      self?.checkFit()
    }
  }

  public static func onScreenFrame(of window: NSWindow?, screens: [NSScreen] = NSScreen.screens) -> CGRect? {
    guard let window, window.isVisible,
      AdaptiveWidthPlanner.isOnScreen(itemFrame: window.frame, screenFrames: screens.map(\.frame))
    else { return nil }
    return window.frame
  }

  public func settleFitCheck() async {
    await fitTask?.value
  }

  public func fits() -> Bool {
    guard let frame = visibleItemFrame(item) else { return false }
    let screen = item.button?.window?.screen
    let areas = notchAreas?() ?? (screen?.auxiliaryTopLeftArea, screen?.auxiliaryTopRightArea)
    return !AdaptiveWidthPlanner.hiddenByNotch(itemFrame: frame, leftArea: areas.0, rightArea: areas.1)
  }

  @discardableResult
  public func checkFit() -> Bool {
    guard !popoverVisible else { return true }
    let fits = fits()
    let oldIndex = planner.index
    let context = layoutContext()
    if fits {
      planner.didFit(context: context)
    } else if let next = planner.didNotFit(ladderCount: ladder.count) {
      log.logDebug("status item does not fit; stepping down to tier \(next)")
      apply(ladder[next])
      recordStatus(
        action: .retier,
        trigger: "fit-check",
        oldTier: oldIndex,
        newTier: next,
        fits: false,
        context: context)
      scheduleFitCheck()
    }
    recordStatus(action: .probe, trigger: "fit-check", fits: fits, context: context)
    return fits
  }

  @discardableResult
  public func collapseToNarrowest() -> Bool {
    let index = planner.selectNarrowest(ladderCount: ladder.count)
    apply(ladder[index])
    return true
  }

  public func reattach() {
    item.isVisible = false
    item.isVisible = true
    lastSignature = nil
    render(force: true)
  }

  func render(force: Bool) {
    let signature = StatusRenderSignature(model: model, dark: isDark, height: Double(barHeight))
    guard force || signature != lastSignature, let button = item.button else { return }
    lastSignature = signature
    let height = barHeight
    if model.showsIcon {
      button.image = AppIcon.image(height: height, tone: model.iconTone, dark: isDark)
      button.imagePosition = model.cells.isEmpty ? .imageOnly : .imageLeading
    } else {
      button.image = nil
      button.imagePosition = .noImage
    }
    button.attributedTitle = StatusItemRenderer.attributedTitle(for: model, height: height, dark: isDark)
    button.setAccessibilityLabel(StatusItemRenderer.accessibilityDescription(for: model))
    button.toolTip = model.cells.map(\.tooltip).joined(separator: "\n")
    item.length = frozenLength ?? NSStatusItem.variableLength
  }

  func updateCountdownTimer() {
    guard model.countdownActive else {
      countdownGeneration += 1
      countdownTask?.cancel()
      countdownTask = nil
      return
    }
    guard countdownTask == nil else { return }
    countdownGeneration += 1
    let generation = countdownGeneration
    countdownTask = Task { @MainActor [weak self, clock] in
      while !Task.isCancelled {
        let now = clock.now()
        let deadline = Self.nextCountdownUpdate(after: now)
        do {
          try await clock.sleep(deadline.timeIntervalSince(now))
        } catch {
          break
        }
        guard !Task.isCancelled else { break }
        self?.onCountdownTick?()
      }
      guard let self, self.countdownGeneration == generation else { return }
      self.countdownTask = nil
    }
  }

  public var countdownRunning: Bool {
    countdownTask != nil
  }

  nonisolated static func nextCountdownUpdate(after date: Date) -> Date {
    Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
  }

  func updateProbeTimer() {
    probeTask?.cancel()
    probeTask = nil
    guard detailedLoggingEnabled else { return }
    probeTask = Self.ticker(every: diagnosticProbeInterval, clock: clock) { [weak self] in self?.probe() }
  }

  public var diagnosticProbeRunning: Bool {
    probeTask != nil
  }

  nonisolated static func ticker(
    every interval: TimeInterval,
    clock: Clock,
    _ tick: @escaping @MainActor @Sendable () -> Void
  ) -> Task<Void, Never> {
    Task.detached {
      while (try? await clock.sleep(interval)) != nil {
        guard !Task.isCancelled else { break }
        await tick()
      }
    }
  }

  @discardableResult
  public func probe() -> StatusItemProbe {
    let button = item.button
    let window = button?.window
    let sample = StatusItemProbe(
      isVisible: item.isVisible,
      buttonHidden: button?.isHidden ?? true,
      windowVisible: window?.isVisible,
      occlusionVisible: window.map { $0.occlusionState.contains(.visible) },
      length: Double(item.length),
      buttonWidth: Double(button?.frame.width ?? 0),
      frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName
    )
    if sample != lastProbe {
      lastProbe = sample
      log.logDebug("status item \(sample.summary)")
      recordStatus(action: .probe, trigger: "visibility-probe", context: layoutContext())
      onProbeChange?(sample)
    }
    return sample
  }

  private func recordStatus(
    action: StatusDiagnostic.Action,
    trigger: String,
    oldTier: Int? = nil,
    newTier: Int? = nil,
    fits: Bool? = nil,
    context: String? = nil
  ) {
    guard detailedLoggingEnabled else { return }
    let buttonFrame = buttonFrameOnScreen.map(DiagnosticRect.init)
    let event: StatusDiagnostic?
    if action == .retier, let oldTier, let newTier {
      event = StatusDiagnostic.retierIfChanged(
        trigger: trigger,
        buttonFrame: buttonFrame,
        oldTier: oldTier,
        newTier: newTier,
        visible: item.isVisible,
        popoverVisible: popoverVisible,
        fits: fits,
        layoutContext: context)
    } else {
      event = StatusDiagnostic(
        action: action,
        trigger: trigger,
        buttonFrame: buttonFrame,
        oldTier: oldTier,
        newTier: newTier,
        visible: item.isVisible,
        popoverVisible: popoverVisible,
        fits: fits,
        layoutContext: context)
    }
    guard let event else { return }
    log.detailed(.status(event))
  }

  public var buttonFrameOnScreen: CGRect? {
    guard let button = item.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  @objc func buttonClicked(_ sender: Any?) {
    handleClick(NSApp.currentEvent)
  }

  public func handleClick(_ event: NSEvent?) {
    if event?.type == .rightMouseUp, let menu = menuProvider?() { return show(menu) }
    onClick?()
  }

  public func show(_ menu: NSMenu) {
    menu.delegate = menuDelegate
    item.menu = menu
    if let button = item.button { presentMenu(button) }
  }

  private lazy var menuDelegate = MenuCloseObserver { [weak self] in self?.item.menu = nil }

  public func remove(from statusBar: NSStatusBar = .system) {
    countdownTask?.cancel()
    countdownTask = nil
    countdownGeneration += 1
    fitTask?.cancel()
    fitTask = nil
    detailedLoggingEnabled = false
    for observer in observers { observer.center.removeObserver(observer.token) }
    observers.removeAll()
    appearanceObservation?.invalidate()
    appearanceObservation = nil
    statusBar.removeStatusItem(item)
  }
}
