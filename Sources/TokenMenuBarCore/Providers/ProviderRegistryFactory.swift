import Foundation

public enum ProviderRegistryFactory {
  public struct Configuration: Sendable {
    public let home: URL
    public let supportDirectory: URL
    public let environment: [String: String]
    public let userName: String
    public let resourceURLs: [String: URL]
    public let resourceAccess: [ProviderID: [ResourceAccessState]]
    public let resourceLeases: [SecurityScopedResourceLease]
    public let enabledProviders: Set<ProviderID>
    public let keychain: KeychainCredentialClient
    public let allowTokenRefresh: @MainActor @Sendable () -> Bool

    public init(
      home: URL,
      supportDirectory: URL,
      environment: [String: String],
      userName: String,
      resourceURLs: [String: URL],
      resourceAccess: [ProviderID: [ResourceAccessState]] = [:],
      resourceLeases: [SecurityScopedResourceLease] = [],
      enabledProviders: Set<ProviderID>,
      keychain: KeychainCredentialClient,
      allowTokenRefresh: @escaping @MainActor @Sendable () -> Bool
    ) {
      self.home = home
      self.supportDirectory = supportDirectory
      self.environment = environment
      self.userName = userName
      self.resourceURLs = resourceURLs
      self.resourceAccess = resourceAccess
      self.resourceLeases = resourceLeases
      self.enabledProviders = enabledProviders
      self.keychain = keychain
      self.allowTokenRefresh = allowTokenRefresh
    }

    fileprivate func url(for resource: SandboxResource) -> URL {
      resourceURLs[resource.id] ?? resource.configuredURL(environment: environment, home: home)
    }
  }

  public static func resourcesRequiringSandboxAccess(environment: [String: String]) -> Set<SandboxResource> {
    let copilotEnvironment = EnvironmentCopilotAuthStore(environment: environment)
    let copilotSource = (try? copilotEnvironment.load()).map { _ in copilotEnvironment.source }
    return Set(
      ProviderID.allCases.flatMap { provider in
        provider.needsSandboxResources(for: provider == .copilot ? copilotSource : nil)
          ? provider.sandboxResources
          : []
      })
  }

  public static func make(
    configuration: Configuration,
    client: APIClient,
    log: LogBuffer
  ) -> ProviderRegistry {
    let claudeHome = configuration.url(for: ProviderID.claude.sandboxResources[0])
    let claudeCredentials = ChainedClaudeCredentialStore([
      KeychainClaudeCredentialStore(
        service: ClaudeOAuthCredentials.keychainService(
          configDir: configuration.environment["CLAUDE_CONFIG_DIR"]),
        account: configuration.userName,
        keychain: configuration.keychain),
      FileClaudeCredentialStore(url: claudeHome.appendingPathComponent(".credentials.json")),
    ])
    let claude = ClaudeProvider(
      credentials: claudeCredentials,
      localAccountURL: configuration.url(for: ProviderID.claude.sandboxResources[1]),
      transcripts: ClaudeTranscriptReader(
        root: claudeHome.appendingPathComponent("projects"),
        stateURL: configuration.supportDirectory.appendingPathComponent("claude-transcript-offsets.json")),
      client: client,
      log: log,
      allowRefresh: configuration.allowTokenRefresh
    )

    let codexHome = configuration.url(for: ProviderID.codex.sandboxResources[0])
    let codexFile = FileCodexAuthStore(url: codexHome.appendingPathComponent("auth.json"))
    let codexAuth: any CodexAuthStore =
      switch CodexCredentialStorageReader.load(from: codexHome.appendingPathComponent("config.toml")) {
      case .file: codexFile
      case .automatic, .keyring, .unknown:
        ChainedCodexAuthStore([
          KeychainCodexAuthStore(
            account: KeychainCodexAuthStore.account(codexHome: codexHome), keychain: configuration.keychain),
          codexFile,
        ])
      }
    let codex = CodexProvider(
      auth: codexAuth,
      rollouts: CodexRolloutReader(sessionsRoot: codexHome.appendingPathComponent("sessions")),
      client: client,
      log: log,
      allowRefresh: configuration.allowTokenRefresh
    )

    let geminiHome = configuration.url(for: ProviderID.gemini.sandboxResources[0])
    let geminiFile = FileGeminiAuthStore(url: geminiHome.appendingPathComponent("oauth_creds.json"))
    let geminiAuth: any GeminiAuthStore =
      switch GeminiCredentialStorage.resolve(environment: configuration.environment) {
      case .file: geminiFile
      case .keychain:
        ChainedGeminiAuthStore([
          KeychainGeminiAuthStore(service: KeychainGeminiAuthStore.service, keychain: configuration.keychain),
          geminiFile,
        ])
      }
    let gemini = GeminiProvider(
      auth: geminiAuth,
      client: client,
      log: log,
      allowRefresh: configuration.allowTokenRefresh,
      oauthClient: { GeminiOAuthConfig.resolve(environment: configuration.environment, home: configuration.home) }
    )

    let cursorAuth = ChainedCursorAuthStore([
      CursorStateStore(
        url: configuration.url(for: ProviderID.cursor.sandboxResources[0])
          .appendingPathComponent("User/globalStorage/state.vscdb")),
      FileCursorAuthStore(
        url: configuration.url(for: ProviderID.cursor.sandboxResources[1]).appendingPathComponent("auth.json")),
    ])
    let cursor = CursorProvider(auth: cursorAuth, client: client, log: log)

    let copilotHome = configuration.url(for: ProviderID.copilot.sandboxResources[0])
    let copilotLegacy = configuration.url(for: ProviderID.copilot.sandboxResources[1])
    let copilotConfig = FileCopilotCLIAuthStore(url: copilotHome.appendingPathComponent("config.json"))
    let copilotAuth = ChainedCopilotAuthStore([
      EnvironmentCopilotAuthStore(environment: configuration.environment),
      KeychainCopilotAuthStore(
        service: KeychainCopilotAuthStore.service,
        accounts: copilotConfig.keychainAccounts(),
        keychain: configuration.keychain),
      copilotConfig,
      FileCopilotAuthStore(
        urls: ["hosts.json", "apps.json"].map { copilotLegacy.appendingPathComponent($0) }),
    ])
    let copilot = CopilotProvider(auth: copilotAuth, client: client, log: log)

    let setupStates = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { provider in
        (
          provider,
          ProviderSetupState.from(
            provider: provider,
            enabled: configuration.enabledProviders.contains(provider),
            credential: .unchecked,
            resources: configuration.resourceAccess[provider] ?? [])
        )
      })
    return ProviderRegistry(
      [claude, codex, gemini, cursor, copilot],
      setupStates: setupStates,
      resourceLeases: configuration.resourceLeases)
  }
}
