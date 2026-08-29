import CoreGraphics
import Foundation

public enum PopoverDismissalTrigger: Sendable, Equatable {
  case mouseDown
  case mouseMoved
  case keyEscape
}

public struct PopoverDismissalGate: Sendable, Equatable {
  private var mouseEnteredPopover = false

  public init() {}

  public mutating func shouldClose(
    mouseLocation: CGPoint,
    popoverFrame: CGRect?,
    excludedFrame: CGRect? = nil,
    trigger: PopoverDismissalTrigger
  ) -> Bool {
    if trigger == .keyEscape { return true }
    let inside = popoverFrame?.contains(mouseLocation) ?? false
    if inside {
      mouseEnteredPopover = true
      return false
    }
    if excludedFrame?.contains(mouseLocation) == true { return false }
    switch trigger {
    case .mouseDown: return true
    case .mouseMoved: return mouseEnteredPopover
    case .keyEscape: return true
    }
  }
}

public enum PopoverGeometry {
  public static let minimumWidth: CGFloat = 728
  public static let minimumHeight: CGFloat = 200
  public static let margin: CGFloat = 12
  public static let chromeHeight: CGFloat = 58

  public static func maxSize(anchor: CGRect, visibleFrame: CGRect) -> CGSize {
    let heightBelow = anchor.minY - visibleFrame.minY - margin
    let height = max(minimumHeight, heightBelow)
    let centered = 2 * min(anchor.midX - visibleFrame.minX, visibleFrame.maxX - anchor.midX) - 2 * margin
    let width = centered >= minimumWidth ? centered : visibleFrame.width - 2 * margin
    return CGSize(width: max(minimumWidth, width), height: height)
  }

  public static func clamp(_ size: CGSize, maximum: CGSize) -> CGSize {
    CGSize(
      width: min(max(size.width, minimumWidth), max(maximum.width, minimumWidth)),
      height: min(max(size.height, minimumHeight), max(maximum.height, minimumHeight)))
  }

  public static func pinnedOrigin(lastTopCenter: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
    let x = min(max(lastTopCenter.x - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width)
    let y = min(max(lastTopCenter.y - size.height, visibleFrame.minY), visibleFrame.maxY - size.height)
    return CGPoint(x: x, y: y)
  }
}
