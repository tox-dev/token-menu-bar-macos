import Foundation

public struct LogFilter: Sendable, Equatable {
  public var search: String
  public var levels: Set<LogLevel>
  public var categories: Set<LogCategory>

  public init(
    search: String = "", levels: Set<LogLevel> = Set(LogLevel.allCases),
    categories: Set<LogCategory> = Set(LogCategory.allCases)
  ) {
    self.search = search
    self.levels = levels
    self.categories = categories
  }

  public func entries(from source: some Sequence<LogEntry>) -> [LogEntry] {
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return source.filter {
      levels.contains($0.level) && categories.contains($0.category)
        && (term.isEmpty || $0.line.localizedCaseInsensitiveContains(term))
    }
  }
}

public struct LogExportHeader: Sendable, Equatable {
  public let appName: String
  public let sourceVersion: String
  public let build: String
  public let distribution: String
  public let osVersion: String

  public init(app: AppInfo, osVersion: String) {
    appName = app.name
    sourceVersion = app.sourceVersion
    build = app.build
    distribution = app.distribution.displayName
    self.osVersion = osVersion
  }

  public init(appName: String, sourceVersion: String, build: String, distribution: String, osVersion: String) {
    self.appName = appName
    self.sourceVersion = sourceVersion
    self.build = build
    self.distribution = distribution
    self.osVersion = osVersion
  }
}

public enum LogExport {
  public static func text(entries: some Sequence<LogEntry>, header: LogExportHeader? = nil) -> String {
    var lines: [String] = []
    if let header {
      lines = [
        "\(header.appName) \(header.sourceVersion) (\(header.build)) \(header.distribution)",
        "macOS \(header.osVersion)",
        "",
      ].map(LogSanitizer.redact)
    }
    lines += entries.map(\.line)
    return lines.joined(separator: "\n")
  }
}

public enum LogSanitizer {
  public static let maximumMessageBytes = 1_900

  public static func message(_ value: String) -> String {
    truncate(
      redact(
        value.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")),
      maximumBytes: maximumMessageBytes)
  }

  public static func redact(_ value: String) -> String {
    var text = value.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path, with: "~")
    for rule in rules.expressions {
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      text = rule.expression.stringByReplacingMatches(
        in: text, options: [], range: range, withTemplate: rule.replacement)
    }
    return text
  }

  static func truncate(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    let suffix = "…"
    var bytes = Array(value.utf8.prefix(max(maximumBytes - suffix.utf8.count, 0)))
    while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self) + suffix
  }

  private static let rules = Rules()

  private final class Rules: @unchecked Sendable {
    let expressions: [(expression: NSRegularExpression, replacement: String)]

    init() {
      expressions = [
        Self.rule(#"\b(?:request|response)?[_-]?body\s*=[^\r\n]*"#, "body=<redacted>"),
        Self.rule(
          #"\b(authorization|proxy[_-]?authorization)\s*[:=]\s*(?:Bearer|Basic)\s+[^\s,;}\]\r\n]+"#,
          "$1=<redacted>"),
        Self.rule(#"\b(Bearer|Basic)\s+[A-Za-z0-9+/_=.:-]+"#, "$1 <redacted>"),
        Self.rule(
          #"(?:\\?[\"'])?\b(authorization|proxy[_-]?authorization|cookie|set[_-]?cookie|password|secret|"#
            + #"client[_-]?secret|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token)"#
            + #"(?:\\?[\"'])?\s*[:=]\s*(?:\\?[\"'][^\"'\r\n]*\\?[\"']|[^\s\\,;}\]\r\n]+)"#,
          "$1=<redacted>"),
        Self.rule(#"([a-z][a-z0-9+.-]*://[^ \t\r\n?]+)\?[^ \t\r\n\\]*"#, "$1?<redacted>"),
        Self.rule(#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
      ]
    }

    private static func rule(
      _ pattern: String, _ replacement: String
    ) -> (
      expression: NSRegularExpression, replacement: String
    ) {
      (
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        replacement
      )
    }
  }
}
