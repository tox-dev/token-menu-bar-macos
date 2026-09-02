import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func claudeCredentialHealthReportsMissingCredentials() {
  #expect(
    MemoryClaudeStore(nil).credentialHealth(now: fixedNow)
      == .missing(expected: ProviderID.claude.setup.credentialSources))
}

@Test func codexCredentialHealthReportsMissingCredentials() {
  #expect(
    MemoryCodexStore(nil).credentialHealth(now: fixedNow)
      == .missing(expected: ProviderID.codex.setup.credentialSources))
}

@Test func copilotCredentialHealthReportsMissingCredentials() {
  #expect(
    MemoryCopilotStore(nil).credentialHealth(now: fixedNow)
      == .missing(expected: ProviderID.copilot.setup.credentialSources))
}

@Test func cursorCredentialHealthReportsMissingCredentials() {
  #expect(
    MemoryCursorStore(nil).credentialHealth(now: fixedNow)
      == .missing(expected: ProviderID.cursor.setup.credentialSources))
}

@Test func geminiCredentialHealthReportsMissingCredentials() {
  #expect(
    MemoryGeminiStore(nil).credentialHealth(now: fixedNow)
      == .missing(expected: ProviderID.gemini.setup.credentialSources))
}

@Test func copilotKeychainStoreReturnsNilForAnUnusedService() throws {
  let store = KeychainCopilotAuthStore(service: "unused", keychain: MemoryKeychain().client)

  #expect(try store.load() == nil)
}

@Test func emptyKeychainDoesNotLoadOrPersistCredentials() throws {
  let keychain = KeychainCredentialClient.empty

  try keychain.save(Data("secret".utf8), service: "tests", account: "tester")
  #expect(try keychain.load(service: "tests", account: "tester") == nil)
}
