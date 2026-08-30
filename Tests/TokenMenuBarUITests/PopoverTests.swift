import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarUI

@MainActor
private func anchoredPopover() -> (PopoverController, NSView, NSWindow) {
  let controller = PopoverController(content: AnyView(Text("hello").frame(width: 300, height: 200)))
  let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  let window = NSWindow(contentRect: screen, styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let anchor = NSView(frame: NSRect(x: screen.width / 2, y: screen.height - 60, width: 40, height: 20))
  window.contentView?.addSubview(anchor)
  window.orderFrontRegardless()
  return (controller, anchor, window)
}

@Test @MainActor func popoverNeedsAnAnchorToOpen() {
  let (controller, _, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  #expect(!controller.isShown)
  controller.excludedFrame = { CGRect(x: 0, y: 0, width: 10, height: 10) }
  controller.show(relativeTo: nil, anchorFrame: nil, visibleFrame: nil)
  #expect(!controller.isShown)
}

@Test @MainActor func popoverOpensAtTheMeasuredSize() {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  var visibility: [Bool] = []
  controller.onVisibilityChange = { visibility.append($0) }
  controller.measure(tab: PopoverTab.usage.rawValue, size: CGSize(width: 480, height: 300))
  controller.select(tab: PopoverTab.history.rawValue)
  controller.toggle(
    relativeTo: anchor, anchorFrame: CGRect(x: 120, y: 380, width: 40, height: 20),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  #expect(controller.isShown)
  #expect(visibility == [true])
  #expect(controller.popover.contentSize.width >= PopoverGeometry.minimumWidth)
}

@Test @MainActor func popoverFollowsAnAnchorThatScrollsOutOfTheMenuBar() {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  controller.toggle(
    relativeTo: anchor, anchorFrame: CGRect(x: 120, y: 380, width: 40, height: 20),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  let before = controller.popover.contentViewController?.view.window?.frame.origin
  controller.repositionIfAnchorHidden(anchorVisible: true, visibleFrame: nil)
  #expect(controller.popover.contentViewController?.view.window?.frame.origin == before)
  controller.repositionIfAnchorHidden(anchorVisible: false, visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 300))
  #expect(controller.popover.contentViewController?.view.window?.frame.origin != before)
  controller.close()
}

@Test @MainActor func popoverToggleClosesWhatItOpened() async throws {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  controller.setContent(AnyView(Text("changed")))
  controller.toggle(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  try await Task.sleep(for: .milliseconds(100))
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
  let scroll = NSEvent.enterExitEvent(
    with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    eventNumber: 0, trackingNumber: 0, userData: nil)!
  #expect(controller.handle(scroll) == false)
  let move = NSEvent.mouseEvent(
    with: .mouseMoved, location: CGPoint(x: -5000, y: -5000), modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
  _ = controller.handle(move)
  controller.close()
  try await Task.sleep(for: .milliseconds(100))
}

@Test @MainActor func popoverClosesOnEscape() async throws {
  let (controller, anchor, window) = anchoredPopover()
  defer { window.orderOut(nil) }
  var visibility: [Bool] = []
  controller.onVisibilityChange = { visibility.append($0) }
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  let escape = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
  #expect(controller.handle(escape))
  try await Task.sleep(for: .milliseconds(100))
  #expect(!controller.isShown)
  #expect(visibility.last == false)
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
  try await Task.sleep(for: .milliseconds(100))
  #expect(!controller.isShown)
  #expect(controller.popoverShouldClose(controller.popover))
  try await Task.sleep(for: .milliseconds(300))
}
