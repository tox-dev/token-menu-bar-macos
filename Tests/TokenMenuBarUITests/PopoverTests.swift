import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore

@testable import TokenMenuBarUI

@Test @MainActor func popoverShowsClosesAndSizes() async throws {
  let controller = PopoverController(content: AnyView(Text("hello").frame(width: 300, height: 200)))
  #expect(!controller.isShown)
  var visibility: [Bool] = []
  controller.onVisibilityChange = { visibility.append($0) }
  controller.excludedFrame = { CGRect(x: 0, y: 0, width: 10, height: 10) }
  controller.show(relativeTo: nil, anchorFrame: nil, visibleFrame: nil)
  #expect(!controller.isShown)
  let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false
  )
  let anchor = NSView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
  window.contentView?.addSubview(anchor)
  window.orderFrontRegardless()
  controller.measure(tab: PopoverTab.usage.rawValue, size: CGSize(width: 480, height: 320))
  controller.select(tab: PopoverTab.history.rawValue)
  controller.toggle(
    relativeTo: anchor, anchorFrame: CGRect(x: 120, y: 380, width: 40, height: 20),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  #expect(controller.isShown)
  #expect(visibility == [true])
  #expect(controller.popover.contentSize.width >= 560)
  controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: nil)
  controller.setContent(AnyView(Text("changed")))
  #expect(controller.evaluate(trigger: .mouseMoved, mouseLocation: CGPoint(x: -1000, y: -1000)) == false)
  #expect(controller.evaluate(trigger: .mouseDown, mouseLocation: CGPoint(x: 5, y: 5)) == false)
  controller.repositionIfAnchorHidden(anchorVisible: true, visibleFrame: nil)
  controller.repositionIfAnchorHidden(anchorVisible: false, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  let escape = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
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
  #expect(controller.handle(escape))
  try await Task.sleep(for: .milliseconds(100))
  #expect(!controller.isShown)
  #expect(visibility.last == false)
  controller.close()
  controller.toggle(
    relativeTo: anchor, anchorFrame: CGRect(x: 120, y: 380, width: 40, height: 20),
    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
  #expect(controller.isShown)
  let click = NSEvent.mouseEvent(
    with: .leftMouseDown, location: CGPoint(x: -5000, y: -5000), modifierFlags: [], timestamp: 0, windowNumber: 0,
    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
  _ = controller.handle(click)
  #expect(controller.evaluate(trigger: .mouseDown, mouseLocation: CGPoint(x: -5000, y: -5000)))
  try await Task.sleep(for: .milliseconds(100))
  #expect(!controller.isShown)
  #expect(controller.popoverShouldClose(controller.popover))
  window.close()
}
