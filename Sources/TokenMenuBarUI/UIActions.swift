import Foundation
import TokenMenuBarCore

@MainActor
public struct UIActions {
  public var refresh: () -> Void
  public var openURL: (URL) -> Void
  public var copy: (String) -> Void
  public var exportHistory: () -> Void
  public var clearHistory: () -> Void
  public var revealHistory: () -> Void
  public var copyDiagnostics: () -> Void
  public var reportIssue: () -> Void
  public var showFullLog: () -> Void
  public var setLaunchAtLogin: (Bool) -> Void
  public var openLoginItems: () -> Void
  public var grantCodexAccess: () -> Void
  public var checkForUpdates: () -> Void
  public var quit: () -> Void
  public var setDemoMode: (Bool) -> Void
  public var settingsChanged: () -> Void

  public init(
    refresh: @escaping () -> Void = {},
    openURL: @escaping (URL) -> Void = { _ in },
    copy: @escaping (String) -> Void = { _ in },
    exportHistory: @escaping () -> Void = {},
    clearHistory: @escaping () -> Void = {},
    revealHistory: @escaping () -> Void = {},
    copyDiagnostics: @escaping () -> Void = {},
    reportIssue: @escaping () -> Void = {},
    showFullLog: @escaping () -> Void = {},
    setLaunchAtLogin: @escaping (Bool) -> Void = { _ in },
    openLoginItems: @escaping () -> Void = {},
    grantCodexAccess: @escaping () -> Void = {},
    checkForUpdates: @escaping () -> Void = {},
    quit: @escaping () -> Void = {},
    setDemoMode: @escaping (Bool) -> Void = { _ in },
    settingsChanged: @escaping () -> Void = {}
  ) {
    self.refresh = refresh
    self.openURL = openURL
    self.copy = copy
    self.exportHistory = exportHistory
    self.clearHistory = clearHistory
    self.revealHistory = revealHistory
    self.copyDiagnostics = copyDiagnostics
    self.reportIssue = reportIssue
    self.showFullLog = showFullLog
    self.setLaunchAtLogin = setLaunchAtLogin
    self.openLoginItems = openLoginItems
    self.grantCodexAccess = grantCodexAccess
    self.checkForUpdates = checkForUpdates
    self.quit = quit
    self.setDemoMode = setDemoMode
    self.settingsChanged = settingsChanged
  }
}

@MainActor
@Observable
public final class UIEnvironment {
  public let state: AppState
  public let settings: Settings
  public let history: UsageHistoryStore
  public let historyPresenter: HistoryPresenter
  public let log: LogBuffer
  public let appInfo: AppInfo
  public let clock: Clock
  public var actions: UIActions
  public var launchAtLoginStatus: LaunchAtLoginBackend.Status
  public var credentialDescriptions: [ProviderID: String]
  public var canCheckForUpdates: Bool
  public var isSandboxed: Bool
  public var isDemo: Bool
  public var samples: [WindowKey: [UsageSample]] = [:]
  public var now: Date

  public init(
    state: AppState,
    settings: Settings,
    history: UsageHistoryStore,
    log: LogBuffer,
    appInfo: AppInfo,
    clock: Clock = .system,
    actions: UIActions = UIActions(),
    launchAtLoginStatus: LaunchAtLoginBackend.Status = .unknown,
    credentialDescriptions: [ProviderID: String] = [:],
    canCheckForUpdates: Bool = false,
    isSandboxed: Bool = false,
    isDemo: Bool = false
  ) {
    self.state = state
    self.settings = settings
    self.history = history
    self.log = log
    self.appInfo = appInfo
    self.clock = clock
    self.actions = actions
    self.launchAtLoginStatus = launchAtLoginStatus
    self.credentialDescriptions = credentialDescriptions
    self.canCheckForUpdates = canCheckForUpdates
    self.isSandboxed = isSandboxed
    self.isDemo = isDemo
    historyPresenter = HistoryPresenter(history: history, settings: settings, clock: clock)
    now = clock.now()
  }

  public func tick() {
    now = clock.now()
  }

  public func loadRecentSamples() async {
    let since = now.addingTimeInterval(-PaceEstimate.slopeWindow)
    var loaded: [WindowKey: [UsageSample]] = [:]
    for (provider, item) in state.providers {
      for window in item.snapshot?.windows ?? [] {
        let key = WindowKey(provider, window)
        loaded[key] = (try? await history.recentSamples(key: key, since: since)) ?? []
      }
    }
    samples = loaded
  }

  public var cards: [ProviderCard] {
    UsagePresenter.cards(state: state.providers, enabled: settings.enabledProviders, samples: samples, now: now)
  }
}
