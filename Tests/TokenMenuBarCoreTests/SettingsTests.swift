import Foundation
import Testing
import TokenMenuBarCore

@Test @MainActor func settingsDefaultsAndClamping() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  #expect(settings.refreshInterval(for: .claude) == 300)
  #expect(settings.refreshInterval(for: .codex) == 120)
  #expect(settings.enabledProviders == Set(ProviderID.allCases))
  #expect(settings.statusFormat == .stacked)
  #expect(settings.activeTemplate == "{label}\n{pct}")
  #expect(settings.hideZeroCells)
  #expect(settings.historyRetentionDays == 60)
  #expect(settings.providerOrder == ProviderID.allCases)
  #expect(settings.modelOrder.isEmpty)
  #expect(!settings.hideUnusedModels)
  #expect(settings.automaticUpdates)
  #expect(settings.lastLaunchedVersion == nil)
  #expect(settings.historyMetricID == HistoryMetric.windowUsagePercent.storageID)
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
  settings.historyRetentionDays = 1
  #expect(settings.historyRetentionDays == 7)
  settings.historyRetentionDays = 500
  #expect(settings.historyRetentionDays == 365)
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
  settings.providerOrder = [.codex, .claude]
  settings.modelOrder = [key]
  settings.hideUnusedModels = true
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
  #expect(reloaded.providerOrder == [.codex, .claude])
  #expect(reloaded.modelOrder == [key])
  #expect(reloaded.hideUnusedModels)
}

@Test @MainActor func shortLabelEditsApplyImmediatelyAndPersistAsOneBatch() async throws {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  let key = WindowKey(provider: .codex, windowID: "weekly")

  settings.setShortLabel("O", for: key)
  settings.setShortLabel("OP", for: key)
  #expect(settings.shortLabels[key] == "OP")
  #expect(Settings(defaults: defaults).shortLabels[key] == nil)
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(5))
  while Settings(defaults: defaults).shortLabels[key] != "OP", clock.now < deadline {
    try await clock.sleep(for: .milliseconds(10))
  }
  #expect(Settings(defaults: defaults).shortLabels[key] == "OP")

  settings.setShortLabel(nil, for: key)
  settings.flush()
  #expect(Settings(defaults: defaults).shortLabels[key] == nil)
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
  settings.historyMetricID = HistoryMetric.analytics(.turns).storageID
  let reloaded = Settings(defaults: defaults)
  #expect(reloaded.lastTab == .history)
  #expect(reloaded.historyRange == .month)
  #expect(reloaded.historyRollup == .day)
  #expect(reloaded.historyStacked)
  #expect(reloaded.historyUseUTC)
  #expect(reloaded.historyHiddenKeys == [key])
  #expect(reloaded.historyAnalyticsMetric == .turns)
  #expect(reloaded.historyMetricID == HistoryMetric.analytics(.turns).storageID)
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
  #expect(reloaded.missingAccess(for: .codex).isEmpty)
  #expect(reloaded.missingAccess(for: .gemini) == ProviderID.gemini.sandboxResources)
}

@Test @MainActor func settingsResetRestoresDefaults() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  settings.setRefreshInterval(600, for: .claude)
  settings.statusFormat = .inline
  settings.enabledProviders = []
  settings.lastTab = .settings
  settings.lastLaunchedVersion = "9"
  settings.historyMetricID = HistoryMetric.analytics(.turns).storageID
  settings.resetToDefaults()
  #expect(settings.refreshInterval(for: .claude) == 300)
  #expect(settings.statusFormat == .stacked)
  #expect(settings.enabledProviders == Set(ProviderID.allCases))
  #expect(settings.lastTab == .settings)
  #expect(settings.lastLaunchedVersion == nil)
  #expect(defaults.object(forKey: "refreshSeconds") == nil)
  #expect(defaults.object(forKey: "lastTab") == nil)
  #expect(settings.historyMetricID == HistoryMetric.windowUsagePercent.storageID)
}

@Test @MainActor func resetToDefaultsRestoresValuesFromAllSixSections() {
  let defaults = freshDefaults()
  let settings = Settings(defaults: defaults)
  settings.statusFormat = .custom
  settings.shortLabels = [WindowKey(provider: .codex, windowID: "weekly"): "W"]
  settings.automaticUpdates = false
  settings.enabledProviders = [.codex]
  settings.allowTokenRefresh = true
  settings.analyticsRefreshMinutes = 30
  settings.historyRetentionDays = 90
  settings.notifications = NotificationSettings(enabled: false)
  settings.detailedLogging = true
  settings.demoMode = true
  settings.resetToDefaults()
  #expect(settings.automaticUpdates)
  #expect(settings.statusFormat == .stacked)
  #expect(settings.shortLabels.isEmpty)
  #expect(settings.enabledProviders == Set(ProviderID.allCases))
  #expect(!settings.allowTokenRefresh)
  #expect(settings.analyticsRefreshMinutes == Settings.defaultAnalyticsMinutes)
  #expect(settings.historyRetentionDays == Settings.defaultHistoryRetentionDays)
  #expect(settings.notifications == NotificationSettings())
  #expect(!settings.detailedLogging)
  #expect(settings.demoMode == nil)
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
  defaults.set("Nope", forKey: "historyMetricID")
  let settings = Settings(defaults: defaults)
  #expect(settings.enabledProviders == Set(ProviderID.allCases))
  #expect(settings.statusFormat == .stacked)
  #expect(settings.windowOrder == .provider)
  #expect(settings.lastTab == .usage)
  #expect(settings.historyRange == .today)
  #expect(settings.historyRollup == .minute)
  #expect(settings.historyAnalyticsMetric == .surfaceUsagePercent)
  #expect(settings.historyMetricID == HistoryMetric.windowUsagePercent.storageID)
  #expect(PopoverTab.allCases.count == 3)
}

@Test @MainActor func historyMetricMigratesOnlyAnExplicitLegacySelection() {
  let defaults = freshDefaults()
  defaults.set(AnalyticsMetric.turns.rawValue, forKey: "historyAnalyticsMetric")
  let settings = Settings(defaults: defaults)
  #expect(settings.historyMetricID == HistoryMetric.analytics(.turns).storageID)
  #expect(Settings(defaults: freshDefaults()).historyMetricID == HistoryMetric.windowUsagePercent.storageID)
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
