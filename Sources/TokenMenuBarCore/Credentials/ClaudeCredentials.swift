import CryptoKit
import Foundation
import Security

public struct ClaudeOAuthCredentials: Sendable, Equatable {
  public static let keychainService = "Claude Code-credentials"
  public static let usageTokenMissingDetail = "Claude Code has not stored a usage token yet; run `claude` once."

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
      guard let current else { return .removed }
      return .changed(current.credentials, source: current.source)
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
  /// The item exists but holds no usable token yet.
  case incomplete(String)
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

  // Claude Code 2.1 can write the item with only an mcpOAuth block; that is a sign-in without a usage token, not an
  // absent sign-in.
  static func parse(_ data: Data) throws -> ClaudeOAuthCredentials {
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("Keychain item is not JSON")
    }
    guard let credentials = ClaudeOAuthCredentials(document: document) else {
      throw CredentialStoreError.incomplete(ClaudeOAuthCredentials.usageTokenMissingDetail)
    }
    return credentials
  }
}

public struct ClaudeKeychainAccount: Sendable, Equatable {
  public let service: String
  public let credentials: ClaudeOAuthCredentials

  public init(service: String, credentials: ClaudeOAuthCredentials) {
    self.service = service
    self.credentials = credentials
  }

  /// The hashed service suffix is all the item reveals about its configuration directory.
  public var label: String {
    service == ClaudeOAuthCredentials.keychainService
      ? "the default configuration"
      : "configuration \(service.dropFirst(ClaudeOAuthCredentials.keychainService.count + 1))"
  }

  public var source: CredentialSource {
    CredentialSource(
      id: "claude.keychain:\(service)", provider: .claude, title: "Claude Code Keychain",
      detail: "Keychain item \(service)")
  }
}

public final class DiscoveredClaudeKeychainStore: ClaudeCredentialStore, @unchecked Sendable {
  public let service: String
  public let account: String
  private let keychain: KeychainCredentialClient
  private let lock = NSLock()
  private var selectedService: String?

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
    "Keychain \(service), plus any \(ClaudeOAuthCredentials.keychainService)* item"
  }

  public var source: CredentialSource { ProviderID.claude.credentialSource("claude.keychain") }

  public func accounts() throws -> [ClaudeKeychainAccount] {
    let scan = scan()
    if scan.accounts.isEmpty, let error = scan.error { throw error }
    return scan.accounts
  }

  public func load() throws -> ClaudeOAuthCredentials? {
    try loadWithSource()?.credentials
  }

  public func loadWithSource() throws -> (credentials: ClaudeOAuthCredentials, source: CredentialSource)? {
    try selected().map {
      ($0.account.credentials, summarySource($0.account.source, count: $0.count, showing: $0.account.label))
    }
  }

  public func save(_ credentials: ClaudeOAuthCredentials) throws {
    let target = try selected()?.account.service ?? service
    try KeychainClaudeCredentialStore(service: target, account: account, keychain: keychain).save(credentials)
  }

  private func selected() throws -> (account: ClaudeKeychainAccount, count: Int)? {
    let scan = scan()
    let chosen = lock.withLock {
      if selectedService == nil {
        selectedService =
          scan.accounts.first { $0.service == service }?.service
          ?? scan.accounts.sorted { $0.service < $1.service }.first?.service
      }
      return selectedService
    }
    guard let best = scan.accounts.first(where: { $0.service == chosen }) else {
      if let error = scan.error { throw error }
      guard scan.incompleteServices.isEmpty else {
        throw CredentialStoreError.incomplete(ClaudeOAuthCredentials.usageTokenMissingDetail)
      }
      return nil
    }
    return (best, scan.accounts.count)
  }

  private func scan() -> (accounts: [ClaudeKeychainAccount], incompleteServices: [String], error: (any Error)?) {
    var accounts: [ClaudeKeychainAccount] = []
    var incompleteServices: [String] = []
    var firstError: (any Error)?
    for service in services() {
      do {
        let store = KeychainClaudeCredentialStore(service: service, account: account, keychain: keychain)
        if let credentials = try store.load() {
          accounts.append(ClaudeKeychainAccount(service: service, credentials: credentials))
        }
      } catch CredentialStoreError.incomplete {
        incompleteServices.append(service)
      } catch {
        firstError = firstError ?? error
      }
    }
    return (accounts, incompleteServices, firstError)
  }

  private func services() -> [String] {
    let listed = (try? keychain.services(prefix: ClaudeOAuthCredentials.keychainService)) ?? []
    return [service] + listed.filter { $0 != service }
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
    try writeCredentialData(JSONEncoder().encode(credentials.document), to: url)
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
    var selected: (credentials: ClaudeOAuthCredentials, source: CredentialSource)?
    for store in stores {
      do {
        guard let found = try store.loadWithSource() else { continue }
        guard let current = selected else {
          selected = found
          continue
        }
        let currentSubject = JWT.payload(current.credentials.accessToken)?["sub"]?.stringValue
        let foundSubject = JWT.payload(found.credentials.accessToken)?["sub"]?.stringValue
        let sameAccount =
          currentSubject != nil && currentSubject == foundSubject
          || current.credentials.refreshToken != nil
            && current.credentials.refreshToken == found.credentials.refreshToken
          || current.credentials.accessToken == found.credentials.accessToken
        if sameAccount,
          (found.credentials.expiresAt ?? .distantFuture) > (current.credentials.expiresAt ?? .distantFuture)
        {
          selected = found
        }
      } catch {
        lastError = CredentialReadFailure(source: store.source, error: error)
      }
    }
    if selected == nil, let lastError { throw lastError }
    return selected
  }

  public func save(_ credentials: ClaudeOAuthCredentials) throws {
    let selected = try loadWithSource()?.credentials
    let target = stores.first { (try? $0.load()) == selected && selected != nil } ?? stores.first
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
