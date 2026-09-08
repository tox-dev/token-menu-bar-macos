import Foundation

/// Refreshing an Antigravity token needs the OAuth client Google ships inside Antigravity itself. Those values belong
/// to Google's app, not to this one, so they are read from the installed copy at runtime rather than vendored here.
public enum AntigravityOAuthConfig {
  public static let applications = ["Antigravity.app", "Gemini.app"]
  public static let relativePaths = [
    "Contents/Resources/bin/language_server_macos_arm",
    "Contents/Resources/app/out/main.js",
    "Contents/MacOS/Gemini",
  ]

  static let clientIDSuffix = Data(".apps.googleusercontent.com".utf8)
  static let clientSecretPrefix = Data("GOCSPX-".utf8)
  static let clientSecretLength = clientSecretPrefix.count + 28
  nonisolated(unsafe) private static let clientIDPattern = try! Regex(
    #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#)
  nonisolated(unsafe) private static let clientSecretPattern = try! Regex(#"^GOCSPX-[A-Za-z0-9_-]{28}$"#)

  public static func searchRoots(home: URL) -> [URL] {
    [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")]
  }

  public static func extract(from data: Data) -> GeminiOAuthClient? {
    guard let id = clientID(in: data), let secret = clientSecret(in: data) else { return nil }
    return GeminiOAuthClient(id: id, secret: secret)
  }

  /// The binaries are large, so the id is located by its fixed suffix and read back to the start of its token.
  static func clientID(in data: Data) -> String? {
    guard let suffix = data.range(of: clientIDSuffix) else { return nil }
    var start = suffix.lowerBound
    while start > data.startIndex, isTokenByte(data[start - 1]) { start -= 1 }
    let candidate = String(decoding: data[start..<suffix.upperBound], as: UTF8.self)
    guard let match = try? clientIDPattern.firstMatch(in: candidate) else { return nil }
    return String(candidate[match.range])
  }

  static func clientSecret(in data: Data) -> String? {
    guard let prefix = data.range(of: clientSecretPrefix) else { return nil }
    let candidate = String(decoding: data[prefix.lowerBound...].prefix(clientSecretLength), as: UTF8.self)
    guard (try? clientSecretPattern.wholeMatch(in: candidate)) != nil else { return nil }
    return candidate
  }

  private static func isTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "_"), UInt8(ascii: "-"):
      true
    default: false
    }
  }

  public static func resolve(
    environment: [String: String], home: URL, read: (URL) -> Data?
  ) -> GeminiOAuthClient? {
    if let id = environment["ANTIGRAVITY_OAUTH_CLIENT_ID"], let secret = environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]
    {
      return GeminiOAuthClient(id: id, secret: secret)
    }
    for root in searchRoots(home: home) {
      for application in applications {
        for path in relativePaths {
          let url = root.appendingPathComponent(application).appendingPathComponent(path)
          guard let data = read(url), let client = extract(from: data) else { continue }
          return client
        }
      }
    }
    return nil
  }
}
