import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
  case claude
  case codex

  public var displayName: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    }
  }

  public var shortLabel: String {
    switch self {
    case .claude: "CC"
    case .codex: "CX"
    }
  }

  public var usagePage: URL {
    switch self {
    case .claude: URL(string: "https://claude.ai/settings/usage")!
    case .codex: URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
    }
  }

  public var loginHint: String {
    switch self {
    case .claude: "Run `claude` once to sign in; the app reads its Keychain token."
    case .codex: "Run `codex login` once; the app reads ~/.codex/auth.json."
    }
  }

  public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
