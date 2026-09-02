import Foundation
import Testing

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

@Test func apiClientMapsHTTPErrorsWithRetryAfter() async {
  let transport = StubTransport()
  transport.on(path: "/header", .text("slow down", status: 429, headers: ["Retry-After": "120"]))
  transport.on(path: "/body", .text(#"{"retry_after": 30}"#, status: 429))
  transport.on(path: "/plain", .text(String(repeating: "x", count: 300), status: 500))
  let log = makeLog()
  log.debugEnabled = true
  let client = APIClient(transport: transport, log: log)
  await #expect(throws: APIError.http(status: 429, body: "slow down", retryAfter: 120)) {
    try await client.get(URL(string: "https://example.com/header")!, headers: [:], operation: "a")
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
    #expect(body.count == APIClient.bodySnippetLength)
    #expect(retryAfter == nil)
  }
  #expect(!log.text.contains("slow down"))
  #expect(!log.text.contains("retry_after"))
  #expect(!log.text.contains(String(repeating: "x", count: 20)))
  #expect(log.snapshot.contains { $0.category == .network && $0.message.contains("status=429") })
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

@Test func apiErrorClassification() {
  #expect(APIError.http(status: 401, body: "", retryAfter: nil).isAuthenticationFailure)
  #expect(APIError.http(status: 403, body: "", retryAfter: nil).isAuthenticationFailure)
  #expect(!APIError.http(status: 500, body: "", retryAfter: nil).isAuthenticationFailure)
  #expect(!APIError.network("x").isAuthenticationFailure)
  #expect(APIError.http(status: 429, body: "", retryAfter: nil).isRateLimited)
  #expect(!APIError.decoding("x").isRateLimited)
  #expect(APIError.http(status: 500, body: "", retryAfter: nil).message == "HTTP 500")
  #expect(APIError.http(status: 500, body: "boom", retryAfter: nil).message == "HTTP 500")
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

@Test func apiClientLiveSessionUsesBoundedMemoryCache() {
  let configuration = APIClient.liveConfiguration()
  #expect(configuration.urlCache?.memoryCapacity == APIClient.liveCacheCapacity)
  #expect(configuration.urlCache?.diskCapacity == 0)
  #expect(configuration.httpCookieStorage == nil)
  #expect(configuration.urlCredentialStorage == nil)
  #expect(configuration.requestCachePolicy == .useProtocolCachePolicy)
}

@Test func disabledHTTPTransportRejectsRequests() async {
  do {
    _ = try await DisabledHTTPTransport().data(for: URLRequest(url: endpoint))
    Issue.record("expected failure")
  } catch {
    #expect((error as? URLError)?.code == .unsupportedURL)
  }
}
