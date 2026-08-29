import AppKit
import TokenMenuBarCore
import UniformTypeIdentifiers

public enum LiveDependencies {
  public struct Paths: Sendable {
    public var home: URL
    public var supportDirectory: URL
    public var environment: [String: String]
    public var userName: String

    public init(
      home: URL = FileManager.default.homeDirectoryForCurrentUser,
      supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Token Menu Bar"),
      environment: [String: String] = ProcessInfo.processInfo.environment,
      userName: String = NSUserName()
    ) {
      self.home = home
      self.supportDirectory = supportDirectory
      self.environment = environment
      self.userName = userName
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
    let history = try UsageHistoryStore(url: paths.supportDirectory.appendingPathComponent("usage.sqlite"))
    let client = APIClient(transport: transport, log: log)
    let build: @MainActor (TokenMenuBarCore.Settings) -> ProviderRegistry = { settings in
      providers(paths: paths, client: client, log: log, settings: settings, isSandboxed: isSandboxed)
    }
    let codexHome = paths.home.appendingPathComponent(".codex")
    return AppDependencies(
      appInfo: appInfo,
      settings: settings,
      state: AppState(),
      history: history,
      log: log,
      registry: build(settings),
      notifier: Notifier(center: notificationCenter, log: log),
      launchAtLogin: LaunchAtLoginService.backend(),
      updater: updater,
      isSandboxed: isSandboxed,
      openURL: { NSWorkspace.shared.open($0) },
      copyToPasteboard: { copy($0, to: .general) },
      revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
      chooseExportURL: { chosen(exportPanel()) { $0.runModal() } },
      chooseCodexHome: { chosen(codexHomePanel(default: codexHome)) { $0.runModal() } },
      terminate: { NSApplication.shared.terminate(nil) },
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
    let claudeHome = claudeConfigDir.map { URL(fileURLWithPath: $0) } ?? paths.home.appendingPathComponent(".claude")
    let claudeStore = ChainedClaudeCredentialStore([
      KeychainClaudeCredentialStore(
        service: ClaudeOAuthCredentials.keychainService(configDir: claudeConfigDir), account: paths.userName),
      FileClaudeCredentialStore(url: claudeHome.appendingPathComponent(".credentials.json")),
    ])
    let claude = ClaudeProvider(
      credentials: claudeStore,
      localAccountURL: paths.home.appendingPathComponent(".claude.json"),
      transcripts: ClaudeTranscriptReader(root: claudeHome.appendingPathComponent("projects")),
      client: client,
      log: log,
      allowRefresh: allowRefresh
    )
    let codexHome = codexHome(paths: paths, bookmark: isSandboxed ? settings.codexHomeBookmark : nil, log: log)
    let codex = CodexProvider(
      auth: FileCodexAuthStore(url: codexHome.appendingPathComponent("auth.json")),
      rollouts: CodexRolloutReader(sessionsRoot: codexHome.appendingPathComponent("sessions")),
      client: client,
      log: log,
      allowRefresh: allowRefresh
    )
    return ProviderRegistry([claude, codex])
  }

  public static func codexHome(paths: Paths, bookmark: Data?, log: LogBuffer) -> URL {
    let fallback = FileCodexAuthStore.defaultURL(environment: paths.environment, home: paths.home)
      .deletingLastPathComponent()
    guard let bookmark else { return fallback }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    else {
      log.logError("codex home bookmark could not be resolved; falling back to \(fallback.path)")
      return fallback
    }
    _ = url.startAccessingSecurityScopedResource()
    if stale { log.log("codex home bookmark is stale; grant access again if reads fail") }
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
  public static func codexHomePanel(default directory: URL) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.showsHiddenFiles = true
    panel.directoryURL = directory
    panel.message = "Select your ~/.codex folder so the app can read auth.json and session logs."
    return panel
  }

  @MainActor
  public static func chosen<Panel: NSSavePanel>(_ panel: Panel, run: (Panel) -> NSApplication.ModalResponse) -> URL? {
    run(panel) == .OK ? panel.url : nil
  }
}
