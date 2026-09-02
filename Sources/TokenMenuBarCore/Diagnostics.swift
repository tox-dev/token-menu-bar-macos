import Foundation

public enum DistributionChannel: String, CaseIterable, Codable, Sendable {
  case direct
  case appStore
  case homebrew

  public init?(configurationValue: String) {
    switch configurationValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "direct": self = .direct
    case "app store", "appstore": self = .appStore
    case "homebrew": self = .homebrew
    default: return nil
    }
  }

  public var displayName: String {
    switch self {
    case .direct: "Direct"
    case .appStore: "App Store"
    case .homebrew: "Homebrew"
    }
  }

  public var isAppStore: Bool { self == .appStore }
  public var allowsSelfUpdate: Bool { self == .direct }
}

public struct AppInfo: Sendable, Equatable {
  public let name: String
  public let version: String
  /// The git-derived version, `1.2.4.dev5+gabc123` off a tag, so a bug report from a dev build names its commit.
  public let sourceVersion: String
  public let build: String
  public let bundleIdentifier: String
  public let distribution: DistributionChannel
  public let selfUpdateEnabled: Bool
  public let repository: URL

  public init(
    name: String, version: String, sourceVersion: String? = nil, build: String, bundleIdentifier: String,
    distribution: DistributionChannel, selfUpdateEnabled: Bool = false, repository: URL
  ) {
    self.name = name
    self.version = version
    self.sourceVersion = sourceVersion ?? version
    self.build = build
    self.bundleIdentifier = bundleIdentifier
    self.distribution = distribution
    self.selfUpdateEnabled = selfUpdateEnabled
    self.repository = repository
  }

  public init(
    name: String, version: String, sourceVersion: String? = nil, build: String, bundleIdentifier: String,
    isAppStore: Bool, repository: URL
  ) {
    self.init(
      name: name, version: version, sourceVersion: sourceVersion, build: build, bundleIdentifier: bundleIdentifier,
      distribution: isAppStore ? .appStore : .direct, repository: repository)
  }

  /// True when this build came from somewhere other than a release tag, which is worth saying out loud in About.
  public var isPrerelease: Bool {
    sourceVersion.contains(".dev")
  }

  public var isAppStore: Bool { distribution.isAppStore }
  public var canSelfUpdate: Bool { distribution.allowsSelfUpdate && selfUpdateEnabled }

  public static let repositoryURL = URL(string: "https://github.com/tox-dev/token-menu-bar-macos")!

  public static func from(bundle: Bundle, isAppStore: Bool) -> AppInfo {
    from(bundle: bundle, distribution: isAppStore ? .appStore : .direct)
  }

  public static func from(bundle: Bundle, distribution fallback: DistributionChannel) -> AppInfo {
    let info = bundle.infoDictionary ?? [:]
    return AppInfo(
      name: info["CFBundleName"] as? String ?? "Token Menu Bar",
      version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
      sourceVersion: info["TMBSourceVersion"] as? String,
      build: info["CFBundleVersion"] as? String ?? "0",
      bundleIdentifier: bundle.bundleIdentifier ?? "dev.tox.token-menu-bar",
      distribution: (info["TMBDistribution"] as? String).flatMap(DistributionChannel.init(configurationValue:))
        ?? fallback,
      selfUpdateEnabled: (info["TMBSelfUpdateEnabled"] as? String)?.localizedCaseInsensitiveCompare("YES")
        == .orderedSame,
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
    out.append("\(app.name) \(app.sourceVersion) (\(app.build)) \(app.distribution.displayName)")
    out.append("macOS \(osVersion)")
    out.append(
      "Refresh "
        + ProviderID.allCases.map { "\($0.rawValue) \(settings.refreshInterval(for: $0))s" }
        .joined(separator: ", ")
        + ", analytics every \(settings.analyticsRefreshMinutes)m, format \(settings.statusFormat.rawValue)"
    )
    let activeProviders = settings.activeProviders(states: state.providers)
    out.append("Providers: \(activeProviders.map(\.rawValue).sorted().joined(separator: ", "))")
    out.append("History: \(historyLocation?.path ?? "in memory")")
    out.append("Last refresh: \(state.lastRefresh.map { Format.relativeAge($0, now: now) } ?? "never")")
    for provider in state.orderedProviders where activeProviders.contains(provider) {
      let item = state.state(for: provider)
      out.append(
        "- \(provider.displayName): \(item.availability.rawValue), "
          + "plan \(item.snapshot?.identity?.planName ?? "-"), windows \(windowSummary(item))"
      )
      if let error = item.lastError { out.append("  error: \(error)") }
      if let credential = item.credentialState { out.append("  credentials: \(credential.description)") }
    }
    out.append("")
    out.append("Log (last \(lines) lines):")
    out += log.tail(lines).map(\.line)
    return LogSanitizer.redact(out.joined(separator: "\n"))
  }

  static func windowSummary(_ state: ProviderState) -> String {
    guard let windows = state.snapshot?.windows, !windows.isEmpty else { return "-" }
    return windows.map { "\($0.id)=\(Format.percent($0.usedPercent))" }.joined(separator: " ")
  }

  public static func issueURL(repository: URL, title: String, report: String) -> URL {
    let lines = LogSanitizer.redact(report).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
