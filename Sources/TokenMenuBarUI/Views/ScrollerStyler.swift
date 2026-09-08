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
    if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
    if !scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = true }
    if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
    if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
    if scrollView.horizontalScrollElasticity != .none { scrollView.horizontalScrollElasticity = .none }
  }

  @MainActor final class ProbeView: NSView {
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
