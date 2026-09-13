import AppKit
import QuartzCore
import SwiftUI

struct RingProgressViewStyle: ProgressViewStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      ActivityRing().frame(width: 14, height: 14).accessibilityHidden(true)
      configuration.label
    }
  }
}

private struct ActivityRing: NSViewRepresentable {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> ActivityRingView {
    ActivityRingView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
  }

  func updateNSView(_ view: ActivityRingView, context: Context) {
    view.update(reduceMotion: reduceMotion)
  }

  static func dismantleNSView(_ view: ActivityRingView, coordinator: ()) {
    view.layer?.removeAllAnimations()
  }
}

final class ActivityRingView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    let ring = CAShapeLayer()
    ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
    ring.fillColor = nil
    ring.lineWidth = 2
    ring.lineCap = .round
    ring.strokeEnd = 0.75
    layer = ring
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func update(reduceMotion: Bool) {
    let ring = layer as! CAShapeLayer
    effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = NSColor.secondaryLabelColor.cgColor }
    if reduceMotion {
      ring.removeAllAnimations()
    } else if ring.animation(forKey: "rotation") == nil {
      // Native spinners enter Core Image shader compilation during cold popover presentation on macOS 14.
      let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
      rotation.toValue = 2 * Double.pi
      rotation.duration = 1
      rotation.repeatCount = .infinity
      ring.add(rotation, forKey: "rotation")
    }
  }
}
