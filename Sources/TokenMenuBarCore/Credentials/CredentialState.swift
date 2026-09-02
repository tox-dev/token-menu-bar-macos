import Foundation

public enum CredentialSaveResult<Value: Sendable>: Sendable {
  case saved
  case changed(Value?, source: CredentialSource?)
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
      return ResolvedCredential(credential: current, source: current == nil ? nil : source, issue: nil)
    }
  } catch {
    let detail = credentialPersistenceDetail(error)
    pending = PendingCredentialSave(
      credential: cached.credential, replacing: cached.replacing, source: cached.source, detail: detail)
    return ResolvedCredential(
      credential: cached.credential,
      source: cached.source,
      issue: .credentialPersistence(provider: provider, detail: detail))
  }
}

func credentialPersistenceDetail(_ error: any Error) -> String {
  "The refreshed session remains active in memory. Token Menu Bar will retry saving it on the next refresh. \(error)"
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
