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
    case .copilot: "GitHub Copilot"
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

  public var loginHint: String {
    switch self {
    case .claude: "Run `claude` once to sign in; the app reads its Keychain or credential-file session."
    case .codex: "Run `codex login` once; the app follows cli_auth_credentials_store in config.toml."
    case .gemini: "Run `gemini` and sign in with Google once; the app reads its selected credential store."
    case .cursor: "Sign in to the Cursor app or run `cursor-agent login`; the app reads Cursor's local session."
    case .copilot:
      "Run `copilot login`; the app also reads supported token environment variables and existing editor sessions."
    }
  }

  public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
