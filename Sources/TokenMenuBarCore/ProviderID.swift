import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
  case claude
  case codex
  case gemini
  case cursor
  case copilot

  public var displayName: String {
    switch self {
    case .claude: "Claude"
    case .codex: "Codex"
    case .gemini: "Gemini"
    case .cursor: "Cursor"
    case .copilot: "Copilot"
    }
  }

  public var shortLabel: String {
    switch self {
    case .claude: "CC"
    case .codex: "CX"
    case .gemini: "GM"
    case .cursor: "CU"
    case .copilot: "CP"
    }
  }

  public var usagePage: URL {
    switch self {
    case .claude: URL(string: "https://claude.ai/settings/usage")!
    case .codex: URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
    case .gemini: URL(string: "https://developers.google.com/gemini-code-assist/resources/quotas")!
    case .cursor: URL(string: "https://cursor.com/dashboard?tab=usage")!
    case .copilot: URL(string: "https://github.com/settings/copilot/features")!
    }
  }

  public var loginHint: String {
    switch self {
    case .claude: "Run `claude` once to sign in; the app reads its Keychain token."
    case .codex: "Run `codex login` once; the app reads ~/.codex/auth.json."
    case .gemini: "Run `gemini` and sign in with Google once; the app reads ~/.gemini/oauth_creds.json."
    case .cursor: "Sign in to the Cursor app or run `cursor-agent login`; the app reads Cursor's local session."
    case .copilot: "Sign in to Copilot from Copilot CLI, Neovim or JetBrains; the app reads ~/.config/github-copilot."
    }
  }

  public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
