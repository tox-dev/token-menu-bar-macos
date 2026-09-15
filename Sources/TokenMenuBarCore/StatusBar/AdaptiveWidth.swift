import CoreGraphics
import Foundation

public enum StatusTier: String, CaseIterable, Codable, Sendable {
  case configured
  case stacked
  case worstPerProvider
  case miniBars
  case iconOnly
}

public struct AdaptiveWidthPlanner: Sendable, Equatable {
  public private(set) var index = 0
  public private(set) var context: String?
  private var remembered: [String: Int] = [:]

  public init() {}

  /// Starts one tier wider than the tier that last fit for this context: menu bar space comes back when the user
  /// quits an app or drops a window, and a planner that only narrowed would stay collapsed until a screen change.
  public mutating func begin(context: String, ladderCount: Int) -> Int {
    self.context = context
    let remembered = min(remembered[context] ?? 0, max(ladderCount - 1, 0))
    index = max(remembered - 1, 0)
    return index
  }

  public mutating func didNotFit(ladderCount: Int) -> Int? {
    guard index + 1 < ladderCount else { return nil }
    index += 1
    return index
  }

  public mutating func resume(ladderCount: Int) -> Int {
    index = min(index, max(ladderCount - 1, 0))
    return index
  }

  public mutating func didFit(context: String) {
    remembered[context] = index
  }

  public mutating func selectNarrowest(ladderCount: Int) -> Int {
    index = max(ladderCount - 1, 0)
    return index
  }

  public mutating func forget() {
    remembered.removeAll()
    index = 0
    context = nil
  }

  public static func ladder(_ models: [StatusItemModel], widths: [Double]) -> [StatusItemModel] {
    guard let first = models.first, let firstWidth = widths.first else { return [] }
    let narrower = zip(models.dropFirst(), widths.dropFirst()).filter { $0.1 < firstWidth }.sorted { $0.1 > $1.1 }
    var ladder = [first]
    for (model, _) in narrower where !ladder.contains(model) { ladder.append(model) }
    return ladder
  }

  public static func isOnScreen(itemFrame: CGRect, screenFrames: [CGRect]) -> Bool {
    !itemFrame.isEmpty && screenFrames.contains { $0.insetBy(dx: -1, dy: -1).contains(itemFrame) }
  }

  public static func isVisible(
    itemFrame: CGRect, screenFrames: [CGRect], occlusionVisible: Bool, placed: Bool, macOSMajor: Int
  ) -> Bool {
    // macOS 27 reports a visible occlusion state for items the menu bar had no room for (FB23349447).
    isOnScreen(itemFrame: itemFrame, screenFrames: screenFrames) && (macOSMajor >= 27 ? placed : occlusionVisible)
  }

  public static func hiddenByNotch(itemFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?) -> Bool {
    guard let leftArea, let rightArea else { return false }
    return itemFrame.minX < rightArea.minX && itemFrame.maxX > leftArea.maxX
  }
}

/// macOS 27 stretches a status item's frame from its old origin as soon as its length changes, then moves the item
/// into place a moment later. When the menu bar has no room, the move never happens, so an origin that stays put after
/// a length change is the only sign that the item did not fit; the window server does not list these windows.
public struct StatusItemPlacement: Sendable, Equatable {
  private var pendingOrigin: CGFloat?
  public private(set) var isPlaced = true

  public init() {}

  public mutating func lengthWillChange(itemFrame: CGRect) {
    pendingOrigin = itemFrame.minX
  }

  /// A frame still at its old origin can be a move that has not landed yet, so the change stays pending until the
  /// item moves or its length changes again.
  public mutating func settle(itemFrame: CGRect) -> Bool {
    if let pendingOrigin {
      isPlaced = abs(itemFrame.minX - pendingOrigin) >= 0.5
      if isPlaced { self.pendingOrigin = nil }
    }
    return isPlaced
  }
}
