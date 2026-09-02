import AppKit
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@MainActor
private final class CoverageTooltipPanel: TooltipPanelPresenting {
  private(set) var contents: [TooltipContent] = []
  var isVisible = false

  func show(
    content: TooltipContent,
    anchorRect: CGRect,
    visibleFrame: CGRect,
    parentWindow: NSWindow,
    reduceMotion: Bool,
    reduceTransparency: Bool
  ) {
    contents.append(content)
    isVisible = true
  }

  func hide() {
    isVisible = false
  }

  func tearDown() {
    isVisible = false
  }
}

@MainActor
private final class CoverageTooltipWindow: NSWindow {
  var pointerLocation = CGPoint.zero

  override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
}

@Suite(.serialized)
struct TooltipCoverageClosureTests {
  @Test @MainActor func defaultCursorContextFindsTheWindowUnderThePointer() async throws {
    quietTestApp()
    let pointer = NSEvent.mouseLocation
    let screen = try #require(NSScreen.screens.first { $0.frame.contains(pointer) })
    let window = NSWindow(
      contentRect: screen.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.alphaValue = 0
    window.orderFrontRegardless()
    let panel = CoverageTooltipPanel()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let content = TooltipContent(title: "Pointer", body: "Explains the control under the pointer.")
    defer {
      presenter.tearDown()
      window.orderOut(nil)
    }

    presenter.updateCursor(content: content, hovering: true)
    await presenter.settle()

    #expect(panel.contents == [content])
  }

  @Test @MainActor func hoveredTrackingViewRefreshesChangedContent() async throws {
    let screen = try #require(NSScreen.screens.first)
    let panel = CoverageTooltipPanel()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let initial = TooltipContent(title: "Initial", body: "First explanation.")
    let view = TooltipTrackingView(content: initial, presenter: presenter)
    let window = CoverageTooltipWindow(
      contentRect: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 180, height: 60),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.alphaValue = 0
    window.contentView = view
    view.frame = CGRect(x: 0, y: 0, width: 180, height: 60)
    window.pointerLocation = CGPoint(x: 90, y: 30)
    window.orderFrontRegardless()
    defer {
      view.dismantle()
      presenter.tearDown()
      window.orderOut(nil)
    }

    view.mouseEntered(with: try mouseEvent())
    await presenter.settle()
    let updated = TooltipContent(title: "Updated", body: "Second explanation.")
    view.update(content: updated, focused: false)

    #expect(panel.contents == [initial, updated])
  }

  @Test @MainActor func cursorPresenterUpdatesTheSharedPresenter() async throws {
    let screen = try #require(NSScreen.screens.first)
    let window = NSWindow(
      contentRect: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 180, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let help = TooltipContent(title: "Refresh", body: "Fetches current usage.")
    let panel = CoverageTooltipPanel()
    let presenter = TooltipPresenter(
      sleep: { _ in }, panelFactory: { panel },
      cursorContext: {
        TooltipPresentationContext(
          anchorRect: window.frame, visibleFrame: screen.visibleFrame, parentWindow: window)
      })
    defer {
      presenter.tearDown()
    }

    presenter.updateCursor(content: help, hovering: true)
    await presenter.settle()
    #expect(panel.contents == [help])
    presenter.updateCursor(content: help, hovering: false)
    await presenter.settle()
    #expect(!panel.isVisible)
  }

  private func mouseEvent() throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
  }
}
