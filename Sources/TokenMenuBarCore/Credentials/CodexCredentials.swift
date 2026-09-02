import CryptoKit
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

  var accountFingerprint: String {
    let value: String
    if let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
      value = "account:\(accountID)"
    } else if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty {
      value = "email:\(email)"
    } else {
      value = "token:\(accessToken)"
    }
    return SHA256.hash(data: Data("codex-analytics:\(value)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
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
  func loadWithSource() throws -> (auth: CodexAuth, source: CredentialSource)?
  func save(_ auth: CodexAuth) throws
  var description: String { get }
  var source: CredentialSource { get }
}

extension CodexAuthStore {
  public var source: CredentialSource {
    CredentialSource(id: "codex.custom", provider: .codex, title: "Codex credentials", detail: description)
  }

  public func save(_ auth: CodexAuth, replacing expected: CodexAuth) throws -> CredentialSaveResult<CodexAuth> {
    let current = try loadWithSource()
    guard current?.auth == expected else { return .changed(current?.auth, source: current?.source) }
    try save(auth)
    return .saved
  }

  public func loadWithSource() throws -> (auth: CodexAuth, source: CredentialSource)? {
    try load().map { ($0, source) }
  }

  public func credentialHealth(now: Date) -> ProviderCredentialHealth {
    do {
      guard let found = try loadWithSource() else {
        return .missing(expected: ProviderID.codex.setup.credentialSources)
      }
      return .from(found.auth.state(now: now), source: found.source, expected: ProviderID.codex.setup.credentialSources)
    } catch {
      return .from(readError: error, fallbackSource: source)
    }
  }
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

  public var source: CredentialSource { ProviderID.codex.credentialSource("codex.file") }

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

public struct KeychainCodexAuthStore: CodexAuthStore {
  public static let service = "Codex Auth"

  public let account: String
  private let keychain: KeychainCredentialClient

  public init(codexHome: URL, keychain: KeychainCredentialClient) {
    account = Self.account(codexHome: codexHome)
    self.keychain = keychain
  }

  public init(account: String, keychain: KeychainCredentialClient) {
    self.account = account
    self.keychain = keychain
  }

  public var description: String { "Keychain item \(Self.service)" }
  public var source: CredentialSource { ProviderID.codex.credentialSource("codex.keyring") }

  public func load() throws -> CodexAuth? {
    guard let item = try keychain.load(service: Self.service, account: account) else { return nil }
    return try Self.parse(item.data)
  }

  public func save(_ auth: CodexAuth) throws {
    try keychain.save(try JSONEncoder().encode(auth.document), service: Self.service, account: account)
  }

  public static func account(codexHome: URL) -> String {
    let canonical = codexHome.standardizedFileURL.resolvingSymlinksInPath().path
    let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    return "cli|\(digest.prefix(16))"
  }

  static func parse(_ data: Data) throws -> CodexAuth? {
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("Codex Keychain item is not JSON")
    }
    return CodexAuth(document: document)
  }
}

public struct ChainedCodexAuthStore: CodexAuthStore {
  public let stores: [any CodexAuthStore]

  public init(_ stores: [any CodexAuthStore]) {
    self.stores = stores
  }

  public var description: String { stores.map(\.description).joined(separator: ", ") }

  public var source: CredentialSource {
    CredentialSource(
      id: "codex.automatic", provider: .codex, title: "Codex credentials",
      detail: stores.map(\.source.title).joined(separator: ", "))
  }

  public func load() throws -> CodexAuth? {
    try loadWithSource()?.auth
  }

  public func loadWithSource() throws -> (auth: CodexAuth, source: CredentialSource)? {
    var firstError: CredentialReadFailure?
    for store in stores {
      do {
        if let found = try store.loadWithSource() { return found }
      } catch {
        firstError = firstError ?? CredentialReadFailure(source: store.source, error: error)
      }
    }
    if let firstError { throw firstError }
    return nil
  }

  public func save(_ auth: CodexAuth) throws {
    let target = stores.first { (try? $0.load()) != nil } ?? stores.first
    guard let target else { return }
    try target.save(auth)
  }
}

public enum CodexCredentialStorage: Sendable, Equatable {
  case automatic
  case file
  case keyring
  case unknown(String)
}

public enum CodexCredentialStorageReader {
  public static func load(
    from url: URL,
    read: (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
  ) -> CodexCredentialStorage {
    guard let text = try? read(url) else { return .automatic }
    return parse(text)
  }

  public static func parse(_ text: String) -> CodexCredentialStorage {
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { break }
      guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
      let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
      guard key == "cli_auth_credentials_store" else { continue }
      let value = trimmed[trimmed.index(after: separator)...]
        .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      switch value {
      case "auto": return .automatic
      case "file": return .file
      case "keyring": return .keyring
      default: return .unknown(value)
      }
    }
    return .automatic
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
