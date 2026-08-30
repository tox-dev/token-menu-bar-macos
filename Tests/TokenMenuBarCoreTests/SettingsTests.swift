import Foundation
import Testing

@testable import TokenMenuBarCore

@Test @MainActor func settingsDefaultsAndClamping() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  #expect(settings.refreshInterval(for: .claude) == 300)
  #expect(settings.refreshInterval(for: .codex) == 120)
  #expect(settings.enabledProviders == Set(ProviderID.allCases))
  #expect(settings.statusFormat == .stacked)
  #expect(settings.activeTemplate == "{cell}\n{pct}")
  #expect(settings.hideZeroCells)
  #expect(settings.automaticUpdates)
  #expect(settings.lastLaunchedVersion == nil)
  settings.setRefreshInterval(5, for: .claude)
  #expect(settings.refreshInterval(for: .claude) == 120)
  settings.setRefreshInterval(5000, for: .codex)
  #expect(settings.refreshInterval(for: .codex) == Settings.maximumRefreshSeconds)
  #expect(Settings(defaults: defaults).refreshInterval(for: .codex) == Settings.maximumRefreshSeconds)
  settings.analyticsRefreshMinutes = 1
  #expect(settings.analyticsRefreshMinutes == 5)
  settings.percentDecimals = 9
  #expect(settings.percentDecimals == 2)
  settings.percentDecimals = -1
  #expect(settings.percentDecimals == 0)
  settings.statusFormat = .custom
  settings.customTemplate = "{pct}"
  #expect(settings.activeTemplate == "{pct}")
}

@MainActor
private func freshDefaults() -> UserDefaults {
  let suite = "tests-settings-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Test @MainActor func menuBarSettingsSurviveAReload() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  let key = WindowKey(provider: .codex, windowID: "weekly")
  settings.enabledProviders = [.codex]
  settings.selectedWindows = [key]
  settings.hasCustomSelection = true
  settings.statusFormat = .miniBars
  settings.customTemplate = "x"
  settings.percentDecimals = 1
  settings.hideZeroCells = false
  settings.windowOrder = .percent
  settings.shortLabels = [key: "W"]
  let reloaded = Settings(defaults: defaults)
  #expect(reloaded.enabledProviders == [.codex])
  #expect(reloaded.selectedWindows == [key])
  #expect(reloaded.hasCustomSelection)
  #expect(reloaded.statusFormat == .miniBars)
  #expect(reloaded.customTemplate == "x")
  #expect(reloaded.percentDecimals == 1)
  #expect(!reloaded.hideZeroCells)
  #expect(reloaded.windowOrder == .percent)
  #expect(reloaded.shortLabels == [key: "W"])
}

@Test @MainActor func historySettingsSurviveAReload() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  let key = WindowKey(provider: .codex, windowID: "weekly")
  settings.lastTab = .history
  settings.historyRange = .month
  settings.historyRollup = .day
  settings.historyStacked = true
  settings.historyUseUTC = true
  settings.historyHiddenKeys = [key]
  settings.historyAnalyticsMetric = .turns
  let reloaded = Settings(defaults: defaults)
  #expect(reloaded.lastTab == .history)
  #expect(reloaded.historyRange == .month)
  #expect(reloaded.historyRollup == .day)
  #expect(reloaded.historyStacked)
  #expect(reloaded.historyUseUTC)
  #expect(reloaded.historyHiddenKeys == [key])
  #expect(reloaded.historyAnalyticsMetric == .turns)
}

@Test @MainActor func appSettingsSurviveAReload() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  settings.allowTokenRefresh = true
  settings.notifications = NotificationSettings(
    enabled: false, thresholds: [50], notifyOnReset: false, notifyOnAuthProblems: false)
  settings.detailedLogging = true
  settings.automaticUpdates = false
  settings.lastLaunchedVersion = "1.2.3"
  let reloaded = Settings(defaults: defaults)
  #expect(reloaded.allowTokenRefresh)
  #expect(
    reloaded.notifications
      == NotificationSettings(enabled: false, thresholds: [50], notifyOnReset: false, notifyOnAuthProblems: false))
  #expect(reloaded.detailedLogging)
  #expect(!reloaded.automaticUpdates)
  #expect(reloaded.lastLaunchedVersion == "1.2.3")
}

@Test @MainActor func clearingTheLastVersionRemovesItFromDefaults() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  settings.lastLaunchedVersion = "1.2.3"
  settings.lastLaunchedVersion = nil
  #expect(defaults.object(forKey: "lastLaunchedVersion") == nil)
}

@Test @MainActor func bookmarksAreStoredPerSandboxResource() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  settings.setBookmark(Data([1, 2]), for: ProviderID.codex.sandboxResources[0])
  let reloaded = Settings(defaults: defaults)
  #expect(reloaded.bookmark(for: ProviderID.codex.sandboxResources[0]) == Data([1, 2]))
  #expect(reloaded.bookmark(for: ProviderID.gemini.sandboxResources[0]) == nil)
}

@Test @MainActor func settingsResetRestoresDefaults() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  settings.setRefreshInterval(600, for: .claude)
  settings.statusFormat = .inline
  settings.enabledProviders = []
  settings.lastTab = .settings
  settings.lastLaunchedVersion = "9"
  settings.resetToDefaults()
  #expect(settings.refreshInterval(for: .claude) == 300)
  #expect(settings.statusFormat == .stacked)
  #expect(settings.enabledProviders == Set(ProviderID.allCases))
  #expect(settings.lastTab == .usage)
  #expect(settings.lastLaunchedVersion == nil)
  #expect(defaults.object(forKey: "refreshSeconds") == nil)
}

@Test @MainActor func settingsIgnoreCorruptStoredValues() {
  let defaults = freshDefaults()
  defaults.set(Data("junk".utf8), forKey: "enabledProviders")
  defaults.set("Nope", forKey: "statusFormat")
  defaults.set("Nope", forKey: "windowOrder")
  defaults.set("Nope", forKey: "lastTab")
  defaults.set("Nope", forKey: "historyRange")
  defaults.set("Nope", forKey: "historyRollup")
  defaults.set("Nope", forKey: "historyAnalyticsMetric")
  let settings = Settings(defaults: defaults)
  #expect(settings.enabledProviders == Set(ProviderID.allCases))
  #expect(settings.statusFormat == .stacked)
  #expect(settings.windowOrder == .provider)
  #expect(settings.lastTab == .usage)
  #expect(settings.historyRange == .today)
  #expect(settings.historyRollup == .minute)
  #expect(settings.historyAnalyticsMetric == .surfaceUsagePercent)
  #expect(PopoverTab.allCases.count == 3)
}

@Test @MainActor func settingsFlushPersistsImmediately() {
  let name = "flush-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  let settings = Settings(defaults: defaults)
  #expect(settings.demoMode == nil)
  settings.demoMode = true
  settings.flush()
  #expect(Settings(defaults: UserDefaults(suiteName: name)!).demoMode == true)
  defaults.removePersistentDomain(forName: name)
}
