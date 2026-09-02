import Foundation
import TokenMenuBarCore

final class StubTransport: HTTPTransport, @unchecked Sendable {
  struct Response {
    let status: Int
    let body: Data
    let headers: [String: String]

    init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
      self.status = status
      self.body = body
      self.headers = headers
    }

    static func json(_ name: String, status: Int = 200) -> Response {
      Response(status: status, body: Fixtures.data(name))
    }

    static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
      Response(status: status, body: Data(text.utf8), headers: headers)
    }
  }

  enum Rule {
    case respond(Response)
    case respondRaw(Data, URLResponse)
    case fail(any Error)
  }

  private let lock = NSLock()
  private var rules: [(match: (URLRequest) -> Bool, rule: Rule)] = []
  private(set) var requests: [URLRequest] = []

  init() {}

  func on(_ predicate: @escaping (URLRequest) -> Bool, _ rule: Rule) {
    lock.withLock { rules.append((predicate, rule)) }
  }

  func on(path: String, _ response: Response) {
    on({ $0.url?.path.hasSuffix(path) == true }, .respond(response))
  }

  func on(path: String, error: any Error) {
    on({ $0.url?.path.hasSuffix(path) == true }, .fail(error))
  }

  func on(path: String, data: Data, response: URLResponse) {
    on({ $0.url?.path.hasSuffix(path) == true }, .respondRaw(data, response))
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let rule = lock.withLock { () -> Rule? in
      requests.append(request)
      return rules.first { $0.match(request) }?.rule
    }
    switch rule {
    case .respond(let response):
      let http = HTTPURLResponse(
        url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: response.headers)!
      return (response.body, http)
    case .respondRaw(let data, let response):
      return (data, response)
    case .fail(let error):
      throw error
    case nil:
      throw URLError(.unsupportedURL)
    }
  }

  func requests(matching path: String) -> [URLRequest] {
    lock.withLock { requests.filter { $0.url?.path.hasSuffix(path) == true } }
  }
}
