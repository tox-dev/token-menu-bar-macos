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

  public mutating func begin(context: String, ladderCount: Int) -> Int {
    index = min(remembered[context] ?? 0, max(ladderCount - 1, 0))
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

  public static func hiddenByNotch(itemFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?) -> Bool {
    guard let leftArea, let rightArea else { return false }
    return itemFrame.minX < rightArea.minX && itemFrame.maxX > leftArea.maxX
  }
}
