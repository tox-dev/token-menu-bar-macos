import CryptoKit
import Foundation
import Security

public struct ClaudeOAuthCredentials: Sendable, Equatable {
  public static let keychainService = "Claude Code-credentials"

  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?
  public let scopes: [String]
  public let subscriptionType: String?
  public let rateLimitTier: String?
  public let document: JSONValue

  public init?(document: JSONValue) {
    guard let oauth = document["claudeAiOauth"], let accessToken = oauth["accessToken"]?.stringValue else { return nil }
    self.document = document
    self.accessToken = accessToken
    refreshToken = oauth["refreshToken"]?.stringValue
    expiresAt = oauth["expiresAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    scopes = oauth["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    subscriptionType = oauth["subscriptionType"]?.stringValue
    rateLimitTier = oauth["rateLimitTier"]?.stringValue
  }

  public init(
    accessToken: String, refreshToken: String?, expiresAt: Date?, scopes: [String] = ["user:profile"],
    subscriptionType: String? = nil, rateLimitTier: String? = nil
  ) {
    var oauth: [String: JSONValue] = [
      "accessToken": .string(accessToken), "scopes": .array(scopes.map(JSONValue.string)),
    ]
    oauth["refreshToken"] = refreshToken.map(JSONValue.string)
    oauth["expiresAt"] = expiresAt.map { .number(($0.timeIntervalSince1970 * 1000).rounded()) }
    oauth["subscriptionType"] = subscriptionType.map(JSONValue.string)
    oauth["rateLimitTier"] = rateLimitTier.map(JSONValue.string)
    self.init(document: .object(["claudeAiOauth": .object(oauth)]))!
  }

  public var hasProfileScope: Bool {
    scopes.contains("user:profile")
  }

  var cacheFingerprint: String {
    let claims = JWT.payload(accessToken)
    let identity = claims?["sub"]?.stringValue ?? claims?["email"]?.stringValue ?? refreshToken ?? accessToken
    return SHA256.hash(data: Data("claude-cache:\(identity)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public func state(now: Date) -> CredentialState {
    CredentialState.from(expiresAt: expiresAt, now: now)
  }

  public func refreshed(
    accessToken: String, refreshToken: String?, expiresIn: TimeInterval, now: Date
  ) -> ClaudeOAuthCredentials {
    var oauth = document["claudeAiOauth"]!.objectValue!
    oauth["accessToken"] = .string(accessToken)
    if let refreshToken { oauth["refreshToken"] = .string(refreshToken) }
    oauth["expiresAt"] = .number((now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000).rounded())
    return ClaudeOAuthCredentials(document: document.merging("claudeAiOauth", .object(oauth)))!
  }

  public static func keychainService(configDir: String?) -> String {
    guard let configDir, !configDir.isEmpty else { return keychainService }
    let digest = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(keychainService)-\(digest.prefix(8))"
  }
}

public protocol ClaudeCredentialStore: Sendable {
  func load() throws -> ClaudeOAuthCredentials?
  func loadWithSource() throws -> (credentials: ClaudeOAuthCredentials, source: CredentialSource)?
  func save(_ credentials: ClaudeOAuthCredentials) throws
  var description: String { get }
  var source: CredentialSource { get }
}

extension ClaudeCredentialStore {
  public var source: CredentialSource {
    CredentialSource(id: "claude.custom", provider: .claude, title: "Claude credentials", detail: description)
  }

  public func save(
    _ credentials: ClaudeOAuthCredentials,
    replacing expected: ClaudeOAuthCredentials
  ) throws -> CredentialSaveResult<ClaudeOAuthCredentials> {
    let current = try loadWithSource()
    guard current?.credentials == expected else {
      return .changed(current?.credentials, source: current?.source)
    }
    try save(credentials)
    return .saved
  }

  public func loadWithSource() throws -> (credentials: ClaudeOAuthCredentials, source: CredentialSource)? {
    try load().map { ($0, source) }
  }

  public func credentialHealth(now: Date) -> ProviderCredentialHealth {
    do {
      guard let found = try loadWithSource() else {
        return .missing(expected: ProviderID.claude.setup.credentialSources)
      }
      return .from(
        found.credentials.state(now: now), source: found.source, expected: ProviderID.claude.setup.credentialSources)
    } catch {
      return .from(readError: error, fallbackSource: source)
    }
  }
}

public enum CredentialStoreError: Error, Equatable {
  case keychain(OSStatus)
  case malformed(String)
}

public struct KeychainClaudeCredentialStore: ClaudeCredentialStore {
  public let service: String
  public let account: String
  private let keychain: KeychainCredentialClient

  public init(
    service: String = ClaudeOAuthCredentials.keychainService,
    account: String,
    keychain: KeychainCredentialClient
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
  }

  public var description: String {
    "Keychain item \(service)"
  }

  public var source: CredentialSource { ProviderID.claude.credentialSource("claude.keychain") }

  public func load() throws -> ClaudeOAuthCredentials? {
    guard let item = try keychain.load(service: service, account: account) else { return nil }
    return try Self.parse(item.data)
  }

  public func save(_ credentials: ClaudeOAuthCredentials) throws {
    try keychain.save(try JSONEncoder().encode(credentials.document), service: service, account: account)
  }

  static func parse(_ data: Data) throws -> ClaudeOAuthCredentials? {
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("Keychain item is not JSON")
    }
    return ClaudeOAuthCredentials(document: document)
  }
}

public struct FileClaudeCredentialStore: ClaudeCredentialStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public var description: String {
    url.path
  }

  public var source: CredentialSource { ProviderID.claude.credentialSource("claude.file") }

  public func load() throws -> ClaudeOAuthCredentials? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("\(url.lastPathComponent) is not JSON")
    }
    return ClaudeOAuthCredentials(document: document)
  }

  public func save(_ credentials: ClaudeOAuthCredentials) throws {
    try JSONEncoder().encode(credentials.document).write(to: url, options: .atomic)
  }
}

public struct ChainedClaudeCredentialStore: ClaudeCredentialStore {
  public let stores: [any ClaudeCredentialStore]

  public init(_ stores: [any ClaudeCredentialStore]) {
    self.stores = stores
  }

  public var description: String {
    stores.map(\.description).joined(separator: ", ")
  }

  public var source: CredentialSource {
    CredentialSource(
      id: "claude.automatic", provider: .claude, title: "Claude Code credentials",
      detail: stores.map(\.source.title).joined(separator: ", "))
  }

  public func load() throws -> ClaudeOAuthCredentials? {
    try loadWithSource()?.credentials
  }

  public func loadWithSource() throws -> (credentials: ClaudeOAuthCredentials, source: CredentialSource)? {
    var lastError: CredentialReadFailure?
    for store in stores {
      do {
        if let found = try store.loadWithSource() { return found }
      } catch {
        lastError = CredentialReadFailure(source: store.source, error: error)
      }
    }
    if let lastError { throw lastError }
    return nil
  }

  public func save(_ credentials: ClaudeOAuthCredentials) throws {
    let target = stores.first { (try? $0.load()) != nil } ?? stores.first
    guard let target else { return }
    try target.save(credentials)
  }
}

public struct ClaudeLocalAccount: Sendable, Equatable {
  public let email: String?
  public let organizationName: String?
  public let rateLimitTier: String?
  public let hasExtraUsageEnabled: Bool?

  public init(email: String?, organizationName: String?, rateLimitTier: String?, hasExtraUsageEnabled: Bool?) {
    self.email = email
    self.organizationName = organizationName
    self.rateLimitTier = rateLimitTier
    self.hasExtraUsageEnabled = hasExtraUsageEnabled
  }

  public static func load(from url: URL) -> ClaudeLocalAccount? {
    guard let data = try? Data(contentsOf: url), let json = try? JSONDecoder().decode(JSONValue.self, from: data),
      let account = json["oauthAccount"]
    else { return nil }
    return ClaudeLocalAccount(
      email: account["emailAddress"]?.stringValue,
      organizationName: account["organizationName"]?.stringValue,
      rateLimitTier: account["organizationRateLimitTier"]?.stringValue,
      hasExtraUsageEnabled: account["hasExtraUsageEnabled"]?.boolValue
    )
  }
}
