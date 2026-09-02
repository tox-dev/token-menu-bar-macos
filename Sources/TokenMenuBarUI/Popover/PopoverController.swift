import AppKit
import SwiftUI
import TokenMenuBarCore

typealias GlobalEventMonitorInstaller = (
  NSEvent.EventTypeMask, @escaping (NSEvent) -> Void
) -> Any?

@MainActor
public final class PopoverController: NSObject, NSPopoverDelegate {
  public let popover: NSPopover
  private let hosting: NSHostingController<AnyView>
  private let isKeyWindow: (NSWindow) -> Bool
  private let log: LogBuffer?
  private var gate = PopoverDismissalGate()
  private var menuObservers: [any NSObjectProtocol] = []
  private var menuTrackingDepth = 0
  private var monitors: [Any] = []
  private var resizeObserver: (any NSObjectProtocol)?
  private var requestedContentSize: CGSize?
  private var recoveryAnchorWindow: NSWindow?
  private var anchorFrame: CGRect?
  private var pinnedTopY: CGFloat?
  private var screenFrame: CGRect?
  private var screenID: String?
  private var visibleFrame: CGRect?
  private let presentsWindow: Bool
  private let recoversOffscreenAnchor: Bool
  private let addGlobalEventMonitor: GlobalEventMonitorInstaller
  public var onVisibilityChange: ((Bool) -> Void)?
  public var onRefresh: (() -> Void)?
  public var excludedFrame: (() -> CGRect?)?
  private(set) var measured: [PopoverTab: CGSize] = [:]
  private(set) var activeTab = PopoverTab.usage
  private(set) var sessionWidth = PopoverGeometry.stableWidth()
  private(set) var popoverChromeSize = CGSize.zero
  public var maximum = CGSize(width: PopoverGeometry.stableWidth(), height: CGFloat.greatestFiniteMagnitude)

  public convenience init(
    content: AnyView, log: LogBuffer? = nil, animates: Bool = false, presentsWindow: Bool = true,
    recoversOffscreenAnchor: Bool = false
  ) {
    self.init(
      content: content, log: log, animates: animates, isKeyWindow: { $0.isKeyWindow },
      presentsWindow: presentsWindow, recoversOffscreenAnchor: recoversOffscreenAnchor)
  }

  init(
    content: AnyView, log: LogBuffer?, animates: Bool, isKeyWindow: @escaping (NSWindow) -> Bool,
    presentsWindow: Bool = true, recoversOffscreenAnchor: Bool = false,
    addGlobalEventMonitor: @escaping GlobalEventMonitorInstaller = NSEvent.addGlobalMonitorForEvents
  ) {
    hosting = NSHostingController(rootView: content)
    self.isKeyWindow = isKeyWindow
    self.log = log
    self.presentsWindow = presentsWindow
    self.recoversOffscreenAnchor = recoversOffscreenAnchor
    self.addGlobalEventMonitor = addGlobalEventMonitor
    popover = NSPopover()
    super.init()
    popover.behavior = .applicationDefined
    popover.animates = animates
    popover.contentViewController = hosting
    popover.delegate = self
  }

  public var isShown: Bool {
    popover.isShown
  }

  public func setContent(_ content: AnyView) {
    hosting.rootView = content
  }

  public func toggle(
    relativeTo view: NSView?,
    anchorFrame: CGRect?,
    visibleFrame: CGRect?,
    screenID: String? = nil,
    screenFrame: CGRect? = nil
  ) {
    if popover.isShown {
      close()
    } else {
      show(
        relativeTo: view,
        anchorFrame: anchorFrame,
        visibleFrame: visibleFrame,
        screenID: screenID,
        screenFrame: screenFrame)
    }
  }

  public func show(
    relativeTo view: NSView?,
    anchorFrame: CGRect?,
    visibleFrame: CGRect?,
    screenID: String? = nil,
    screenFrame: CGRect? = nil
  ) {
    guard let view, view.window != nil, !popover.isShown else { return }
    removeResizeObserver()
    pinnedTopY = nil
    requestedContentSize = nil
    popoverChromeSize = .zero
    sessionWidth = PopoverGeometry.stableWidth()
    maximum = CGSize(width: sessionWidth, height: .greatestFiniteMagnitude)
    let resolvedVisibleFrame = Self.resolveVisibleFrame(
      visibleFrame, windowScreen: view.window?.screen?.visibleFrame, mainScreen: NSScreen.main?.visibleFrame)
    let reportedAnchorFrame =
      anchorFrame ?? Self.frameOnScreen(of: view)
      ?? resolvedVisibleFrame.map {
        CGRect(x: $0.midX, y: $0.maxY, width: 1, height: 1)
      }
    let presentation = presentationAnchor(
      view: view, anchorFrame: reportedAnchorFrame, visibleFrame: resolvedVisibleFrame)
    updateGeometry(
      anchorFrame: presentation.frame,
      visibleFrame: resolvedVisibleFrame,
      screenID: screenID,
      screenFrame: screenFrame,
      trigger: "open")
    gate = PopoverDismissalGate()
    onVisibilityChange?(true)
    // An accessory app is never frontmost on its own, and a popover in a background app takes no key events, so
    // neither Tab nor VoiceOver reaches the controls until the app activates.
    NSApplication.shared.activate()
    popover.show(relativeTo: presentation.view.bounds, of: presentation.view, preferredEdge: .minY)
    guard popover.isShown else {
      removeRecoveryAnchor()
      onVisibilityChange?(false)
      return
    }
    configureShownWindow()
    if presentation.recovered {
      recordPanel(action: .screenChanged, trigger: "offscreen-anchor-recovery")
    }
    installMonitors()
    installMenuTrackingObservers()
    recordPanel(action: .open, trigger: "status-item")
  }

  public func close() {
    guard popover.isShown else { return }
    popover.close()
  }

  public func popoverDidClose(_ notification: Notification) {
    TooltipPresenter.shared.tearDown()
    removeResizeObserver()
    pinnedTopY = nil
    removeMonitors()
    removeMenuTrackingObservers()
    removeRecoveryAnchor()
    onVisibilityChange?(false)
  }

  public func popoverShouldClose(_ popover: NSPopover) -> Bool {
    true
  }

  public func measure(_ measurement: PopoverMeasurement) {
    measured[measurement.tab] = measurement.size
    guard measurement.tab == activeTab else { return }
    applySize()
  }

  public func select(tab: PopoverTab) {
    activeTab = tab
    guard measured[tab] != nil else { return }
    Task { @MainActor [weak self] in self?.applySize() }
  }

  public func applySize(trigger: String = "measurement") {
    let content = idealContentSize()
    let size = PopoverGeometry.clamp(content, maximum: maximum)
    guard requestedContentSize.map({ Self.differs($0, size) }) ?? true else { return }
    requestedContentSize = size
    guard Self.differs(popover.contentSize, size) else { return }
    DiagnosticSignposts.geometry.withInterval("Panel resize") { popover.contentSize = size }
    pinWindowFrame()
    recordPanel(action: .resize, trigger: trigger, proposed: content, clamped: size)
  }

  public func updateGeometry(
    anchorFrame: CGRect?,
    visibleFrame: CGRect?,
    screenID: String? = nil,
    screenFrame: CGRect? = nil,
    trigger: String = "display-change"
  ) {
    guard let anchorFrame, let visibleFrame else { return }
    var shiftedOriginX: CGFloat?
    if popover.isShown {
      let anchorDeltaX = Self.anchorDeltaX(current: anchorFrame, previous: self.anchorFrame)
      let anchorOffset = Self.anchorOffset(pinnedTopY: pinnedTopY, previous: self.anchorFrame)
      pinnedTopY = anchorFrame.minY + anchorOffset
      if abs(anchorDeltaX) > 0.5, let window = popover.contentViewController?.view.window {
        shiftedOriginX = window.frame.minX + anchorDeltaX
      }
    }
    self.anchorFrame = anchorFrame
    self.screenID = screenID
    self.screenFrame = screenFrame
    maximum = PopoverGeometry.maxSize(
      anchor: anchorFrame, visibleFrame: visibleFrame, popoverChromeSize: popoverChromeSize)
    sessionWidth = maximum.width
    self.visibleFrame = visibleFrame
    applySize(trigger: trigger)
    if popover.isShown {
      if let shiftedOriginX, let window = popover.contentViewController?.view.window {
        let maximumX = max(visibleFrame.maxX - window.frame.width, visibleFrame.minX)
        let x = min(max(shiftedOriginX, visibleFrame.minX), maximumX)
        window.setFrameOrigin(CGPoint(x: x, y: window.frame.minY))
      }
      pinWindowFrame()
      recordPanel(action: .screenChanged, trigger: trigger)
    }
  }

  static func resolveVisibleFrame(
    _ explicit: CGRect?, windowScreen: CGRect?, mainScreen: CGRect?
  ) -> CGRect? {
    if let explicit { return explicit }
    if let windowScreen { return windowScreen }
    return mainScreen
  }

  static func anchorDeltaX(current: CGRect, previous: CGRect?) -> CGFloat {
    guard let previous else { return 0 }
    return current.midX - previous.midX
  }

  static func anchorOffset(pinnedTopY: CGFloat?, previous: CGRect?) -> CGFloat {
    guard let pinnedTopY, let previous else { return 0 }
    return pinnedTopY - previous.minY
  }

  private func recordPanel(
    action: PanelDiagnostic.Action,
    trigger: String,
    proposed: CGSize? = nil,
    clamped: CGSize? = nil
  ) {
    guard let log, log.debugEnabled else { return }
    let proposed = proposed ?? idealContentSize()
    let clamped = clamped ?? PopoverGeometry.clamp(proposed, maximum: maximum)
    let window = popover.contentViewController?.view.window
    log.detailed(
      .panel(
        PanelDiagnostic(
          action: action,
          trigger: trigger,
          tab: activeTab.rawValue,
          anchor: anchorFrame.map(DiagnosticRect.init),
          screenID: screenID,
          screenFrame: (screenFrame ?? visibleFrame).map(DiagnosticRect.init),
          maximum: DiagnosticSize(maximum),
          proposed: DiagnosticSize(proposed),
          clamped: DiagnosticSize(clamped),
          resultFrame: window.map { DiagnosticRect($0.frame) },
          appActive: NSApp.isActive,
          windowKey: window?.isKeyWindow,
          windowMain: window?.isMainWindow,
          frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)))
  }

  func installMonitors() {
    removeMonitors()
    monitors.append(
      addGlobalEventMonitor(Self.globalEventMask) { [weak self] in self?.handle($0) } as Any)
    monitors.append(
      NSEvent.addLocalMonitorForEvents(matching: Self.localEventMask) { [weak self] event in
        guard let self else { return event }
        return self.routeLocal(event)
      } as Any)
  }

  static let globalEventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
  static let localEventMask = globalEventMask.union(.keyDown)

  func removeMonitors() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors.removeAll()
  }

  @discardableResult
  public func forward(_ event: NSEvent) -> NSEvent {
    handle(event)
    return event
  }

  func routeLocal(_ event: NSEvent) -> NSEvent? {
    guard event.type == .keyDown else {
      handle(event)
      return event
    }
    guard owns(event), let window = popover.contentViewController?.view.window, acceptsKeyRouting(in: window) else {
      return event
    }
    handle(event)
    return nil
  }

  @discardableResult
  public func handle(_ event: NSEvent) -> Bool {
    if ownsRefresh(event) {
      onRefresh?()
      return true
    }
    let trigger: PopoverDismissalTrigger
    switch event.type {
    case .leftMouseDown, .rightMouseDown: trigger = .mouseDown
    case .mouseMoved: trigger = .mouseMoved
    case .keyDown: trigger = .keyEscape
    default: return false
    }
    if trigger == .keyEscape, event.keyCode != 53 { return false }
    let mouseLocation =
      if let window = event.window {
        window.convertPoint(toScreen: event.locationInWindow)
      } else {
        event.locationInWindow
      }
    return evaluate(trigger: trigger, mouseLocation: mouseLocation)
  }

  private func owns(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, let window = popover.contentViewController?.view.window,
      isKeyWindow(window), event.windowNumber == window.windowNumber
    else { return false }
    return ownsRefresh(event) || ownsEscape(event)
  }

  private func ownsRefresh(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "r" else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    return modifiers == .command
  }

  private func ownsEscape(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.keyCode == 53 else { return false }
    return event.modifierFlags.intersection([.command, .control, .option]).isEmpty
  }

  private func acceptsKeyRouting(in window: NSWindow) -> Bool {
    // AppKit does not send events from nested control and menu tracking loops through a local monitor. Keep the
    // explicit state for tracking-area exits and for any key event already queued when a menu starts tracking.
    guard menuTrackingDepth == 0 else { return false }
    let responder = window.firstResponder
    if let input = responder as? any NSTextInputClient, input.hasMarkedText() { return false }
    if let textView = responder as? NSTextView, textView.isFieldEditor { return false }
    return true
  }

  @discardableResult
  public func evaluate(trigger: PopoverDismissalTrigger, mouseLocation: CGPoint) -> Bool {
    let frame = popover.contentViewController?.view.window?.frame
    guard
      gate.shouldClose(
        mouseLocation: mouseLocation, popoverFrame: frame, excludedFrame: excludedFrame?(), trigger: trigger)
    else { return false }
    close()
    return true
  }

  private func configureShownWindow() {
    let window = hosting.view.window!
    if !presentsWindow { window.alphaValue = 0 }
    if recoversOffscreenAnchor {
      window.setAccessibilityElement(true)
      window.setAccessibilityRole(.window)
      window.setAccessibilityLabel("Token Menu Bar")
    }
    pinnedTopY = window.frame.maxY
    let contentSize = hosting.view.frame.size
    if contentSize.width > 0, contentSize.height > 0 {
      popoverChromeSize = CGSize(
        width: max(window.frame.width - contentSize.width, 0),
        height: max(window.frame.height - contentSize.height, 0))
    }
    if let anchorFrame, let visibleFrame {
      maximum = PopoverGeometry.maxSize(
        anchor: anchorFrame, visibleFrame: visibleFrame, popoverChromeSize: popoverChromeSize)
      sessionWidth = maximum.width
    }
    resizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: window, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.popover.isShown else { return }
        self.pinWindowFrame()
        self.recordPanel(action: .resize, trigger: "backing-window")
      }
    }
    if measured[activeTab] == nil || popover.contentSize.width > maximum.width + 1
      || popover.contentSize.height > maximum.height + 1
    {
      applySize(trigger: "window-chrome")
    }
  }

  private func idealContentSize() -> CGSize {
    CGSize(
      width: sessionWidth,
      height: PopoverGeometry.preferredHeight(for: activeTab, measured: measured[activeTab]?.height))
  }

  private func presentationAnchor(
    view: NSView, anchorFrame: CGRect?, visibleFrame: CGRect?
  ) -> (view: NSView, frame: CGRect?, recovered: Bool) {
    removeRecoveryAnchor()
    guard recoversOffscreenAnchor, let anchorFrame, let visibleFrame, !anchorFrame.intersects(visibleFrame) else {
      return (view, anchorFrame, false)
    }
    let size = CGSize(width: max(anchorFrame.width, 1), height: max(anchorFrame.height, 1))
    let frame = PopoverGeometry.recoveredFrame(
      windowFrame: CGRect(origin: .zero, size: size), visibleFrame: visibleFrame)
    let window = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.isOpaque = false
    window.isReleasedWhenClosed = false
    let anchor = NSView(frame: CGRect(origin: .zero, size: size))
    window.contentView = anchor
    window.orderFrontRegardless()
    recoveryAnchorWindow = window
    return (anchor, frame, true)
  }

  private func removeRecoveryAnchor() {
    recoveryAnchorWindow?.orderOut(nil)
    recoveryAnchorWindow = nil
  }

  private static func differs(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) > 1 || abs(lhs.height - rhs.height) > 1
  }

  private static func frameOnScreen(of view: NSView) -> CGRect? {
    let window = view.window!
    let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
    return frame.isEmpty ? nil : frame
  }

  private func pinWindowFrame() {
    // NSPopover does not define which edge survives contentSize changes. Keep the backing-window dependency here so
    // an NSPanel migration can delete one compatibility seam instead of unwinding window manipulation across the UI.
    guard let pinnedTopY, let window = popover.contentViewController?.view.window else { return }
    let y = pinnedTopY - window.frame.height
    guard abs(window.frame.minY - y) > 0.5 else { return }
    window.setFrameOrigin(CGPoint(x: window.frame.minX, y: y))
  }

  private func installMenuTrackingObservers() {
    removeMenuTrackingObservers()
    menuObservers = [
      NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.menuTrackingDepth += 1 }
      },
      NotificationCenter.default.addObserver(
        forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.menuTrackingDepth = max(self.menuTrackingDepth - 1, 0)
        }
      },
    ]
  }

  private func removeMenuTrackingObservers() {
    for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
    menuObservers.removeAll()
    menuTrackingDepth = 0
  }

  private func removeResizeObserver() {
    guard let resizeObserver else { return }
    NotificationCenter.default.removeObserver(resizeObserver)
    self.resizeObserver = nil
  }
}
