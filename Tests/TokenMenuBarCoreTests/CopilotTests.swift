import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func copilotFileStoreFindsGitHubEntries() throws {
  let root = temporaryDirectory()
  let hosts = root.appendingPathComponent("hosts.json")
  let apps = root.appendingPathComponent("apps.json")
  let store = FileCopilotAuthStore(urls: [hosts, apps])
  #expect(store.description == "\(hosts.path), \(apps.path)")
  #expect(try store.load() == nil)
  try Fixtures.data("copilot_hosts").write(to: apps)
  let loaded = try store.load()
  #expect(loaded == CopilotAuth(token: "gho_test_token_123", user: "octocat", host: "github.com"))
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

@Test func copilotMapperReadsPaidPlans() {
  let user = Fixtures.json("copilot_user")
  let windows = CopilotMapper.windows(user)
  #expect(windows.map(\.id) == ["premium_interactions", "completions"])
  #expect(windows[0].label == "Premium requests")
  #expect(windows[0].usedPercent == 100)
  #expect(windows[0].resetsAt == DayStamp.date("2026-09-01"))
  #expect(windows[1].usedPercent == 75)
  let identity = CopilotMapper.identity(user, auth: validCopilot)
  #expect(identity.planName == "Pro Plus")
  #expect(identity.tier == "copilot_pro_seat")
  #expect(identity.email == "octocat")
  let notices = CopilotMapper.notices(user)
  #expect(
    notices.map(\.text) == [
      "Token-based billing: 33 credits used this cycle.", "Premium requests: quota exceeded, 15 overage requests.",
    ])
  #expect(notices[1].kind == .info)
  #expect(CopilotMapper.date("2026-09-01T10:00:00Z") == ISODate.parse("2026-09-01T10:00:00Z"))
  #expect(CopilotMapper.date(nil) == nil)
  #expect(CopilotMapper.date("garbage") == nil)
  #expect(CopilotMapper.label("chat") == "Chat")
}

@Test func copilotMapperReadsFreePlans() {
  let user = Fixtures.json("copilot_user_free")
  let windows = CopilotMapper.windows(user)
  #expect(windows.map(\.id) == ["premium_interactions", "free:chat", "free:completions"])
  #expect(windows[0].usedPercent == 60)
  #expect(abs(windows[1].usedPercent - 18) < 0.001)
  #expect(windows[1].resetsAt == DayStamp.date("2026-09-11"))
  #expect(windows[2].usedPercent == 0)
  #expect(CopilotMapper.identity(user, auth: CopilotAuth(token: "t")).planName == "Individual")
  #expect(CopilotMapper.notices(user).isEmpty)
  let overage = JSONValue.object([
    "quota_snapshots": .object([
      "chat": .object(["percent_remaining": .number(-10), "overage_permitted": .bool(false)]),
      "premium_interactions": .object(["entitlement": .number(0), "remaining": .number(0)]),
    ])
  ])
  let overageNotices = CopilotMapper.notices(overage)
  #expect(overageNotices.map(\.kind) == [.limitReached])
  #expect(CopilotMapper.windows(overage).map(\.id) == ["chat"])
  #expect(CopilotMapper.identity(.object([:]), auth: CopilotAuth(token: "t")).planName == "Copilot")
  #expect(CopilotMapper.windows(.object([:])).isEmpty)
}

@Test func copilotProviderFetchesUsage() async {
  let (provider, transport) = makeProvider(validCopilot)
  transport.on(path: "/copilot_internal/user", .json("copilot_user"))
  #expect(provider.credentialDescription == "memory")
  #expect(provider.credentialState(now: fixedNow) == .valid(expiresAt: nil))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  guard case .success(let snapshot) = result.outcome else {
    Issue.record("expected success")
    return
  }
  #expect(snapshot.windows.count == 2)
  #expect(snapshot.identity?.planName == "Pro Plus")
  let request = transport.requests(matching: "/copilot_internal/user").first!
  #expect(request.url?.host() == "api.github.com")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "token gho_test")
  #expect(request.value(forHTTPHeaderField: "Editor-Version") == CopilotAPI.editorVersion)
  #expect(
    CopilotAPI.userURL(host: "ghe.example.com").absoluteString == "https://api.ghe.example.com/copilot_internal/user")
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
