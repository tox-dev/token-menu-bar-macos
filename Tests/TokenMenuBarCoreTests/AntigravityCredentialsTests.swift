import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let expiry = Date(timeIntervalSince1970: 1_788_033_600)

func antigravityKeychainValue(_ document: JSONValue, prefixed: Bool = true) -> Data {
  let json = try! JSONEncoder().encode(document)
  return prefixed ? Data((AntigravityAuth.keychainPrefix + json.base64EncodedString()).utf8) : json
}

@Test(
  arguments: [
    ("nested, prefixed", Fixtures.json("antigravity_keychain_token"), true, "1//0g-antigravity"),
    (
      "root snake case, bare",
      JSONValue.object([
        "access_token": .string("ya29.antigravity"), "refresh_token": .string("1//root"),
        "expires_at": .string("2026-08-29T20:00:00Z"),
      ]), false, "1//root"
    ),
    (
      "root camel case with epoch seconds",
      .object([
        "accessToken": .string("ya29.antigravity"), "refreshToken": .string("1//camel"),
        "expiresAt": .number(1_788_033_600),
      ]), true, "1//camel"
    ),
    (
      "nested camel case with expiry",
      .object([
        "token": .object([
          "accessToken": .string("ya29.antigravity"), "refreshToken": .string("1//nested"),
          "expiry": .string("2026-08-29T20:00:00.5Z"),
        ])
      ]), true, "1//nested"
    ),
  ])
func antigravityAuthDecodesEveryKeychainLayout(
  name: String, document: JSONValue, prefixed: Bool, refreshToken: String
) throws {
  let auth = try #require(
    try AntigravityAuth.parse(keychainValue: antigravityKeychainValue(document, prefixed: prefixed)))
  #expect(auth.accessToken == "ya29.antigravity")
  #expect(auth.refreshToken == refreshToken)
  #expect(auth.expiresAt.map { abs($0.timeIntervalSince(expiry)) < 1 } == true)
}

@Test func antigravityAuthRejectsDocumentsWithoutAnAccessToken() throws {
  #expect(try AntigravityAuth.parse(keychainValue: antigravityKeychainValue(.object(["token": .object([:])]))) == nil)
  #expect(AntigravityAuth(document: .object(["refresh_token": .string("r")])) == nil)
}

@Test(
  arguments: [
    ("go-keyring-base64:a", "base64"), ("go-keyring-base64:bm90IGpzb24=", "JSON"), ("plain text", "JSON"),
  ])
func antigravityAuthReportsMalformedItems(value: String, detail: String) {
  #expect(throws: CredentialStoreError.malformed("Antigravity Keychain item is not \(detail)")) {
    try AntigravityAuth.parse(keychainValue: Data(value.utf8))
  }
}

@Test func antigravityAuthTracksExpiryAndRefresh() {
  let auth = AntigravityAuth(accessToken: "a", refreshToken: "r", expiresAt: expiry)
  #expect(auth.state(now: fixedNow) == .valid(expiresAt: expiry))
  #expect(auth.state(now: expiry) == .expired(expiry))
  #expect(AntigravityAuth(accessToken: "a").state(now: fixedNow) == .valid(expiresAt: nil))
  let refreshed = auth.refreshed(accessToken: "b", expiresIn: 60, now: fixedNow)
  #expect(refreshed == AntigravityAuth(accessToken: "b", refreshToken: "r", expiresAt: fixedNow.addingTimeInterval(60)))
}

@Test func antigravityKeychainStoreReadsTheItemAntigravityWrites() throws {
  let keychain = MemoryKeychain()
  let store = KeychainAntigravityAuthStore(keychain: keychain.client)
  #expect(store.description == "Keychain item gemini (antigravity)")
  #expect(store.source.id == "antigravity.keychain")
  #expect(store.source.provider == .antigravity)
  #expect(try store.load() == nil)
  #expect(store.credentialHealth(now: fixedNow) == .missing(expected: ProviderID.antigravity.setup.credentialSources))
  try keychain.client.save(
    antigravityKeychainValue(Fixtures.json("antigravity_keychain_token")), service: "gemini", account: "antigravity")
  let auth = try #require(try store.load())
  #expect(auth.accessToken == "ya29.antigravity")
  #expect(store.credentialHealth(now: fixedNow) == .valid(source: store.source, expiresAt: auth.expiresAt))
  try keychain.client.save(Data("nope".utf8), service: "gemini", account: "antigravity")
  #expect(
    store.credentialHealth(now: fixedNow)
      == .unreadable(source: store.source, detail: "Antigravity Keychain item is not JSON"))
}

@Test func antigravitySetupDescribesTheKeychainSource() {
  let setup = ProviderID.antigravity.setup
  #expect(setup.signInCommand == "agy")
  #expect(setup.credentialSources.map(\.id) == ["antigravity.keychain"])
  #expect(ProviderID.antigravity.sandboxResources.isEmpty)
  #expect(ProviderID.antigravity.shortLabel == "AG")
  #expect(ProviderID.antigravity.loginHint.contains("agy"))
  #expect(ProviderID.allCases.firstIndex(of: .antigravity) == ProviderID.allCases.firstIndex(of: .gemini)! + 1)
  #expect(PollingPolicy.defaults(for: .antigravity) == PollingPolicy.defaults(for: .gemini))
}
