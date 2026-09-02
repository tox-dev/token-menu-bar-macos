import Foundation

public struct CopilotAuth: Sendable, Equatable {
  public let token: String
  public let user: String?
  public let host: String

  public init(token: String, user: String? = nil, host: String = "github.com") {
    self.token = token
    self.user = user
    self.host = Self.normalizedHost(host) ?? ""
  }

  static func normalizedHost(_ value: String) -> String? {
    var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://"] where host.lowercased().hasPrefix(prefix) {
      host.removeFirst(prefix.count)
      break
    }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !host.isEmpty, !host.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0.isWhitespace })
    else { return nil }
    let punctuation = CharacterSet(charactersIn: ".-")
    guard host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || punctuation.contains($0) })
    else { return nil }
    return host.lowercased()
  }

  public func state(now: Date) -> CredentialState {
    .valid(expiresAt: nil)
  }
}

public protocol CopilotAuthStore: Sendable {
  func load() throws -> CopilotAuth?
  func loadWithSource() throws -> (auth: CopilotAuth, source: CredentialSource)?
  var description: String { get }
  var source: CredentialSource { get }
}

extension CopilotAuthStore {
  public var source: CredentialSource {
    CredentialSource(id: "copilot.custom", provider: .copilot, title: "GitHub Copilot credentials", detail: description)
  }

  public func loadWithSource() throws -> (auth: CopilotAuth, source: CredentialSource)? {
    try load().map { ($0, source) }
  }

  public func credentialHealth(now: Date) -> ProviderCredentialHealth {
    do {
      guard let found = try loadWithSource() else {
        return .missing(expected: ProviderID.copilot.setup.credentialSources)
      }
      return .from(
        found.auth.state(now: now), source: found.source, expected: ProviderID.copilot.setup.credentialSources)
    } catch {
      return .from(readError: error, fallbackSource: source)
    }
  }
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

  public var source: CredentialSource { ProviderID.copilot.credentialSource("copilot.legacy-file") }

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

public struct EnvironmentCopilotAuthStore: CopilotAuthStore {
  public let environment: [String: String]

  public init(environment: [String: String]) {
    self.environment = environment
  }

  public var description: String { "COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN" }
  public var source: CredentialSource { ProviderID.copilot.credentialSource("copilot.environment") }

  public func load() throws -> CopilotAuth? {
    for key in ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] {
      if let token = environment[key], !token.isEmpty {
        return CopilotAuth(token: token, host: environment["GH_HOST"] ?? "github.com")
      }
    }
    return nil
  }
}

public struct FileCopilotCLIAuthStore: CopilotAuthStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public var description: String { url.path }
  public var source: CredentialSource { ProviderID.copilot.credentialSource("copilot.file") }

  public func load() throws -> CopilotAuth? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("\(url.lastPathComponent) is not JSON")
    }
    return Self.accounts(document).compactMap { account in
      account.token.map { CopilotAuth(token: $0, user: account.user, host: account.host) }
    }.first
  }

  public func keychainAccounts() -> [String] {
    guard let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return [] }
    return Self.accounts(document).map(\.account).uniqued()
  }

  static func accounts(_ document: JSONValue) -> [CopilotCLIAccount] {
    guard let users = document["loggedInUsers"] else { return [] }
    if let entries = users.objectValue {
      return entries.keys.sorted().compactMap { account(key: $0, value: entries[$0]!) }
    }
    return users.arrayValue?.compactMap { account(key: nil, value: $0) } ?? []
  }

  private static func account(key: String?, value: JSONValue) -> CopilotCLIAccount? {
    let values = value.objectValue
    let user =
      values?["user"]?.stringValue ?? values?["login"]?.stringValue ?? values?["username"]?.stringValue
      ?? value.stringValue
    let hostValue = values?["host"]?.stringValue ?? values?["url"]?.stringValue ?? key ?? "github.com"
    let host = hostValue.replacingOccurrences(of: "https://", with: "").trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
    let account =
      values?["keychainAccount"]?.stringValue
      ?? user.map { "https://\(host):\($0)" }
      ?? key
    guard let account else { return nil }
    let token =
      values?["token"]?.stringValue ?? values?["oauthToken"]?.stringValue ?? values?["oauth_token"]?.stringValue
    return CopilotCLIAccount(account: account, token: token, user: user, host: host)
  }
}

struct CopilotCLIAccount {
  let account: String
  let token: String?
  let user: String?
  let host: String
}

public struct KeychainCopilotAuthStore: CopilotAuthStore {
  public static let service = "copilot-cli"
  public let accounts: [String]
  private let service: String
  private let keychain: KeychainCredentialClient

  public init(
    service: String = Self.service,
    accounts: [String] = [],
    keychain: KeychainCredentialClient
  ) {
    self.service = service
    self.accounts = accounts
    self.keychain = keychain
  }

  public var description: String { "Keychain item \(service)" }
  public var source: CredentialSource { ProviderID.copilot.credentialSource("copilot.keychain") }

  public func load() throws -> CopilotAuth? {
    var firstError: CredentialReadFailure?
    for account in accounts.map(Optional.some) + [nil] {
      do {
        guard let item = try keychain.load(service: service, account: account) else { continue }
        if let auth = try Self.parse(item.data, account: item.account) { return auth }
      } catch {
        firstError = firstError ?? CredentialReadFailure(source: source, error: error)
      }
    }
    if let firstError { throw firstError }
    return nil
  }

  static func parse(_ data: Data, account: String?) throws -> CopilotAuth? {
    let accountIdentity = identity(account)
    if let document = try? JSONDecoder().decode(JSONValue.self, from: data) {
      let token =
        document["token"]?.stringValue ?? document["access_token"]?.stringValue
        ?? document["oauth_token"]?.stringValue
      guard let token, !token.isEmpty else { return nil }
      return CopilotAuth(
        token: token,
        user: document["user"]?.stringValue ?? document["login"]?.stringValue ?? accountIdentity.user,
        host: document["host"]?.stringValue ?? accountIdentity.host ?? "github.com")
    }
    guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else { throw CredentialStoreError.malformed("GitHub Copilot Keychain item is not a token") }
    return CopilotAuth(token: token, user: accountIdentity.user, host: accountIdentity.host ?? "github.com")
  }

  private static func identity(_ account: String?) -> (host: String?, user: String?) {
    guard var value = account?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return (nil, nil)
    }
    let lowercase = value.lowercased()
    let hadScheme = lowercase.hasPrefix("https://") || lowercase.hasPrefix("http://")
    if lowercase.hasPrefix("https://") {
      value.removeFirst(8)
    } else if lowercase.hasPrefix("http://") {
      value.removeFirst(7)
    }
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let separator = value.lastIndex(of: ":") else {
      return (nil, hadScheme ? nil : value)
    }
    let host = String(value[..<separator])
    let user = String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let normalized = CopilotAuth.normalizedHost(host), !user.isEmpty else {
      return (nil, hadScheme ? nil : account)
    }
    return (normalized, user)
  }
}

public struct ChainedCopilotAuthStore: CopilotAuthStore {
  public let stores: [any CopilotAuthStore]

  public init(_ stores: [any CopilotAuthStore]) {
    self.stores = stores
  }

  public var description: String { stores.map(\.description).joined(separator: ", ") }

  public var source: CredentialSource {
    CredentialSource(
      id: "copilot.automatic", provider: .copilot, title: "GitHub Copilot credentials",
      detail: stores.map(\.source.title).joined(separator: ", "))
  }

  public func load() throws -> CopilotAuth? {
    try loadWithSource()?.auth
  }

  public func loadWithSource() throws -> (auth: CopilotAuth, source: CredentialSource)? {
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
}

public enum CopilotCredentialStorage: Sendable, Equatable {
  case environment
  case cliKeychain
  case cliFile
  case legacyFile
  case missing
}

public enum CopilotCredentialStorageReader {
  public static func detect(
    environmentTokenExists: Bool,
    keychainItemExists: Bool,
    cliFileExists: Bool,
    legacyFileExists: Bool
  ) -> CopilotCredentialStorage {
    if environmentTokenExists { return .environment }
    if keychainItemExists { return .cliKeychain }
    if cliFileExists { return .cliFile }
    return legacyFileExists ? .legacyFile : .missing
  }

  public static func detect(keychainItemExists: Bool, legacyFileExists: Bool) -> CopilotCredentialStorage {
    detect(
      environmentTokenExists: false,
      keychainItemExists: keychainItemExists,
      cliFileExists: false,
      legacyFileExists: legacyFileExists)
  }
}
