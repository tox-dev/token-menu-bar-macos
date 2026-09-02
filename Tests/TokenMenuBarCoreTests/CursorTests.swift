import Foundation
import Testing
import TokenMenuBarCore

@Test func cursorAuthDerivesUserAndCookie() {
  #expect(validCursor.userID == "user_01ABC")
  #expect(validCursor.sessionCookie == "WorkosCursorSessionToken=user_01ABC%3A%3A\(validCursor.accessToken)")
  #expect(validCursor.state(now: fixedNow) == .valid(expiresAt: Date(timeIntervalSince1970: 1_900_000_000)))
  let opaque = CursorAuth(accessToken: "opaque")
  #expect(opaque.userID == nil)
  #expect(opaque.sessionCookie == "WorkosCursorSessionToken=%3A%3Aopaque")
  #expect(opaque.state(now: fixedNow) == .valid(expiresAt: nil))
  #expect(CursorAuth(accessToken: cursorJWT(exp: 1)).state(now: fixedNow).isUsable == false)
}

private func cursorJWT(subject: String = "auth0|user_01ABC", exp: Double = 1_900_000_000) -> String {
  let payload = try! JSONEncoder().encode(JSONValue.object(["sub": .string(subject), "exp": .number(exp)]))
    .base64EncodedString().replacingOccurrences(of: "=", with: "")
  return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
}

private let validCursor = CursorAuth(accessToken: cursorJWT(), email: "cached@example.com", membershipType: "pro")

@Test func cursorStateStoreReadsTheAppDatabase() throws {
  let root = temporaryDirectory()
  let url = root.appendingPathComponent("state.vscdb")
  let database = try SQLiteDatabase(path: url.path)
  try database.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
  let store = CursorStateStore(url: url)
  #expect(try store.load() == nil)
  for (key, value) in [
    ("cursorAuth/accessToken", validCursor.accessToken), ("cursorAuth/refreshToken", "refresh"),
    ("cursorAuth/cachedEmail", "cached@example.com"), ("cursorAuth/stripeMembershipType", "pro"),
    ("storage.serviceMachineId", "m"),
  ] {
    try database.execute("INSERT INTO ItemTable (key, value) VALUES (?, ?)", [.text(key), .text(value)])
  }
  let loaded = try store.load()
  #expect(loaded?.accessToken == validCursor.accessToken)
  #expect(loaded?.refreshToken == "refresh")
  #expect(loaded?.email == "cached@example.com")
  #expect(loaded?.membershipType == "pro")
  #expect(store.description == url.path)
  #expect(CursorStateStore.defaultURL(home: root).path.hasSuffix("Cursor/User/globalStorage/state.vscdb"))
  #expect(try CursorStateStore(url: root.appendingPathComponent("missing.vscdb")).load() == nil)
  try Data("not a database".utf8).write(to: root.appendingPathComponent("broken.vscdb"))
  #expect(throws: (any Error).self) { try CursorStateStore(url: root.appendingPathComponent("broken.vscdb")).load() }
}

@Test func cursorStateStoreReadsCredentialsFromTheLiveWAL() throws {
  let directory = temporaryDirectory().appendingPathComponent("Application Support")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("state.vscdb")
  let writer = try SQLiteDatabase(path: url.path)
  try writer.execute("PRAGMA journal_mode = WAL")
  try writer.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
  try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
  try writer.execute("PRAGMA wal_autocheckpoint = 0")
  try writer.execute(
    "INSERT INTO ItemTable (key, value) VALUES (?, ?)",
    [.text("cursorAuth/accessToken"), .text(validCursor.accessToken)])

  #expect(FileManager.default.fileExists(atPath: "\(url.path)-wal"))
  let loaded = try withExtendedLifetime(writer) { try CursorStateStore(url: url).load() }
  #expect(loaded?.accessToken == validCursor.accessToken)
}

@Test func cursorFileStoreAndChainFallThrough() throws {
  let root = temporaryDirectory()
  let url = root.appendingPathComponent("auth.json")
  let store = FileCursorAuthStore(url: url)
  #expect(store.description == url.path)
  #expect(try store.load() == nil)
  try Data(#"{"accessToken":"\#(validCursor.accessToken)","refreshToken":"r"}"#.utf8).write(to: url)
  #expect(try store.load()?.refreshToken == "r")
  try Data(#"{"other":1}"#.utf8).write(to: url)
  #expect(try store.load() == nil)
  try Data("nope".utf8).write(to: url)
  #expect(throws: CredentialStoreError.self) { try store.load() }
  #expect(FileCursorAuthStore.defaultURL(environment: [:], home: root).path == root.path + "/.cursor/auth.json")
  let failing = MemoryCursorStore(nil)
  failing.loadError = TestError()
  let chain = ChainedCursorAuthStore([failing, MemoryCursorStore(validCursor)])
  #expect(chain.description == "memory, memory")
  #expect(try chain.load() == validCursor)
  #expect(throws: CredentialReadFailure.self) { try ChainedCursorAuthStore([failing, MemoryCursorStore(nil)]).load() }
  #expect(try ChainedCursorAuthStore([MemoryCursorStore(nil)]).load() == nil)
}

@MainActor
private func cursorSnapshot(
  summary: StubTransport.Response, me: StubTransport.Response = .json("cursor_me"),
  period: StubTransport.Response? = nil, auth: CursorAuth = validCursor
) async -> ProviderSnapshot? {
  let (provider, transport) = makeProvider(auth)
  transport.on(path: "/api/usage-summary", summary)
  transport.on(path: "/api/auth/me", me)
  if let period { transport.on(path: "/GetCurrentPeriodUsage", period) }
  guard case .success(let snapshot) = await provider.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected a snapshot")
    return nil
  }
  return snapshot
}

@Test func cursorReportsOneWindowPerQuotaBucket() async throws {
  let snapshot = try #require(await cursorSnapshot(summary: .json("cursor_usage_summary")))
  #expect(snapshot.windows.map(\.id) == ["on_demand", "plan", "team_pool"])
  #expect(snapshot.windows.first { $0.id == "plan" }?.usedPercent == 30)
  #expect(snapshot.windows.first { $0.id == "on_demand" }?.usedPercent == 5)
  #expect(snapshot.windows.first { $0.id == "team_pool" }?.usedPercent == 25)
  #expect(snapshot.windows.first { $0.id == "plan" }?.duration == Double(31 * 86400))
  #expect(snapshot.windows.first { $0.id == "plan" }?.resetsAt == ISODate.parse("2026-09-10T00:00:00.000Z"))
}

@Test func cursorReportsTheOnDemandSpendLimit() async throws {
  let snapshot = try #require(await cursorSnapshot(summary: .json("cursor_usage_summary")))
  #expect(snapshot.spend?.used == Money(amountMinor: 500, currency: "USD"))
  #expect(snapshot.spend?.limit == Money(amountMinor: 10000, currency: "USD"))
  #expect(snapshot.spend?.percent == 5)
  #expect(snapshot.spend?.limitReached == false)
}

@Test func cursorPrefersTheAccountEmailOverTheCachedOne() async throws {
  let withAccount = try #require(await cursorSnapshot(summary: .json("cursor_usage_summary")))
  #expect(withAccount.identity?.planName == "Pro Plus")
  #expect(withAccount.identity?.email == "you@example.com")
  let cached = try #require(
    await cursorSnapshot(summary: .json("cursor_usage_summary"), me: .text("nope", status: 403)))
  #expect(cached.identity?.email == "cached@example.com")
}

@Test func cursorFallsBackToThePeriodEndpoint() async throws {
  let snapshot = try #require(
    await cursorSnapshot(
      summary: .text("nope", status: 403), me: .text("nope", status: 403), period: .json("cursor_period_usage"),
      auth: CursorAuth(accessToken: "x")))
  #expect(snapshot.windows.map(\.id) == ["plan"])
  #expect(snapshot.windows.first?.usedPercent == 60)
  #expect(snapshot.spend == nil)
  #expect(snapshot.identity?.planName == "Cursor")
  #expect(snapshot.notices.map(\.text) == ["You have used 60% of your plan."])
}

@Test func cursorCallsAnUnlimitedPlanOut() async throws {
  let body = #"{"isUnlimited": true, "individualUsage": null}"#
  let snapshot = try #require(
    await cursorSnapshot(summary: .text(body), period: .json("cursor_period_usage")))
  #expect(snapshot.notices.map(\.text).contains("This plan has unlimited usage."))
}

@Test func cursorIgnoresADisabledOnDemandBucket() async throws {
  let body = #"""
    {"individualUsage": {"onDemand": {"enabled": false, "used": 1, "limit": 1, "remaining": 0}}}
    """#
  let snapshot = try #require(await cursorSnapshot(summary: .text(body)))
  #expect(snapshot.spend == nil)
  #expect(snapshot.windows.isEmpty)
}

@Test func cursorCallsAFullOnDemandBucketAReachedLimit() async throws {
  let body = #"""
    {"billingCycleStart": "bad",
     "individualUsage": {"onDemand": {"used": 100, "limit": 100, "remaining": 0}}}
    """#
  let snapshot = try #require(await cursorSnapshot(summary: .text(body)))
  #expect(snapshot.spend?.limitReached == true)
  #expect(snapshot.spend?.percent == 100)
  #expect(snapshot.windows.first?.duration == nil)
}

@MainActor
private func cursorPlanWindows(_ fields: String) async throws -> [QuotaWindow] {
  let body = "{\"individualUsage\": {\"plan\": {\"enabled\": true, " + fields + "}}}"
  return try #require(await cursorSnapshot(summary: .text(body))).windows
}

/// The vendor reports a bucket's usage four ways and the app has to agree on one number: the total wins, then the
/// mean of the auto and API shares, then whichever share is present, then used against the limit.
@Test(
  arguments: [
    (#""autoPercentUsed": 1, "apiPercentUsed": 2, "totalPercentUsed": 3"#, 3.0),
    (#""autoPercentUsed": 10, "apiPercentUsed": 20"#, 15.0),
    (#""autoPercentUsed": 10"#, 10.0),
    (#""apiPercentUsed": 20"#, 20.0),
    (#""used": 25, "limit": 100"#, 25.0),
  ])
func cursorPicksThePercentTheVendorReports(fields: String, percent: Double) async throws {
  #expect(try await cursorPlanWindows(fields).map(\.usedPercent) == [percent])
}

@Test(arguments: [#""used": 25, "limit": 0"#, #""remaining": 3"#])
func cursorSkipsABucketWithoutAPercent(fields: String) async throws {
  #expect(try await cursorPlanWindows(fields).isEmpty)
}

@Test func cursorProviderFetchesSummaryAndIdentity() async {
  let store = MemoryCursorStore(validCursor)
  let (provider, transport) = makeProvider(validCursor, store: store)
  transport.on(path: "/api/usage-summary", .json("cursor_usage_summary"))
  transport.on(path: "/api/auth/me", .json("cursor_me"))
  #expect(provider.credentialDescription == "memory")
  #expect(provider.credentialState(now: fixedNow).isUsable)
  let credentialState = validCursor.state(now: fixedNow)
  #expect(
    await provider.credentialHealth(now: fixedNow)
      == .from(credentialState, source: store.source, expected: ProviderID.cursor.setup.credentialSources))
  let readsBeforeFetch = store.readCount
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(store.readCount == readsBeforeFetch + 1)
  #expect(
    result.credentialStatus
      == ProviderCredentialStatus(
        state: credentialState,
        health: .from(credentialState, source: store.source, expected: ProviderID.cursor.setup.credentialSources)))
  guard case .success(let snapshot) = result.outcome else {
    Issue.record("expected success")
    return
  }
  #expect(snapshot.windows.count == 3)
  #expect(snapshot.identity?.email == "you@example.com")
  #expect(snapshot.spend?.percent == 5)
  let request = transport.requests(matching: "/api/usage-summary").first!
  #expect(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=user_01ABC") == true)
  #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
}

@Test func cursorProviderCachesIdentityUntilItsTTL() async {
  let (provider, transport) = makeProvider(validCursor)
  transport.on(path: "/api/usage-summary", .json("cursor_usage_summary"))
  transport.on(path: "/api/auth/me", .json("cursor_me"))

  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(transport.requests(matching: "/api/auth/me").count == 1)
  _ = await provider.fetch(
    now: fixedNow.addingTimeInterval(CursorProvider.identityTTL + 1), options: FetchOptions())
  #expect(transport.requests(matching: "/api/auth/me").count == 2)
}

@Test func cursorProviderCachesIdentityFailuresBriefly() async {
  let (provider, transport) = makeProvider(validCursor)
  transport.on(path: "/api/usage-summary", .json("cursor_usage_summary"))
  transport.on(path: "/api/auth/me", .text("unavailable", status: 503))

  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(transport.requests(matching: "/api/auth/me").count == 1)
  _ = await provider.fetch(
    now: fixedNow.addingTimeInterval(CursorProvider.identityFailureTTL + 1), options: FetchOptions())
  #expect(transport.requests(matching: "/api/auth/me").count == 2)
}

@Test func cursorProviderCoalescesConcurrentIdentityRequests() async {
  let transport = StubTransport()
  transport.on(path: "/api/usage-summary", .json("cursor_usage_summary"))
  transport.on(path: "/api/auth/me", .json("cursor_me"))
  let gate = TestGate()
  let delayed = CursorIdentityDelayedTransport(base: transport, gate: gate)
  let provider = CursorProvider(
    auth: MemoryCursorStore(validCursor), client: APIClient(transport: delayed, log: makeLog(), clock: testClock),
    log: makeLog())

  async let first = provider.fetch(now: fixedNow, options: FetchOptions())
  while !delayed.identityStarted { await Task.yield() }
  async let second = provider.fetch(now: fixedNow, options: FetchOptions())
  while transport.requests(matching: "/api/usage-summary").count < 2 { await Task.yield() }
  for _ in 0..<100 { await Task.yield() }
  gate.open()
  _ = await (first, second)
  #expect(transport.requests(matching: "/api/auth/me").count == 1)
}

private final class CursorIdentityDelayedTransport: HTTPTransport, @unchecked Sendable {
  private let base: any HTTPTransport
  private let gate: TestGate
  private let lock = NSLock()
  private var didStartIdentity = false

  init(base: any HTTPTransport, gate: TestGate) {
    self.base = base
    self.gate = gate
  }

  var identityStarted: Bool { lock.withLock { didStartIdentity } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    if request.url?.path.hasSuffix("/api/auth/me") == true {
      lock.withLock { didStartIdentity = true }
      try await gate.wait()
    }
    return try await base.data(for: request)
  }
}

private func makeProvider(_ auth: CursorAuth?, store: MemoryCursorStore? = nil) -> (CursorProvider, StubTransport) {
  let transport = StubTransport()
  let provider = CursorProvider(
    auth: store ?? MemoryCursorStore(auth), client: APIClient(transport: transport, log: makeLog(), clock: testClock),
    log: makeLog())
  return (provider, transport)
}

@Test func cursorProviderFallsBackToBearerEndpoint() async {
  let (provider, transport) = makeProvider(validCursor)
  transport.on(path: "/api/usage-summary", .text("nope", status: 403))
  transport.on(path: "/GetCurrentPeriodUsage", .json("cursor_period_usage"))
  transport.on(path: "/api/auth/me", .text("nope", status: 403))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  guard case .success(let snapshot) = result.outcome else {
    Issue.record("expected success")
    return
  }
  #expect(snapshot.windows.map(\.id) == ["plan"])
  #expect(snapshot.identity?.planName == "Pro")
  #expect(snapshot.notices.map(\.text) == ["You have used 60% of your plan."])
  #expect(result.warnings.first?.contains("Dashboard summary unavailable") == true)
  let bearer = transport.requests(matching: "/GetCurrentPeriodUsage").first!
  #expect(bearer.value(forHTTPHeaderField: "Authorization") == "Bearer \(validCursor.accessToken)")
  #expect(bearer.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
  let (failing, transport2) = makeProvider(validCursor)
  transport2.on(path: "/api/usage-summary", .text("nope", status: 401))
  transport2.on(path: "/GetCurrentPeriodUsage", .text("nope", status: 401))
  guard case .notAuthenticated = await failing.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected notAuthenticated")
    return
  }
}

@Test func cursorProviderHandlesCredentialProblems() async {
  let (missing, _) = makeProvider(nil)
  #expect(missing.credentialState(now: fixedNow) == .missing("no Cursor sign-in found"))
  guard case .notAuthenticated(let reason) = await missing.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(reason.contains("No Cursor credentials"))
  let store = MemoryCursorStore(validCursor)
  store.loadError = TestError()
  let (broken, _) = makeProvider(nil, store: store)
  #expect(broken.credentialState(now: fixedNow).isMissing)
  guard case .notAuthenticated(let loadReason) = await broken.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(loadReason.contains("Cannot read"))
  let (expired, _) = makeProvider(CursorAuth(accessToken: cursorJWT(exp: 1)))
  guard
    case .notAuthenticated(let expiredReason) = await expired.fetch(now: fixedNow, options: FetchOptions())
      .outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(expiredReason.contains("expired"))
}
