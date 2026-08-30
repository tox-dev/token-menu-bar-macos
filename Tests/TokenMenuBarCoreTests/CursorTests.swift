import Foundation
import Testing

@testable import TokenMenuBarCore

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
  #expect(throws: TestError.self) { try ChainedCursorAuthStore([failing, MemoryCursorStore(nil)]).load() }
  #expect(try ChainedCursorAuthStore([MemoryCursorStore(nil)]).load() == nil)
}

@Test func cursorMapperBuildsOneWindowPerQuotaBucket() {
  let summary = Fixtures.decode(CursorAPI.UsageSummary.self, "cursor_usage_summary")
  let windows = CursorMapper.windows(summary)
  #expect(windows.map(\.id) == ["plan", "on_demand", "team_pool"])
  #expect(windows.map(\.usedPercent) == [30, 5, 25])
  #expect(windows.first?.duration == Double(31 * 86400))
  #expect(windows.first?.resetsAt == ISODate.parse("2026-09-10T00:00:00.000Z"))
}

@Test func cursorMapperReadsTheOnDemandSpendLimit() {
  let spend = CursorMapper.spend(Fixtures.decode(CursorAPI.UsageSummary.self, "cursor_usage_summary"))
  #expect(spend?.used == Money(amountMinor: 500, currency: "USD"))
  #expect(spend?.limit == Money(amountMinor: 10000, currency: "USD"))
  #expect(spend?.percent == 5)
  #expect(spend?.limitReached == false)
}

@Test func cursorMapperPrefersTheAccountEmailOverTheCachedOne() {
  let summary = Fixtures.decode(CursorAPI.UsageSummary.self, "cursor_usage_summary")
  let identity = CursorMapper.identity(
    summary, auth: validCursor, me: Fixtures.decode(CursorAPI.Me.self, "cursor_me"))
  #expect(identity.planName == "Pro Plus")
  #expect(identity.email == "you@example.com")
  #expect(CursorMapper.identity(summary, auth: validCursor, me: nil).email == "cached@example.com")
}

@Test func cursorMapperFallsBackToThePeriodEndpoint() {
  let fallback = Fixtures.decode(CursorAPI.PeriodUsage.self, "cursor_period_usage").summary
  #expect(CursorMapper.windows(fallback).map(\.id) == ["plan"])
  #expect(CursorMapper.windows(fallback).first?.usedPercent == 60)
  #expect(CursorMapper.spend(fallback) == nil)
  #expect(CursorMapper.identity(fallback, auth: CursorAuth(accessToken: "x"), me: nil).planName == "Cursor")
}

@Test func cursorMapperNoticesUnlimitedPlansAndPeriodUsage() {
  let summary = Fixtures.decode(CursorAPI.UsageSummary.self, "cursor_usage_summary")
  #expect(CursorMapper.notices(summary, period: nil).isEmpty)
  let notices = CursorMapper.notices(
    CursorAPI.UsageSummary(
      billingCycleStart: nil, billingCycleEnd: nil, membershipType: nil, isUnlimited: true, individualUsage: nil,
      teamUsage: nil), period: Fixtures.decode(CursorAPI.PeriodUsage.self, "cursor_period_usage"))
  #expect(notices.map(\.text) == ["This plan has unlimited usage.", "You have used 60% of your plan."])
}

@Test(
  arguments: [
    (cursorBucket(auto: 1, api: 2, total: 3), 3.0), (cursorBucket(auto: 10, api: 20), 15.0),
    (cursorBucket(auto: 10), 10.0), (cursorBucket(api: 20), 20.0), (cursorBucket(used: 25, limit: 100), 25.0),
    (cursorBucket(used: 25, limit: 0), nil), (cursorBucket(), nil),
  ])
func cursorBucketPercentPrecedence(bucket: CursorAPI.Bucket, percent: Double?) {
  #expect(bucket.percentUsed == percent)
}

private func cursorBucket(
  auto: Double? = nil, api: Double? = nil, total: Double? = nil, used: Double? = nil, limit: Double? = nil
) -> CursorAPI.Bucket {
  CursorAPI.Bucket(
    enabled: true, used: used, limit: limit, remaining: nil, autoPercentUsed: auto, apiPercentUsed: api,
    totalPercentUsed: total)
}

@Test func cursorSpendReflectsTheOnDemandBucket() {
  let disabledSpend = CursorAPI.UsageSummary(
    billingCycleStart: nil, billingCycleEnd: nil, membershipType: nil, isUnlimited: nil,
    individualUsage: CursorAPI.IndividualUsage(
      plan: nil,
      onDemand: CursorAPI.Bucket(
        enabled: false, used: 1, limit: 1, remaining: 0, autoPercentUsed: nil, apiPercentUsed: nil,
        totalPercentUsed: nil),
      overall: nil), teamUsage: nil)
  #expect(CursorMapper.spend(disabledSpend) == nil)
  #expect(CursorMapper.windows(disabledSpend).isEmpty)
  let exhausted = CursorAPI.UsageSummary(
    billingCycleStart: "bad", billingCycleEnd: nil, membershipType: nil, isUnlimited: nil,
    individualUsage: CursorAPI.IndividualUsage(
      plan: nil,
      onDemand: CursorAPI.Bucket(
        enabled: nil, used: 100, limit: 100, remaining: 0, autoPercentUsed: nil, apiPercentUsed: nil,
        totalPercentUsed: nil),
      overall: nil), teamUsage: nil)
  #expect(CursorMapper.spend(exhausted)?.limitReached == true)
  #expect(CursorMapper.spend(exhausted)?.percent == 100)
  #expect(CursorMapper.windows(exhausted).first?.duration == nil)
}

@Test func cursorProviderFetchesSummaryAndIdentity() async {
  let (provider, transport) = makeProvider(validCursor)
  transport.on(path: "/api/usage-summary", .json("cursor_usage_summary"))
  transport.on(path: "/api/auth/me", .json("cursor_me"))
  #expect(provider.credentialDescription == "memory")
  #expect(provider.credentialState(now: fixedNow).isUsable)
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
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
