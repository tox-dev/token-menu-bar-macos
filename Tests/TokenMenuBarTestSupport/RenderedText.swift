import Foundation

public struct RenderedText: Codable, Sendable {
  public enum Layout: String, Codable, Sendable {
    case sparse, paragraph
  }

  public let contains: [String]
  public let excludes: [String]
  public let suffix: String?
  public let matches: Bool
  public let layout: Layout

  public init(
    contains: [String] = [], excludes: [String] = [], suffix: String? = nil, matches: Bool = true,
    layout: Layout = .sparse
  ) {
    self.contains = contains
    self.excludes = excludes
    self.suffix = suffix
    self.matches = matches
    self.layout = layout
  }

  public func capture(_ png: Data, at image: URL) throws {
    try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: image, options: .atomic)
    try JSONEncoder().encode(self).write(
      to: image.deletingPathExtension().appendingPathExtension("ocr.json"), options: .atomic)
  }
}
