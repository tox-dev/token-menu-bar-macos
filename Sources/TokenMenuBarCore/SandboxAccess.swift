import Foundation

/// A path the sandboxed build cannot read until the user grants a security-scoped bookmark for it.
public struct SandboxResource: Sendable, Hashable, Identifiable {
  /// How an environment variable, when set, moves the path away from the default under the home directory.
  public enum Override: Sendable, Hashable {
    /// The variable holds the resource path itself, as `CODEX_HOME` and `CLAUDE_CONFIG_DIR` do.
    case path(String)
    /// The variable replaces the home directory, as `GEMINI_CLI_HOME` does.
    case home(String)
    /// The variable replaces the leading directories, as `XDG_CONFIG_HOME` does for `.config`.
    case prefix(String)
  }

  /// How much the provider depends on the folder, so Settings can say what to grant and what to skip.
  public enum Need: Sendable, Hashable {
    /// The provider reports nothing without it.
    case required
    /// It adds local history and cost estimates; the provider's quota does not depend on it.
    case optional
    /// One of several folders that can each hold the sign-in; the client the user uses decides which.
    case oneOf(String)
  }

  public let id: String
  public let relativePath: String
  public let provider: ProviderID
  public let need: Need
  public let explanation: String
  public let override: Override?

  public init(
    id: String, relativePath: String, provider: ProviderID, need: Need = .required, explanation: String,
    override: Override? = nil
  ) {
    self.id = id
    self.relativePath = relativePath
    self.provider = provider
    self.need = need
    self.explanation = explanation
    self.override = override
  }

  public var alternativesGroup: String? {
    if case .oneOf(let group) = need { group } else { nil }
  }

  public var label: String {
    "~/\(relativePath)"
  }

  /// The path this build reads, so the grant panel and the provider agree on one location.
  public func configuredURL(environment: [String: String], home: URL) -> URL {
    switch override {
    case .path(let key):
      if let value = environment[key] { return URL(fileURLWithPath: value) }
    case .home(let key):
      if let value = environment[key] { return URL(fileURLWithPath: value).appending(path: relativePath) }
    case .prefix(let key):
      if let value = environment[key] {
        return URL(fileURLWithPath: value).appending(path: (relativePath as NSString).lastPathComponent)
      }
    case nil:
      break
    }
    return home.appending(path: relativePath)
  }
}

extension ProviderID {
  /// The paths this provider reads under the user's home. The unsandboxed build reads them directly; the App Store
  /// build needs one bookmark per entry before the provider reports anything.
  public var sandboxResources: [SandboxResource] {
    switch self {
    case .claude:
      [
        SandboxResource(
          id: "claude.home", relativePath: ".claude", provider: self, need: .optional,
          explanation:
            "Claude Code keeps its transcripts here. They give History its token counts and API-equivalent "
            + "costs. Quota, plan and account come from Claude Code's Keychain sign-in, so Claude works without "
            + "this folder. It also holds the credentials file Claude Code writes only when the Keychain refuses "
            + "its sign-in.",
          override: .path("CLAUDE_CONFIG_DIR"))
      ]
    case .codex:
      [
        SandboxResource(
          id: "codex.home", relativePath: ".codex", provider: self,
          explanation:
            "Codex keeps its sign-in (auth.json) and its session logs here. The sign-in lets the app ask OpenAI "
            + "for your limits; the logs give History its token counts.",
          override: .path("CODEX_HOME"))
      ]
    case .gemini:
      [
        SandboxResource(
          id: "gemini.home", relativePath: ".gemini", provider: self,
          explanation:
            "Gemini CLI keeps its sign-in (oauth_creds.json) here. The app uses it to ask Google for your "
            + "limits. Not needed if you store the sign-in in the Keychain with GEMINI_FORCE_ENCRYPTED_FILE_STORAGE.",
          override: .home("GEMINI_CLI_HOME"))
      ]
    case .antigravity:
      []
    case .cursor:
      [
        SandboxResource(
          id: "cursor.support", relativePath: "Library/Application Support/Cursor", provider: self,
          need: .oneOf("cursor"),
          explanation:
            "The Cursor app keeps its session in a database here (state.vscdb). The app reads it, read-only, to "
            + "ask Cursor for your usage. Grant this folder if you sign in through the Cursor app; ~/.cursor is "
            + "then not needed."),
        SandboxResource(
          id: "cursor.home", relativePath: ".cursor", provider: self, need: .oneOf("cursor"),
          explanation:
            "cursor-agent saves its sign-in (auth.json) here. Grant this folder if you sign in with cursor-agent; "
            + "the Cursor app's folder is then not needed."),
      ]
    case .copilot:
      [
        SandboxResource(
          id: "copilot.home", relativePath: ".copilot", provider: self, need: .oneOf("copilot"),
          explanation:
            "The GitHub Copilot CLI saves its settings and sign-in (config.json) here. Grant this folder if you "
            + "sign in with copilot login and the sign-in is not in the Keychain; ~/.config/github-copilot is "
            + "then not needed.",
          override: .path("COPILOT_HOME")),
        SandboxResource(
          id: "copilot.config", relativePath: ".config/github-copilot", provider: self, need: .oneOf("copilot"),
          explanation:
            "GitHub Copilot's editor extensions save hosts.json and apps.json here. Grant this folder if you use "
            + "Copilot only through an editor extension; ~/.copilot is then not needed.",
          override: .prefix("XDG_CONFIG_HOME")),
      ]
    }
  }

  public static var allSandboxResources: [SandboxResource] {
    allCases.flatMap(\.sandboxResources)
  }
}
