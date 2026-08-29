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
  public static let minimumRefreshSeconds = 60
  public static let maximumRefreshSeconds = 600
  public static let defaultRefreshSeconds = 120
  public static let defaultAnalyticsMinutes = 15

  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var loading = true

  public var refreshSeconds: Int {
    didSet {
      let clamped = min(max(refreshSeconds, Self.minimumRefreshSeconds), Self.maximumRefreshSeconds)
      if clamped != refreshSeconds {
        refreshSeconds = clamped
        return
      }
      store(refreshSeconds, key: .refreshSeconds)
    }
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

  public var enabledProviders: Set<ProviderID> { didSet { storeCodable(enabledProviders, key: .enabledProviders) } }
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
  public var windowOrder: WindowOrder { didSet { store(windowOrder.rawValue, key: .windowOrder) } }
  public var shortLabels: [WindowKey: String] { didSet { storeCodable(shortLabels, key: .shortLabels) } }
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
  public var detailedLogging: Bool { didSet { store(detailedLogging, key: .detailedLogging) } }
  public var automaticUpdates: Bool { didSet { store(automaticUpdates, key: .automaticUpdates) } }
  public var lastLaunchedVersion: String? { didSet { store(lastLaunchedVersion, key: .lastLaunchedVersion) } }
  public var codexHomeBookmark: Data? { didSet { store(codexHomeBookmark, key: .codexHomeBookmark) } }

  public init(defaults: UserDefaults) {
    self.defaults = defaults
    refreshSeconds = defaults.object(forKey: Key.refreshSeconds.rawValue) as? Int ?? Self.defaultRefreshSeconds
    analyticsRefreshMinutes =
      defaults.object(forKey: Key.analyticsMinutes.rawValue) as? Int ?? Self.defaultAnalyticsMinutes
    enabledProviders = Self.loadCodable(Set<ProviderID>.self, defaults, .enabledProviders) ?? Set(ProviderID.allCases)
    selectedWindows = Self.loadCodable([WindowKey].self, defaults, .selectedWindows) ?? []
    hasCustomSelection = defaults.bool(forKey: Key.hasCustomSelection.rawValue)
    statusFormat =
      (defaults.string(forKey: Key.statusFormat.rawValue)).flatMap(StatusFormat.init(rawValue:)) ?? .stacked
    customTemplate = defaults.string(forKey: Key.customTemplate.rawValue) ?? "{provider} {window}\n{pct}"
    percentDecimals = defaults.object(forKey: Key.percentDecimals.rawValue) as? Int ?? 0
    hideZeroCells = defaults.object(forKey: Key.hideZeroCells.rawValue) as? Bool ?? true
    windowOrder = defaults.string(forKey: Key.windowOrder.rawValue).flatMap(WindowOrder.init(rawValue:)) ?? .provider
    shortLabels = Self.loadCodable([WindowKey: String].self, defaults, .shortLabels) ?? [:]
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
    detailedLogging = defaults.bool(forKey: Key.detailedLogging.rawValue)
    automaticUpdates = defaults.object(forKey: Key.automaticUpdates.rawValue) as? Bool ?? true
    lastLaunchedVersion = defaults.string(forKey: Key.lastLaunchedVersion.rawValue)
    codexHomeBookmark = defaults.data(forKey: Key.codexHomeBookmark.rawValue)
    loading = false
  }

  public func resetToDefaults() {
    for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
    let fresh = Settings(defaults: defaults)
    loading = true
    defer {
      loading = false
      for key in Key.allCases { defaults.removeObject(forKey: key.rawValue) }
    }
    refreshSeconds = fresh.refreshSeconds
    analyticsRefreshMinutes = fresh.analyticsRefreshMinutes
    enabledProviders = fresh.enabledProviders
    selectedWindows = fresh.selectedWindows
    hasCustomSelection = fresh.hasCustomSelection
    statusFormat = fresh.statusFormat
    customTemplate = fresh.customTemplate
    percentDecimals = fresh.percentDecimals
    hideZeroCells = fresh.hideZeroCells
    windowOrder = fresh.windowOrder
    shortLabels = fresh.shortLabels
    allowTokenRefresh = fresh.allowTokenRefresh
    notifications = fresh.notifications
    lastTab = fresh.lastTab
    historyRange = fresh.historyRange
    historyRollup = fresh.historyRollup
    historyStacked = fresh.historyStacked
    historyUseUTC = fresh.historyUseUTC
    historyHiddenKeys = fresh.historyHiddenKeys
    historyAnalyticsMetric = fresh.historyAnalyticsMetric
    detailedLogging = fresh.detailedLogging
    automaticUpdates = fresh.automaticUpdates
    lastLaunchedVersion = fresh.lastLaunchedVersion
    codexHomeBookmark = fresh.codexHomeBookmark
  }

  public var activeTemplate: String {
    statusFormat.template ?? customTemplate
  }

  enum Key: String, CaseIterable {
    case refreshSeconds, analyticsMinutes, enabledProviders, selectedWindows, hasCustomSelection, statusFormat,
      customTemplate
    case percentDecimals, hideZeroCells, windowOrder, shortLabels, allowTokenRefresh, notifications, lastTab
    case historyRange, historyRollup, historyStacked, historyUseUTC, historyHiddenKeys, historyAnalyticsMetric
    case detailedLogging, automaticUpdates, lastLaunchedVersion, codexHomeBookmark
  }

  private func store(_ value: (any Sendable)?, key: Key) {
    guard !loading else { return }
    if let value {
      defaults.set(value, forKey: key.rawValue)
    } else {
      defaults.removeObject(forKey: key.rawValue)
    }
  }

  private func storeCodable<T: Encodable>(_ value: T, key: Key) {
    guard !loading, let data = try? encoder.encode(value) else { return }
    defaults.set(data, forKey: key.rawValue)
  }

  private static func loadCodable<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: Key) -> T? {
    defaults.data(forKey: key.rawValue).flatMap { try? JSONDecoder().decode(type, from: $0) }
  }
}
