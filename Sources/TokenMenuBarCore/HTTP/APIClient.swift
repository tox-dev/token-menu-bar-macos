import Foundation

public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public enum APIError: Error, Equatable, Sendable {
  case http(status: Int, body: String, retryAfter: TimeInterval?)
  case network(String)
  case decoding(String)

  public var isAuthenticationFailure: Bool {
    if case .http(let status, _, _) = self { return status == 401 || status == 403 }
    return false
  }

  public var isRateLimited: Bool {
    if case .http(let status, _, _) = self { return status == 429 }
    return false
  }

  public var retryAfter: TimeInterval? {
    if case .http(_, _, let retryAfter) = self { return retryAfter }
    return nil
  }

  public var message: String {
    switch self {
    case .http(let status, let body, _): body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
    case .network(let text): "Network error: \(text)"
    case .decoding(let text): "Unexpected response: \(text)"
    }
  }
}

public struct APIClient: Sendable {
  public static let bodySnippetLength = 200
  public static let timeout: TimeInterval = 20

  private let transport: any HTTPTransport
  private let log: LogBuffer
  private let clock: Clock
  private let decoder: JSONDecoder

  public init(transport: any HTTPTransport, log: LogBuffer, clock: Clock = .system) {
    self.transport = transport
    self.log = log
    self.clock = clock
    decoder = JSONDecoder()
  }

  public func get(_ url: URL, headers: [String: String], operation: String) async throws(APIError) -> Data {
    var request = URLRequest(url: url, timeoutInterval: Self.timeout)
    request.httpMethod = "GET"
    return try await send(request, headers: headers, operation: operation)
  }

  public func post(
    _ url: URL, json body: Data, headers: [String: String], operation: String
  ) async throws(APIError) -> Data {
    var request = URLRequest(url: url, timeoutInterval: Self.timeout)
    request.httpMethod = "POST"
    request.httpBody = body
    return try await send(
      request, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, operation: operation)
  }

  public func getJSON<T: Decodable>(
    _ type: T.Type, _ url: URL, headers: [String: String], operation: String
  ) async throws(APIError) -> T {
    let data = try await get(url, headers: headers, operation: operation)
    return try decode(type, data, operation: operation)
  }

  public func decode<T: Decodable>(_ type: T.Type, _ data: Data, operation: String) throws(APIError) -> T {
    do {
      return try decoder.decode(type, from: data)
    } catch {
      log.logError("decode failed operation=\(operation) error=\(error)")
      throw APIError.decoding("\(operation): \(error)")
    }
  }

  private func send(_ base: URLRequest, headers: [String: String], operation: String) async throws(APIError) -> Data {
    var request = base
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    let endpoint = Self.redact(request.url)
    let started = clock.now()
    log.logDebug(
      "request started operation=\(operation) id=\(id) method=\(request.httpMethod ?? "GET") endpoint=\(endpoint)")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(for: request)
    } catch {
      log.logError(
        "request failed operation=\(operation) id=\(id) endpoint=\(endpoint) error=\(error.localizedDescription)")
      throw APIError.network(error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let duration = Int(clock.now().timeIntervalSince(started) * 1000)
    log.logDebug(
      "response operation=\(operation) id=\(id) endpoint=\(endpoint) status=\(status) bytes=\(data.count) duration=\(duration)ms"
    )
    guard (200..<300).contains(status) else {
      let snippet = String(decoding: data.prefix(Self.bodySnippetLength), as: UTF8.self)
      log.logError("request rejected operation=\(operation) id=\(id) status=\(status) body=\(snippet)")
      throw APIError.http(
        status: status, body: snippet, retryAfter: Self.retryAfter(response as? HTTPURLResponse, data))
    }
    return data
  }

  static func retryAfter(_ response: HTTPURLResponse?, _ body: Data) -> TimeInterval? {
    if let header = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header) {
      return seconds
    }
    if let json = try? JSONDecoder().decode(JSONValue.self, from: body), let seconds = json["retry_after"]?.doubleValue
    {
      return seconds
    }
    return nil
  }

  static func redact(_ url: URL?) -> String {
    guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "-" }
    components.query = nil
    let uuid = try! Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    return (components.string ?? "-").replacing(uuid, with: "{id}")
  }
}
