import Foundation

public struct AntigravityAuth: Sendable, Equatable {
  public static let keychainPrefix = "go-keyring-base64:"

  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?

  public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }

  /// Antigravity nests the token under `token`; `agy` has written the same fields at the root, in either case style.
  public init?(document: JSONValue) {
    let fields = document["token"] ?? document
    guard let accessToken = fields["access_token"]?.stringValue ?? fields["accessToken"]?.stringValue else {
      return nil
    }
    self.init(
      accessToken: accessToken,
      refreshToken: fields["refresh_token"]?.stringValue ?? fields["refreshToken"]?.stringValue,
      expiresAt: Self.expiry(fields["expiry"] ?? fields["expires_at"] ?? fields["expiresAt"]))
  }

  static func expiry(_ value: JSONValue?) -> Date? {
    if let seconds = value?.doubleValue { return Date(timeIntervalSince1970: seconds) }
    return ISODate.parse(value?.stringValue)
  }

  public static func parse(keychainValue data: Data) throws -> AntigravityAuth? {
    var text = String(decoding: data, as: UTF8.self)
    if text.hasPrefix(keychainPrefix) {
      guard
        let decoded = Data(
          base64Encoded: String(text.dropFirst(keychainPrefix.count)), options: .ignoreUnknownCharacters)
      else { throw CredentialStoreError.malformed("Antigravity Keychain item is not base64") }
      text = String(decoding: decoded, as: UTF8.self)
    }
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
      throw CredentialStoreError.malformed("Antigravity Keychain item is not JSON")
    }
    return AntigravityAuth(document: document)
  }

  public func state(now: Date) -> CredentialState {
    CredentialState.from(expiresAt: expiresAt, now: now)
  }

  public func refreshed(accessToken: String, expiresIn: TimeInterval, now: Date) -> AntigravityAuth {
    AntigravityAuth(accessToken: accessToken, refreshToken: refreshToken, expiresAt: now.addingTimeInterval(expiresIn))
  }
}

/// Antigravity owns its Keychain item, so the store only reads; a refreshed access token stays in the provider.
public protocol AntigravityAuthStore: Sendable {
  func load() throws -> AntigravityAuth?
  var description: String { get }
  var source: CredentialSource { get }
}

extension AntigravityAuthStore {
  public var source: CredentialSource {
    CredentialSource(
      id: "antigravity.custom", provider: .antigravity, title: "Antigravity credentials", detail: description)
  }

  public func credentialHealth(now: Date) -> ProviderCredentialHealth {
    let expected = ProviderID.antigravity.setup.credentialSources
    do {
      guard let auth = try load() else { return .missing(expected: expected) }
      return .from(auth.state(now: now), source: source, expected: expected)
    } catch {
      return .from(readError: error, fallbackSource: source)
    }
  }
}

public struct KeychainAntigravityAuthStore: AntigravityAuthStore {
  public static let service = "gemini"
  public static let account = "antigravity"
  private let keychain: KeychainCredentialClient

  public init(keychain: KeychainCredentialClient) {
    self.keychain = keychain
  }

  public var description: String { "Keychain item \(Self.service) (\(Self.account))" }
  public var source: CredentialSource { ProviderID.antigravity.credentialSource("antigravity.keychain") }

  public func load() throws -> AntigravityAuth? {
    guard let item = try keychain.load(service: Self.service, account: Self.account) else { return nil }
    return try AntigravityAuth.parse(keychainValue: item.data)
  }
}
