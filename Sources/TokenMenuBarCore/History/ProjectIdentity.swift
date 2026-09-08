import CryptoKit
import Foundation

public enum ProjectIdentity {
  public static func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  public static func anonymous(_ identity: String) -> String {
    "Project " + SHA256.hash(data: Data(identity.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }

  public static func labels(_ identities: [String], private: Bool) -> [String: String] {
    let unique = Set(identities)
    if `private` { return Dictionary(uniqueKeysWithValues: unique.map { ($0, anonymous($0)) }) }
    let groups = Dictionary(grouping: unique) { $0.split(separator: "/").last.map(String.init) ?? $0 }
    return Dictionary(
      uniqueKeysWithValues: groups.flatMap { label, paths in
        paths.map { path in
          guard paths.count > 1 else { return (path, label) }
          let components = path.split(separator: "/")
          for depth in 2...max(2, components.count) {
            let suffix = components.suffix(depth).joined(separator: "/")
            if !paths.contains(where: {
              $0 != path && $0.split(separator: "/").suffix(depth).joined(separator: "/") == suffix
            }) {
              return (path, suffix)
            }
          }
          return (path, path)
        }
      })
  }

  public static func exportLabel(_ identity: String, metric: String, hidePersonalInformation: Bool) -> String {
    hidePersonalInformation
      && [AnalyticsMetric.projectCost.rawValue, AnalyticsMetric.projectMessages.rawValue].contains(metric)
      ? anonymous(identity) : identity
  }
}
