import Foundation

public struct AppInfo: Sendable, Equatable {
  public let name: String
  public let version: String
  public let build: String
  public let bundleIdentifier: String
  public let isAppStore: Bool
  public let repository: URL

  public init(name: String, version: String, build: String, bundleIdentifier: String, isAppStore: Bool, repository: URL)
  {
    self.name = name
    self.version = version
    self.build = build
    self.bundleIdentifier = bundleIdentifier
    self.isAppStore = isAppStore
    self.repository = repository
  }

  public static let repositoryURL = URL(string: "https://github.com/tox-dev/token-menu-bar-macos")!

  public static func from(bundle: Bundle, isAppStore: Bool) -> AppInfo {
    let info = bundle.infoDictionary ?? [:]
    return AppInfo(
      name: info["CFBundleName"] as? String ?? "Token Menu Bar",
      version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
      build: info["CFBundleVersion"] as? String ?? "0",
      bundleIdentifier: bundle.bundleIdentifier ?? "dev.tox.token-menu-bar",
      isAppStore: isAppStore,
      repository: repositoryURL
    )
  }

  public var releasesURL: URL {
    repository.appendingPathComponent("releases")
  }
}

public enum Diagnostics {
  public static let maxIssueURLLength = 8000
  public static let logLines = 80

  @MainActor
  public static func report(
    app: AppInfo, osVersion: String, settings: Settings, state: AppState, historyLocation: URL?, log: LogBuffer,
    now: Date, lines: Int = logLines
  ) -> String {
    var out: [String] = []
    out.append("\(app.name) \(app.version) (\(app.build)) \(app.isAppStore ? "App Store" : "Direct")")
    out.append("macOS \(osVersion)")
    out.append(
      "Refresh every \(settings.refreshSeconds)s, analytics every \(settings.analyticsRefreshMinutes)m, format \(settings.statusFormat.rawValue)"
    )
    out.append("Providers: \(settings.enabledProviders.map(\.rawValue).sorted().joined(separator: ", "))")
    out.append("History: \(historyLocation?.path ?? "in memory")")
    out.append("Last refresh: \(state.lastRefresh.map { Format.relativeAge($0, now: now) } ?? "never")")
    for provider in state.orderedProviders {
      let item = state.state(for: provider)
      out.append(
        "- \(provider.displayName): \(item.availability.rawValue), plan \(item.snapshot?.identity?.planName ?? "-"), windows \(item.snapshot?.windows.map { "\($0.id)=\(Format.percent($0.usedPercent))" }.joined(separator: " ") ?? "-")"
      )
      if let error = item.lastError { out.append("  error: \(error)") }
      if let credential = item.credentialState { out.append("  credentials: \(credential.description)") }
    }
    out.append("")
    out.append("Log (last \(lines) lines):")
    out += log.tail(lines).map(\.line)
    return out.joined(separator: "\n")
  }

  public static func issueURL(repository: URL, title: String, report: String) -> URL {
    let lines = report.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    func candidate(_ count: Int) -> URL {
      build(repository: repository, title: title, body: lines.prefix(count).joined(separator: "\n"))
    }
    var low = 0
    var high = lines.count
    while low < high {
      let mid = (low + high + 1) / 2
      if candidate(mid).absoluteString.count <= maxIssueURLLength {
        low = mid
      } else {
        high = mid - 1
      }
    }
    return candidate(low)
  }

  static func build(repository: URL, title: String, body: String) -> URL {
    var components = URLComponents(
      url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: "```\n\(body)\n```"),
    ]
    return components.url!
  }
}
