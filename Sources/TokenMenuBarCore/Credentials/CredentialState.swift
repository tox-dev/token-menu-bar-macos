import Foundation

public enum CredentialSaveResult<Value: Sendable>: Sendable {
  case saved
  case changed(Value, source: CredentialSource)
  case removed
}

struct PendingCredentialSave<Value: Sendable & Equatable>: Sendable {
  let credential: Value
  let replacing: Value
  let source: CredentialSource
  let detail: String
}

struct ResolvedCredential<Value: Sendable>: Sendable {
  let credential: Value?
  let source: CredentialSource?
  let issue: ProviderRecoveryIssue?
}

func resolveCredential<Value: Sendable & Equatable>(
  pending: inout PendingCredentialSave<Value>?,
  provider: ProviderID,
  load: () throws -> (credential: Value, source: CredentialSource)?,
  save: (Value, Value) throws -> CredentialSaveResult<Value>
) throws -> ResolvedCredential<Value> {
  let loaded: (credential: Value, source: CredentialSource)?
  do {
    loaded = try load()
  } catch {
    guard let pending else { throw error }
    return ResolvedCredential(
      credential: pending.credential,
      source: pending.source,
      issue: .credentialPersistence(provider: provider, detail: pending.detail))
  }
  guard let cached = pending else {
    return ResolvedCredential(credential: loaded?.credential, source: loaded?.source, issue: nil)
  }
  if loaded?.credential == cached.credential {
    pending = nil
    return ResolvedCredential(credential: loaded?.credential, source: loaded?.source, issue: nil)
  }
  guard loaded?.credential == cached.replacing else {
    pending = nil
    return ResolvedCredential(credential: loaded?.credential, source: loaded?.source, issue: nil)
  }
  do {
    switch try save(cached.credential, cached.replacing) {
    case .saved:
      pending = nil
      return ResolvedCredential(credential: cached.credential, source: cached.source, issue: nil)
    case .changed(let current, let source):
      pending = nil
      return ResolvedCredential(credential: current, source: source, issue: nil)
    case .removed:
      pending = nil
      return ResolvedCredential(credential: nil, source: nil, issue: nil)
    }
  } catch {
    let detail = credentialPersistenceDetail()
    pending = PendingCredentialSave(
      credential: cached.credential, replacing: cached.replacing, source: cached.source, detail: detail)
    return ResolvedCredential(
      credential: cached.credential,
      source: cached.source,
      issue: .credentialPersistence(provider: provider, detail: detail))
  }
}

func credentialPersistenceDetail() -> String {
  "The refreshed session remains active in memory. Token Menu Bar will retry saving it on the next refresh."
}

enum CredentialRefreshError: Error {
  case api(APIError)
  case missingRefreshToken
  case credentialsRemoved
  case oauthClientUnavailable
  case invalidResponse(String)
  case signInRequired(code: String)

  var message: String {
    switch self {
    case .api(let error): error.message
    case .missingRefreshToken: "the credential has no refresh token"
    case .credentialsRemoved: "the credentials were removed during refresh"
    case .oauthClientUnavailable: "the OAuth client could not be read from the installed Google client"
    case .invalidResponse(let detail): detail
    case .signInRequired(let code): "the provider rejected the stored sign-in (\(code)). Sign in with the CLI again."
    }
  }
}

let terminalRefreshErrorCodes: Set<String> = [
  "invalid_grant", "invalid_client", "unauthorized_client", "refresh_token_expired", "refresh_token_reused",
  "refresh_token_invalidated",
]

// A rejected refresh token stays rejected, so the token endpoint is left alone until the CLI writes a new credential.
struct RefreshRejection<Value: Sendable & Equatable>: Sendable {
  private var rejected: (credential: Value, code: String)?

  func check(_ stored: Value) throws(CredentialRefreshError) {
    guard let rejected, rejected.credential == stored else { return }
    throw .signInRequired(code: rejected.code)
  }

  mutating func failure(_ error: APIError, refreshing stored: Value) -> CredentialRefreshError {
    guard case .http(let status, let body, _) = error, (400..<500).contains(status),
      let code = (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)))?["error"]?.stringValue,
      terminalRefreshErrorCodes.contains(code)
    else { return .api(error) }
    rejected = (stored, code)
    return .signInRequired(code: code)
  }
}

func persistRefreshedCredential<Value: Sendable & Equatable>(
  _ credential: Value,
  replacing previous: Value,
  source: CredentialSource,
  provider: ProviderID,
  pending: inout PendingCredentialSave<Value>?,
  log: LogBuffer,
  save: (Value, Value) throws -> CredentialSaveResult<Value>
) throws(CredentialRefreshError) -> (
  credential: Value,
  source: CredentialSource,
  issue: ProviderRecoveryIssue?
) {
  let result: CredentialSaveResult<Value>
  do {
    result = try save(credential, previous)
  } catch {
    log.logError("\(provider.rawValue) token refreshed but could not be stored: \(error)")
    let detail = credentialPersistenceDetail()
    pending = PendingCredentialSave(
      credential: credential, replacing: previous, source: source, detail: detail)
    return (credential, source, .credentialPersistence(provider: provider, detail: detail))
  }
  switch result {
  case .saved:
    log.log("\(provider.rawValue) token refreshed and stored")
    return (credential, source, nil)
  case .changed(let current, let currentSource):
    log.log("\(provider.rawValue) token refresh not stored because the credential source changed")
    return (current, currentSource, nil)
  case .removed:
    log.log("\(provider.rawValue) token refresh not stored because the credentials were removed")
    throw .credentialsRemoved
  }
}

public enum CredentialState: Sendable, Equatable {
  case missing(String)
  case expired(Date)
  case valid(expiresAt: Date?)

  public static let expiryBuffer: TimeInterval = 120

  public static func from(expiresAt: Date?, now: Date) -> CredentialState {
    if let expiresAt, expiresAt.timeIntervalSince(now) < expiryBuffer { return .expired(expiresAt) }
    return .valid(expiresAt: expiresAt)
  }

  public var isMissing: Bool {
    if case .missing = self { return true }
    return false
  }

  public var isUsable: Bool {
    if case .valid = self { return true }
    return false
  }

  public var description: String {
    switch self {
    case .missing(let reason): "No credentials: \(reason)"
    case .expired(let date): "Token expired \(date.formatted(.relative(presentation: .named)))"
    case .valid(let date):
      date.map { "Token valid until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Token present"
    }
  }
}

public enum JWT {
  public static func payload(_ token: String) -> JSONValue? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { return nil }
    var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  public static func expiry(_ token: String) -> Date? {
    payload(token)?["exp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
  }
}
