import AppKit
import TokenMenuBarCore

extension NSView {
  @MainActor func logTabHitTesting(to log: LogBuffer) {
    guard log.debugEnabled, let window, let control = tabControl(in: self),
      let segments = control.cell?.accessibilityChildren()
    else { return }
    for case let segment as any NSAccessibilityProtocol in segments {
      let frame = segment.accessibilityFrame()
      let point = CGPoint(x: frame.midX, y: frame.midY)
      let windowHit = window.accessibilityHitTest(point) as? any NSAccessibilityProtocol
      let applicationHit = NSApp.accessibilityHitTest(point) as? any NSAccessibilityProtocol
      log.logDebug(
        "control.hit-testing tab=\(hitDescription(segment)) frame=\(frame) "
          + "windowHit=\(hitDescription(windowHit)) appHit=\(hitDescription(applicationHit)) "
          + "visible=\(window.isVisible) key=\(window.isKeyWindow)", category: .tabs)
    }
  }
}

@MainActor private func tabControl(in view: NSView) -> NSSegmentedControl? {
  if let control = view as? NSSegmentedControl, control.accessibilityIdentifier() == "popover-tabs" { return control }
  for subview in view.subviews {
    if let control = tabControl(in: subview) { return control }
  }
  return nil
}

@MainActor private func hitDescription(_ element: (any NSAccessibilityProtocol)?) -> String {
  "\(element?.accessibilityLabel() ?? "unnamed"):\(element?.accessibilityRole()?.rawValue ?? "none")"
}
