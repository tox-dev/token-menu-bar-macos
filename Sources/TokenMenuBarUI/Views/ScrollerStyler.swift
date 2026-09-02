import AppKit
import SwiftUI
import TokenMenuBarCore

public struct ScrollerStyler: NSViewRepresentable {
  public init() {}

  public func makeNSView(context: Context) -> NSView {
    let view = ProbeView(frame: .zero)
    DispatchQueue.main.async { Self.apply(from: view) }
    return view
  }

  public func updateNSView(_ view: NSView, context: Context) {
    Self.applyEnclosing(from: view)
  }

  static func apply(from view: NSView) {
    applyEnclosing(from: view)
  }

  static func applyEnclosing(from view: NSView) {
    guard let scrollView = view.enclosingScrollView else { return }
    apply(to: scrollView)
  }

  static func apply(to scrollView: NSScrollView) {
    scrollView.scrollerStyle = .overlay
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.horizontalScrollElasticity = .none
  }

  @MainActor final class ProbeView: NSView {
    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      ScrollerStyler.applyEnclosing(from: self)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      ScrollerStyler.applyEnclosing(from: self)
      DispatchQueue.main.async { ScrollerStyler.apply(from: self) }
    }
  }
}
