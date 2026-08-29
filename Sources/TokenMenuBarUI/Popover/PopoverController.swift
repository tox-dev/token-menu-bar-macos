import AppKit
import SwiftUI
import TokenMenuBarCore

@MainActor
public final class PopoverController: NSObject, NSPopoverDelegate {
  public let popover: NSPopover
  private let hosting: NSHostingController<AnyView>
  private var gate = PopoverDismissalGate()
  private var monitors: [Any] = []
  private var lastTopCenter: CGPoint?
  public var onVisibilityChange: ((Bool) -> Void)?
  public var excludedFrame: (() -> CGRect?)?
  private(set) var measured: [String: CGSize] = [:]
  private(set) var activeTab: String = PopoverTab.usage.rawValue
  public var maximum: CGSize = CGSize(width: 900, height: 900)

  public init(content: AnyView) {
    hosting = NSHostingController(rootView: content)
    popover = NSPopover()
    super.init()
    popover.behavior = .applicationDefined
    popover.animates = false
    popover.contentViewController = hosting
    popover.delegate = self
  }

  public var isShown: Bool {
    popover.isShown
  }

  public func setContent(_ content: AnyView) {
    hosting.rootView = content
  }

  public func toggle(relativeTo view: NSView?, anchorFrame: CGRect?, visibleFrame: CGRect?) {
    if popover.isShown {
      close()
    } else {
      show(relativeTo: view, anchorFrame: anchorFrame, visibleFrame: visibleFrame)
    }
  }

  public func show(relativeTo view: NSView?, anchorFrame: CGRect?, visibleFrame: CGRect?) {
    guard let view, !popover.isShown else { return }
    if let anchorFrame, let visibleFrame {
      maximum = PopoverGeometry.maxSize(anchor: anchorFrame, visibleFrame: visibleFrame)
      lastTopCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.minY)
    }
    applySize()
    gate = PopoverDismissalGate()
    popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    installMonitors()
    onVisibilityChange?(true)
  }

  public func close() {
    guard popover.isShown else { return }
    popover.performClose(nil)
  }

  public func popoverDidClose(_ notification: Notification) {
    removeMonitors()
    onVisibilityChange?(false)
  }

  public func popoverShouldClose(_ popover: NSPopover) -> Bool {
    true
  }

  public func measure(tab: String, size: CGSize) {
    measured[tab] = size
    applySize()
  }

  public func select(tab: String) {
    activeTab = tab
    applySize()
  }

  func applySize() {
    let size = PopoverGeometry.contentSize(
      measured: measured,
      activeTab: activeTab,
      minimumWidths: [PopoverTab.history.rawValue: 560],
      fallbackHeight: 320,
      maximum: maximum
    )
    if popover.contentSize != size { popover.contentSize = size }
  }

  func installMonitors() {
    removeMonitors()
    let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .mouseMoved, .keyDown]
    monitors.append(NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] in self?.forward($0) } as Any)
    monitors.append(NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] in self?.forward($0) } as Any)
  }

  func removeMonitors() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors.removeAll()
  }

  @discardableResult
  public func forward(_ event: NSEvent) -> NSEvent {
    handle(event)
    return event
  }

  @discardableResult
  public func handle(_ event: NSEvent) -> Bool {
    let trigger: PopoverDismissalTrigger
    switch event.type {
    case .leftMouseDown, .rightMouseDown: trigger = .mouseDown
    case .mouseMoved: trigger = .mouseMoved
    case .keyDown: trigger = .keyEscape
    default: return false
    }
    if trigger == .keyEscape, event.keyCode != 53 { return false }
    return evaluate(trigger: trigger, mouseLocation: NSEvent.mouseLocation)
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

  public func repositionIfAnchorHidden(anchorVisible: Bool, visibleFrame: CGRect?) {
    guard !anchorVisible, popover.isShown, let window = popover.contentViewController?.view.window, let lastTopCenter,
      let visibleFrame
    else { return }
    let origin = PopoverGeometry.pinnedOrigin(
      lastTopCenter: lastTopCenter, size: window.frame.size, visibleFrame: visibleFrame)
    window.setFrameOrigin(origin)
  }
}
