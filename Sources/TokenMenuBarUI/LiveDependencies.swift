import AppKit
import TokenMenuBarCore
import UniformTypeIdentifiers
import WidgetKit

public enum LiveDependencies {
  public struct Paths: Sendable {
    public var home: URL
    public var supportDirectory: URL
    public var environment: [String: String]
    public var userName: String
    public var arguments: [String]

    public init(
      home: URL = FileManager.default.homeDirectoryForCurrentUser,
      supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Token Menu Bar"),
      environment: [String: String] = ProcessInfo.processInfo.environment,
      userName: String = NSUserName(),
      arguments: [String] = CommandLine.arguments
    ) {
      self.home = home
      self.supportDirectory = supportDirectory
      self.environment = environment
      self.userName = userName
      self.arguments = arguments
    }

    public var demoRequested: Bool {
      environment["TOKEN_MENU_BAR_DEMO"] != nil || arguments.contains("--demo")
    }
  }

  @MainActor
  public static func make(
    appInfo: AppInfo,
    paths: Paths = Paths(),
    defaults: UserDefaults = .standard,
    notificationCenter: (any NotificationCenterProtocol)?,
    updater: (any UpdaterHook)? = nil,
    isSandboxed: Bool = false,
    transport: any HTTPTransport = URLSession.shared
  ) throws -> AppDependencies {
    let log = LogBuffer(fileURL: paths.supportDirectory.appendingPathComponent("log.json"))
    let settings = TokenMenuBarCore.Settings(defaults: defaults)
    let isDemo = paths.demoRequested || settings.demoMode
    let history = try UsageHistoryStore(
      url: paths.supportDirectory.appendingPathComponent(isDemo ? "usage-demo.sqlite" : "usage.sqlite"))
    if isDemo { seedDemo(history, log: log) }
    let client = APIClient(transport: transport, log: log)
    let build: @MainActor (TokenMenuBarCore.Settings) -> ProviderRegistry = { settings in
      isDemo
        ? ProviderRegistry(ProviderID.allCases.map(DemoProvider.init))
        : providers(paths: paths, client: client, log: log, settings: settings, isSandboxed: isSandboxed)
    }
    let registry = build(settings)
    return AppDependencies(
      appInfo: appInfo,
      settings: settings,
      state: AppState(),
      history: history,
      log: log,
      registry: registry,
      notifier: Notifier(center: notificationCenter, log: log),
      launchAtLogin: LaunchAtLoginService.backend(),
      updater: updater,
      isSandboxed: isSandboxed,
      isDemo: isDemo,
      openURL: { NSWorkspace.shared.open($0) },
      copyToPasteboard: { copy($0, to: .general) },
      revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
      chooseExportURL: { chosen(exportPanel()) { $0.runModal() } },
      chooseDirectory: { chosen(directoryPanel($0, paths: paths)) { $0.runModal() } },
      terminate: { NSApplication.shared.terminate(nil) },
      relaunch: { relaunch(bundle: .main, workspace: NSWorkspace.shared) { NSApplication.shared.terminate(nil) } },
      widgetStore: isDemo ? nil : widgetStore(supportDirectory: paths.supportDirectory),
      snapshotCache: SnapshotCache(
        url: paths.supportDirectory.appendingPathComponent(isDemo ? "snapshots-demo.json" : "snapshots.json")),
      reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
      rebuildProviders: build,
      screenVisibleFrame: { NSScreen.main?.visibleFrame },
      openPopoverOnLaunch: paths.environment["TOKEN_MENU_BAR_OPEN_POPOVER"] != nil
    )
  }

  @MainActor
  public static func providers(
    paths: Paths, client: APIClient, log: LogBuffer, settings: TokenMenuBarCore.Settings, isSandboxed: Bool
  ) -> ProviderRegistry {
    let allowRefresh: @Sendable () -> Bool = { MainActor.assumeIsolated { settings.allowTokenRefresh } }
    let claudeConfigDir = paths.environment["CLAUDE_CONFIG_DIR"]
    // The bookmark only replaces a path the sandbox blocks; the configured location still decides where to look,
    // so CLAUDE_CONFIG_DIR, CODEX_HOME, GEMINI_CLI_HOME and XDG_CONFIG_HOME keep working in both builds.
    let granted: (SandboxResource) -> URL = { resource in
      let configured = resource.configuredURL(environment: paths.environment, home: paths.home)
      guard isSandboxed, let bookmark = settings.bookmark(for: resource) else { return configured }
      return resolve(bookmark: bookmark, fallback: configured, log: log)
    }
    let claudeHome = granted(ProviderID.claude.sandboxResources[0])
    let claude = ClaudeProvider(
      credentials: ChainedClaudeCredentialStore([
        KeychainClaudeCredentialStore(
          service: ClaudeOAuthCredentials.keychainService(configDir: claudeConfigDir), account: paths.userName),
        FileClaudeCredentialStore(url: claudeHome.appendingPathComponent(".credentials.json")),
      ]),
      localAccountURL: granted(ProviderID.claude.sandboxResources[1]),
      transcripts: ClaudeTranscriptReader(root: claudeHome.appendingPathComponent("projects")),
      client: client,
      log: log,
      allowRefresh: allowRefresh
    )
    let codexHome = granted(ProviderID.codex.sandboxResources[0])
    let codex = CodexProvider(
      auth: FileCodexAuthStore(url: codexHome.appendingPathComponent("auth.json")),
      rollouts: CodexRolloutReader(sessionsRoot: codexHome.appendingPathComponent("sessions")),
      client: client,
      log: log,
      allowRefresh: allowRefresh
    )
    let gemini = GeminiProvider(
      auth: FileGeminiAuthStore(
        url: granted(ProviderID.gemini.sandboxResources[0]).appendingPathComponent("oauth_creds.json")),
      client: client,
      log: log,
      allowRefresh: allowRefresh,
      oauthClient: { GeminiOAuthConfig.resolve(environment: paths.environment, home: paths.home) }
    )
    let cursor = CursorProvider(
      auth: ChainedCursorAuthStore([
        CursorStateStore(
          url: granted(ProviderID.cursor.sandboxResources[0])
            .appendingPathComponent("User/globalStorage/state.vscdb")),
        FileCursorAuthStore(
          url: granted(ProviderID.cursor.sandboxResources[1]).appendingPathComponent("auth.json")),
      ]),
      client: client,
      log: log
    )
    let copilot = CopilotProvider(
      auth: FileCopilotAuthStore(
        urls: ["hosts.json", "apps.json"].map {
          granted(ProviderID.copilot.sandboxResources[0]).appendingPathComponent($0)
        }),
      client: client,
      log: log
    )
    return ProviderRegistry([claude, codex, gemini, cursor, copilot])
  }

  public static func widgetStore(
    supportDirectory: URL,
    containerURL: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
    appGroup: String = WidgetSnapshot.appGroup(info: Bundle.main.infoDictionary)
  ) -> WidgetSnapshotStore {
    WidgetSnapshotStore(
      url: WidgetSnapshotStore.sharedURL(
        containerURL: containerURL, fallbackDirectory: supportDirectory, appGroup: appGroup))
  }

  public static func seedDemo(_ history: UsageHistoryStore, log: LogBuffer, now: Date = Date()) {
    Task {
      do {
        guard try await history.stats().sampleCount == 0 else { return }
        try await DemoData.seed(history, providers: ProviderID.allCases, now: now)
        log.log("demo history seeded")
      } catch {
        log.logError("demo history seeding failed: \(error)")
      }
    }
  }

  @MainActor
  public static func relaunch(
    bundle: Bundle, workspace: NSWorkspace, then terminate: @escaping @MainActor @Sendable () -> Void
  ) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    workspace.openApplication(at: bundle.bundleURL, configuration: configuration) { _, _ in
      Task { @MainActor in terminate() }
    }
  }

  /// Resolves a home directory the sandbox would otherwise block, using the bookmark the user granted for it.
  @MainActor
  public static func directory(
    _ resource: SandboxResource, paths: Paths, settings: TokenMenuBarCore.Settings, isSandboxed: Bool, log: LogBuffer
  ) -> URL {
    let configured = resource.configuredURL(environment: paths.environment, home: paths.home)
    guard isSandboxed else { return configured }
    return resolve(bookmark: settings.bookmark(for: resource), fallback: configured, log: log)
  }

  public static func resolve(bookmark: Data?, fallback: URL, log: LogBuffer) -> URL {
    guard let bookmark else { return fallback }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    else {
      log.logError("bookmark could not be resolved; falling back to \(fallback.path)")
      return fallback
    }
    _ = url.startAccessingSecurityScopedResource()
    if stale { log.log("bookmark for \(url.lastPathComponent) is stale; grant access again if reads fail") }
    return url
  }

  public static func copy(_ text: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  @MainActor
  public static func exportPanel() -> NSSavePanel {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = "token-menu-bar-history.csv"
    return panel
  }

  @MainActor
  public static func directoryPanel(_ resource: SandboxResource, paths: Paths) -> NSOpenPanel {
    directoryPanel(
      resource: resource, default: resource.configuredURL(environment: paths.environment, home: paths.home))
  }

  @MainActor
  public static func directoryPanel(resource: SandboxResource, default directory: URL) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = resource.kind == .directory
    panel.canChooseFiles = resource.kind == .file
    panel.showsHiddenFiles = true
    panel.directoryURL = resource.kind == .file ? directory.deletingLastPathComponent() : directory
    panel.message = "Select \(resource.label) so \(resource.provider.displayName) usage can be read."
    return panel
  }

  @MainActor
  public static func chosen<Panel: NSSavePanel>(_ panel: Panel, run: (Panel) -> NSApplication.ModalResponse) -> URL? {
    run(panel) == .OK ? panel.url : nil
  }
}
