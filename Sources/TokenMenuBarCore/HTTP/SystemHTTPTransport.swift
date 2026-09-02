import Foundation

public enum SystemHTTPTransport {
  public static func make() -> any HTTPTransport {
    URLSession(configuration: APIClient.liveConfiguration())
  }
}
