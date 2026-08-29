import Foundation

public enum CredentialState: Sendable, Equatable {
  case missing(String)
  case expired(Date)
  case valid(expiresAt: Date?)

  public static let expiryBuffer: TimeInterval = 120

  public static func from(expiresAt: Date?, now: Date) -> CredentialState {
    if let expiresAt, expiresAt.timeIntervalSince(now) < expiryBuffer { return .expired(expiresAt) }
    return .valid(expiresAt: expiresAt)
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
