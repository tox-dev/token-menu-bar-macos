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

  public enum Kind: Sendable, Hashable {
    case directory
    case file
  }

  public let id: String
  public let relativePath: String
  public let provider: ProviderID
  public let kind: Kind
  public let override: Override?

  public init(
    id: String, relativePath: String, provider: ProviderID, kind: Kind = .directory, override: Override? = nil
  ) {
    self.id = id
    self.relativePath = relativePath
    self.provider = provider
    self.kind = kind
    self.override = override
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
          id: "claude.home", relativePath: ".claude", provider: self, override: .path("CLAUDE_CONFIG_DIR")),
        SandboxResource(id: "claude.account", relativePath: ".claude.json", provider: self, kind: .file),
      ]
    case .codex:
      [SandboxResource(id: "codex.home", relativePath: ".codex", provider: self, override: .path("CODEX_HOME"))]
    case .gemini:
      [SandboxResource(id: "gemini.home", relativePath: ".gemini", provider: self, override: .home("GEMINI_CLI_HOME"))]
    case .cursor:
      [
        SandboxResource(id: "cursor.support", relativePath: "Library/Application Support/Cursor", provider: self),
        SandboxResource(id: "cursor.home", relativePath: ".cursor", provider: self),
      ]
    case .copilot:
      [
        SandboxResource(
          id: "copilot.home", relativePath: ".copilot", provider: self, override: .path("COPILOT_HOME")),
        SandboxResource(
          id: "copilot.config", relativePath: ".config/github-copilot", provider: self,
          override: .prefix("XDG_CONFIG_HOME")),
      ]
    }
  }

  public static var allSandboxResources: [SandboxResource] {
    allCases.flatMap(\.sandboxResources)
  }
}
