import CoreGraphics
import Foundation

public enum TooltipTiming {
  public static let presentationDelay: Duration = .milliseconds(150)
  public static let dismissalDelay: Duration = .milliseconds(150)
  public static let fadeDuration: TimeInterval = 0.09
}

public struct TooltipOwner: Hashable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct TooltipRequest: Equatable, Sendable {
  public let owner: TooltipOwner
  public let generation: UInt64

  public init(owner: TooltipOwner, generation: UInt64) {
    self.owner = owner
    self.generation = generation
  }
}

public struct TooltipArbiter: Equatable, Sendable {
  public private(set) var generation: UInt64 = 0
  public private(set) var pending: TooltipRequest?
  public private(set) var visible: TooltipRequest?

  public init() {}

  public mutating func arm(owner: TooltipOwner) -> TooltipRequest? {
    if pending?.owner == owner || visible?.owner == owner { return nil }
    generation &+= 1
    let request = TooltipRequest(owner: owner, generation: generation)
    pending = request
    return request
  }

  public mutating func present(_ request: TooltipRequest) -> Bool {
    guard pending == request else { return false }
    pending = nil
    visible = request
    return true
  }

  public mutating func dismiss(owner: TooltipOwner) -> Bool {
    if pending?.owner == owner {
      generation &+= 1
      pending = nil
      return true
    }
    if visible?.owner == owner {
      generation &+= 1
      visible = nil
      return true
    }
    return false
  }

  public mutating func dismissAll() {
    guard pending != nil || visible != nil else { return }
    clear()
  }

  private mutating func clear() {
    generation &+= 1
    pending = nil
    visible = nil
  }
}

public enum TooltipSide: Sendable, Equatable {
  case above
  case below
}

public struct TooltipPlacement: Sendable, Equatable {
  public let origin: CGPoint
  public let side: TooltipSide

  public init(origin: CGPoint, side: TooltipSide) {
    self.origin = origin
    self.side = side
  }
}

public enum TooltipGeometry {
  public static let screenInset: CGFloat = 8
  public static let targetGap: CGFloat = 7
  public static let maximumWidth: CGFloat = 320

  public static func placement(
    anchor: CGRect,
    tooltipSize: CGSize,
    visibleFrame: CGRect,
    screenInset: CGFloat = screenInset,
    targetGap: CGFloat = targetGap
  ) -> TooltipPlacement {
    let minimumX = visibleFrame.minX + screenInset
    let maximumX = max(minimumX, visibleFrame.maxX - screenInset - tooltipSize.width)
    let preferredX = anchor.midX - tooltipSize.width / 2
    let x = min(max(preferredX, minimumX), maximumX)

    let minimumY = visibleFrame.minY + screenInset
    let maximumY = max(minimumY, visibleFrame.maxY - screenInset - tooltipSize.height)
    let below = anchor.minY - targetGap - tooltipSize.height
    let side: TooltipSide = below >= minimumY ? .below : .above
    let preferredY = side == .below ? below : anchor.maxY + targetGap
    let y = min(max(preferredY, minimumY), maximumY)
    return TooltipPlacement(origin: CGPoint(x: x, y: y), side: side)
  }
}
