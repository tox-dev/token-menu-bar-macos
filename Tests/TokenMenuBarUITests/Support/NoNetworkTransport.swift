import Foundation
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

struct NoNetworkTransport: HTTPTransport {
  func data(for _: URLRequest) async throws -> (Data, URLResponse) {
    throw URLError(.unsupportedURL)
  }
}
