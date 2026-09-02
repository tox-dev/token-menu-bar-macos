import Foundation

public struct CredentialSource: Sendable, Equatable, Hashable, Identifiable {
  public let id: String
  public let provider: ProviderID
  public let title: String
  public let detail: String

  public init(id: String, provider: ProviderID, title: String, detail: String) {
    self.id = id
    self.provider = provider
    self.title = title
    self.detail = detail
  }
}

public struct CredentialReadFailure: Error, Sendable, Equatable, CustomStringConvertible {
  public let source: CredentialSource
  public let detail: String

  public init(source: CredentialSource, detail: String) {
    self.source = source
    self.detail = detail
  }

  public init(source: CredentialSource, error: any Error) {
    if let failure = error as? CredentialReadFailure {
      self = failure
    } else {
      self.init(source: source, detail: String(describing: error))
    }
  }

  public var description: String { detail }
}

public enum ProviderCredentialHealth: Sendable, Equatable {
  case unchecked
  case missing(expected: [CredentialSource])
  case valid(source: CredentialSource, expiresAt: Date?)
  case expired(source: CredentialSource, at: Date)
  case unreadable(source: CredentialSource?, detail: String)

  public var source: CredentialSource? {
    switch self {
    case .valid(let source, _), .expired(let source, _): source
    case .unreadable(let source, _): source
    case .unchecked, .missing: nil
    }
  }

  public var isUsable: Bool {
    if case .valid = self { return true }
    return false
  }

  public static func from(
    _ state: CredentialState,
    source: CredentialSource,
    expected: [CredentialSource]
  ) -> ProviderCredentialHealth {
    switch state {
    case .missing: .missing(expected: expected)
    case .valid(let expiresAt): .valid(source: source, expiresAt: expiresAt)
    case .expired(let date): .expired(source: source, at: date)
    }
  }

  static func from(readError: any Error, fallbackSource: CredentialSource) -> ProviderCredentialHealth {
    let failure = CredentialReadFailure(source: fallbackSource, error: readError)
    return .unreadable(source: failure.source, detail: failure.detail)
  }
}

public enum ProviderServiceHealth: Sendable, Equatable {
  case unchecked
  case checking
  case available
  case offline(detail: String)
  case rateLimited(retryAt: Date?, detail: String)
  case unavailable(detail: String)

  public static func from(
    availability: QuotaAvailability,
    detail: String?,
    retryAt: Date? = nil
  ) -> ProviderServiceHealth {
    switch availability {
    case .loading: .checking
    case .current, .stale: .available
    case .networkUnavailable: .offline(detail: detail ?? "The provider could not be reached.")
    case .rateLimited: .rateLimited(retryAt: retryAt, detail: detail ?? "The provider is rate limiting requests.")
    case .authenticationRequired, .unavailable: .unavailable(detail: detail ?? availability.title)
    case .disabled: .unchecked
    }
  }
}

public enum ResourceAccessHealth: Sendable, Equatable {
  case notRequired
  case needed
  case granted
  case stale
  case error(String)
}

public struct ResourceAccessState: Sendable, Equatable, Identifiable {
  public let resource: SandboxResource
  public let health: ResourceAccessHealth
  public let isRequired: Bool

  public var id: String { resource.id }

  public init(resource: SandboxResource, health: ResourceAccessHealth, isRequired: Bool = true) {
    self.resource = resource
    self.health = health
    self.isRequired = isRequired
  }

  public static func notRequired(_ resource: SandboxResource) -> ResourceAccessState {
    ResourceAccessState(resource: resource, health: .notRequired, isRequired: false)
  }
}

public enum ProviderRecoveryAction: Sendable, Equatable {
  case copyCommand(String)
  case checkAgain
  case refreshProvider(ProviderID)
  case grantAccess(SandboxResource)
  case openLoginItems
  case contactAdministrator

  public var title: String {
    switch self {
    case .copyCommand: "Copy command"
    case .checkAgain: "Check again"
    case .refreshProvider: "Check again"
    case .grantAccess: "Grant access"
    case .openLoginItems: "Open Login Items"
    case .contactAdministrator: "Contact administrator"
    }
  }
}

public struct ProviderRecoveryIssue: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case credentialMissing
    case credentialExpired
    case credentialUnreadable
    case resourceAccess
    case network
    case rateLimited
    case service
    case accountUnsupported
    case credentialPersistence
  }

  public let kind: Kind
  public let title: String
  public let detail: String
  public let action: ProviderRecoveryAction

  public init(kind: Kind, title: String, detail: String, action: ProviderRecoveryAction) {
    self.kind = kind
    self.title = title
    self.detail = detail
    self.action = action
  }

  public static func unsupportedAccount(provider: ProviderID, detail: String) -> ProviderRecoveryIssue {
    ProviderRecoveryIssue(
      kind: .accountUnsupported,
      title: "\(provider.displayName) account is not supported",
      detail: detail,
      action: provider.setup.missingCredentialIssue.action)
  }
}

public struct ProviderSetupState: Sendable, Equatable {
  public var enabled: Bool
  public var credential: ProviderCredentialHealth
  public var service: ProviderServiceHealth
  public var resources: [ResourceAccessState]
  public var issue: ProviderRecoveryIssue?

  public init(
    enabled: Bool,
    credential: ProviderCredentialHealth = .unchecked,
    service: ProviderServiceHealth = .unchecked,
    resources: [ResourceAccessState] = [],
    issue: ProviderRecoveryIssue? = nil
  ) {
    self.enabled = enabled
    self.credential = credential
    self.service = service
    self.resources = resources
    self.issue = issue
  }

  public static func from(
    provider: ProviderID,
    enabled: Bool,
    credentialState: CredentialState,
    source: CredentialSource,
    resources: [ResourceAccessState]
  ) -> ProviderSetupState {
    let credential = ProviderCredentialHealth.from(
      credentialState, source: source, expected: provider.setup.credentialSources)
    var state = from(provider: provider, enabled: enabled, credential: credential, resources: resources)
    if case .missing(let detail) = credentialState, state.issue?.kind != .resourceAccess {
      state.issue = ProviderRecoveryIssue(
        kind: .credentialMissing,
        title: provider.setup.signInTitle,
        detail: detail,
        action: provider.setup.missingCredentialIssue.action)
    }
    return state
  }

  public static func from(
    provider: ProviderID,
    enabled: Bool,
    credential: ProviderCredentialHealth,
    resources: [ResourceAccessState]
  ) -> ProviderSetupState {
    var issue: ProviderRecoveryIssue?
    switch credential {
    case .unchecked, .valid:
      break
    case .missing:
      issue = provider.setup.missingCredentialIssue
    case .expired:
      issue = ProviderRecoveryIssue(
        kind: .credentialExpired,
        title: "\(provider.displayName) sign-in expired",
        detail: provider.setup.signInDetail,
        action: provider.setup.missingCredentialIssue.action)
    case .unreadable(_, let detail):
      issue = ProviderRecoveryIssue(
        kind: .credentialUnreadable,
        title: "\(provider.displayName) credentials could not be read",
        detail: detail,
        action: .refreshProvider(provider))
    }
    if !credential.isUsable,
      let resource = resources.first(where: { $0.isRequired && $0.health != .granted })
    {
      issue = ProviderRecoveryIssue(
        kind: .resourceAccess,
        title: resource.health == .stale ? "Access grant needs renewal" : "File access needed",
        detail: "Grant access to \(resource.resource.label) so \(provider.displayName) data can be read.",
        action: .grantAccess(resource.resource))
    }
    return ProviderSetupState(
      enabled: enabled, credential: credential, resources: resources, issue: issue)
  }
}

public struct ProviderSetupMetadata: Sendable, Equatable {
  public let provider: ProviderID
  public let signInTitle: String
  public let signInDetail: String
  public let signInCommand: String?
  public let credentialSources: [CredentialSource]

  public init(
    provider: ProviderID,
    signInTitle: String,
    signInDetail: String,
    signInCommand: String?,
    credentialSources: [CredentialSource]
  ) {
    self.provider = provider
    self.signInTitle = signInTitle
    self.signInDetail = signInDetail
    self.signInCommand = signInCommand
    self.credentialSources = credentialSources
  }

  public var missingCredentialIssue: ProviderRecoveryIssue {
    ProviderRecoveryIssue(
      kind: .credentialMissing,
      title: signInTitle,
      detail: signInDetail,
      action: signInCommand.map(ProviderRecoveryAction.copyCommand) ?? .refreshProvider(provider))
  }
}

extension ProviderRecoveryIssue {
  public static func credentialPersistence(provider: ProviderID, detail: String) -> ProviderRecoveryIssue {
    ProviderRecoveryIssue(
      kind: .credentialPersistence,
      title: "\(provider.displayName) sign-in could not be saved",
      detail: detail,
      action: .refreshProvider(provider))
  }
}

extension ProviderID {
  public func credentialSource(_ id: String) -> CredentialSource {
    setup.credentialSources.first { $0.id == id }
      ?? CredentialSource(id: id, provider: self, title: "Local credentials", detail: "A local credential source.")
  }

  public func needsSandboxResources(for credentialSource: CredentialSource?) -> Bool {
    self != .copilot || credentialSource?.id != "copilot.environment"
  }

  public var setup: ProviderSetupMetadata {
    let sources: [CredentialSource]
    let title: String
    let detail: String
    let command: String?
    switch self {
    case .claude:
      sources = [
        CredentialSource(
          id: "claude.keychain", provider: self, title: "Claude Code Keychain",
          detail: "The sign-in maintained by Claude Code."),
        CredentialSource(
          id: "claude.file", provider: self, title: "Claude credential file",
          detail: "The file fallback under the Claude configuration directory."),
      ]
      title = "Sign in to Claude Code"
      detail = "Run Claude Code once and complete its sign-in. Token Menu Bar reads that local session."
      command = "claude"
    case .codex:
      sources = [
        CredentialSource(
          id: "codex.keyring", provider: self, title: "Codex keychain",
          detail: "Used when cli_auth_credentials_store is keyring or auto."),
        CredentialSource(
          id: "codex.file", provider: self, title: "Codex auth.json",
          detail: "Used when cli_auth_credentials_store is file or its file fallback is present."),
      ]
      title = "Sign in to Codex"
      detail = "Sign in with the Codex CLI. Token Menu Bar follows the credential store selected in config.toml."
      command = "codex login"
    case .gemini:
      sources = [
        CredentialSource(
          id: "gemini.keychain", provider: self, title: "Gemini CLI Keychain",
          detail: "Used when encrypted credential storage is enabled for Gemini CLI."),
        CredentialSource(
          id: "gemini.file", provider: self, title: "Gemini oauth_creds.json",
          detail: "The standard Gemini CLI credential file."),
      ]
      title = "Sign in to Gemini CLI"
      detail = "Run Gemini CLI and choose Sign in with Google. Token Menu Bar reads that local session."
      command = "gemini"
    case .cursor:
      sources = [
        CredentialSource(
          id: "cursor.app", provider: self, title: "Cursor app session",
          detail: "The session in Cursor's local application database."),
        CredentialSource(
          id: "cursor.agent", provider: self, title: "Cursor Agent auth.json",
          detail: "The session created by cursor-agent login."),
      ]
      title = "Sign in to Cursor"
      detail = "Sign in in Cursor or use Cursor Agent. Token Menu Bar checks both local sessions."
      command = "cursor-agent login"
    case .copilot:
      sources = [
        CredentialSource(
          id: "copilot.environment", provider: self, title: "GitHub token environment",
          detail: "COPILOT_GITHUB_TOKEN, GH_TOKEN or GITHUB_TOKEN, in that order."),
        CredentialSource(
          id: "copilot.keychain", provider: self, title: "GitHub Copilot CLI Keychain",
          detail: "The current Copilot CLI session in macOS Keychain."),
        CredentialSource(
          id: "copilot.file", provider: self, title: "GitHub Copilot CLI config.json",
          detail: "The plaintext fallback under COPILOT_HOME when Keychain is unavailable."),
        CredentialSource(
          id: "copilot.legacy-file", provider: self, title: "GitHub Copilot extension files",
          detail: "Existing hosts.json and apps.json sessions remain supported."),
      ]
      title = "Sign in to GitHub Copilot"
      detail = "Sign in from GitHub Copilot CLI or a supported editor, then check again."
      command = "copilot login"
    }
    return ProviderSetupMetadata(
      provider: self, signInTitle: title, signInDetail: detail, signInCommand: command,
      credentialSources: sources)
  }
}
