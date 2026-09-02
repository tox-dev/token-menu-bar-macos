import CryptoKit
import Foundation

public struct GeminiAuth: Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  public let expiresAt: Date?
  public let document: JSONValue

  public init?(document: JSONValue) {
    let wrapped = document["token"]
    guard let accessToken = document["access_token"]?.stringValue ?? wrapped?["accessToken"]?.stringValue else {
      return nil
    }
    self.document = document
    self.accessToken = accessToken
    refreshToken = document["refresh_token"]?.stringValue ?? wrapped?["refreshToken"]?.stringValue
    idToken = document["id_token"]?.stringValue ?? wrapped?["idToken"]?.stringValue
    expiresAt = (document["expiry_date"]?.doubleValue ?? wrapped?["expiresAt"]?.doubleValue).map {
      Date(timeIntervalSince1970: $0 / 1000)
    }
  }

  public init(accessToken: String, refreshToken: String? = nil, idToken: String? = nil, expiresAt: Date? = nil) {
    var document: [String: JSONValue] = ["access_token": .string(accessToken), "token_type": .string("Bearer")]
    document["refresh_token"] = refreshToken.map(JSONValue.string)
    document["id_token"] = idToken.map(JSONValue.string)
    document["expiry_date"] = expiresAt.map { .number($0.timeIntervalSince1970 * 1000) }
    self.init(document: .object(document))!
  }

  public var email: String? {
    idToken.flatMap(JWT.payload)?["email"]?.stringValue
  }

  public var hostedDomain: String? {
    idToken.flatMap(JWT.payload)?["hd"]?.stringValue
  }

  var cacheFingerprint: String {
    let claims = idToken.flatMap(JWT.payload)
    let identity = claims?["sub"]?.stringValue ?? claims?["email"]?.stringValue ?? refreshToken ?? accessToken
    return SHA256.hash(data: Data("gemini-cache:\(identity)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public func state(now: Date) -> CredentialState {
    CredentialState.from(expiresAt: expiresAt, now: now)
  }

  public func refreshed(accessToken: String, expiresIn: TimeInterval, idToken: String?, now: Date) -> GeminiAuth {
    if var token = document["token"]?.objectValue {
      token["accessToken"] = .string(accessToken)
      token["expiresAt"] = .number(now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
      if let idToken { token["idToken"] = .string(idToken) }
      return GeminiAuth(document: document.merging("token", .object(token)))!
    }
    var updated = document.merging("access_token", .string(accessToken))
      .merging("expiry_date", .number(now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000))
    if let idToken { updated = updated.merging("id_token", .string(idToken)) }
    return GeminiAuth(document: updated)!
  }
}

public protocol GeminiAuthStore: Sendable {
  func load() throws -> GeminiAuth?
  func loadWithSource() throws -> (auth: GeminiAuth, source: CredentialSource)?
  func save(_ auth: GeminiAuth) throws
  var description: String { get }
  var source: CredentialSource { get }
}

extension GeminiAuthStore {
  public var source: CredentialSource {
    CredentialSource(id: "gemini.custom", provider: .gemini, title: "Gemini credentials", detail: description)
  }

  public func save(_ auth: GeminiAuth, replacing expected: GeminiAuth) throws -> CredentialSaveResult<GeminiAuth> {
    let current = try loadWithSource()
    guard current?.auth == expected else { return .changed(current?.auth, source: current?.source) }
    try save(auth)
    return .saved
  }

  public func loadWithSource() throws -> (auth: GeminiAuth, source: CredentialSource)? {
    try load().map { ($0, source) }
  }

  public func credentialHealth(now: Date) -> ProviderCredentialHealth {
    do {
      guard let found = try loadWithSource() else {
        return .missing(expected: ProviderID.gemini.setup.credentialSources)
      }
      return .from(
        found.auth.state(now: now), source: found.source, expected: ProviderID.gemini.setup.credentialSources)
    } catch {
      return .from(readError: error, fallbackSource: source)
    }
  }
}

public struct FileGeminiAuthStore: GeminiAuthStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static func defaultURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    let root = environment["GEMINI_CLI_HOME"].map { URL(fileURLWithPath: $0) } ?? home
    return root.appendingPathComponent(".gemini").appendingPathComponent("oauth_creds.json")
  }

  public var description: String {
    url.path
  }

  public var source: CredentialSource { ProviderID.gemini.credentialSource("gemini.file") }

  public func load() throws -> GeminiAuth? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("\(url.lastPathComponent) is not JSON")
    }
    return GeminiAuth(document: document)
  }

  public func save(_ auth: GeminiAuth) throws {
    try JSONEncoder().encode(auth.document).write(to: url, options: .atomic)
  }
}

public struct KeychainGeminiAuthStore: GeminiAuthStore {
  public static let service = "gemini-cli-oauth"
  public static let account = "main-account"
  private let service: String
  private let keychain: KeychainCredentialClient

  public init(service: String = Self.service, keychain: KeychainCredentialClient) {
    self.service = service
    self.keychain = keychain
  }

  public var description: String { "Keychain item \(service)" }
  public var source: CredentialSource { ProviderID.gemini.credentialSource("gemini.keychain") }

  public func load() throws -> GeminiAuth? {
    guard let item = try keychain.load(service: service, account: Self.account) else { return nil }
    return try Self.parse(item.data)
  }

  public func save(_ auth: GeminiAuth) throws {
    try keychain.save(
      try JSONEncoder().encode(Self.document(for: auth, updatedAt: Date())), service: service,
      account: Self.account)
  }

  static func parse(_ data: Data) throws -> GeminiAuth? {
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("Gemini Keychain item is not JSON")
    }
    return GeminiAuth(document: document)
  }

  static func document(for auth: GeminiAuth, updatedAt: Date) -> JSONValue {
    if auth.document["token"]?.objectValue != nil {
      var document = auth.document.merging("updatedAt", .number(updatedAt.timeIntervalSince1970 * 1000))
      if document["serverName"] == nil { document = document.merging("serverName", .string(Self.account)) }
      return document
    }
    var token: [String: JSONValue] = [
      "accessToken": .string(auth.accessToken),
      "tokenType": .string("Bearer"),
    ]
    token["refreshToken"] = auth.refreshToken.map(JSONValue.string)
    token["idToken"] = auth.idToken.map(JSONValue.string)
    token["expiresAt"] = auth.expiresAt.map { .number($0.timeIntervalSince1970 * 1000) }
    return .object([
      "serverName": .string(Self.account),
      "token": .object(token),
      "updatedAt": .number(updatedAt.timeIntervalSince1970 * 1000),
    ])
  }
}

public struct ChainedGeminiAuthStore: GeminiAuthStore {
  public let stores: [any GeminiAuthStore]

  public init(_ stores: [any GeminiAuthStore]) {
    self.stores = stores
  }

  public var description: String { stores.map(\.description).joined(separator: ", ") }

  public var source: CredentialSource {
    CredentialSource(
      id: "gemini.automatic", provider: .gemini, title: "Gemini credentials",
      detail: stores.map(\.source.title).joined(separator: ", "))
  }

  public func load() throws -> GeminiAuth? {
    try loadWithSource()?.auth
  }

  public func loadWithSource() throws -> (auth: GeminiAuth, source: CredentialSource)? {
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

  public func save(_ auth: GeminiAuth) throws {
    let target = stores.first { (try? $0.load()) != nil } ?? stores.first
    guard let target else { return }
    try target.save(auth)
  }
}

public enum GeminiCredentialStorage: Sendable, Equatable {
  case file
  case keychain

  public static func resolve(environment: [String: String]) -> GeminiCredentialStorage {
    environment["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE"] == "true" ? .keychain : .file
  }
}
