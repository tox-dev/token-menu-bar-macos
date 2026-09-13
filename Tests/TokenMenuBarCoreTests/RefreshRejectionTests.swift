import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

struct TerminalRefreshCase: Sendable, CustomTestStringConvertible {
  let provider: ProviderID
  let code: String
  let tokenPath: String
  let make: @Sendable (StubTransport) -> (provider: any UsageProvider, signInAgain: @Sendable () throws -> Void)

  var testDescription: String { "\(provider.rawValue) \(code)" }
}

private let expiredAt = fixedNow.addingTimeInterval(-10)

let terminalRefreshCases = [
  TerminalRefreshCase(provider: .claude, code: "invalid_grant", tokenPath: "/v1/oauth/token") { transport in
    let store = MemoryClaudeStore(ClaudeOAuthCredentials(accessToken: "old", refreshToken: "ref", expiresAt: expiredAt))
    return (
      claudeProvider(store, transport: transport, allowRefresh: true),
      { try store.write(ClaudeOAuthCredentials(accessToken: "old", refreshToken: "ref-2", expiresAt: expiredAt)) }
    )
  },
  TerminalRefreshCase(provider: .codex, code: "refresh_token_reused", tokenPath: "/oauth/token") { transport in
    let token = makeJWT(.object(["exp": .number(expiredAt.timeIntervalSince1970)]))
    let store = MemoryCodexStore(CodexAuth(accessToken: token, refreshToken: "ref"))
    return (
      codexProvider(store, transport: transport, allowRefresh: true),
      { try store.write(CodexAuth(accessToken: token, refreshToken: "ref-2")) }
    )
  },
  TerminalRefreshCase(provider: .gemini, code: "invalid_grant", tokenPath: "/token") { transport in
    let store = MemoryGeminiStore(GeminiAuth(accessToken: "old", refreshToken: "ref", expiresAt: expiredAt))
    let provider = GeminiProvider(
      auth: store, client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
      allowRefresh: { true }, oauthClient: { GeminiOAuthClient(id: "client", secret: "secret") })
    return (provider, { try store.write(GeminiAuth(accessToken: "old", refreshToken: "ref-2", expiresAt: expiredAt)) })
  },
]

@Test(arguments: terminalRefreshCases)
func refreshStopsAfterATerminalRejectionUntilTheCredentialChanges(testCase: TerminalRefreshCase) async throws {
  let transport = StubTransport()
  transport.on(path: testCase.tokenPath, .text(#"{"error":"\#(testCase.code)"}"#, status: 400))
  let (provider, signInAgain) = testCase.make(transport)

  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  let second = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())

  #expect(
    first.outcome
      == .notAuthenticated(
        "\(testCase.provider.displayName) token refresh failed: the provider rejected the stored sign-in "
          + "(\(testCase.code)). Sign in with the CLI again."))
  #expect(second.outcome == first.outcome)
  #expect(transport.requests(matching: testCase.tokenPath).count == 1)

  try signInAgain()
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(120), options: FetchOptions())

  #expect(transport.requests(matching: testCase.tokenPath).count == 2)
}

@Test(arguments: [
  (status: 400, body: #"{"error":"temporarily_unavailable"}"#),
  (status: 400, body: "not json"),
  (status: 500, body: #"{"error":"invalid_grant"}"#),
])
func refreshRetriesAfterANonTerminalRejection(response: (status: Int, body: String)) async {
  let transport = StubTransport()
  transport.on(path: "/oauth/token", .text(response.body, status: response.status))
  let token = makeJWT(.object(["exp": .number(expiredAt.timeIntervalSince1970)]))
  let provider = codexProvider(
    MemoryCodexStore(CodexAuth(accessToken: token, refreshToken: "ref")), transport: transport, allowRefresh: true)

  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())

  #expect(first.outcome == .notAuthenticated("Codex token refresh failed: HTTP \(response.status)"))
  #expect(transport.requests(matching: "/oauth/token").count == 2)
}
