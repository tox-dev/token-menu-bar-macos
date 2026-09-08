import AppKit
import QuartzCore
import Testing

@testable import TokenMenuBarUI

@Test @MainActor func activityRingDrawsAnOpenStrokeWithoutAnImageFilter() throws {
  let view = ActivityRingView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
  let ring = try #require(view.layer as? CAShapeLayer)

  #expect(ring.path?.boundingBox == CGRect(x: 1, y: 1, width: 12, height: 12))
  #expect(ring.strokeEnd == 0.75 && ring.fillColor == nil && ring.lineWidth == 2)
  #expect(ring.filters?.isEmpty != false)
}

@Test(arguments: [false, true]) @MainActor
func activityRingRespectsReduceMotion(reduceMotion: Bool) throws {
  let view = ActivityRingView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
  view.update(reduceMotion: false)

  view.update(reduceMotion: reduceMotion)

  #expect((view.layer?.animation(forKey: "rotation") != nil) == !reduceMotion)
}

@Test @MainActor func activityRingUsesACompositorAnimation() throws {
  let view = ActivityRingView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))

  view.update(reduceMotion: false)

  let animation = try #require(view.layer?.animation(forKey: "rotation") as? CABasicAnimation)
  #expect(animation.keyPath == "transform.rotation.z")
  #expect(animation.duration == 1 && animation.repeatCount == .infinity)
}
