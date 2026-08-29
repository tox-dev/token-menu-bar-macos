import Foundation

public struct CursorAuth: Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  public let email: String?
  public let membershipType: String?

  public init(accessToken: String, refreshToken: String? = nil, email: String? = nil, membershipType: String? = nil) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.email = email
    self.membershipType = membershipType
  }

  public var userID: String? {
    guard let subject = JWT.payload(accessToken)?["sub"]?.stringValue else { return nil }
    return subject.split(separator: "|", maxSplits: 1).last.map(String.init)
  }

  public var sessionCookie: String {
    "WorkosCursorSessionToken=\(userID ?? "")%3A%3A\(accessToken)"
  }

  public func state(now: Date) -> CredentialState {
    CredentialState.from(expiresAt: JWT.expiry(accessToken), now: now)
  }
}

public protocol CursorAuthStore: Sendable {
  func load() throws -> CursorAuth?
  var description: String { get }
}

public struct CursorStateStore: CursorAuthStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
  }

  public var description: String {
    url.path
  }

  public func load() throws -> CursorAuth? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let database = try SQLiteDatabase(path: "file:\(url.path)?immutable=1", readOnly: true)
    let rows = try database.query("SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth/%'") { row in
      (row.text(0), row.text(1))
    }
    let values = Dictionary(rows, uniquingKeysWith: { $1 })
    guard let token = values["cursorAuth/accessToken"], !token.isEmpty else { return nil }
    return CursorAuth(
      accessToken: token, refreshToken: values["cursorAuth/refreshToken"], email: values["cursorAuth/cachedEmail"],
      membershipType: values["cursorAuth/stripeMembershipType"])
  }
}

public struct FileCursorAuthStore: CursorAuthStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static func defaultURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    home.appendingPathComponent(".cursor").appendingPathComponent("auth.json")
  }

  public var description: String {
    url.path
  }

  public func load() throws -> CursorAuth? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw CredentialStoreError.malformed("\(url.lastPathComponent) is not JSON")
    }
    guard let token = document["accessToken"]?.stringValue else { return nil }
    return CursorAuth(accessToken: token, refreshToken: document["refreshToken"]?.stringValue)
  }
}

public struct ChainedCursorAuthStore: CursorAuthStore {
  public let stores: [any CursorAuthStore]

  public init(_ stores: [any CursorAuthStore]) {
    self.stores = stores
  }

  public var description: String {
    stores.map(\.description).joined(separator: ", ")
  }

  public func load() throws -> CursorAuth? {
    var firstError: (any Error)?
    for store in stores {
      do {
        if let auth = try store.load() { return auth }
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError { throw firstError }
    return nil
  }
}
