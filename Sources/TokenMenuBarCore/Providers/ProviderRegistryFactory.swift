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
    public let readOAuthSource: @Sendable (URL) -> Data?
    public let allowTokenRefresh: @MainActor @Sendable () -> Bool
    public let allowsGeminiTokenRefresh: Bool
    public let analyticsWatermarkPersistence: CodexAnalyticsWatermarkPersistence
    /// Nil in the sandboxed build, where the process table is out of reach and Antigravity reads Cloud Code alone.
    public let processScanner: (any ProcessScanner)?

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
      readOAuthSource: @escaping @Sendable (URL) -> Data?,
      allowTokenRefresh: @escaping @MainActor @Sendable () -> Bool,
      allowsGeminiTokenRefresh: Bool = true,
      analyticsWatermarkPersistence: CodexAnalyticsWatermarkPersistence,
      processScanner: (any ProcessScanner)? = nil
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
      self.readOAuthSource = readOAuthSource
      self.allowTokenRefresh = allowTokenRefresh
      self.allowsGeminiTokenRefresh = allowsGeminiTokenRefresh
      self.analyticsWatermarkPersistence = analyticsWatermarkPersistence
      self.processScanner = processScanner
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
      DiscoveredClaudeKeychainStore(
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
      allowRefresh: configuration.allowTokenRefresh,
      configuredLocalService: ClaudeOAuthCredentials.keychainService(
        configDir: configuration.environment["CLAUDE_CONFIG_DIR"])
    )

    let codexHome = configuration.url(for: ProviderID.codex.sandboxResources[0])
    let codexAuth = CodexAuthStores.discovering(
      configured: codexHome, home: configuration.home, keychain: configuration.keychain)
    let codex = CodexProvider(
      auth: codexAuth,
      rollouts: CodexRolloutReader(sessionsRoot: codexHome.appendingPathComponent("sessions")),
      client: client,
      log: log,
      allowRefresh: configuration.allowTokenRefresh,
      analyticsWatermarkPersistence: configuration.analyticsWatermarkPersistence
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
      allowRefresh: {
        configuration.allowsGeminiTokenRefresh && configuration.allowTokenRefresh()
      },
      oauthClient: {
        GeminiOAuthConfig.resolve(
          environment: configuration.environment, home: configuration.home,
          read: { configuration.readOAuthSource($0).flatMap { String(data: $0, encoding: .utf8) } })
      }
    )

    let antigravity = AntigravityProvider(
      auth: KeychainAntigravityAuthStore(keychain: configuration.keychain),
      client: client,
      log: log,
      allowRefresh: configuration.allowTokenRefresh,
      oauthClient: {
        AntigravityOAuthConfig.resolve(
          environment: configuration.environment, home: configuration.home, read: configuration.readOAuthSource)
      },
      processScanner: configuration.processScanner
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
      [claude, codex, gemini, antigravity, cursor, copilot],
      setupStates: setupStates,
      resourceLeases: configuration.resourceLeases,
      retryCredentialReads: { providers in
        for provider in providers {
          let service: String? =
            switch provider {
            case .claude: ClaudeOAuthCredentials.keychainService
            case .codex: KeychainCodexAuthStore.service
            case .gemini: KeychainGeminiAuthStore.service
            case .antigravity: KeychainAntigravityAuthStore.service
            case .copilot: KeychainCopilotAuthStore.service
            case .cursor: nil
            }
          if let service {
            configuration.keychain.retryDeniedReads(service: service, includingVariants: provider == .claude)
          }
        }
      })
  }
}
