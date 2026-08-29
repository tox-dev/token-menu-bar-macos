import Foundation

public struct CopilotAuth: Sendable, Equatable {
  public let token: String
  public let user: String?
  public let host: String

  public init(token: String, user: String? = nil, host: String = "github.com") {
    self.token = token
    self.user = user
    self.host = host
  }

  public func state(now: Date) -> CredentialState {
    .valid(expiresAt: nil)
  }
}

public protocol CopilotAuthStore: Sendable {
  func load() throws -> CopilotAuth?
  var description: String { get }
}

public struct FileCopilotAuthStore: CopilotAuthStore {
  public let urls: [URL]

  public init(urls: [URL]) {
    self.urls = urls
  }

  public static func defaultURLs(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [URL] {
    let config =
      environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
    let root = config.appendingPathComponent("github-copilot")
    return [root.appendingPathComponent("hosts.json"), root.appendingPathComponent("apps.json")]
  }

  public var description: String {
    urls.map(\.path).joined(separator: ", ")
  }

  public func load() throws -> CopilotAuth? {
    for url in urls where FileManager.default.fileExists(atPath: url.path) {
      let data = try Data(contentsOf: url)
      guard let document = try? JSONDecoder().decode(JSONValue.self, from: data), let entries = document.objectValue
      else { throw CredentialStoreError.malformed("\(url.lastPathComponent) is not a JSON object") }
      let candidates = entries.keys.sorted().filter { $0.contains("github.com") } + entries.keys.sorted()
      for key in candidates {
        guard let token = entries[key]?["oauth_token"]?.stringValue, !token.isEmpty else { continue }
        return CopilotAuth(
          token: token, user: entries[key]?["user"]?.stringValue,
          host: String(key.split(separator: ":").first ?? "github.com"))
      }
    }
    return nil
  }
}
