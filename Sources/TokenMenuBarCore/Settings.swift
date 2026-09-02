import Foundation
import Observation

public enum PopoverTab: String, CaseIterable, Codable, Sendable {
  case usage = "Usage"
  case history = "History"
  case settings = "Settings"
}

@MainActor
@Observable
public final class Settings {
  public static let maximumRefreshSeconds = 1800
  public static let defaultAnalyticsMinutes = 15
  public static let defaultHistoryRetentionDays = 60
  public static let defaultCustomTemplate = "{provider} {window}\n{pct}"

  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var loading = true
  @ObservationIgnored private var defersShortLabelStore = false
  @ObservationIgnored private var shortLabelStoreTask: Task<Void, Never>?

  public var refreshSeconds: [ProviderID: Int] {
    didSet { storeCodable(refreshSeconds, key: .refreshSeconds) }
  }

  public func refreshInterval(for provider: ProviderID) -> Int {
    refreshSeconds[provider] ?? Int(PollingPolicy.defaults(for: provider).defaultInterval)
  }

  public func setRefreshInterval(_ seconds: Int, for provider: ProviderID) {
    let floor = Int(PollingPolicy.defaults(for: provider).minimumInterval)
    refreshSeconds[provider] = min(max(seconds, floor), Self.maximumRefreshSeconds)
  }

  public var analyticsRefreshMinutes: Int {
    didSet {
      let clamped = max(analyticsRefreshMinutes, 5)
      if clamped != analyticsRefreshMinutes {
        analyticsRefreshMinutes = clamped
        return
      }
      store(analyticsRefreshMinutes, key: .analyticsMinutes)
    }
  }

  public var historyRetentionDays: Int {
    didSet {
      let clamped = min(max(historyRetentionDays, 7), 365)
      if clamped != historyRetentionDays {
        historyRetentionDays = clamped
        return
      }
      store(historyRetentionDays, key: .historyRetentionDays)
    }
  }

  public var enabledProviders: Set<ProviderID> { didSet { storeCodable(enabledProviders, key: .enabledProviders) } }
  public var showAllProviders: Bool { didSet { store(showAllProviders, key: .showAllProviders) } }
  public var configuredProviders: Set<ProviderID> {
    didSet { storeCodable(configuredProviders, key: .configuredProviders) }
  }

  public func providerOverride(for provider: ProviderID) -> Bool? {
    configuredProviders.contains(provider) ? enabledProviders.contains(provider) : nil
  }

  public func setProvider(_ provider: ProviderID, enabled: Bool) {
    configuredProviders.insert(provider)
    if enabled {
      enabledProviders.insert(provider)
    } else {
      enabledProviders.remove(provider)
    }
  }

  public func isProviderActive(_ provider: ProviderID, state: ProviderState?) -> Bool {
    ProviderSettingsVisibility.isActive(
      provider, state: state, enabled: enabledProviders, overridden: configuredProviders)
  }

  public func activeProviders(states: [ProviderID: ProviderState]) -> Set<ProviderID> {
    ProviderSettingsVisibility.activeProviders(
      states: states, enabled: enabledProviders, overridden: configuredProviders)
  }

  public var configuredProviderSettings: Set<ProviderID> {
    var providers = configuredProviders.union(refreshSeconds.keys)
    for provider in ProviderID.allCases
    where provider.sandboxResources.contains(where: { accessBookmarks[$0.id] != nil }) {
      providers.insert(provider)
    }
    return providers
  }
  public var selectedWindows: [WindowKey] { didSet { storeCodable(selectedWindows, key: .selectedWindows) } }
  public var hasCustomSelection: Bool { didSet { store(hasCustomSelection, key: .hasCustomSelection) } }
  public var statusFormat: StatusFormat { didSet { store(statusFormat.rawValue, key: .statusFormat) } }
  public var customTemplate: String { didSet { store(customTemplate, key: .customTemplate) } }
  public var percentDecimals: Int {
    didSet {
      let clamped = min(max(percentDecimals, 0), 2)
      if clamped != percentDecimals {
        percentDecimals = clamped
        return
      }
      store(percentDecimals, key: .percentDecimals)
    }
  }
  public var hideZeroCells: Bool { didSet { store(hideZeroCells, key: .hideZeroCells) } }
  public var adaptiveWidth: Bool { didSet { store(adaptiveWidth, key: .adaptiveWidth) } }
  public var windowOrder: WindowOrder { didSet { store(windowOrder.rawValue, key: .windowOrder) } }
  public var shortLabels: [WindowKey: String] {
    didSet {
      if !defersShortLabelStore { storeCodable(shortLabels, key: .shortLabels) }
    }
  }

  public func setShortLabel(_ label: String?, for key: WindowKey) {
    defersShortLabelStore = true
    shortLabels[key] = label
    defersShortLabelStore = false
    shortLabelStoreTask?.cancel()
    let labels = shortLabels
    shortLabelStoreTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        return
      }
      guard let self else { return }
      storeCodable(labels, key: .shortLabels)
      shortLabelStoreTask = nil
    }
  }
  public var providerOrder: [ProviderID] { didSet { storeCodable(providerOrder, key: .providerOrder) } }
  public var modelOrder: [WindowKey] { didSet { storeCodable(modelOrder, key: .modelOrder) } }
  public var hideUnusedModels: Bool { didSet { store(hideUnusedModels, key: .hideUnusedModels) } }
  public var allowTokenRefresh: Bool { didSet { store(allowTokenRefresh, key: .allowTokenRefresh) } }
  public var notifications: NotificationSettings { didSet { storeCodable(notifications, key: .notifications) } }
  public var lastTab: PopoverTab { didSet { store(lastTab.rawValue, key: .lastTab) } }
  public var historyRange: HistoryRange { didSet { store(historyRange.rawValue, key: .historyRange) } }
  public var historyRollup: Rollup { didSet { store(historyRollup.rawValue, key: .historyRollup) } }
  public var historyStacked: Bool { didSet { store(historyStacked, key: .historyStacked) } }
  public var historyUseUTC: Bool { didSet { store(historyUseUTC, key: .historyUseUTC) } }
  public var historyHiddenKeys: Set<WindowKey> { didSet { storeCodable(historyHiddenKeys, key: .historyHiddenKeys) } }
  public var historyAnalyticsMetric: AnalyticsMetric {
    didSet { store(historyAnalyticsMetric.rawValue, key: .historyAnalyticsMetric) }
  }
  public var historyMetricID: String { didSet { store(historyMetricID, key: .historyMetricID) } }
  public var detailedLogging: Bool { didSet { store(detailedLogging, key: .detailedLogging) } }
  public var automaticUpdates: Bool { didSet { store(automaticUpdates, key: .automaticUpdates) } }
  public var lastLaunchedVersion: String? { didSet { store(lastLaunchedVersion, key: .lastLaunchedVersion) } }
  public var accessBookmarks: [String: Data] { didSet { storeCodable(accessBookmarks, key: .accessBookmarks) } }
  /// nil follows TOKEN_MENU_BAR_DEMO or --demo; once the user ticks the box their choice wins, so turning demo
  /// off in an instance the environment started leaves demo mode.
  public var demoMode: Bool? { didSet { store(demoMode, key: .demoMode) } }

  public init(defaults: UserDefaults) {
    self.defaults = defaults
    refreshSeconds = Self.loadCodable([ProviderID: Int].self, defaults, .refreshSeconds) ?? [:]
    analyticsRefreshMinutes =
      defaults.object(forKey: Key.analyticsMinutes.rawValue) as? Int ?? Self.defaultAnalyticsMinutes
    historyRetentionDays =
      defaults.object(forKey: Key.historyRetentionDays.rawValue) as? Int ?? Self.defaultHistoryRetentionDays
    let storedProviders = Self.loadCodable(Set<ProviderID>.self, defaults, .enabledProviders)
    enabledProviders = storedProviders ?? Set(ProviderID.allCases)
    showAllProviders = defaults.bool(forKey: Key.showAllProviders.rawValue)
    configuredProviders =
      Self.loadCodable(Set<ProviderID>.self, defaults, .configuredProviders)
      ?? (storedProviders == nil ? [] : Set(ProviderID.allCases))
    selectedWindows = Self.loadCodable([WindowKey].self, defaults, .selectedWindows) ?? []
    hasCustomSelection = defaults.bool(forKey: Key.hasCustomSelection.rawValue)
    statusFormat =
      (defaults.string(forKey: Key.statusFormat.rawValue)).flatMap(StatusFormat.init(rawValue:)) ?? .stacked
    customTemplate = defaults.string(forKey: Key.customTemplate.rawValue) ?? Self.defaultCustomTemplate
    percentDecimals = defaults.object(forKey: Key.percentDecimals.rawValue) as? Int ?? 0
    hideZeroCells = defaults.object(forKey: Key.hideZeroCells.rawValue) as? Bool ?? true
    adaptiveWidth = defaults.object(forKey: Key.adaptiveWidth.rawValue) as? Bool ?? true
    windowOrder = defaults.string(forKey: Key.windowOrder.rawValue).flatMap(WindowOrder.init(rawValue:)) ?? .provider
    shortLabels = Self.loadCodable([WindowKey: String].self, defaults, .shortLabels) ?? [:]
    providerOrder = Self.loadCodable([ProviderID].self, defaults, .providerOrder) ?? ProviderID.allCases
    modelOrder = Self.loadCodable([WindowKey].self, defaults, .modelOrder) ?? []
    hideUnusedModels = defaults.bool(forKey: Key.hideUnusedModels.rawValue)
    allowTokenRefresh = defaults.bool(forKey: Key.allowTokenRefresh.rawValue)
    notifications = Self.loadCodable(NotificationSettings.self, defaults, .notifications) ?? NotificationSettings()
    lastTab = defaults.string(forKey: Key.lastTab.rawValue).flatMap(PopoverTab.init(rawValue:)) ?? .usage
    historyRange = defaults.string(forKey: Key.historyRange.rawValue).flatMap(HistoryRange.init(rawValue:)) ?? .today
    historyRollup = defaults.string(forKey: Key.historyRollup.rawValue).flatMap(Rollup.init(rawValue:)) ?? .minute
    historyStacked = defaults.bool(forKey: Key.historyStacked.rawValue)
    historyUseUTC = defaults.bool(forKey: Key.historyUseUTC.rawValue)
    historyHiddenKeys = Self.loadCodable(Set<WindowKey>.self, defaults, .historyHiddenKeys) ?? []
    historyAnalyticsMetric =
      defaults.string(forKey: Key.historyAnalyticsMetric.rawValue).flatMap(AnalyticsMetric.init(rawValue:))
      ?? .surfaceUsagePercent
    historyMetricID =
      defaults.string(forKey: Key.historyMetricID.rawValue).flatMap(HistoryMetric.init(storageID:))?.storageID
      ?? defaults.string(forKey: Key.historyAnalyticsMetric.rawValue).flatMap(AnalyticsMetric.init(rawValue:))
      .map { HistoryMetric.analytics($0).storageID }
      ?? HistoryMetric.windowUsagePercent.storageID
    detailedLogging = defaults.bool(forKey: Key.detailedLogging.rawValue)
    automaticUpdates = defaults.object(forKey: Key.automaticUpdates.rawValue) as? Bool ?? true
    lastLaunchedVersion = defaults.string(forKey: Key.lastLaunchedVersion.rawValue)
    accessBookmarks = Self.loadCodable([String: Data].self, defaults, .accessBookmarks) ?? [:]
    demoMode = defaults.object(forKey: Key.demoMode.rawValue) as? Bool
    loading = false
  }

  public func bookmark(for resource: SandboxResource) -> Data? {
    accessBookmarks[resource.id]
  }

  public func setBookmark(_ data: Data, for resource: SandboxResource) {
    accessBookmarks[resource.id] = data
  }

  /// The paths this provider still cannot read in a sandboxed build, so Settings can offer one button each.
  public func missingAccess(for provider: ProviderID) -> [SandboxResource] {
    provider.sandboxResources.filter { bookmark(for: $0) == nil }
  }

  public func flush() {
    shortLabelStoreTask?.cancel()
    shortLabelStoreTask = nil
    storeCodable(shortLabels, key: .shortLabels)
    defaults.synchronize()
  }

  public func resetToDefaults() {
    shortLabelStoreTask?.cancel()
    shortLabelStoreTask = nil
    let activeTab = lastTab
    for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
    let fresh = Settings(defaults: defaults)
    loading = true
    defer {
      loading = false
      for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
    }
    refreshSeconds = fresh.refreshSeconds
    analyticsRefreshMinutes = fresh.analyticsRefreshMinutes
    historyRetentionDays = fresh.historyRetentionDays
    enabledProviders = fresh.enabledProviders
    showAllProviders = fresh.showAllProviders
    configuredProviders = fresh.configuredProviders
    selectedWindows = fresh.selectedWindows
    hasCustomSelection = fresh.hasCustomSelection
    statusFormat = fresh.statusFormat
    customTemplate = fresh.customTemplate
    percentDecimals = fresh.percentDecimals
    hideZeroCells = fresh.hideZeroCells
    adaptiveWidth = fresh.adaptiveWidth
    windowOrder = fresh.windowOrder
    shortLabels = fresh.shortLabels
    providerOrder = fresh.providerOrder
    modelOrder = fresh.modelOrder
    hideUnusedModels = fresh.hideUnusedModels
    allowTokenRefresh = fresh.allowTokenRefresh
    notifications = fresh.notifications
    lastTab = activeTab
    historyRange = fresh.historyRange
    historyRollup = fresh.historyRollup
    historyStacked = fresh.historyStacked
    historyUseUTC = fresh.historyUseUTC
    historyHiddenKeys = fresh.historyHiddenKeys
    historyAnalyticsMetric = fresh.historyAnalyticsMetric
    historyMetricID = fresh.historyMetricID
    detailedLogging = fresh.detailedLogging
    automaticUpdates = fresh.automaticUpdates
    lastLaunchedVersion = fresh.lastLaunchedVersion
    accessBookmarks = fresh.accessBookmarks
    demoMode = fresh.demoMode
  }

  public var activeTemplate: String {
    statusFormat.template ?? customTemplate
  }

  enum Key: String, CaseIterable {
    case refreshSeconds, analyticsMinutes, historyRetentionDays, enabledProviders, selectedWindows, hasCustomSelection,
      statusFormat, customTemplate
    case percentDecimals, hideZeroCells, adaptiveWidth, windowOrder, shortLabels, providerOrder, modelOrder,
      hideUnusedModels, allowTokenRefresh, notifications, lastTab, showAllProviders, configuredProviders
    case historyRange, historyRollup, historyStacked, historyUseUTC, historyHiddenKeys, historyAnalyticsMetric,
      historyMetricID
    case detailedLogging, automaticUpdates, lastLaunchedVersion, accessBookmarks, demoMode

  }

  private func store(_ value: (any Sendable)?, key: Key) {
    guard !loading else { return }
    if let value {
      defaults.set(value, forKey: key.rawValue)
    } else {
      defaults.removeObject(forKey: key.rawValue)
    }
  }

  private func storeCodable<Value: Encodable>(_ value: Value, key: Key) {
    guard !loading, let data = try? encoder.encode(value) else { return }
    defaults.set(data, forKey: key.rawValue)
  }

  private static func loadCodable<Value: Decodable>(_ type: Value.Type, _ defaults: UserDefaults, _ key: Key) -> Value?
  {
    defaults.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(type, from: $0) }
  }
}
