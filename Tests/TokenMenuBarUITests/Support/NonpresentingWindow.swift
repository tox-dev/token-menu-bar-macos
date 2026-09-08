import AppKit
import Testing

@MainActor
final class NonpresentingWindow: NSWindow {
  init(content: NSView, frame: CGRect = CGRect(x: 100, y: 100, width: 880, height: 900)) {
    prepareTestApp()
    super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
    isReleasedWhenClosed = false
    contentView = content
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int) {
    if place == .out {
      super.order(place, relativeTo: otherWindowNumber)
    } else {
      rejectPresentation()
    }
  }

  override func orderFrontRegardless() { rejectPresentation() }
  override func orderFront(_ sender: Any?) { rejectPresentation() }
  override func orderBack(_ sender: Any?) { rejectPresentation() }
  override func makeKeyAndOrderFront(_ sender: Any?) { rejectPresentation() }
  override func makeKey() { rejectPresentation() }
  override func makeMain() { rejectPresentation() }

  private func rejectPresentation() {
    Issue.record("A nonpresenting test tried to show or focus a window")
  }
}

@Test(arguments: [NSWindow.OrderingMode.above, .below]) @MainActor
func nonpresentingWindowRejectsOrdering(mode: NSWindow.OrderingMode) {
  let window = NonpresentingWindow(content: NSView())
  defer { window.close() }

  withKnownIssue { window.order(mode, relativeTo: 0) }

  #expect(!window.isVisible && !window.canBecomeKey && !window.canBecomeMain)
}
