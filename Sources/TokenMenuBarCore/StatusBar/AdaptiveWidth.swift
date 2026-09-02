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
  private var remembered: [String: Int] = [:]

  public init() {}

  /// Starts one tier wider than the tier that last fit for this context: menu bar space comes back when the user
  /// quits an app or drops a window, and a planner that only narrowed would stay collapsed until a screen change.
  public mutating func begin(context: String, ladderCount: Int) -> Int {
    let remembered = min(remembered[context] ?? 0, max(ladderCount - 1, 0))
    index = max(remembered - 1, 0)
    return index
  }

  public mutating func didNotFit(ladderCount: Int) -> Int? {
    guard index + 1 < ladderCount else { return nil }
    index += 1
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
  }

  public static func ladder(_ models: [StatusItemModel], widths: [Double]) -> [StatusItemModel] {
    guard let first = models.first, let firstWidth = widths.first else { return [] }
    let narrower = zip(models.dropFirst(), widths.dropFirst()).filter { $0.1 < firstWidth }.sorted { $0.1 > $1.1 }
    var ladder = [first]
    for (model, _) in narrower where !ladder.contains(model) { ladder.append(model) }
    return ladder
  }

  /// macOS parks an item that no longer fits past the screen edge, so an item whose frame stops overlapping every
  /// screen counts as hidden. Overlap decides it rather than containment, since an edge item can poke a point past.
  public static func isOnScreen(itemFrame: CGRect, screenFrames: [CGRect]) -> Bool {
    itemFrame.width > 0 && screenFrames.contains { $0.intersects(itemFrame) }
  }

  public static func hiddenByNotch(itemFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?) -> Bool {
    guard let leftArea, let rightArea else { return false }
    return itemFrame.minX < rightArea.minX && itemFrame.maxX > leftArea.maxX
  }
}
