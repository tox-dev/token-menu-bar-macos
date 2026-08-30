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
  private(set) var ladder: [StatusItemModel] = [.empty]
  public var adaptive = true
  public var notchAreas: () -> (CGRect?, CGRect?) = {
    (NSScreen.main?.auxiliaryTopLeftArea, NSScreen.main?.auxiliaryTopRightArea)
  }
  public var frontmostContext: () -> String = {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
  }
  public var visibleItemFrame: (NSStatusItem) -> CGRect? = { StatusItemController.onScreenFrame(of: $0.button?.window) }
  public var fitCheckDelay: Duration = .milliseconds(250)
  private var observers: [Any] = []
  private var appearanceObservation: NSKeyValueObservation?
  private(set) var model: StatusItemModel = .empty
  public var onClick: (() -> Void)?
  public var onCountdownTick: (() -> Void)?
  public var onProbeChange: ((StatusItemProbe) -> Void)?
  public var menuProvider: (() -> NSMenu)?
  public var probing = false {
    didSet { updateProbeTimer() }
  }
  private let presentMenu: (NSStatusBarButton) -> Void
  private let tickInterval: TimeInterval

  public init(
    statusBar: NSStatusBar = .system, log: LogBuffer, tickInterval: TimeInterval = 1,
    presentMenu: @escaping (NSStatusBarButton) -> Void
  ) {
    self.log = log
    self.tickInterval = tickInterval
    self.presentMenu = presentMenu
    item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "dev.tox.token-menu-bar.status"
    item.button?.target = self
    item.button?.action = #selector(buttonClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.button?.setAccessibilityLabel("Token Menu Bar")
    appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in self?.appearanceChanged()
    }
    let center = NotificationCenter.default
    for name in [
      NSApplication.didChangeScreenParametersNotification, NSWorkspace.didWakeNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      let sender: NotificationCenter =
        name == NSApplication.didChangeScreenParametersNotification ? center : NSWorkspace.shared.notificationCenter
      observers.append(
        sender.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.layoutChanged(forgetting: name != NSWorkspace.didActivateApplicationNotification)
          }
        })
    }
  }

  func layoutChanged(forgetting: Bool) {
    probe()
    if forgetting { planner.forget() }
    restart()
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
    let widths = ladder.map {
      Double(StatusItemRenderer.attributedTitle(for: $0, height: barHeight, dark: isDark).size().width)
    }
    self.ladder = AdaptiveWidthPlanner.ladder(ladder, widths: widths)
    restart()
  }

  func restart() {
    let count = adaptive ? self.ladder.count : 1
    let index = planner.begin(context: frontmostContext(), ladderCount: count)
    apply(self.ladder[min(index, self.ladder.count - 1)])
    scheduleFitCheck()
  }

  func apply(_ model: StatusItemModel) {
    self.model = model
    render(force: false)
    updateCountdownTimer()
  }

  func scheduleFitCheck() {
    fitTask?.cancel()
    guard adaptive, ladder.count > 1 else { return }
    fitTask = Task { @MainActor [weak self, fitCheckDelay] in
      guard (try? await Task.sleep(for: fitCheckDelay)) != nil else { return }
      self?.checkFit()
    }
  }

  /// macOS parks a status item that no longer fits beyond the screen edge, so an item whose frame no longer
  /// overlaps any screen counts as hidden. Overlap rather than containment: a legitimate item at the very edge
  /// can still report a frame that pokes a point or two past the screen.
  public static func onScreenFrame(of window: NSWindow?, screens: [NSScreen] = NSScreen.screens) -> CGRect? {
    guard let window, window.isVisible, window.frame.width > 0,
      screens.contains(where: { $0.frame.intersects(window.frame) })
    else { return nil }
    return window.frame
  }

  public func settleFitCheck() async {
    await fitTask?.value
  }

  public func fits() -> Bool {
    guard let frame = visibleItemFrame(item) else { return false }
    let areas = notchAreas()
    return !AdaptiveWidthPlanner.hiddenByNotch(itemFrame: frame, leftArea: areas.0, rightArea: areas.1)
  }

  @discardableResult
  public func checkFit() -> Bool {
    let fits = fits()
    if fits {
      planner.didFit(context: frontmostContext())
    } else if let next = planner.didNotFit(ladderCount: ladder.count) {
      log.logDebug("status item does not fit; stepping down to tier \(next)")
      apply(ladder[next])
      scheduleFitCheck()
    }
    return fits
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
    button.toolTip = model.cells.map(\.tooltip).joined(separator: "\n")
    item.length = NSStatusItem.variableLength
  }

  func updateCountdownTimer() {
    if model.countdownActive, countdownTask == nil {
      countdownTask = Self.ticker(every: tickInterval) { [weak self] in self?.onCountdownTick?() }
    } else if !model.countdownActive {
      countdownTask?.cancel()
      countdownTask = nil
    }
  }

  public var countdownRunning: Bool {
    countdownTask != nil
  }

  func updateProbeTimer() {
    probeTask?.cancel()
    probeTask = nil
    guard probing else { return }
    probeTask = Self.ticker(every: tickInterval) { [weak self] in self?.probe() }
  }

  static func ticker(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
      while (try? await Task.sleep(for: .seconds(interval))) != nil {
        tick()
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
      onProbeChange?(sample)
    }
    return sample
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
    fitTask?.cancel()
    fitTask = nil
    probing = false
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    statusBar.removeStatusItem(item)
  }
}
