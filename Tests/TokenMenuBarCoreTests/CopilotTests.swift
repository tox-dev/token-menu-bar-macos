import Foundation
import Testing
import TokenMenuBarCore

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
  #expect(snapshot.windows.map(\.label) == ["Completions", "Premium requests"])
  #expect(snapshot.windows.map(\.usedPercent) == [75, 100])
  #expect(snapshot.windows.allSatisfy { $0.resetsAt == DayStamp.date("2026-09-01") })
  #expect(snapshot.identity?.planName == "Pro Plus")
  #expect(snapshot.identity?.tier == "copilot_pro_seat")
  #expect(snapshot.identity?.email == "octocat")
}

@Test func copilotReportsBillingAndOverageAsNotices() async throws {
  let snapshot = try #require(await copilotSnapshot(.json("copilot_user")))
  #expect(
    snapshot.notices.map(\.text) == [
      "Token-based billing: 33 credits used this cycle.", "Premium requests: quota exceeded, 15 overage requests.",
    ])
  #expect(snapshot.notices[1].kind == .info)
}

@Test func copilotReportsAFreePlanFromItsMonthlyAllowances() async throws {
  let snapshot = try #require(await copilotSnapshot(.json("copilot_user_free")))
  #expect(snapshot.windows.map(\.id) == ["free:chat", "free:completions", "premium_interactions"])
  #expect(snapshot.windows.map(\.label) == ["Chat", "Completions", "Premium requests"])
  #expect(abs(snapshot.windows[0].usedPercent - 18) < 0.001)
  #expect(snapshot.windows[0].resetsAt == DayStamp.date("2026-09-11"))
  #expect(snapshot.windows[1].usedPercent == 0)
  #expect(snapshot.windows[2].usedPercent == 60)
  #expect(snapshot.identity?.planName == "Individual")
  #expect(snapshot.notices.isEmpty)
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
  #expect(transport.requests.first?.url?.host() == "api.ghe.example.com")
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
