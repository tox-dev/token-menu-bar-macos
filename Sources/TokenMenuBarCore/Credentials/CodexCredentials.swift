import Foundation

public struct CodexAuth: Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  public let accountID: String?
  public let apiKey: String?
  public let lastRefresh: Date?
  public let document: JSONValue

  public init?(document: JSONValue) {
    let tokens = document["tokens"]
    apiKey = document["OPENAI_API_KEY"]?.stringValue
    guard let accessToken = tokens?["access_token"]?.stringValue ?? apiKey else { return nil }
    self.document = document
    self.accessToken = accessToken
    refreshToken = tokens?["refresh_token"]?.stringValue
    idToken = tokens?["id_token"]?.stringValue
    accountID =
      tokens?["account_id"]?.stringValue
      ?? JWT.payload(idToken ?? "")?["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue
    lastRefresh = ISODate.parse(document["last_refresh"]?.stringValue)
  }

  public init(
    accessToken: String, refreshToken: String? = nil, idToken: String? = nil, accountID: String? = nil,
    lastRefresh: Date? = nil
  ) {
    var tokens: [String: JSONValue] = ["access_token": .string(accessToken)]
    tokens["refresh_token"] = refreshToken.map(JSONValue.string)
    tokens["id_token"] = idToken.map(JSONValue.string)
    tokens["account_id"] = accountID.map(JSONValue.string)
    var document: [String: JSONValue] = [
      "tokens": .object(tokens), "auth_mode": .string("chatgpt"), "OPENAI_API_KEY": .null,
    ]
    document["last_refresh"] = lastRefresh.map { .string(ISODate.string($0)) }
    self.init(document: .object(document))!
  }

  public var claims: JSONValue? {
    idToken.flatMap(JWT.payload)
  }

  public var email: String? {
    claims?["email"]?.stringValue
  }

  public var planType: String? {
    claims?["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.stringValue
  }

  public var subscriptionActiveUntil: Date? {
    ISODate.parse(claims?["https://api.openai.com/auth"]?["chatgpt_subscription_active_until"]?.stringValue)
  }

  public func state(now: Date) -> CredentialState {
    CredentialState.from(expiresAt: JWT.expiry(accessToken), now: now)
  }

  public func refreshed(accessToken: String, refreshToken: String?, idToken: String?, now: Date) -> CodexAuth {
    var tokens = document["tokens"]?.objectValue ?? [:]
    tokens["access_token"] = .string(accessToken)
    if let refreshToken { tokens["refresh_token"] = .string(refreshToken) }
    if let idToken { tokens["id_token"] = .string(idToken) }
    let updated = document.merging("tokens", .object(tokens)).merging("last_refresh", .string(ISODate.string(now)))
    return CodexAuth(document: updated)!
  }
}

public protocol CodexAuthStore: Sendable {
  func load() throws -> CodexAuth?
  func save(_ auth: CodexAuth) throws
  var description: String { get }
}

public struct FileCodexAuthStore: CodexAuthStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static func defaultURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    let root = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
    return root.appendingPathComponent("auth.json")
  }

  public var description: String {
    url.path
  }

  public func load() throws -> CodexAuth? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("\(url.lastPathComponent) is not JSON")
    }
    return CodexAuth(document: document)
  }

  public func save(_ auth: CodexAuth) throws {
    try JSONEncoder().encode(auth.document).write(to: url, options: .atomic)
  }
}

public enum ISODate {
  nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

  public static func parse(_ string: String?) -> Date? {
    guard let string else { return nil }
    return fractional.date(from: string) ?? plain.date(from: string)
  }

  public static func string(_ date: Date) -> String {
    fractional.string(from: date)
  }
}
