import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let validAuth = AntigravityAuth(
  accessToken: "ya29.valid", refreshToken: "1//refresh", expiresAt: fixedNow.addingTimeInterval(3600))
private let expiredAuth = AntigravityAuth(
  accessToken: "ya29.expired", refreshToken: "1//refresh", expiresAt: fixedNow.addingTimeInterval(-60))
private let testOAuth = GeminiOAuthClient(id: "client", secret: "secret")
private let localQuotaPath = "LanguageServerService/RetrieveUserQuotaSummary"
private let localStatusPath = "LanguageServerService/GetUserStatus"
private let cloudQuotaPath = ":retrieveUserQuotaSummary"
private let cloudAssistPath = ":loadCodeAssist"
private let dailyBase = "daily-cloudcode-pa.googleapis.com"

private func makeProvider(
  _ auth: AntigravityAuth?, allowRefresh: Bool = false, store: MemoryAntigravityStore? = nil,
  oauth: GeminiOAuthClient? = testOAuth, scanner: (any ProcessScanner)? = nil
) -> (AntigravityProvider, StubTransport, MemoryAntigravityStore) {
  let transport = StubTransport()
  let store = store ?? MemoryAntigravityStore(auth)
  let log = makeLog()
  log.debugEnabled = true
  let provider = AntigravityProvider(
    auth: store, client: APIClient(transport: transport, log: log, clock: testClock), log: log,
    allowRefresh: { allowRefresh }, oauthClient: { oauth }, processScanner: scanner)
  return (provider, transport, store)
}

private func snapshot(_ result: ProviderFetchResult) throws -> ProviderSnapshot {
  try #require(result.outcome.snapshot, "expected a snapshot, got \(result.outcome)")
}

private let serverScanner = StubProcessScanner(
  [antigravityServer, antigravityCLI], ports: [4242: [4321], 4343: [5353]])

@Test func antigravityRediscoversAfterTheCachedLanguageServerStopsResponding() async throws {
  let (provider, transport, _) = makeProvider(nil, scanner: serverScanner)
  var firstEndpointCalls = 0
  transport.on(
    { request in
      guard request.url?.port == 4321, request.url?.path.hasSuffix(localQuotaPath) == true else { return false }
      firstEndpointCalls += 1
      return firstEndpointCalls > 1
    }, .fail(URLError(.cannotConnectToHost)))
  transport.on(path: localQuotaPath, .json("antigravity_local_quota"))
  transport.on(path: localStatusPath, .json("antigravity_user_status"))
  _ = try snapshot(await provider.fetch(now: fixedNow, options: FetchOptions()))
  _ = try snapshot(await provider.fetch(now: fixedNow.addingTimeInterval(6), options: FetchOptions()))
  #expect(transport.requests(matching: localQuotaPath).map { $0.url?.port } == [4321, 4321, 4321, 5353])
}

@Test func antigravityPreservesNumericAbsoluteQuotas() async throws {
  let (provider, transport, _) = makeProvider(nil, scanner: serverScanner)
  transport.on(
    path: localQuotaPath,
    .text(#"{"groups":[{"buckets":[{"bucketId":"absolute","remaining":{"remainingAmount":0}}]}]}"#))
  let value = try snapshot(await provider.fetch(now: fixedNow, options: FetchOptions()))
  #expect(value.details?.first?.value == "0 remaining")
}

@Test func antigravityReadsTheLanguageServerOverHTTPSThenHTTP() async throws {
  let (provider, transport, _) = makeProvider(validAuth, scanner: serverScanner)
  transport.on({ $0.url?.scheme == "https" }, .fail(URLError(.secureConnectionFailed)))
  transport.on(path: localQuotaPath, .json("antigravity_local_quota"))
  transport.on(path: localStatusPath, .json("antigravity_user_status"))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  let snapshot = try snapshot(result)
  #expect(snapshot.windows.map(\.id) == ["gemini:session", "gemini:weekly"])
  #expect(
    snapshot.identity
      == ProviderIdentity(planName: "Google AI Ultra", tier: "google_ai_ultra", email: "you@example.com"))
  #expect(result.credentialStatus?.state == .valid(expiresAt: nil))
  let quotaRequests = transport.requests(matching: localQuotaPath)
  #expect(quotaRequests.map { $0.url!.scheme! } == ["https", "http"])
  #expect(quotaRequests.map { $0.url!.port! } == [4321, 4321])
  #expect(quotaRequests.last?.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "csrf-1")
  #expect(quotaRequests.last?.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
  #expect(quotaRequests.last?.value(forHTTPHeaderField: "Content-Type") == "application/json")
  #expect(quotaRequests.last.map { String(decoding: $0.httpBody!, as: UTF8.self) } == #"{"forceRefresh":true}"#)
  let statusRequest = try #require(transport.requests(matching: localStatusPath).first)
  #expect(statusRequest.url?.scheme == "http")
  #expect(String(decoding: statusRequest.httpBody!, as: UTF8.self).contains(#""ideName":"antigravity""#))
  #expect(transport.requests(matching: cloudQuotaPath).isEmpty)
}

@Test func antigravityMapsLocalBucketsIncludingUsedUpAndDisabledOnes() async throws {
  let (provider, transport, _) = makeProvider(validAuth, scanner: serverScanner)
  transport.on(path: localQuotaPath, .json("antigravity_local_quota"))
  transport.on(path: localStatusPath, .json("antigravity_user_status"))

  let snapshot = try snapshot(await provider.fetch(now: fixedNow, options: FetchOptions()))

  let session = try #require(snapshot.window("gemini:session"))
  #expect(abs(session.usedPercent - 25.1) < 0.001)
  #expect(session.label == "Gemini 5-hour")
  #expect(session.group == .session)
  #expect(session.duration == 18000)
  #expect(session.resetsAt == ISODate.parse("2026-08-29T22:05:10Z"))
  let weekly = try #require(snapshot.window("gemini:weekly"))
  #expect(abs(weekly.usedPercent - 4.2) < 0.001)
  #expect(weekly.group == .weekly)
  #expect(weekly.duration == 604_800)
  #expect(snapshot.window("3p:weekly") == nil)
  #expect(snapshot.window("3p:session") == nil)
  #expect(snapshot.window("legacy-daily") == nil)
  #expect(snapshot.details?.contains { $0.id == "legacy-daily" && $0.value == "12 remaining" } == true)
}

@Test func antigravityUsesTheCLIWithoutACSRFToken() async throws {
  let scanner = StubProcessScanner([antigravityCLI], ports: [4343: [5353]])
  let (provider, transport, _) = makeProvider(validAuth, scanner: scanner)
  transport.on(path: localQuotaPath, .json("antigravity_local_quota"))
  transport.on(path: localStatusPath, .text("boom", status: 500))

  let snapshot = try snapshot(await provider.fetch(now: fixedNow, options: FetchOptions()))

  let request = try #require(transport.requests(matching: localQuotaPath).first)
  #expect(request.url?.port == 5353)
  #expect(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == nil)
  #expect(snapshot.identity == ProviderIdentity(planName: "Antigravity"))
}

@Test(
  arguments: [
    (404, "not found", 4), (200, #"{"code":16,"message":"unauthenticated"}"#, 2), (200, "not json", 4),
    (200, #"{"code":13,"message":"internal"}"#, 2), (200, "{}", 2),
  ])
func antigravityFallsBackToCloudCodeWhenTheLanguageServerCannotAnswer(
  status: Int, body: String, attempts: Int
) async throws {
  let (provider, transport, _) = makeProvider(validAuth, scanner: serverScanner)
  transport.on(path: localQuotaPath, .text(body, status: status))
  transport.on(path: cloudQuotaPath, .json("antigravity_cloud_quota"))
  transport.on(path: cloudAssistPath, .json("antigravity_load_code_assist"))

  let snapshot = try snapshot(await provider.fetch(now: fixedNow, options: FetchOptions()))

  #expect(snapshot.windows.map(\.id) == ["3p:session", "gemini:session", "3p:weekly", "gemini:weekly"])
  #expect(transport.requests(matching: localQuotaPath).count == attempts)
  #expect(transport.requests(matching: localStatusPath).isEmpty)
  #expect(transport.requests(matching: cloudQuotaPath).count == 1)
}

@Test func antigravityReusesTheLastWorkingLocalEndpoint() async throws {
  let (provider, transport, _) = makeProvider(nil, scanner: serverScanner)
  transport.on(path: localQuotaPath, .json("antigravity_local_quota"))
  transport.on(path: localStatusPath, .json("antigravity_user_status"))
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  let result = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(try snapshot(result).fetchedAt == fixedNow.addingTimeInterval(60))
  #expect(transport.requests(matching: localQuotaPath).map { $0.url?.port } == [4321, 4321])
}

@Test func antigravityReadsCloudCodeAndCachesTheTier() async throws {
  let longLived = AntigravityAuth(accessToken: "ya29.valid", expiresAt: fixedNow.addingTimeInterval(86400))
  let (provider, transport, _) = makeProvider(longLived)
  transport.on(path: cloudQuotaPath, .json("antigravity_cloud_quota"))
  transport.on(path: cloudAssistPath, .json("antigravity_load_code_assist"))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  let snapshot = try snapshot(result)
  #expect(result.warnings.isEmpty)
  #expect(
    snapshot.identity == ProviderIdentity(planName: "Gemini Code Assist in Google One AI Pro", tier: "standard-tier"))
  #expect(abs(snapshot.window("3p:weekly")!.usedPercent - 70) < 0.001)
  #expect(abs(snapshot.window("gemini:session")!.usedPercent - 40) < 0.001)
  let quotaRequest = try #require(transport.requests(matching: cloudQuotaPath).first)
  #expect(quotaRequest.url?.host == dailyBase)
  #expect(quotaRequest.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.valid")
  #expect(quotaRequest.value(forHTTPHeaderField: "User-Agent") == "antigravity")
  #expect(quotaRequest.value(forHTTPHeaderField: "Accept") == "application/json")
  #expect(String(decoding: quotaRequest.httpBody!, as: UTF8.self) == "{}")
  let assistRequest = try #require(transport.requests(matching: cloudAssistPath).first)
  #expect(String(decoding: assistRequest.httpBody!, as: UTF8.self).contains(#""ideType":"ANTIGRAVITY""#))
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(transport.requests(matching: cloudAssistPath).count == 1)
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(3601), options: FetchOptions())
  #expect(transport.requests(matching: cloudAssistPath).count == 2)
}

@Test func antigravityUsesTheSecondCloudBaseAfterAServerError() async throws {
  let (provider, transport, _) = makeProvider(validAuth)
  transport.on({ $0.url?.host == dailyBase }, .respond(.text("down", status: 503)))
  transport.on(path: cloudQuotaPath, .json("antigravity_cloud_quota_free"))
  transport.on(path: cloudAssistPath, .text("boom", status: 500))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  let snapshot = try snapshot(result)
  #expect(snapshot.windows.map(\.id) == ["3p:weekly", "gemini:weekly"])
  #expect(snapshot.identity == ProviderIdentity(planName: "Antigravity"))
  #expect(result.warnings == ["Plan details unavailable: HTTP 500"])
  #expect(
    transport.requests(matching: cloudQuotaPath).map { $0.url!.host! } == [dailyBase, "cloudcode-pa.googleapis.com"])
  #expect(transport.requests(matching: cloudAssistPath).map { $0.url!.host! } == ["cloudcode-pa.googleapis.com"])
}

@Test func antigravityReportsTheLastCloudFailure() async {
  let (failing, transport, _) = makeProvider(validAuth)
  transport.on({ $0.url?.host == dailyBase }, .respond(.text("down", status: 503)))
  transport.on(path: cloudQuotaPath, .text("gone", status: 500))
  #expect(await failing.fetch(now: fixedNow, options: FetchOptions()).outcome == .failed("HTTP 500"))
  let (offline, transport2, _) = makeProvider(validAuth)
  transport2.on(path: cloudQuotaPath, error: URLError(.notConnectedToInternet))
  guard case .networkUnavailable = await offline.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected networkUnavailable")
    return
  }
}

@Test func antigravityReportsRejectedTokensWithoutRefreshing() async {
  let (provider, transport, _) = makeProvider(validAuth)
  transport.on(path: cloudQuotaPath, .text("denied", status: 401))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("HTTP 401. \(ProviderID.antigravity.loginHint)"))
  #expect(transport.requests(matching: cloudQuotaPath).count == 1)
  #expect(transport.requests(matching: "/token").isEmpty)
}

@Test func antigravityRefreshesOnceWhenCloudCodeRejectsTheToken() async throws {
  let (provider, transport, _) = makeProvider(validAuth, allowRefresh: true)
  transport.on(
    { $0.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.valid" }, .respond(.text("denied", status: 401)))
  transport.on(path: "/token", .text(#"{"access_token":"ya29.renewed","expires_in":1800}"#))
  transport.on(path: cloudQuotaPath, .json("antigravity_cloud_quota"))
  transport.on(path: cloudAssistPath, .json("antigravity_load_code_assist"))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  _ = try snapshot(result)
  #expect(result.credentialStatus?.state == .valid(expiresAt: fixedNow.addingTimeInterval(1800)))
  #expect(transport.requests(matching: cloudQuotaPath).count == 2)
  let tokenRequest = try #require(transport.requests(matching: "/token").first)
  let form = String(decoding: tokenRequest.httpBody!, as: UTF8.self)
  #expect(form.contains("client_id=client") && form.contains("refresh_token=1//refresh"))
  #expect(form.contains("grant_type=refresh_token"))
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(30), options: FetchOptions())
  #expect(transport.requests(matching: "/token").count == 1)
  #expect(
    transport.requests(matching: cloudQuotaPath).last?.value(forHTTPHeaderField: "Authorization")
      == "Bearer ya29.renewed")
}

@Test func antigravityGivesUpAfterOneRefreshAttempt() async {
  let (provider, transport, _) = makeProvider(validAuth, allowRefresh: true)
  transport.on(path: "/token", .text(#"{"access_token":"ya29.renewed","expires_in":1800}"#))
  transport.on(path: cloudQuotaPath, .text("denied", status: 401))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("HTTP 401. \(ProviderID.antigravity.loginHint)"))
  #expect(transport.requests(matching: cloudQuotaPath).count == 2)
  #expect(transport.requests(matching: "/token").count == 1)
}

@Test func antigravityReportsAFailedRefreshAfterARejectedToken() async {
  let (provider, transport, _) = makeProvider(validAuth, allowRefresh: true)
  transport.on(path: "/token", .text("unavailable", status: 503))
  transport.on(path: cloudQuotaPath, .text("denied", status: 401))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("Antigravity token refresh failed: HTTP 503"))
}

@Test func antigravityDropsTheRememberedTokenWhenAntigravityWritesANewOne() async throws {
  let store = MemoryAntigravityStore(expiredAuth)
  let (provider, transport, _) = makeProvider(nil, allowRefresh: true, store: store)
  transport.on(path: "/token", .text(#"{"access_token":"ya29.renewed"}"#))
  transport.on(path: cloudQuotaPath, .json("antigravity_cloud_quota"))
  transport.on(path: cloudAssistPath, .json("antigravity_load_code_assist"))

  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(first.credentialStatus?.state == .valid(expiresAt: fixedNow.addingTimeInterval(3600)))
  _ = try snapshot(first)
  #expect(
    transport.requests(matching: cloudQuotaPath).last?.value(forHTTPHeaderField: "Authorization")
      == "Bearer ya29.renewed")
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(10), options: FetchOptions())
  #expect(transport.requests(matching: "/token").count == 1)
  try store.write(validAuth)
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(20), options: FetchOptions())
  #expect(
    transport.requests(matching: cloudQuotaPath).last?.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.valid"
  )
  #expect(transport.requests(matching: "/token").count == 1)
}

@Test func antigravityLeavesExpiredTokensAloneUnlessRefreshIsAllowed() async {
  let (provider, transport, _) = makeProvider(expiredAuth)

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("Antigravity token expired. \(ProviderID.antigravity.loginHint)"))
  #expect(result.credentialStatus?.state == .expired(expiredAuth.expiresAt!))
  #expect(transport.requests.isEmpty)
}

@Test(
  arguments: [
    (AntigravityAuth(accessToken: "a", expiresAt: fixedNow), testOAuth, "no refresh token"),
    (expiredAuth, nil, "OAuth client could not be read"),
  ])
func antigravityExplainsWhyARefreshCannotStart(auth: AntigravityAuth, oauth: GeminiOAuthClient?, detail: String) async {
  let (provider, transport, _) = makeProvider(auth, allowRefresh: true, oauth: oauth)

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome.errorDescription?.contains(detail) == true)
  #expect(transport.requests.isEmpty)
}

@Test(
  arguments: [
    (#"{"error":"server_error","error_description":"try later"}"#, "try later"),
    (#"{"error":"server_error"}"#, "server_error"),
    ("{}", "refresh returned no access token"),
  ])
func antigravityExplainsARefreshWithoutAToken(body: String, detail: String) async {
  let (provider, transport, _) = makeProvider(expiredAuth, allowRefresh: true)
  transport.on(path: "/token", .text(body))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("Antigravity token refresh failed: \(detail)"))
}

@Test func antigravityStopsRefreshingARejectedToken() async {
  let (provider, transport, _) = makeProvider(expiredAuth, allowRefresh: true)
  transport.on(path: "/token", .text(#"{"error":"invalid_grant"}"#, status: 400))

  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  let second = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(first.outcome.errorDescription?.contains("invalid_grant") == true)
  #expect(second.outcome == first.outcome)
  #expect(transport.requests(matching: "/token").count == 1)
}

@Test func antigravityHandlesMissingAndUnreadableCredentials() async {
  let (missing, transport, store) = makeProvider(nil)
  #expect(missing.credentialDescription == "memory")
  #expect(missing.credentialState(now: fixedNow) == .missing("no Antigravity sign-in found"))
  #expect(
    await missing.credentialHealth(now: fixedNow) == .missing(expected: ProviderID.antigravity.setup.credentialSources))
  let result = await missing.fetch(now: fixedNow, options: FetchOptions())
  #expect(result.outcome == .notAuthenticated("No Antigravity credentials. \(ProviderID.antigravity.loginHint)"))
  #expect(result.credentialStatus == .missing("no Antigravity sign-in found", provider: .antigravity))
  #expect(transport.requests.isEmpty)
  store.loadError = TestError()
  #expect(missing.credentialState(now: fixedNow) == .missing("The credential source could not be read."))
  #expect(
    await missing.credentialHealth(now: fixedNow)
      == .unreadable(source: store.source, detail: "The credential source could not be read."))
  let unreadable = await missing.fetch(now: fixedNow, options: FetchOptions())
  #expect(
    unreadable.outcome
      == .notAuthenticated("Cannot read Antigravity credentials: The credential source could not be read."))
  #expect(
    unreadable.credentialStatus?.health
      == .unreadable(source: store.source, detail: "The credential source could not be read."))
}

@Test func antigravitySkipsTheLanguageServerWithoutAProcessScanner() async throws {
  let (provider, transport, _) = makeProvider(validAuth, scanner: nil)
  transport.on(path: localQuotaPath, .json("antigravity_local_quota"))
  transport.on(path: cloudQuotaPath, .json("antigravity_cloud_quota"))
  transport.on(path: cloudAssistPath, .json("antigravity_load_code_assist"))

  let snapshot = try snapshot(await provider.fetch(now: fixedNow, options: FetchOptions()))

  #expect(snapshot.identity?.tier == "standard-tier")
  #expect(transport.requests(matching: localQuotaPath).isEmpty)
  #expect(transport.requests(matching: cloudQuotaPath).count == 1)
}

@Test func antigravityIgnoresProcessesWithoutPorts() async throws {
  let (provider, transport, _) = makeProvider(validAuth, scanner: StubProcessScanner([antigravityServer]))
  transport.on(path: cloudQuotaPath, .json("antigravity_cloud_quota"))
  transport.on(path: cloudAssistPath, .json("antigravity_load_code_assist"))

  _ = try snapshot(await provider.fetch(now: fixedNow, options: FetchOptions()))

  #expect(transport.requests(matching: localQuotaPath).isEmpty)
}

@Test(
  arguments: [
    (
      #"{"userTier":{"id":"ultra","name":"Google AI Ultra"},"planStatus":{"planInfo":{"planName":"Pro"}}}"#,
      "Google AI Ultra", "ultra"
    ),
    (#"{"planStatus":{"planInfo":{"planName":"Pro"}}}"#, "Pro", nil),
    (#"{"email":"a@b"}"#, "Antigravity", nil),
  ])
func antigravityPrefersTheTierNameOverThePlanName(status: String, planName: String, tier: String?) throws {
  let decoded = try JSONDecoder().decode(AntigravityAPI.UserStatus.self, from: Data(status.utf8))
  let identity = AntigravityMapper.identity(decoded)
  #expect(identity.planName == planName)
  #expect(identity.tier == tier)
}

@Test func antigravityIdentityWithoutAnyStatusIsGeneric() {
  #expect(AntigravityMapper.identity(nil as AntigravityAPI.UserStatus?) == ProviderIdentity(planName: "Antigravity"))
  #expect(AntigravityMapper.identity(nil as AntigravityAPI.Tier?) == ProviderIdentity(planName: "Antigravity"))
}

@Test(
  arguments: [
    (#"{"response":{"groups":[{"displayName":"a"}]}}"#, ["a"]),
    (#"{"groups":[{"displayName":"b"}]}"#, ["b"]),
    (#"{"code":16}"#, []),
  ])
func antigravityQuotaSummaryAcceptsWrappedAndBareGroups(body: String, names: [String]) throws {
  let summary = try JSONDecoder().decode(AntigravityAPI.QuotaSummary.self, from: Data(body.utf8))
  #expect(summary.allGroups.map(\.displayName) == names)
}

@Test(
  arguments: [
    ("127.0.0.1", NSURLAuthenticationMethodServerTrust, true),
    ("localhost", NSURLAuthenticationMethodServerTrust, true),
    ("::1", NSURLAuthenticationMethodServerTrust, true),
    ("cloudcode-pa.googleapis.com", NSURLAuthenticationMethodServerTrust, false),
    ("127.0.0.1", NSURLAuthenticationMethodHTTPBasic, false),
  ])
func loopbackTrustCoversTheLoopbackInterfaceOnly(host: String, method: String, expected: Bool) {
  #expect(LoopbackTrust.accepts(host: host, authenticationMethod: method) == expected)
}

@Test @MainActor func antigravityProviderReportsAnUnavailableOAuthClient() async {
  let transport = StubTransport()
  let provider = AntigravityProvider(
    auth: MemoryAntigravityStore(expiredAuth),
    client: APIClient(transport: transport, log: makeLog(), clock: testClock),
    log: makeLog(), allowRefresh: { true }, oauthClient: { nil })

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.credentialStatus?.state == .expired(expiredAuth.expiresAt!))
  guard case .notAuthenticated = result.outcome else {
    Issue.record("expected a sign-in failure, got \(result.outcome)")
    return
  }
}

@Test @MainActor func antigravityCredentialStateFollowsTheStoredToken() {
  let (missing, _, _) = makeProvider(nil)
  let (signedIn, _, _) = makeProvider(validAuth)

  #expect(missing.credentialState(now: fixedNow) == .missing("no Antigravity sign-in found"))
  #expect(signedIn.credentialState(now: fixedNow) == .valid(expiresAt: validAuth.expiresAt))
}
