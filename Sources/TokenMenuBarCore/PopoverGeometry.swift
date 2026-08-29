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
  public static let widestTabWidth: CGFloat = 1274
  public static let viewportWidthShare: CGFloat = 0.42
  public static let minimumHeight: CGFloat = 200
  public static let margin: CGFloat = 12
  public static let chromeHeight: CGFloat = 58

  public static func maxSize(anchor: CGRect, visibleFrame: CGRect) -> CGSize {
    let heightBelow = anchor.minY - visibleFrame.minY - margin
    let height = max(minimumHeight, heightBelow)
    return CGSize(width: max(minimumWidth, visibleFrame.width - 2 * margin), height: height)
  }

  public static func preferredWidth(visibleFrame: CGRect?) -> CGFloat {
    guard let visibleFrame else { return minimumWidth }
    return min(max(visibleFrame.width * viewportWidthShare, minimumWidth), visibleFrame.width - 2 * margin)
  }

  public static func clamp(_ size: CGSize, maximum: CGSize) -> CGSize {
    CGSize(
      width: min(max(size.width, minimumWidth), max(maximum.width, minimumWidth)),
      height: min(max(size.height, minimumHeight), max(maximum.height, minimumHeight)))
  }

  public static func stableCenterX(anchorMidX: CGFloat, visibleFrame: CGRect, widestWidth: CGFloat) -> CGFloat {
    let half = min(widestWidth, visibleFrame.width - 2 * margin) / 2
    return min(max(anchorMidX, visibleFrame.minX + margin + half), visibleFrame.maxX - margin - half)
  }

  public static func alignedOriginX(centerX: CGFloat, width: CGFloat, visibleFrame: CGRect) -> CGFloat {
    min(max(centerX - width / 2, visibleFrame.minX), max(visibleFrame.maxX - width, visibleFrame.minX))
  }

  public static func pinnedOrigin(lastTopCenter: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
    let x = min(max(lastTopCenter.x - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width)
    let y = min(max(lastTopCenter.y - size.height, visibleFrame.minY), visibleFrame.maxY - size.height)
    return CGPoint(x: x, y: y)
  }
}
