import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let endpoint = URL(
  string: "https://example.com/api/organizations/565b9c34-9c85-4cad-a16d-03f1e6e313a0/usage?x=1")!

@Test func apiClientGetDecodesAndLogs() async throws {
  let transport = StubTransport()
  transport.on(path: "/usage", .text(#"{"value":1}"#))
  let log = makeLog()
  log.debugEnabled = true
  let client = APIClient(transport: transport, log: log, clock: testClock)
  struct Payload: Decodable { let value: Int }
  #expect(try await client.getJSON(Payload.self, endpoint, headers: ["X-Test": "1"], operation: "op").value == 1)
  let request = transport.requests[0]
  #expect(request.value(forHTTPHeaderField: "X-Test") == "1")
  #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
  #expect(request.httpMethod == "GET")
  #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
  let lines = log.text
  #expect(lines.contains("endpoint=https://example.com/api/organizations/{id}/usage"))
  #expect(!lines.contains("x=1"))
  #expect(lines.contains("status=200"))
}

@Test func apiClientPostSendsJSONBody() async throws {
  let transport = StubTransport()
  transport.on(path: "/token", .text("{}"))
  let client = APIClient(transport: transport, log: makeLog())
  _ = try await client.post(
    URL(string: "https://example.com/token")!, json: Data("{\"a\":1}".utf8),
    headers: ["Content-Type": "text/plain", "A": "b"], operation: "post")
  let request = transport.requests[0]
  #expect(request.httpMethod == "POST")
  #expect(request.httpBody == Data("{\"a\":1}".utf8))
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  #expect(request.value(forHTTPHeaderField: "A") == "b")
}

@Test func apiClientFormEncodingPreservesLiteralPlusSigns() async throws {
  let transport = StubTransport()
  transport.on(path: "/token", .text("{}"))
  let client = APIClient(transport: transport, log: makeLog())

  _ = try await client.post(
    URL(string: "https://example.com/token")!, form: ["a+b": "c+d e"], headers: [:], operation: "post")

  #expect(transport.requests[0].httpBody == Data("a%2Bb=c%2Bd%20e".utf8))
}

@Test func apiClientMapsHTTPErrorsWithRetryAfter() async {
  let transport = StubTransport()
  transport.on(path: "/header", .text("slow down", status: 429, headers: ["Retry-After": "120"]))
  transport.on(
    path: "/date",
    .text("slow down", status: 503, headers: ["Retry-After": "Sat, 29 Aug 2026 19:02:00 GMT"]))
  transport.on(path: "/body", .text(#"{"retry_after": 30}"#, status: 429))
  transport.on(path: "/plain", .text(String(repeating: "x", count: 300), status: 500))
  transport.on(path: "/large", .text(String(repeating: "x", count: 70_000), status: 500))
  let log = makeLog()
  log.debugEnabled = true
  let client = APIClient(transport: transport, log: log, clock: testClock)
  await #expect(throws: APIError.http(status: 429, body: "slow down", retryAfter: 120)) {
    try await client.get(URL(string: "https://example.com/header")!, headers: [:], operation: "a")
  }
  await #expect(throws: APIError.http(status: 503, body: "slow down", retryAfter: 120)) {
    try await client.get(URL(string: "https://example.com/date")!, headers: [:], operation: "date")
  }
  await #expect(throws: APIError.http(status: 429, body: #"{"retry_after": 30}"#, retryAfter: 30)) {
    try await client.get(URL(string: "https://example.com/body")!, headers: [:], operation: "b")
  }
  do {
    _ = try await client.get(URL(string: "https://example.com/plain")!, headers: [:], operation: "c")
    Issue.record("expected failure")
  } catch {
    guard case .http(let status, let body, let retryAfter) = error else {
      Issue.record("wrong error")
      return
    }
    #expect(status == 500)
    #expect(body.count == 300)
    #expect(retryAfter == nil)
  }
  do {
    _ = try await client.get(URL(string: "https://example.com/large")!, headers: [:], operation: "large")
    Issue.record("expected failure")
  } catch {
    guard case .http(_, let body, _) = error else {
      Issue.record("wrong error")
      return
    }
    #expect(body.utf8.count == APIClient.maximumErrorBodyBytes)
  }
  #expect(!log.text.contains("slow down"))
  #expect(!log.text.contains("retry_after"))
  #expect(!log.text.contains(String(repeating: "x", count: 20)))
  #expect(log.snapshot.contains { $0.category == .network && $0.message.contains("status=429") })
}

@Test func apiClientRetainsStructuredErrorReasonsBeyondTheFormerSnippetLimit() async {
  let transport = StubTransport()
  let message = String(repeating: "x", count: 300)
  let body = #"{"error":{"message":"\#(message)","details":[{"reason":"SUBSCRIPTION_REQUIRED"}]}}"#
  transport.on(path: "/reason", .text(body, status: 403))
  let client = APIClient(transport: transport, log: makeLog())

  do {
    _ = try await client.get(URL(string: "https://example.com/reason")!, headers: [:], operation: "reason")
    Issue.record("expected failure")
  } catch {
    guard case .http(_, let retainedBody, _) = error else {
      Issue.record("wrong error")
      return
    }
    #expect(retainedBody == body)
    #expect(retainedBody.contains("SUBSCRIPTION_REQUIRED"))
  }
}

@Test func apiClientDistinguishesVendorSecurityChallengesFromAuthenticationFailures() async {
  let transport = StubTransport()
  transport.on(
    path: "/challenge",
    .text("<!doctype html><title>Just a moment</title>", status: 403, headers: ["Content-Type": "text/html"]))
  let client = APIClient(transport: transport, log: makeLog())

  await #expect(throws: APIError.vendorSecurityCheck(status: 403)) {
    try await client.get(URL(string: "https://example.com/challenge")!, headers: [:], operation: "challenge")
  }
  #expect(!APIError.vendorSecurityCheck(status: 403).isAuthenticationFailure)
  #expect(APIError.vendorSecurityCheck(status: 403).message.contains("provider security check"))
}

@Test func apiClientMapsNetworkAndDecodingErrors() async {
  let transport = StubTransport()
  transport.on(path: "/down", error: URLError(.notConnectedToInternet))
  transport.on(path: "/bad", .text("not json"))
  let log = makeLog()
  log.debugEnabled = true
  let client = APIClient(transport: transport, log: log)
  do {
    _ = try await client.get(URL(string: "https://example.com/down")!, headers: [:], operation: "a")
    Issue.record("expected failure")
  } catch {
    guard case .network(let text) = error else {
      Issue.record("wrong error")
      return
    }
    #expect(!text.isEmpty)
    #expect(error.message.hasPrefix("Network error"))
  }
  struct Account: Decodable { let remaining: Int }
  struct Envelope: Decodable { let account: Account }
  do {
    _ = try client.decode(Envelope.self, Data(#"{"account":{"remaining":"many"}}"#.utf8), operation: "shape")
    Issue.record("expected failure")
  } catch {
    #expect(error.message.hasPrefix("Unexpected response"))
  }
  do {
    _ = try await client.getJSON(
      [String: Int].self, URL(string: "https://example.com/bad")!, headers: [:], operation: "decode")
    Issue.record("expected failure")
  } catch {
    guard case .decoding(let text) = error else {
      Issue.record("wrong error")
      return
    }
    #expect(text.hasPrefix("decode:"))
    #expect(error.message.hasPrefix("Unexpected response"))
  }
  do {
    _ = try await client.get(URL(string: "https://example.com/unmatched")!, headers: [:], operation: "u")
    Issue.record("expected failure")
  } catch {
    #expect(error.retryAfter == nil)
  }
  #expect(
    log.snapshot.contains {
      $0.category == .network && $0.message.contains("request.finished")
        && $0.message.contains("errorDomain=NSURLErrorDomain")
    })
  #expect(log.text.contains("Path: account.remaining"))
  #expect(log.text.contains("Expected to decode Int but found a string instead"))
}

@Test func apiClientKeepsRequestFailuresOutOfTheDefaultLog() async {
  let transport = StubTransport()
  transport.on(path: "/optional", .text("missing", status: 404))
  let log = makeLog()
  let client = APIClient(transport: transport, log: log)

  await #expect(throws: APIError.http(status: 404, body: "missing", retryAfter: nil)) {
    try await client.get(URL(string: "https://example.com/optional")!, headers: [:], operation: "optional")
  }

  #expect(log.snapshot.isEmpty)
}

@Test(arguments: [
  (#"{"account":{}}"#, "account.remaining"),
  (#"{"account":{"remaining":null}}"#, "account.remaining"),
  (#"{"account":{"remaining":"many"}}"#, "account.remaining"),
  ("not json", "<root>"),
])
func apiClientReportsStableDecodingPaths(payload: String, path: String) {
  struct Account: Decodable { let remaining: Int }
  struct Envelope: Decodable { let account: Account }
  let log = makeLog()
  log.debugEnabled = true
  let client = APIClient(transport: StubTransport(), log: log)
  #expect(throws: APIError.decoding("fixture: invalid payload")) {
    try client.decode(Envelope.self, Data(payload.utf8), operation: "fixture")
  }
  #expect(log.text.contains("Path: \(path);"))
}

@Test func apiClientRetainsCustomDecodingFailureDiagnostics() {
  struct Rejected: Decodable {
    enum Failure: Error { case unsupportedVersion }
    init(from decoder: any Decoder) throws { throw Failure.unsupportedVersion }
  }
  let log = makeLog()
  log.debugEnabled = true
  let client = APIClient(transport: StubTransport(), log: log)
  #expect(throws: APIError.decoding("fixture: invalid payload")) {
    try client.decode(Rejected.self, Data("{}".utf8), operation: "fixture")
  }
  #expect(log.text.contains("unsupportedVersion"))
}

@Test func apiErrorClassification() {
  #expect(APIError.http(status: 401, body: "", retryAfter: nil).isAuthenticationFailure)
  #expect(
    APIError.http(
      status: 403, body: #"{"error":{"status":"UNAUTHENTICATED"}}"#, retryAfter: nil
    ).isAuthenticationFailure)
  #expect(!APIError.http(status: 403, body: "", retryAfter: nil).isAuthenticationFailure)
  #expect(
    !APIError.http(
      status: 403, body: #"{"error":{"status":"PERMISSION_DENIED"}}"#, retryAfter: nil
    ).isAuthenticationFailure)
  #expect(!APIError.http(status: 500, body: "", retryAfter: nil).isAuthenticationFailure)
  #expect(!APIError.network("x").isAuthenticationFailure)
  #expect(APIError.http(status: 429, body: "", retryAfter: nil).isRateLimited)
  #expect(!APIError.decoding("x").isRateLimited)
  #expect(APIError.http(status: 500, body: "", retryAfter: nil).message == "HTTP 500")
  #expect(APIError.http(status: 500, body: "boom", retryAfter: nil).message == "HTTP 500")
  #expect(APIError.http(status: 302, body: "", retryAfter: nil).message == "Unexpected redirect (HTTP 302)")
}

@Test func apiClientRedactsURLs() {
  #expect(APIClient.redact(nil) == "-")
  #expect(
    APIClient.redact(URL(string: "https://h/p/ABCDEF12-3456-7890-abcd-ef1234567890/x?q=1")!) == "https://h/p/{id}/x")
  #expect(APIClient.retryAfter(nil, Data()) == nil)
}

@Test func apiClientRejectsMalformedIdentifierShapes() {
  #expect(!APIClient.isIdentifier("not-an-identifier"))
  #expect(!APIClient.isIdentifier("zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"))
  #expect(APIClient.isIdentifier("abcdef12-3456-7890-abcd-ef1234567890"))
}

@Test func apiClientLiveSessionDisablesCachingAndBoundsRequestLifetime() {
  let configuration = APIClient.liveConfiguration()
  #expect(configuration.urlCache == nil)
  #expect(configuration.httpCookieStorage == nil)
  #expect(configuration.urlCredentialStorage == nil)
  #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
  #expect(configuration.timeoutIntervalForRequest == APIClient.timeout)
  #expect(configuration.timeoutIntervalForResource == APIClient.resourceTimeout)
}

@Test func apiClientRedirectPolicyAllowsOnlyTheOriginalOrigin() {
  let source = URL(string: "https://first.test/start")!
  var sameOrigin = URLRequest(url: URL(string: "https://first.test/end")!)
  sameOrigin.setValue("token", forHTTPHeaderField: "X-Secret")
  #expect(APIClient.redirectedRequest(from: source, to: sameOrigin) == sameOrigin)
  #expect(
    APIClient.redirectedRequest(
      from: source, to: URLRequest(url: URL(string: "https://second.test/end")!)) == nil)
  #expect(
    APIClient.redirectedRequest(
      from: source, to: URLRequest(url: URL(string: "http://first.test/end")!)) == nil)
  #expect(APIClient.redirectedRequest(from: nil, to: sameOrigin) == nil)
}

@Test func disabledHTTPTransportRejectsRequests() async {
  do {
    _ = try await DisabledHTTPTransport().data(for: URLRequest(url: endpoint))
    Issue.record("expected failure")
  } catch {
    #expect((error as? URLError)?.code == .unsupportedURL)
  }
}
