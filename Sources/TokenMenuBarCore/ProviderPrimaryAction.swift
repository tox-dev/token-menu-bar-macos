import Foundation

public enum ProviderPrimaryAction: Sendable, Equatable {
  case refresh
  case retry
  case signIn
  case setup

  public init(availability: QuotaAvailability, issue: ProviderRecoveryIssue?) {
    switch availability {
    case .authenticationRequired, .unavailable:
      switch issue?.kind {
      case .credentialUnreadable, .resourceAccess, .accountUnsupported: self = .setup
      default: self = availability == .authenticationRequired ? .signIn : .retry
      }
    case .networkUnavailable, .rateLimited: self = .retry
    case .disabled: self = .setup
    case .current, .stale, .loading: self = .refresh
    }
  }

  public var title: String {
    switch self {
    case .refresh: "Refresh"
    case .retry: "Retry"
    case .signIn: "Sign in…"
    case .setup: "Set up…"
    }
  }

  public var symbol: String {
    switch self {
    case .refresh, .retry: "arrow.clockwise"
    case .signIn: "key.fill"
    case .setup: "slider.horizontal.3"
    }
  }

  public var explanation: String {
    switch self {
    case .refresh: "Fetches current quota data. Last-known values remain visible if the refresh fails."
    case .retry: "Tries fetching quota again. Last-known values stay muted until a fetch succeeds."
    case .signIn:
      "Starts the provider's login in Terminal when supported, otherwise opens its setup instructions. "
        + "Cached values stay muted until fresh usage arrives."
    case .setup: "Opens the provider's access settings. Repair file permissions or account access before trying again."
    }
  }
}

public enum ProviderLoginCommand: String, Sendable, CaseIterable {
  case claude = "claude auth login"
  case codex = "codex login"
  case cursor = "cursor-agent login"
  case copilot = "copilot login"

  public init?(provider: ProviderID, source: CredentialSource?) {
    switch provider {
    case .claude: self = .claude
    case .codex: self = .codex
    case .cursor where source?.id == "cursor.agent": self = .cursor
    case .copilot where source?.id == "copilot.keychain" || source?.id == "copilot.file": self = .copilot
    case .cursor, .copilot, .gemini, .antigravity: return nil
    }
  }

  public var script: String {
    script(configurationDirectory: nil)
  }

  public static func configurationDirectories(environment: [String: String]) -> [Self: URL] {
    Dictionary(
      uniqueKeysWithValues: allCases.compactMap { command in
        command.configurationVariable.flatMap { environment[$0] }.map { (command, URL(filePath: $0)) }
      })
  }

  public func script(configurationDirectory: URL?) -> String {
    let configuration =
      if let variable = configurationVariable, let configurationDirectory {
        "export \(variable)='\(configurationDirectory.path.replacingOccurrences(of: "'", with: "'\\''"))'\n"
      } else { configurationVariable.map { "unset \($0)\n" } ?? "" }
    return
      """
      #!/bin/zsh -l
      cd || exit 1
      export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
      \(configuration)\(rawValue)
      result=$?
      if (( result == 0 )); then
        print 'Sign-in finished. Return to Token Menu Bar to refresh usage.'
      else
        print 'Sign-in did not finish. Resolve the error above and try again.'
      fi
      exit "$result"

      """
  }

  public func write(in directory: URL, configurationDirectory: URL? = nil) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("\(self).command")
    try Data(script(configurationDirectory: configurationDirectory).utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private var configurationVariable: String? {
    switch self {
    case .claude: "CLAUDE_CONFIG_DIR"
    case .codex: "CODEX_HOME"
    case .copilot: "COPILOT_HOME"
    case .cursor: nil
    }
  }
}

public struct ProviderLoginFlow: Sendable {
  private enum Phase: Sendable { case opening, awaitingReturn }
  private var phases: [ProviderID: Phase] = [:]

  public init() {}

  public mutating func begin(_ provider: ProviderID) -> Bool {
    guard phases[provider] == nil else { return false }
    phases[provider] = .opening
    return true
  }

  public mutating func opened(_ provider: ProviderID) { phases[provider] = .awaitingReturn }
  public mutating func failed(_ provider: ProviderID) { phases[provider] = nil }

  public mutating func takeReturnedProviders() -> Set<ProviderID> {
    let returned = Set(phases.compactMap { $0.value == .awaitingReturn ? $0.key : nil })
    for provider in returned { phases[provider] = nil }
    return returned
  }
}
