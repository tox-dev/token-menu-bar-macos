import Foundation

public struct GeminiOAuthClient: Sendable, Equatable {
  public let id: String
  public let secret: String

  public init(id: String, secret: String) {
    self.id = id
    self.secret = secret
  }
}

/// Refreshing a Gemini token needs the installed CLI's own installed-app OAuth client. Those values belong to the
/// Gemini CLI, not to this app, so they are read from the installed copy at runtime rather than vendored here.
public enum GeminiOAuthConfig {
  public static let relativePaths = [
    "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
    "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
    "lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
    "lib/node_modules/@google/gemini-cli/dist/gemini.js",
  ]

  public static func searchRoots(environment: [String: String], home: URL) -> [URL] {
    var roots = [
      home.appendingPathComponent(".npm-global"), URL(fileURLWithPath: "/opt/homebrew"),
      URL(fileURLWithPath: "/usr/local"),
    ]
    if let prefix = environment["NPM_CONFIG_PREFIX"] { roots.insert(URL(fileURLWithPath: prefix), at: 0) }
    return roots
  }

  nonisolated(unsafe) private static let clientIDPattern = pattern(for: "OAUTH_CLIENT_ID")
  nonisolated(unsafe) private static let clientSecretPattern = pattern(for: "OAUTH_CLIENT_SECRET")

  public static func extract(from source: String) -> GeminiOAuthClient? {
    guard let id = value(matching: clientIDPattern, in: source),
      let secret = value(matching: clientSecretPattern, in: source)
    else { return nil }
    return GeminiOAuthClient(id: id, secret: secret)
  }

  private static func pattern(for name: String) -> Regex<AnyRegexOutput> {
    try! Regex("\(name)\\s*=\\s*['\"]([^'\"]+)['\"]")
  }

  private static func value(matching pattern: Regex<AnyRegexOutput>, in source: String) -> String? {
    guard let match = try? pattern.firstMatch(in: source), let range = match[1].range else { return nil }
    return String(source[range])
  }

  public static func resolve(
    environment: [String: String], home: URL, read: (URL) -> String?
  ) -> GeminiOAuthClient? {
    if let id = environment["GEMINI_OAUTH_CLIENT_ID"], let secret = environment["GEMINI_OAUTH_CLIENT_SECRET"] {
      return GeminiOAuthClient(id: id, secret: secret)
    }
    for root in searchRoots(environment: environment, home: home) {
      for path in relativePaths {
        guard let source = read(root.appendingPathComponent(path)), let client = extract(from: source) else { continue }
        return client
      }
    }
    return nil
  }
}
