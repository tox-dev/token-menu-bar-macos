import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test func copilotFileStoreFindsGitHubEntries() throws {
  let root = temporaryDirectory()
  let hosts = root.appendingPathComponent("hosts.json")
  let apps = root.appendingPathComponent("apps.json")
  let store = FileCopilotAuthStore(urls: [hosts, apps])
  #expect(store.description == "\(hosts.path), \(apps.path)")
  #expect(try store.load() == nil)
  try Fixtures.data("copilot_hosts").write(to: apps)
  #expect(try store.load() == CopilotAuth(token: "gho_test_token_123", user: "octocat", host: "github.com"))
  try Data(#"{"ghe.example.com:Iv1.x": {"user": "ent", "oauth_token": "gho_ent"}, "empty": {"oauth_token": ""}}"#.utf8)
    .write(to: hosts)
  #expect(try store.load() == CopilotAuth(token: "gho_ent", user: "ent", host: "ghe.example.com"))
  try Data("[]".utf8).write(to: hosts)
  #expect(throws: CredentialStoreError.self) { try store.load() }
  try Data(#"{"github.com": {"user": "x"}}"#.utf8).write(to: hosts)
  try FileManager.default.removeItem(at: apps)
  #expect(try store.load() == nil)
  #expect(
    FileCopilotAuthStore.defaultURLs(environment: [:], home: root).map(\.lastPathComponent) == [
      "hosts.json", "apps.json",
    ])
  #expect(
    FileCopilotAuthStore.defaultURLs(environment: ["XDG_CONFIG_HOME": "/xdg"], home: root).first?.path
      == "/xdg/github-copilot/hosts.json")
  #expect(validCopilot.state(now: fixedNow) == .valid(expiresAt: nil))
}

private let validCopilot = CopilotAuth(token: "gho_test", user: "octocat")

@Test func copilotCategoryResetOverridesTheBillingCycleReset() async throws {
  let snapshot = try #require(
    await copilotSnapshot(
      .text(
        #"{"quota_reset_date":"2026-10-01","quota_snapshots":{"chat":{"entitlement":100,"remaining":50,"quota_reset_at":1788558705},"unknown":{"remaining":5}}}"#
      )))
  #expect(snapshot.windows.count == 1)
  #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1788558705))
  #expect(snapshot.windows.first?.resetPrecision == .instant)
}

@MainActor
private func copilotSnapshot(
  _ response: StubTransport.Response, auth: CopilotAuth = validCopilot
) async
  -> ProviderSnapshot?
{
  let (provider, transport) = makeProvider(auth)
  transport.on(path: "/copilot_internal/user", response)
  guard case .success(let snapshot) = await provider.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected a snapshot")
    return nil
  }
  return snapshot
}

@Test func copilotReportsAPaidPlanAsMonthlyWindows() async throws {
  let snapshot = try #require(await copilotSnapshot(.json("copilot_user")))
  #expect(snapshot.windows.map(\.id) == ["completions", "premium_interactions"])
  #expect(snapshot.windows.map(\.label) == ["Completions", "Premium credits"])
  #expect(snapshot.windows.map(\.usedPercent) == [75, 100])
  #expect(snapshot.windows.allSatisfy { $0.resetsAt == DayStamp.date("2026-09-01") && $0.resetPrecision == .day })
  #expect(snapshot.identity?.planName == "Pro Plus")
  #expect(snapshot.identity?.tier == "copilot_pro_seat")
  #expect(snapshot.identity?.email == "octocat")
}

@Test func copilotReportsBillingAndOverageAsNotices() async throws {
  let snapshot = try #require(await copilotSnapshot(.json("copilot_user")))
  #expect(
    snapshot.notices.map(\.text) == [
      "Premium credits: quota exceeded, 15 overage credits."
    ])
  #expect(snapshot.notices.first?.kind == .info)
}

@Test func copilotReportsAFreePlanFromItsMonthlyAllowances() async throws {
  let snapshot = try #require(await copilotSnapshot(.json("copilot_user_free")))
  #expect(snapshot.windows.map(\.id) == ["free:chat", "free:completions", "premium_interactions"])
  #expect(snapshot.windows.map(\.label) == ["Chat", "Completions", "Premium requests"])
  #expect(abs(snapshot.windows[0].usedPercent - 18) < 0.001)
  #expect(snapshot.windows[0].resetsAt == DayStamp.date("2026-09-11"))
  #expect(snapshot.windows[0].resetPrecision == .day)
  #expect(snapshot.windows[1].usedPercent == 0)
  #expect(snapshot.windows[2].usedPercent == 60)
  #expect(snapshot.identity?.planName == "Pro")
  #expect(snapshot.notices.isEmpty)
}

@Test func copilotOrganizationManagedSeatNamesTheOrganizationAndKeepsItsPremiumWindow() async throws {
  let (provider, transport) = makeProvider(validCopilot)
  transport.on(path: "/copilot_internal/user", .json("copilot_user_org"))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  let snapshot = try #require(result.outcome.snapshot)
  #expect(result.outcome.errorDescription == nil)
  #expect(result.credentialStatus?.state == .valid(expiresAt: nil))
  #expect(snapshot.identity?.planName == "Business via octo-org")
  #expect(snapshot.identity?.tier == "copilot_for_business_seat")
  #expect(snapshot.identity?.email == "octocat")
  #expect(snapshot.windows.map(\.id) == ["premium_interactions"])
  #expect(snapshot.windows.map(\.usedPercent) == [30])
  #expect(snapshot.notices.isEmpty)
}

@Test func copilotListsEveryManagingOrganization() async throws {
  let body = #"{"copilot_plan": "enterprise", "organization_login_list": ["octo-org", "octo-labs"]}"#
  let snapshot = try #require(await copilotSnapshot(.text(body)))
  #expect(snapshot.identity?.planName == "Enterprise via octo-org, octo-labs")
}

@Test func copilotCallsAnExhaustedQuotaWithoutOverageALimit() async throws {
  let body = #"""
    {"quota_snapshots": {"chat": {"percent_remaining": -10, "overage_permitted": false},
     "premium_interactions": {"entitlement": 0, "remaining": 0}}}
    """#
  let snapshot = try #require(await copilotSnapshot(.text(body), auth: CopilotAuth(token: "t")))
  #expect(snapshot.notices.map(\.kind) == [.limitReached])
  #expect(snapshot.windows.map(\.id) == ["chat"])
  #expect(snapshot.identity?.planName == "Copilot")
}

@Test func copilotLeavesTheResetOpenWhenTheDateMakesNoSense() async throws {
  let body = #"{"quota_reset_date": "whenever", "quota_snapshots": {"chat": {"percent_remaining": 40}}}"#
  let snapshot = try #require(await copilotSnapshot(.text(body), auth: CopilotAuth(token: "t")))
  #expect(snapshot.windows.map(\.resetsAt) == [nil])
  #expect(snapshot.windows.map(\.usedPercent) == [60])
}

@Test func copilotReportsNoWindowsWhenTheAccountHasNoQuota() async throws {
  let snapshot = try #require(await copilotSnapshot(.text("{}"), auth: CopilotAuth(token: "t")))
  #expect(snapshot.windows.isEmpty)
  #expect(snapshot.notices.isEmpty)
}

@Test func copilotProviderIdentifiesItselfAsAnEditor() async {
  let store = MemoryCopilotStore(validCopilot)
  let (provider, transport) = makeProvider(validCopilot, store: store)
  transport.on(path: "/copilot_internal/user", .json("copilot_user"))
  #expect(provider.credentialDescription == "memory")
  #expect(provider.credentialState(now: fixedNow) == .valid(expiresAt: nil))
  let health = await provider.credentialHealth(now: fixedNow)
  guard case .valid(let source, let expiresAt) = health else {
    Issue.record("expected a valid Copilot credential, got \(health)")
    return
  }
  #expect(source == store.source)
  #expect(expiresAt == nil)
  let readsBeforeFetch = store.readCount
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(store.readCount == readsBeforeFetch + 1)
  #expect(
    result.credentialStatus
      == ProviderCredentialStatus(
        state: .valid(expiresAt: nil), health: .valid(source: store.source, expiresAt: nil)))
  let request = transport.requests(matching: "/copilot_internal/user").first!
  #expect(request.url?.host() == "api.github.com")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "token gho_test")
  // GitHub answers this endpoint for editor clients, so the request carries an editor and plugin version
  #expect(request.value(forHTTPHeaderField: "Editor-Version")?.hasPrefix("vscode/") == true)
  #expect(request.value(forHTTPHeaderField: "Editor-Plugin-Version")?.isEmpty == false)
}

@Test func copilotProviderAsksTheEnterpriseHost() async {
  let (provider, transport) = makeProvider(CopilotAuth(token: "gho_ent", user: "ent", host: "ghe.example.com"))
  transport.on(path: "/copilot_internal/user", .json("copilot_user"))
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(transport.requests.first?.url?.host() == "ghe.example.com")
  #expect(transport.requests.first?.url?.path == "/api/v3/copilot_internal/user")
}

@Test func copilotProviderUsesTheEnterpriseCloudAPIHost() async {
  let (provider, transport) = makeProvider(CopilotAuth(token: "gho_ent", user: "ent", host: "octocorp.ghe.com"))
  transport.on(path: "/copilot_internal/user", .json("copilot_user"))
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(transport.requests.first?.url?.host() == "api.octocorp.ghe.com")
  #expect(transport.requests.first?.url?.path == "/copilot_internal/user")
}

@Test func copilotProviderRejectsAnInvalidHostWithoutSendingTheToken() async {
  let (provider, transport) = makeProvider(CopilotAuth(token: "secret", host: "https://ghe.example/path"))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  guard case .notAuthenticated = result.outcome else {
    Issue.record("expected invalid credentials")
    return
  }
  #expect(result.recoveryIssue?.kind == .credentialUnreadable)
  #expect(transport.requests.isEmpty)
}

private func makeProvider(_ auth: CopilotAuth?, store: MemoryCopilotStore? = nil) -> (CopilotProvider, StubTransport) {
  let transport = StubTransport()
  let provider = CopilotProvider(
    auth: store ?? MemoryCopilotStore(auth), client: APIClient(transport: transport, log: makeLog(), clock: testClock),
    log: makeLog())
  return (provider, transport)
}

@Test func copilotProviderHandlesFailures() async {
  let (missing, _) = makeProvider(nil)
  #expect(missing.credentialState(now: fixedNow) == .missing("no Copilot sign-in found"))
  guard case .notAuthenticated(let reason) = await missing.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(reason.contains("No Copilot credentials"))
  let store = MemoryCopilotStore(validCopilot)
  store.loadError = TestError()
  let (broken, _) = makeProvider(nil, store: store)
  #expect(broken.credentialState(now: fixedNow).isMissing)
  guard case .notAuthenticated(let loadReason) = await broken.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(loadReason.contains("Cannot read"))
  let (rejected, transport) = makeProvider(validCopilot)
  transport.on(path: "/copilot_internal/user", .text("bad credentials", status: 401))
  guard case .notAuthenticated = await rejected.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected notAuthenticated")
    return
  }
}

@Test(
  arguments: [
    (#""quota_reset_date": "2026-09-01T10:00:00Z""#, ResetPrecision.instant),
    (#""quota_reset_date": "2026-09-01""#, ResetPrecision.day),
  ])
func copilotKeepsTheResetPrecisionTheAPIGave(field: String, precision: ResetPrecision) async throws {
  let body = #"{"quota_snapshots": {"premium_interactions": {"entitlement": 300, "remaining": 120}}, "# + field + "}"
  let snapshot = try #require(await copilotSnapshot(.text(body)))
  #expect(snapshot.windows.map(\.usedPercent) == [60])
  #expect(snapshot.windows.first?.resetPrecision == precision)
}

@Test func copilotFreePlanWithoutResetDatesShowsNoCountdown() async throws {
  let snapshot = try #require(
    await copilotSnapshot(.text(#"{"limited_user_quotas": {"chat": 41}, "monthly_quotas": {"chat": 50}}"#)))
  #expect(snapshot.windows.map(\.id) == ["free:chat"])
  #expect(snapshot.windows.first?.resetsAt == nil)
  #expect(snapshot.windows.first?.resetPrecision == .instant)
}

@Test func copilotKeepsAnAPIHostAsIs() async {
  let (provider, transport) = makeProvider(CopilotAuth(token: "gho_ent", user: "ent", host: "api.octocorp.example"))
  transport.on(path: "/copilot_internal/user", .json("copilot_user"))
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(transport.requests.first?.url?.host() == "api.octocorp.example")
}
