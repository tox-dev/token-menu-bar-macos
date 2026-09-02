import Foundation

public enum StatusFormat: String, CaseIterable, Codable, Sendable {
  case stacked = "Stacked"
  case inline = "Inline"
  case miniBars = "Mini bars"
  case custom = "Custom"

  public var template: String? {
    switch self {
    case .stacked: "{label}\n{pct}"
    case .inline: "{label}:{pct}"
    case .miniBars, .custom: nil
    }
  }
}

public struct StatusRun: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case label
    case number
    case usage(Double)
  }

  public let text: String
  public let kind: Kind

  public init(text: String, kind: Kind) {
    self.text = text
    self.kind = kind
  }
}

public struct StatusCellContext: Sendable {
  public let provider: ProviderID
  public let window: QuotaWindow
  public let cellLabel: String
  public let shortLabel: String
  public let decimals: Int
  public let planName: String?
  public let credits: String?
  public let now: Date

  public init(
    provider: ProviderID, window: QuotaWindow, cellLabel: String, shortLabel: String, decimals: Int, planName: String?,
    credits: String?, now: Date
  ) {
    self.provider = provider
    self.window = window
    self.cellLabel = cellLabel
    self.shortLabel = shortLabel
    self.decimals = decimals
    self.planName = planName
    self.credits = credits
    self.now = now
  }
}

public enum StatusTemplate {
  public static let tokens: [(token: String, help: String)] = [
    ("{cell}", "provider tag, plus the window tag when a provider shows several windows"),
    ("{provider}", "provider tag (CC, CX)"),
    ("{providerName}", "provider name"),
    ("{window}", "window tag (5h, 7d, model)"),
    ("{label}", "editable short label"),
    ("{pct}", "used percent at the configured decimals"),
    ("{pct0}", "used percent, no decimals"),
    ("{pct1}", "used percent, one decimal"),
    ("{remaining}", "remaining percent"),
    ("{reset}", "countdown to reset"),
    ("{resetClock}", "reset time"),
    ("{plan}", "plan name"),
    ("{credits}", "credit balance"),
  ]

  enum Token: Equatable {
    case text(String)
    case placeholder(String)
    case newline
  }

  /// A template parsed once. The status bar renders the same template for every cell, and again for every tier the
  /// adaptive ladder tries, so parsing per render walked the string two dozen times per rebuild.
  public struct Compiled: Sendable {
    let tokens: [Token]
    public let referencesCountdown: Bool

    init(_ template: String) {
      tokens = StatusTemplate.parse(template)
      referencesCountdown = tokens.contains { $0 == .placeholder("reset") }
    }
  }

  public static func compile(_ template: String) -> Compiled {
    Compiled(template)
  }

  public static func referencesCountdown(_ template: String) -> Bool {
    Compiled(template).referencesCountdown
  }

  public static func render(_ template: String, context: StatusCellContext) -> [[StatusRun]] {
    render(Compiled(template), context: context)
  }

  public static func render(_ compiled: Compiled, context: StatusCellContext) -> [[StatusRun]] {
    var lines: [[StatusRun]] = [[]]
    for token in compiled.tokens {
      switch token {
      case .newline: lines.append([])
      case .text(let text): lines[lines.count - 1].append(StatusRun(text: text, kind: .label))
      case .placeholder(let name):
        if let run = run(for: name, context: context) { lines[lines.count - 1].append(run) }
      }
    }
    return lines.filter { !$0.isEmpty }
  }

  static func parse(_ template: String) -> [Token] {
    var tokens: [Token] = []
    var text = ""
    var iterator = template.makeIterator()
    var pending: Character?
    func flush() {
      if !text.isEmpty { tokens.append(.text(text)) }
      text = ""
    }
    while let character = pending ?? iterator.next() {
      pending = nil
      switch character {
      case "\\":
        if let next = iterator.next() {
          if next == "n" {
            flush()
            tokens.append(.newline)
          } else {
            text.append(next)
          }
        }
      case "\n":
        flush()
        tokens.append(.newline)
      case "{":
        if let next = iterator.next() {
          if next == "{" {
            text.append("{")
          } else {
            var name = String(next)
            var closed = false
            while let inner = iterator.next() {
              if inner == "}" {
                closed = true
                break
              }
              name.append(inner)
            }
            if closed {
              flush()
              tokens.append(.placeholder(name))
            } else {
              text += "{" + name
            }
          }
        } else {
          text.append("{")
        }
      case "}":
        if let next = iterator.next() {
          if next != "}" { pending = next }
        }
        text.append("}")
      default:
        text.append(character)
      }
    }
    flush()
    return tokens
  }

  static func run(for name: String, context: StatusCellContext) -> StatusRun? {
    let percent = context.window.usedPercent
    switch name {
    case "cell": return StatusRun(text: context.cellLabel, kind: .label)
    case "provider": return StatusRun(text: context.provider.shortLabel, kind: .label)
    case "providerName": return StatusRun(text: context.provider.displayName, kind: .label)
    case "window": return StatusRun(text: windowTag(context.window), kind: .label)
    case "label": return StatusRun(text: context.shortLabel, kind: .label)
    case "pct": return StatusRun(text: Format.percent(percent, decimals: context.decimals), kind: .usage(percent))
    case "pct0": return StatusRun(text: Format.percent(percent, decimals: 0), kind: .usage(percent))
    case "pct1": return StatusRun(text: Format.percent(percent, decimals: 1), kind: .usage(percent))
    case "pct2": return StatusRun(text: Format.percent(percent, decimals: 2), kind: .usage(percent))
    case "remaining":
      return StatusRun(
        text: Format.percent(context.window.remainingPercent, decimals: context.decimals), kind: .usage(percent))
    case "reset":
      return StatusRun(text: Format.compactCountdown(to: context.window.resetsAt, now: context.now), kind: .number)
    case "resetClock":
      return StatusRun(text: Format.resetClock(context.window.resetsAt, now: context.now), kind: .number)
    case "plan": return context.planName.map { StatusRun(text: $0, kind: .label) }
    case "credits": return context.credits.map { StatusRun(text: $0, kind: .number) }
    default: return nil
    }
  }

  public static func plainText(_ lines: [[StatusRun]]) -> String {
    lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
  }

  public static func windowTag(_ window: QuotaWindow) -> String {
    switch window.id {
    case "session": return "5h"
    case "weekly": return "7d"
    case "monthly": return "1mo"
    default:
      if let scope = window.scope {
        return String((scope.split(separator: " ").first.map(String.init) ?? scope).prefix(3)).uppercased()
      }
      return String((window.id.split(separator: ":").last.map(String.init) ?? window.id).prefix(3)).uppercased()
    }
  }
}
