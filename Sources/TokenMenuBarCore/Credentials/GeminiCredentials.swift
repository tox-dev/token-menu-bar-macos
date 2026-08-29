import Foundation

public struct GeminiAuth: Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  public let idToken: String?
  public let expiresAt: Date?
  public let document: JSONValue

  public init?(document: JSONValue) {
    guard let accessToken = document["access_token"]?.stringValue else { return nil }
    self.document = document
    self.accessToken = accessToken
    refreshToken = document["refresh_token"]?.stringValue
    idToken = document["id_token"]?.stringValue
    expiresAt = document["expiry_date"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
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

  public func state(now: Date) -> CredentialState {
    CredentialState.from(expiresAt: expiresAt, now: now)
  }

  public func refreshed(accessToken: String, expiresIn: TimeInterval, idToken: String?, now: Date) -> GeminiAuth {
    var updated = document.merging("access_token", .string(accessToken))
      .merging("expiry_date", .number(now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000))
    if let idToken { updated = updated.merging("id_token", .string(idToken)) }
    return GeminiAuth(document: updated)!
  }
}

public protocol GeminiAuthStore: Sendable {
  func load() throws -> GeminiAuth?
  func save(_ auth: GeminiAuth) throws
  var description: String { get }
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
