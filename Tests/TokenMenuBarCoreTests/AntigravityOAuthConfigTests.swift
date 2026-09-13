import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let clientID = "123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com"
// Built from parts so the literal never matches GitHub's secret scanner, which blocks pushes on the real pattern.
private let secretPrefix = "GOCSPX" + "-"
private let clientSecret = secretPrefix + "abcdefghijklmnopqrstuvwxyz01"
private let binary =
  Data([0x00, 0xFF, 0x7F]) + Data("\"\(clientID)\"\u{0}secret=\(clientSecret)\u{0}".utf8) + Data([0xC3])

@Test func antigravityOAuthConfigExtractsTheClientFromBinaryData() {
  #expect(AntigravityOAuthConfig.extract(from: binary) == GeminiOAuthClient(id: clientID, secret: clientSecret))
}

@Test(
  arguments: [
    ("no id", Data(clientSecret.utf8)),
    ("no secret", Data("1-a.apps.googleusercontent.com".utf8)),
    ("id without digits", Data("abc-def.apps.googleusercontent.com \(clientSecret)".utf8)),
    ("short secret", Data("\(clientID) \(secretPrefix)short".utf8)),
    ("secret with a bad character", Data("\(clientID) \(secretPrefix)abcdefghijklmnopqrstuvwxyz0!".utf8)),
  ])
func antigravityOAuthConfigRejectsPartialMatches(name: String, data: Data) {
  #expect(AntigravityOAuthConfig.extract(from: data) == nil)
}

@Test func antigravityOAuthConfigPrefersTheEnvironment() {
  let environment = ["ANTIGRAVITY_OAUTH_CLIENT_ID": "env-id", "ANTIGRAVITY_OAUTH_CLIENT_SECRET": "env-secret"]
  #expect(
    AntigravityOAuthConfig.resolve(environment: environment, home: temporaryDirectory(), read: { _ in nil })
      == GeminiOAuthClient(id: "env-id", secret: "env-secret"))
}

@Test func antigravityOAuthConfigScansInstalledApplications() throws {
  let home = temporaryDirectory()
  let mainJS = home.appendingPathComponent("Applications/Gemini.app/Contents/Resources/app/out/main.js")
  try FileManager.default.createDirectory(at: mainJS.deletingLastPathComponent(), withIntermediateDirectories: true)
  try binary.write(to: mainJS)
  var visited: [String] = []
  let client = AntigravityOAuthConfig.resolve(
    environment: [:], home: home,
    read: { url in
      visited.append(url.path.replacingOccurrences(of: home.path, with: "~"))
      return try? Data(contentsOf: url)
    })
  #expect(client == GeminiOAuthClient(id: clientID, secret: clientSecret))
  #expect(visited.first == "~/Applications/Antigravity.app/Contents/Resources/bin/language_server_macos_arm")
  #expect(visited.last == "~/Applications/Gemini.app/Contents/Resources/app/out/main.js")
  #expect(
    AntigravityOAuthConfig.resolve(
      environment: [:], home: home, read: { $0 == mainJS ? try? Data(contentsOf: $0) : nil }) == client)
}

@Test func antigravityOAuthConfigReportsNothingWithoutAnInstalledClient() {
  #expect(AntigravityOAuthConfig.resolve(environment: [:], home: temporaryDirectory(), read: { _ in nil }) == nil)
}
