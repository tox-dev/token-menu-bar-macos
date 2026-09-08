import Foundation

public enum SystemHTTPTransport {
  public static func make() -> any HTTPTransport {
    URLSession(configuration: APIClient.liveConfiguration(), delegate: LiveSessionDelegate(), delegateQueue: nil)
  }
}

private final class LiveSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(APIClient.redirectedRequest(from: response.url, to: request))
  }

  func urlSession(
    _: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    guard LoopbackTrust.accepts(host: space.host, authenticationMethod: space.authenticationMethod),
      let trust = space.serverTrust
    else { return completionHandler(.performDefaultHandling, nil) }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
}
