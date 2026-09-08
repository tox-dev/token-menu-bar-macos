import Foundation
import Security
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private func claudeChain(keychain: KeychainCredentialClient, fileToken: String?) throws -> ChainedClaudeCredentialStore
{
  let file = FileClaudeCredentialStore(url: temporaryDirectory().appendingPathComponent(".credentials.json"))
  if let fileToken {
    try file.save(ClaudeOAuthCredentials(accessToken: fileToken, refreshToken: nil, expiresAt: fixedNow + 3600))
  }
  return ChainedClaudeCredentialStore([DiscoveredClaudeKeychainStore(account: "me", keychain: keychain), file])
}

@Test func claudeKeychainMissWithAValidFileYieldsTheFileCredential() throws {
  let chain = try claudeChain(keychain: MemoryKeychain().client, fileToken: "file")

  let found = try #require(try chain.loadWithSource())

  #expect(found.credentials.accessToken == "file")
  #expect(found.source.id == "claude.file")
  #expect(
    chain.credentialHealth(now: fixedNow)
      == .valid(source: ProviderID.claude.credentialSource("claude.file"), expiresAt: fixedNow + 3600))
}

@Test func claudeDeniedKeychainWithAValidFileYieldsTheFileCredential() throws {
  let denied = KeychainCredentialClient(
    load: { _, _ in throw CredentialStoreError.keychain(errSecAuthFailed) }, save: { _, _, _ in })
  let chain = try claudeChain(keychain: denied, fileToken: "file")

  #expect(try chain.loadWithSource()?.source.id == "claude.file")
}

@Test func claudeReportsMissingOnlyWhenEverySourceIsEmpty() throws {
  let chain = try claudeChain(keychain: MemoryKeychain().client, fileToken: nil)

  #expect(try chain.loadWithSource() == nil)
  #expect(chain.credentialHealth(now: fixedNow) == .missing(expected: ProviderID.claude.setup.credentialSources))
}

@Test func codexKeychainMissWithAValidAuthFileYieldsTheFileCredential() throws {
  let home = temporaryDirectory()
  try Data(#"cli_auth_credentials_store = "auto""#.utf8).write(to: home.appendingPathComponent("config.toml"))
  try FileCodexAuthStore(url: home.appendingPathComponent("auth.json")).save(CodexAuth(accessToken: "file"))
  let store = CodexAuthStores.store(codexHome: home, keychain: MemoryKeychain().client)

  let found = try #require(try store.loadWithSource())

  #expect(found.auth.accessToken == "file")
  #expect(found.source.id == "codex.file")
  #expect(
    store.credentialHealth(now: fixedNow)
      == .valid(source: ProviderID.codex.credentialSource("codex.file"), expiresAt: nil))
}

@Test func codexReportsMissingOnlyWhenEverySourceIsEmpty() {
  let store = CodexAuthStores.store(codexHome: temporaryDirectory(), keychain: MemoryKeychain().client)

  #expect(store.credentialHealth(now: fixedNow) == .missing(expected: ProviderID.codex.setup.credentialSources))
}
