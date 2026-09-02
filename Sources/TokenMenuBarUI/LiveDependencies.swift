import AppKit
import TokenMenuBarCore
import UniformTypeIdentifiers
import WidgetKit

public enum LiveDependencies {
  public typealias WorkspaceOpen =
    @MainActor @Sendable (
      URL, NSWorkspace.OpenConfiguration, @escaping @Sendable () -> Void
    ) -> Void

  public struct Paths: Sendable {
    public var home: URL
    public var supportDirectory: URL
    public var environment: [String: String]
    public var userName: String
    public var arguments: [String]
    public var verificationProfile: VerificationProfile?

    public init(
      home: URL = FileManager.default.homeDirectoryForCurrentUser,
      supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Token Menu Bar"),
      environment: [String: String] = ProcessInfo.processInfo.environment,
      userName: String = NSUserName(),
      arguments: [String] = CommandLine.arguments,
      verificationProfile: VerificationProfile? = nil
    ) {
      self.home = home
      self.supportDirectory = supportDirectory
      self.environment = environment
      self.userName = userName
      self.arguments = arguments
      self.verificationProfile = verificationProfile
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
    transport: any HTTPTransport,
    keychain: KeychainCredentialClient,
    launchAtLogin: LaunchAtLoginBackend,
    workspaceOpen: WorkspaceOpen? = nil
  ) async throws -> AppDependencies {
    let log = LogBuffer(fileURL: paths.supportDirectory.appendingPathComponent("log.txt"))
    let settings = TokenMenuBarCore.Settings(defaults: defaults)
    let isDemo = settings.demoMode ?? paths.demoRequested
    let history = try UsageHistoryStore(
      url: paths.supportDirectory.appendingPathComponent(isDemo ? "usage-demo.sqlite" : "usage.sqlite"),
      retentionDays: settings.historyRetentionDays)
    let resolvedWorkspaceOpen = resolvedWorkspaceOpen(workspaceOpen)
    return await assemble(
      appInfo: appInfo, paths: paths, notificationCenter: notificationCenter, updater: updater,
      isSandboxed: isSandboxed, transport: transport, keychain: keychain, log: log, settings: settings,
      history: history, isDemo: isDemo, launchAtLogin: launchAtLogin, workspaceOpen: resolvedWorkspaceOpen)
  }

  @MainActor
  public static func makeDeferred(
    appInfo: AppInfo,
    paths: Paths = Paths(),
    defaults: UserDefaults = .standard,
    notificationCenter: (any NotificationCenterProtocol)?,
    updater: (any UpdaterHook)? = nil,
    isSandboxed: Bool = false,
    transport: any HTTPTransport,
    keychain: KeychainCredentialClient,
    launchAtLogin: LaunchAtLoginBackend,
    workspaceOpen: WorkspaceOpen? = nil
  ) async throws -> AppDependencies {
    let settings = TokenMenuBarCore.Settings(defaults: defaults)
    let isDemo = settings.demoMode ?? paths.demoRequested
    let supportDirectory = paths.supportDirectory
    let retentionDays = settings.historyRetentionDays
    let logTask = Task.detached(priority: .utility) {
      LogBuffer(fileURL: supportDirectory.appendingPathComponent("log.txt"))
    }
    let historyTask = Task.detached(priority: .utility) {
      try UsageHistoryStore(
        url: supportDirectory.appendingPathComponent(isDemo ? "usage-demo.sqlite" : "usage.sqlite"),
        retentionDays: retentionDays)
    }
    let log = await logTask.value
    let history = try await historyTask.value
    let resolvedWorkspaceOpen = resolvedWorkspaceOpen(workspaceOpen)
    return await assemble(
      appInfo: appInfo, paths: paths, notificationCenter: notificationCenter, updater: updater,
      isSandboxed: isSandboxed, transport: transport, keychain: keychain, log: log, settings: settings,
      history: history, isDemo: isDemo, launchAtLogin: launchAtLogin, workspaceOpen: resolvedWorkspaceOpen)
  }

  @MainActor
  private static func assemble(
    appInfo: AppInfo,
    paths: Paths,
    notificationCenter: (any NotificationCenterProtocol)?,
    updater: (any UpdaterHook)?,
    isSandboxed: Bool,
    transport: any HTTPTransport,
    keychain: KeychainCredentialClient,
    log: LogBuffer,
    settings: TokenMenuBarCore.Settings,
    history: UsageHistoryStore,
    isDemo: Bool,
    launchAtLogin: LaunchAtLoginBackend,
    workspaceOpen: @escaping WorkspaceOpen
  ) async -> AppDependencies {
    let verificationProfile = paths.verificationProfile
    if isDemo { seedDemo(history, log: log, fixture: verificationProfile?.fixture ?? .standard) }
    let client = APIClient(transport: transport, log: log)
    let build: @MainActor @Sendable (TokenMenuBarCore.Settings) async -> ProviderRegistry = { settings in
      if isDemo { return demoRegistry(fixture: verificationProfile?.fixture ?? .standard) }
      return await providers(
        paths: paths, client: client, log: log, settings: settings, isSandboxed: isSandboxed, keychain: keychain)
    }
    let registry = await build(settings)
    let state = AppState()
    state.applySetupStates(registry.setupStates)
    let effectiveSandboxed = isSandboxed || verificationProfile?.fixture == .controlAudit
    let runtimeActions = runtimeActions(verification: verificationProfile != nil)
    let relaunchAction: @MainActor @Sendable () -> Void = {
      Self.relaunch(bundle: .main, open: workspaceOpen) { NSApplication.shared.terminate(nil) }
    }
    return AppDependencies(
      appInfo: appInfo,
      settings: settings,
      state: state,
      history: history,
      log: log,
      registry: registry,
      notifier: Notifier(center: notificationCenter, log: log),
      launchAtLogin: launchAtLogin,
      updater: updater,
      isSandboxed: effectiveSandboxed,
      isDemo: isDemo,
      openURL: runtimeActions.openURL,
      copyToPasteboard: runtimeActions.copy,
      revealInFinder: runtimeActions.reveal,
      chooseExportURL: exportChooser(profile: verificationProfile, supportDirectory: paths.supportDirectory),
      chooseDirectory: directoryChooser(
        profile: verificationProfile, paths: paths, supportDirectory: paths.supportDirectory),
      terminate: runtimeActions.terminate,
      relaunch: relaunchAction,
      widgetStore: isDemo ? nil : widgetStore(supportDirectory: paths.supportDirectory),
      snapshotCache: SnapshotCache(
        url: paths.supportDirectory.appendingPathComponent(isDemo ? "snapshots-demo.json" : "snapshots.json")),
      reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
      rebuildProviders: build,
      screenVisibleFrame: {
        PopoverGeometry.visibleFrame(
          NSScreen.main?.visibleFrame, cappedTo: verificationProfile?.visibleFrameWidth.map { CGFloat($0) })
      },
      openPopoverOnLaunch: paths.environment["TOKEN_MENU_BAR_OPEN_POPOVER"] != nil,
      persistsStatusItemPosition: verificationProfile == nil,
      recoversOffscreenPopover: verificationProfile != nil,
      verificationSession: paths.environment[LaunchPolicy.verificationSessionKey],
      verificationSnapshotURL: verificationProfile.map { _ in
        paths.supportDirectory.appendingPathComponent("process-snapshot.json")
      }
    )
  }

  private static func demoRegistry(fixture: VerificationProfile.Fixture) -> ProviderRegistry {
    let providers = ProviderID.allCases.map { DemoProvider(id: $0, fixture: fixture) }
    let setup = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { provider in
        let source = CredentialSource(
          id: "demo-\(provider.rawValue)", provider: provider,
          title: fixture == .longText
            ? "Deterministic verification credential source for \(provider.displayName)" : "Demo data",
          detail: fixture == .longText
            ? "/private/tmp/token-menu-bar-verification/credentials/\(provider.rawValue)"
              + "/account-profile-with-a-deliberately-long-file-name.json"
            : "Generated locally for previewing the interface.")
        return (
          provider,
          ProviderSetupState(
            enabled: true, credential: .valid(source: source, expiresAt: nil),
            resources: fixture == .controlAudit
              ? provider.sandboxResources.map { ResourceAccessState(resource: $0, health: .needed) } : [])
        )
      })
    return ProviderRegistry(providers, setupStates: setup)
  }

  @MainActor
  static func exportChooser(
    profile: VerificationProfile?, supportDirectory: URL,
    run: @escaping (NSSavePanel) -> NSApplication.ModalResponse = { $0.runModal() }
  ) -> () -> URL? {
    guard let profile else { return { chosen(exportPanel(), run: run) } }
    guard profile.nativePanels else {
      let url = supportDirectory.appendingPathComponent("verification-history.csv")
      return { url }
    }
    return { chosen(exportPanel(default: supportDirectory), run: run) }
  }

  @MainActor
  static func directoryChooser(
    profile: VerificationProfile?, paths: Paths, supportDirectory: URL,
    run: @escaping (NSOpenPanel) -> NSApplication.ModalResponse = { $0.runModal() }
  ) -> (SandboxResource) -> URL? {
    guard let profile else {
      return { chosen(directoryPanel($0, paths: paths), run: run) }
    }
    guard profile.nativePanels else { return { _ in nil } }
    return { resource in
      let initialURL =
        resource.kind == .file ? supportDirectory.appendingPathComponent("verification-selection") : supportDirectory
      return chosen(directoryPanel(resource: resource, default: initialURL), run: run)
    }
  }

  @MainActor
  public static func providers(
    paths: Paths,
    client: APIClient,
    log: LogBuffer,
    settings: TokenMenuBarCore.Settings,
    isSandboxed: Bool,
    keychain: KeychainCredentialClient,
    resolver: SecurityScopedResourceResolver = SecurityScopedResourceResolver(),
    buildRegistry:
      @escaping @Sendable (
        ProviderRegistryFactory.Configuration, APIClient, LogBuffer
      ) -> ProviderRegistry = { ProviderRegistryFactory.make(configuration: $0, client: $1, log: $2) }
  ) async -> ProviderRegistry {
    let bookmarks = Dictionary(
      uniqueKeysWithValues: ProviderID.allSandboxResources.compactMap { resource in
        settings.bookmark(for: resource).map { (resource.id, $0) }
      })
    let enabledProviders = Set(
      ProviderID.allCases.filter {
        settings.isProviderActive($0, state: ProviderState(credentialHealth: .unchecked))
      })
    let allowTokenRefresh: @MainActor @Sendable () -> Bool = { settings.allowTokenRefresh }
    let result = await Task.detached(priority: .userInitiated) {
      buildProviders(
        paths: paths,
        client: client,
        log: log,
        bookmarks: bookmarks,
        enabledProviders: enabledProviders,
        keychain: keychain,
        allowTokenRefresh: allowTokenRefresh,
        isSandboxed: isSandboxed,
        resolver: resolver,
        buildRegistry: buildRegistry)
    }.value
    for event in result.logEvents {
      switch event {
      case .info(let message): log.log(message)
      case .error(let message): log.logError(message)
      }
    }
    for resource in ProviderID.allSandboxResources {
      guard let bookmark = result.replacementBookmarks[resource.id] else { continue }
      settings.setBookmark(bookmark, for: resource)
    }
    if !result.replacementBookmarks.isEmpty { settings.flush() }
    return result.registry
  }

  private static func buildProviders(
    paths: Paths,
    client: APIClient,
    log: LogBuffer,
    bookmarks: [String: Data],
    enabledProviders: Set<ProviderID>,
    keychain: KeychainCredentialClient,
    allowTokenRefresh: @escaping @MainActor @Sendable () -> Bool,
    isSandboxed: Bool,
    resolver: SecurityScopedResourceResolver,
    buildRegistry:
      @escaping @Sendable (
        ProviderRegistryFactory.Configuration, APIClient, LogBuffer
      ) -> ProviderRegistry
  ) -> ProviderBuildResult {
    var access: [ProviderID: [ResourceAccessState]] = [:]
    var leases: [SecurityScopedResourceLease] = []
    var resourceURLs: [String: URL] = [:]
    var replacementBookmarks: [String: Data] = [:]
    var logEvents: [ProviderBuildLogEvent] = []
    let required = ProviderRegistryFactory.resourcesRequiringSandboxAccess(environment: paths.environment)
    for resource in ProviderID.allSandboxResources {
      let configured = resource.configuredURL(environment: paths.environment, home: paths.home)
      guard isSandboxed else {
        resourceURLs[resource.id] = configured
        continue
      }
      guard required.contains(resource) else {
        resourceURLs[resource.id] = configured
        access[resource.provider, default: []].append(.notRequired(resource))
        continue
      }
      let result = resolver.resolve(
        resource: resource, bookmark: bookmarks[resource.id], fallback: configured)
      resourceURLs[resource.id] = result.url
      access[resource.provider, default: []].append(result.access)
      if let lease = result.lease { leases.append(lease) }
      if let bookmark = result.replacementBookmark {
        replacementBookmarks[resource.id] = bookmark
        logEvents.append(.info("replaced stale bookmark for \(resource.label)"))
      }
      switch result.access.health {
      case .error(let detail): logEvents.append(.error("\(resource.label) access failed: \(detail)"))
      case .stale: logEvents.append(.error("\(resource.label) access grant is stale"))
      case .notRequired, .needed, .granted: break
      }
    }
    let configuration = ProviderRegistryFactory.Configuration(
      home: paths.home,
      supportDirectory: paths.supportDirectory,
      environment: paths.environment,
      userName: paths.userName,
      resourceURLs: resourceURLs,
      resourceAccess: access,
      resourceLeases: leases,
      enabledProviders: enabledProviders,
      keychain: keychain,
      allowTokenRefresh: allowTokenRefresh)
    let registry = buildRegistry(configuration, client, log)
    return ProviderBuildResult(
      registry: registry, replacementBookmarks: replacementBookmarks, logEvents: logEvents)
  }

  private struct ProviderBuildResult: Sendable {
    let registry: ProviderRegistry
    let replacementBookmarks: [String: Data]
    let logEvents: [ProviderBuildLogEvent]
  }

  private enum ProviderBuildLogEvent: Sendable {
    case info(String)
    case error(String)
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

  @discardableResult
  public static func seedDemo(
    _ history: UsageHistoryStore, log: LogBuffer, now: Date = Date(),
    fixture: VerificationProfile.Fixture = .standard
  ) -> Task<Void, Never> {
    Task {
      do {
        guard try await history.stats().sampleCount == 0 else { return }
        try await DemoData.seed(history, providers: ProviderID.allCases, now: now, fixture: fixture)
        log.log("demo history seeded")
      } catch {
        log.logError("demo history seeding failed: \(error)")
      }
    }
  }

  @MainActor
  public static func relaunch(
    bundle: Bundle,
    open: @MainActor (URL, NSWorkspace.OpenConfiguration, @escaping @Sendable () -> Void) -> Void,
    then terminate: @escaping @MainActor @Sendable () -> Void
  ) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    // Start the replacement without the demo flag this instance may have been launched with.
    configuration.environment = ProcessInfo.processInfo.environment.filter { $0.key != "TOKEN_MENU_BAR_DEMO" }
    open(bundle.bundleURL, configuration) { Task { @MainActor in terminate() } }
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
    if stale { log.log("bookmark for \(url.lastPathComponent) is stale; grant access again if reads fail") }
    return url
  }

  public static func copy(_ text: String, to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  @MainActor
  public static func exportPanel(default directory: URL? = nil) -> NSSavePanel {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = "token-menu-bar-history.csv"
    panel.directoryURL = directory
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
