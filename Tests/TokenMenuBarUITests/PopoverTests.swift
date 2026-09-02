import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func popoverGeometryFallbacksPreferTheNearestScreenAndPinnedAnchor() {
  let explicit = CGRect(x: 1, y: 2, width: 3, height: 4)
  let window = CGRect(x: 5, y: 6, width: 7, height: 8)
  let main = CGRect(x: 9, y: 10, width: 11, height: 12)
  let previous = CGRect(x: 20, y: 40, width: 10, height: 8)
  let current = CGRect(x: 30, y: 50, width: 20, height: 8)

  #expect(PopoverController.resolveVisibleFrame(explicit, windowScreen: window, mainScreen: main) == explicit)
  #expect(PopoverController.resolveVisibleFrame(nil, windowScreen: window, mainScreen: main) == window)
  #expect(PopoverController.resolveVisibleFrame(nil, windowScreen: nil, mainScreen: main) == main)
  #expect(PopoverController.anchorDeltaX(current: current, previous: previous) == 15)
  #expect(PopoverController.anchorDeltaX(current: current, previous: nil) == 0)
  #expect(PopoverController.anchorOffset(pinnedTopY: 60, previous: previous) == 20)
  #expect(PopoverController.anchorOffset(pinnedTopY: nil, previous: previous) == 0)
}

@MainActor
private func anchoredPopover(
  isKeyWindow: @escaping (NSWindow) -> Bool = { $0.isKeyWindow }
) -> (PopoverController, NSView, NSWindow) {
  quietTestApp()
  let controller = PopoverController(
    content: AnyView(Text("hello").frame(width: 300, height: 200)), log: nil, animates: false,
    isKeyWindow: isKeyWindow, presentsWindow: false)
  let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  // A window the size of the screen, ordered front, painted a blank rectangle over the whole desktop on every run.
  // The popover only needs an anchor view in a window that is on a screen, so this is small and transparent.
  let frame = NSRect(x: screen.midX - 20, y: screen.maxY - 40, width: 40, height: 20)
  let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.alphaValue = 0
  let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
  window.contentView?.addSubview(anchor)
  window.orderFrontRegardless()
  return (controller, anchor, window)
}

@MainActor
private func keyEvent(
  _ characters: String,
  keyCode: UInt16,
  window: NSWindow,
  modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: modifiers,
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    characters: characters,
    charactersIgnoringModifiers: characters,
    isARepeat: false,
    keyCode: keyCode)!
}

@Test @MainActor func popoverNeedsAnAnchorToOpen() {
  let (controller, _, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  #expect(!controller.isShown)
  controller.excludedFrame = { CGRect(x: 0, y: 0, width: 10, height: 10) }
  controller.show(relativeTo: nil, anchorFrame: nil, visibleFrame: nil)
  #expect(!controller.isShown)
}

@Test @MainActor func popoverRejectsADetachedAnchorView() {
  quietTestApp()
  let controller = PopoverController(content: AnyView(EmptyView()), presentsWindow: false)

  controller.show(
    relativeTo: NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20)), anchorFrame: nil, visibleFrame: nil)

  #expect(!controller.isShown)
}

@Test @MainActor func popoverOpensAtTheMeasuredSize() {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  var visibility: [Bool] = []
  controller.onVisibilityChange = { visibility.append($0) }
  controller.measure(PopoverMeasurement(tab: .usage, size: CGSize(width: 480, height: 300)))
  controller.select(tab: .history)
  controller.toggle(
    relativeTo: anchor, anchorFrame: CGRect(x: 120, y: 380, width: 40, height: 20),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  #expect(controller.isShown)
  #expect(visibility == [true])
  #expect(controller.popover.contentSize.width >= PopoverGeometry.minimumWidth)
}

@Test @MainActor func popoverKeepsItsWidthAndIgnoresLateOutgoingMeasurements() async throws {
  let (controller, anchorView, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  // A status item near the right edge is where moving the window was most visible.
  let anchorFrame = CGRect(x: screen.maxX - 60, y: screen.maxY - 24, width: 40, height: 20)
  controller.show(relativeTo: anchorView, anchorFrame: anchorFrame, visibleFrame: screen)
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  let openedX = popoverWindow.frame.minX
  let openedTop = popoverWindow.frame.maxY
  controller.measure(PopoverMeasurement(tab: .history, size: CGSize(width: 700, height: 700)))
  controller.select(tab: .history)
  await waitUntil { abs(controller.popover.contentSize.height - 700) < 0.5 }
  #expect(abs(popoverWindow.frame.maxY - openedTop) < 0.5)
  let width = controller.popover.contentSize.width
  let historyHeight = controller.popover.contentSize.height

  controller.select(tab: .settings)
  controller.measure(PopoverMeasurement(tab: .history, size: CGSize(width: 700, height: 710)))
  #expect(controller.popover.contentSize.height == historyHeight)
  controller.measure(PopoverMeasurement(tab: .settings, size: CGSize(width: 500, height: 400)))
  await waitUntil { abs(controller.popover.contentSize.height - 400) < 0.5 }
  #expect(controller.activeTab == .settings)
  #expect(controller.measured[.history]?.height == 710)
  #expect(controller.popover.contentSize.width == width)
  #expect(width == PopoverGeometry.stableWidth(maximum: screen.width - PopoverGeometry.margin * 2))
  #expect(abs(popoverWindow.frame.minX - openedX) < 0.5)
  #expect(abs(popoverWindow.frame.maxY - openedTop) < 0.5)
  controller.close()
}

@Test @MainActor func popoverBudgetsItsMeasuredArrowAndWindowChrome() async throws {
  let (controller, anchorView, anchorWindow) = anchoredPopover()
  defer { anchorWindow.orderOut(nil) }
  let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  let anchorFrame = anchorWindow.frame
  controller.measure(PopoverMeasurement(tab: .usage, size: CGSize(width: 880, height: 5000)))
  controller.show(relativeTo: anchorView, anchorFrame: anchorFrame, visibleFrame: screen)
  defer { controller.close() }

  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  let frameBudget = anchorFrame.minY - screen.minY - PopoverGeometry.margin
  #expect(controller.popoverChromeSize.width > 0)
  #expect(controller.popoverChromeSize.height > 0)
  #expect(abs(controller.maximum.height - (frameBudget - controller.popoverChromeSize.height)) < 0.5)
  #expect(controller.popover.contentSize.height <= controller.maximum.height + 0.5)
  await waitUntil {
    abs(popoverWindow.frame.height - controller.popover.contentSize.height - controller.popoverChromeSize.height)
      < 0.5
  }
  #expect(popoverWindow.frame.height <= frameBudget + 0.5)
  #expect(popoverWindow.frame.width <= screen.width - PopoverGeometry.margin * 2 + 0.5)
}

@Test @MainActor func popoverUsesDeterministicDefaultsWithoutForcingLayout() {
  let measured = PopoverController(content: AnyView(Text("measured")))
  measured.measure(PopoverMeasurement(tab: .usage, size: CGSize(width: 880, height: 320)))
  measured.applySize()
  #expect(measured.popover.contentSize.height == 320)

  let fallback = PopoverController(content: AnyView(Text("fallback")))
  fallback.applySize()
  #expect(fallback.popover.contentSize.height == PopoverGeometry.usageInitialHeight)
}

@Test @MainActor func popoverDoesNotFightAppKitsNormalizationOfAnAppliedSize() {
  let controller = PopoverController(content: AnyView(Text("measured")))
  let initial = PopoverMeasurement(tab: .usage, size: CGSize(width: 880, height: 320))
  controller.measure(initial)
  controller.popover.contentSize.height = 324

  controller.measure(initial)

  #expect(controller.popover.contentSize.height == 324)
  controller.measure(PopoverMeasurement(tab: .usage, size: CGSize(width: 880, height: 360)))
  #expect(controller.popover.contentSize.height == 360)
}

@Test @MainActor func popoverPinsItsFirstVisibleFrameAfterTheBackingWindowResizes() async throws {
  // The window-server arrow check is the "Verifying the live panel" recipe in website/content/contributing/_index.md.
  let (controller, anchorView, anchorWindow) = anchoredPopover()
  defer { anchorWindow.orderOut(nil) }
  let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  controller.show(relativeTo: anchorView, anchorFrame: anchorWindow.frame, visibleFrame: screen)
  defer { controller.close() }

  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  let top = popoverWindow.frame.maxY
  let x = popoverWindow.frame.minX
  let movedX = x + 120
  popoverWindow.setFrame(
    CGRect(
      origin: CGPoint(x: movedX, y: popoverWindow.frame.minY),
      size: CGSize(width: popoverWindow.frame.width, height: 240)),
    display: false)
  await waitUntil { abs(popoverWindow.frame.maxY - top) < 0.5 }
  #expect(abs(popoverWindow.frame.minX - movedX) < 0.5)
  #expect(abs(popoverWindow.frame.maxY - top) < 0.5)
}

@Test @MainActor func popoverRecoversAnOffscreenVerificationAnchor() throws {
  quietTestApp()
  let controller = PopoverController(
    content: AnyView(Text("hello").frame(width: 300, height: 200)), animates: false,
    presentsWindow: false, recoversOffscreenAnchor: true)
  let anchorWindow = NSWindow(
    contentRect: CGRect(x: -4604, y: 1054, width: 40, height: 20), styleMask: [.borderless],
    backing: .buffered, defer: false)
  anchorWindow.isReleasedWhenClosed = false
  anchorWindow.alphaValue = 0
  let anchor = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
  anchorWindow.contentView?.addSubview(anchor)
  anchorWindow.orderFrontRegardless()
  defer { anchorWindow.orderOut(nil) }
  let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

  controller.show(relativeTo: anchor, anchorFrame: anchorWindow.frame, visibleFrame: visibleFrame)
  defer { controller.close() }

  let window = try #require(controller.popover.contentViewController?.view.window)
  #expect(window.frame.intersects(visibleFrame))
  #expect(window.frame.maxY <= visibleFrame.maxY)
}

@Test @MainActor func popoverMovesItsPinnedTopWithAChangedAnchor() async throws {
  let (controller, anchorView, anchorWindow) = anchoredPopover()
  defer { anchorWindow.orderOut(nil) }
  let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  controller.measure(PopoverMeasurement(tab: .usage, size: CGSize(width: 880, height: 10_000)))
  controller.show(relativeTo: anchorView, anchorFrame: anchorWindow.frame, visibleFrame: screen)
  defer { controller.close() }

  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  let oldX = popoverWindow.frame.minX
  let oldTop = popoverWindow.frame.maxY
  let movedAnchor = anchorWindow.frame.offsetBy(dx: 120, dy: -120)
  controller.updateGeometry(anchorFrame: movedAnchor, visibleFrame: screen)
  let expectedX = min(oldX + 120, screen.maxX - popoverWindow.frame.width)
  await waitUntil {
    abs(popoverWindow.frame.minX - expectedX) < 0.5 && abs(popoverWindow.frame.maxY - (oldTop - 120)) < 0.5
  }
  #expect(abs(popoverWindow.frame.minX - expectedX) < 0.5)
  #expect(abs(popoverWindow.frame.maxY - (oldTop - 120)) < 0.5)
}

@Test @MainActor func popoverLogsEachBackingWindowResizeAfterPinning() async throws {
  let log = makeLog()
  log.debugEnabled = true
  let (_, anchorView, anchorWindow) = anchoredPopover()
  let controller = PopoverController(
    content: AnyView(Text("hello").frame(width: 300, height: 200)), log: log, animates: false,
    presentsWindow: false)
  defer { anchorWindow.orderOut(nil) }
  let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  controller.show(relativeTo: anchorView, anchorFrame: anchorWindow.frame, visibleFrame: screen)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  await mainActorTurn()
  log.clear()

  for height in [240.0, 280.0] {
    let priorCount = log.snapshot.count { $0.message.contains("panel.resize trigger=backing-window") }
    popoverWindow.setFrame(
      CGRect(origin: popoverWindow.frame.origin, size: CGSize(width: popoverWindow.frame.width, height: height)),
      display: false)
    await waitUntil {
      log.snapshot.count { $0.message.contains("panel.resize trigger=backing-window") } > priorCount
    }
    let entry = try #require(
      log.snapshot.last { $0.message.contains("panel.resize trigger=backing-window") })
    #expect(entry.message.contains("result="))
  }
}

@Test @MainActor func popoverReclampsItsSessionWidthWhenTheScreenChanges() {
  let controller = PopoverController(content: AnyView(Text("hello")))
  controller.measure(PopoverMeasurement(tab: .usage, size: CGSize(width: 1200, height: 300)))
  let screen = CGRect(x: -800, y: 0, width: 800, height: 900)
  controller.updateGeometry(
    anchorFrame: CGRect(x: -60, y: 880, width: 40, height: 20), visibleFrame: screen)
  #expect(controller.sessionWidth == screen.width - PopoverGeometry.margin * 2)
  #expect(controller.popover.contentSize.width == controller.sessionWidth)
}

@Test @MainActor func popoverExpandsHistoryToItsIdealHeightBeforeScrolling() async {
  let controller = PopoverController(content: AnyView(Text("history")))
  let screen = CGRect(x: 0, y: 0, width: 1440, height: 1300)
  controller.updateGeometry(
    anchorFrame: CGRect(x: 700, y: 1260, width: 40, height: 20), visibleFrame: screen)
  controller.measure(PopoverMeasurement(tab: .usage, size: CGSize(width: 880, height: 320)))
  controller.measure(PopoverMeasurement(tab: .history, size: CGSize(width: 880, height: 960)))

  controller.select(tab: .history)

  await waitUntil { controller.popover.contentSize.height == 960 }
  #expect(controller.maximum.height > 960)
  #expect(controller.popover.contentSize.height == 960)
}

@Test @MainActor func popoverToggleClosesWhatItOpened() async throws {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  controller.setContent(AnyView(Text("changed")))
  controller.toggle(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  await waitUntil { !controller.isShown }
  #expect(!controller.isShown)
  controller.toggle(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  #expect(controller.isShown)
  controller.close()
}

@Test @MainActor func popoverDismissalIgnoresMouseMovesAndKeysItDoesNotOwn() async throws {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  #expect(!controller.evaluate(trigger: .mouseMoved, mouseLocation: CGPoint(x: -5000, y: -5000)))
  #expect(controller.evaluate(trigger: .mouseDown, mouseLocation: CGPoint(x: -5000, y: -5000)))
  let otherKey = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a",
    charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
  #expect(controller.handle(otherKey) == false)
  #expect(controller.routeLocal(otherKey) === otherKey)
  let scroll = NSEvent.enterExitEvent(
    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    eventNumber: 0, trackingNumber: 0, userData: nil)!
  #expect(controller.handle(scroll) == false)
  let move = NSEvent.mouseEvent(
    with: .mouseMoved, location: CGPoint(x: -5000, y: -5000), modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
  _ = controller.handle(move)
  controller.close()
  await waitUntil { !controller.isShown }
}

@Test @MainActor func popoverMonitorsMouseClicksWithoutMonitoringMouseMovement() {
  #expect(!PopoverController(content: AnyView(EmptyView())).popover.animates)
  #expect(PopoverController.globalEventMask.contains(.leftMouseDown))
  #expect(PopoverController.globalEventMask.contains(.rightMouseDown))
  #expect(!PopoverController.globalEventMask.contains(.mouseMoved))
  #expect(PopoverController.localEventMask.contains(.keyDown))
  #expect(!PopoverController.localEventMask.contains(.mouseMoved))
}

@Test @MainActor func popoverRoutesEventsFromTheInstalledGlobalMonitor() throws {
  var installedMask: NSEvent.EventTypeMask = []
  var installedHandler: ((NSEvent) -> Void)?
  let controller = PopoverController(
    content: AnyView(EmptyView()), log: nil, animates: false, isKeyWindow: { _ in true }, presentsWindow: false,
    addGlobalEventMonitor: { mask, handler in
      installedMask = mask
      installedHandler = handler
      return nil
    })
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }

  controller.installMonitors()
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
    characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
  let handler = try #require(installedHandler)
  handler(event)

  #expect(installedMask == PopoverController.globalEventMask)
  #expect(refreshes == 1)
}

@Test @MainActor func popoverIgnoresMouseMovementBeforeItHasAWindow() {
  let controller = PopoverController(content: AnyView(EmptyView()), presentsWindow: false)

  #expect(!controller.evaluate(trigger: .mouseMoved, mouseLocation: .zero))
  #expect(!controller.isShown)
}

@Test @MainActor func popoverClosesOnEscape() async throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  var visibility: [Bool] = []
  controller.onVisibilityChange = { visibility.append($0) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  popoverWindow.makeKey()
  let escape = keyEvent("", keyCode: 53, window: popoverWindow)
  #expect(controller.routeLocal(escape) == nil)
  await waitUntil { !controller.isShown }
  #expect(!controller.isShown)
  #expect(visibility.last == false)
}

@Test @MainActor func popoverPublicInitializerRejectsKeysFromANonkeyBackingWindow() throws {
  let (_, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  let controller = PopoverController(content: AnyView(EmptyView()), presentsWindow: false)
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  popoverWindow.makeKey()
  let event = keyEvent("r", keyCode: 15, window: popoverWindow, modifiers: .command)
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }

  #expect(!popoverWindow.isKeyWindow)
  #expect(controller.routeLocal(event) === event)
  #expect(refreshes == 0)
}

@Test @MainActor func popoverInstalledMonitorConsumesOwnedEscape() async throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)

  NSApplication.shared.sendEvent(keyEvent("", keyCode: 53, window: popoverWindow))

  await waitUntil { !controller.isShown }
  #expect(!controller.isShown)
}

@Test @MainActor func popoverLocalRoutePreservesMouseEventsInsideTheExcludedFrame() {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  controller.excludedFrame = { CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000) }
  let event = NSEvent.mouseEvent(
    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!

  #expect(controller.routeLocal(event) === event)
  #expect(controller.isShown)
}

@Test @MainActor func popoverStaysOpenAcrossMenuTrackingAndPointerExit() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  let menu = NSMenu()
  NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
  let escape = keyEvent("", keyCode: 53, window: popoverWindow)

  #expect(controller.routeLocal(escape) === escape)
  #expect(!controller.evaluate(trigger: .mouseMoved, mouseLocation: CGPoint(x: -1_000, y: -1_000)))
  #expect(controller.isShown)
  NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
  #expect(!controller.evaluate(trigger: .mouseMoved, mouseLocation: CGPoint(x: -1_000, y: -1_000)))
  #expect(controller.isShown)
}

@Test @MainActor func popoverClosesOnAClickOutsideIt() async throws {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  controller.toggle(
    relativeTo: anchor, anchorFrame: CGRect(x: 120, y: 380, width: 40, height: 20),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  #expect(controller.isShown)
  let click = NSEvent.mouseEvent(
    with: .leftMouseDown, location: CGPoint(x: -5000, y: -5000), modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  _ = controller.handle(click)
  await waitUntil { !controller.isShown }
  #expect(!controller.isShown)
  #expect(controller.popoverShouldClose(controller.popover))
}

@Test @MainActor func popoverRoutesCommandRToRefresh() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  popoverWindow.makeKey()
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }
  let event = keyEvent("r", keyCode: 15, window: popoverWindow, modifiers: .command)
  #expect(controller.routeLocal(event) == nil)
  #expect(refreshes == 1)
}

@Test @MainActor func popoverRoutesOwnedKeysFromANontextResponder() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  #expect(popoverWindow.makeFirstResponder(nil))
  #expect(popoverWindow.firstResponder === popoverWindow)
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }

  let event = keyEvent("r", keyCode: 15, window: popoverWindow, modifiers: .command)

  #expect(controller.routeLocal(event) == nil)
  #expect(refreshes == 1)
}

@Test @MainActor func popoverLeavesUnownedKeysFromItsKeyWindowUntouched() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  let event = keyEvent("a", keyCode: 0, window: popoverWindow)

  #expect(controller.routeLocal(event) === event)
  #expect(controller.isShown)
}

@Test @MainActor func popoverLeavesKeysFromAnotherWindowUntouched() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  popoverWindow.makeKey()
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }
  let event = keyEvent("r", keyCode: 15, window: window, modifiers: .command)
  #expect(controller.routeLocal(event) === event)
  #expect(refreshes == 0)
}

@Test @MainActor func popoverLeavesKeysUntouchedWhenItIsNotTheKeyWindow() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in false })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }
  let event = keyEvent("r", keyCode: 15, window: popoverWindow, modifiers: .command)
  #expect(controller.routeLocal(event) === event)
  #expect(refreshes == 0)
}

@Test @MainActor func popoverLeavesKeysUntouchedWhileAMenuTracks() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverWindow = try #require(controller.popover.contentViewController?.view.window)
  popoverWindow.makeKey()
  let menu = NSMenu()
  NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
  defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }
  let event = keyEvent("r", keyCode: 15, window: popoverWindow, modifiers: .command)
  #expect(controller.routeLocal(event) === event)
  #expect(refreshes == 0)
}

@Test @MainActor func popoverLeavesFieldEditorEscapeUntouched() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverView = try #require(controller.popover.contentViewController?.view)
  let popoverWindow = try #require(popoverView.window)
  let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
  popoverView.addSubview(field)
  popoverWindow.makeKey()
  field.selectText(nil)
  let editor = try #require(popoverWindow.firstResponder as? NSTextView)
  #expect(editor.isFieldEditor)
  let escape = keyEvent("", keyCode: 53, window: popoverWindow)
  #expect(controller.routeLocal(escape) === escape)
  #expect(controller.isShown)
}

@Test @MainActor func popoverLeavesMarkedTextShortcutsUntouched() throws {
  let (controller, anchor, window) = anchoredPopover(isKeyWindow: { _ in true })
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  defer { controller.close() }
  let popoverView = try #require(controller.popover.contentViewController?.view)
  let popoverWindow = try #require(popoverView.window)
  let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
  popoverView.addSubview(editor)
  popoverWindow.makeKey()
  popoverWindow.makeFirstResponder(editor)
  editor.setMarkedText(
    "r", selectedRange: NSRange(location: 1, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: 0))
  #expect(editor.hasMarkedText())
  var refreshes = 0
  controller.onRefresh = { refreshes += 1 }
  let event = keyEvent("r", keyCode: 15, window: popoverWindow, modifiers: .command)
  #expect(controller.routeLocal(event) === event)
  #expect(refreshes == 0)
}

@Test @MainActor func popoverTabsDoNotForceTheWideLayoutOnANarrowDisplay() throws {
  let environment = try makeEnvironment()
  let views = [
    AnyView(UsageTab(environment: environment)), AnyView(HistoryTab(environment: environment)),
    AnyView(RootView(environment: environment, onMeasure: { _ in }, onTabChange: { _ in })),
  ]
  for view in views {
    let hosting = host(view, width: 600, height: 500)
    let scrollView = try #require(descendant(NSScrollView.self, in: hosting))
    #expect((scrollView.documentView?.frame.width ?? 0) <= 600)
  }
}

@MainActor
private func descendant<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
  if let root = root as? View { return root }
  return root.subviews.lazy.compactMap { descendant(type, in: $0) }.first
}
