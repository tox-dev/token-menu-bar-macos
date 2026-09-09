import Foundation

public struct RenderedText: Codable, Sendable {
  public let contains: [String]
  public let excludes: [String]
  public let suffix: String?
  public let matches: Bool

  public init(contains: [String] = [], excludes: [String] = [], suffix: String? = nil, matches: Bool = true) {
    self.contains = contains
    self.excludes = excludes
    self.suffix = suffix
    self.matches = matches
  }

  public func capture(_ png: Data, at image: URL) throws {
    try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: image, options: .atomic)
    try JSONEncoder().encode(self).write(
      to: image.deletingPathExtension().appendingPathExtension("ocr.json"), options: .atomic)
  }
}
