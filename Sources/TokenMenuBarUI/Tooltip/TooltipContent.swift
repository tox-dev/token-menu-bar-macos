import Foundation

public enum TooltipSpan: Hashable, Sendable {
  case code(String)
  case text(String)

  var text: String {
    switch self {
    case .code(let value), .text(let value): value
    }
  }
}

public struct TooltipContent: Hashable, Sendable {
  public let title: String
  public let body: [TooltipSpan]

  public init(title: String, body: String) {
    self.init(title: title, body: [.text(body)])
  }

  public init(title: String, body: [TooltipSpan]) {
    self.title = title
    self.body = body
  }

  public var accessibilityHint: String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = body.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return body }
    guard !body.isEmpty else { return title }

    if let titleRange = body.range(of: title, options: [.anchored, .caseInsensitive]),
      titleRange.upperBound == body.endIndex || body[titleRange.upperBound].isWhitespace
        || body[titleRange.upperBound].isPunctuation
    {
      return body
    }
    return "\(title). \(body)"
  }
}
