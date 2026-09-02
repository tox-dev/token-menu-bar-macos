import Foundation

public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public struct DisabledHTTPTransport: HTTPTransport {
  public init() {}

  public func data(for _: URLRequest) async throws -> (Data, URLResponse) {
    throw URLError(.unsupportedURL)
  }
}

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
    case .http(let status, _, _): "HTTP \(status)"
    case .network(let text): "Network error: \(LogSanitizer.message(text))"
    case .decoding(let text): "Unexpected response: \(LogSanitizer.message(text))"
    }
  }
}

public struct APIClient: Sendable {
  static let bodySnippetLength = 200
  static let liveCacheCapacity = 4 * 1024 * 1024
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

  static func liveConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = URLCache(
      memoryCapacity: liveCacheCapacity,
      diskCapacity: 0,
      diskPath: nil)
    configuration.requestCachePolicy = .useProtocolCachePolicy
    return configuration
  }

  public func get(_ url: URL, headers: [String: String], operation: String) async throws(APIError) -> Data {
    let request = URLRequest(url: url, timeoutInterval: Self.timeout)
    return try await send(request, method: "GET", headers: headers, operation: operation)
  }

  public func post(
    _ url: URL, json body: Data, headers: [String: String], operation: String
  ) async throws(APIError) -> Data {
    var request = URLRequest(url: url, timeoutInterval: Self.timeout)
    request.httpBody = body
    return try await send(
      request, method: "POST", headers: headers.merging(["Content-Type": "application/json"]) { $1 },
      operation: operation)
  }

  public func post(
    _ url: URL, form fields: [String: String], headers: [String: String], operation: String
  ) async throws(APIError) -> Data {
    var request = URLRequest(url: url, timeoutInterval: Self.timeout)
    var components = URLComponents()
    components.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: fields[$0]) }
    request.httpBody = Data(components.percentEncodedQuery!.utf8)
    return try await send(
      request, method: "POST",
      headers: headers.merging(["Content-Type": "application/x-www-form-urlencoded"]) { $1 },
      operation: operation)
  }

  public func getJSON<Payload: Decodable>(
    _ type: Payload.Type, _ url: URL, headers: [String: String], operation: String
  ) async throws(APIError) -> Payload {
    let data = try await get(url, headers: headers, operation: operation)
    return try decode(type, data, operation: operation)
  }

  public func decode<Payload: Decodable>(
    _ type: Payload.Type, _ data: Data, operation: String
  ) throws(APIError) -> Payload {
    do {
      return try decoder.decode(type, from: data)
    } catch {
      let value = error as NSError
      log.logDebug(
        "decode failed operation=\(operation) errorDomain=\(value.domain) errorCode=\(value.code)",
        category: .network)
      throw APIError.decoding("\(operation): invalid payload")
    }
  }

  private func send(
    _ base: URLRequest, method: String, headers: [String: String], operation: String
  ) async throws(APIError) -> Data {
    var request = base
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    let endpoint = Self.redact(request.url)
    let started = clock.now()
    log.logDebug(
      "request started operation=\(operation) id=\(id) method=\(method) endpoint=\(endpoint)",
      category: .network)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(for: request)
    } catch {
      let duration = Int(clock.now().timeIntervalSince(started) * 1000)
      let value = error as NSError
      log.detailed(
        .request(
          RequestDiagnostic(
            requestID: id,
            operation: operation,
            method: method,
            byteCount: 0,
            durationMilliseconds: duration,
            error: error)))
      log.logDebug(
        "request failed operation=\(operation) id=\(id) endpoint=\(endpoint) "
          + "errorDomain=\(value.domain) errorCode=\(value.code)",
        category: .network)
      throw APIError.network(error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let duration = Int(clock.now().timeIntervalSince(started) * 1000)
    log.detailed(
      .request(
        RequestDiagnostic(
          requestID: id,
          operation: operation,
          method: method,
          status: status,
          byteCount: data.count,
          durationMilliseconds: duration)))
    guard (200..<300).contains(status) else {
      let snippet = String(decoding: data.prefix(Self.bodySnippetLength), as: UTF8.self)
      log.logDebug(
        "request rejected operation=\(operation) id=\(id) status=\(status) bytes=\(data.count) "
          + "duration=\(duration)ms",
        category: .network)
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
    // Assigning back through `components.path` would percent-encode the braces, so replace on the rendered string.
    return components.string!.split(separator: "/", omittingEmptySubsequences: false).map {
      isIdentifier($0) ? "{id}" : $0
    }.joined(separator: "/")
  }

  static func isIdentifier(_ component: Substring) -> Bool {
    let groups = component.split(separator: "-", omittingEmptySubsequences: false)
    guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
    return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
  }
}
