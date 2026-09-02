import Foundation

public enum SettingsSection: String, CaseIterable, Sendable {
  case about
  case menuBar
  case providers
  case data
  case notifications
  case log

  public var title: String {
    switch self {
    case .about: "About"
    case .menuBar: "Menu bar"
    case .providers: "Providers"
    case .data: "Data"
    case .notifications: "Notifications"
    case .log: "Log"
    }
  }
}

public struct SettingsModelRow: Sendable, Equatable, Identifiable {
  public let key: WindowKey
  public let window: QuotaWindow
  public let detail: String
  public let recency: String
  public let isSelected: Bool
  public let defaultLabel: String
  public let label: String
  public let isLabelOverridden: Bool

  public var id: WindowKey { key }

  public init(
    key: WindowKey, window: QuotaWindow, detail: String, recency: String, isSelected: Bool, defaultLabel: String,
    label: String, isLabelOverridden: Bool
  ) {
    self.key = key
    self.window = window
    self.detail = detail
    self.recency = recency
    self.isSelected = isSelected
    self.defaultLabel = defaultLabel
    self.label = label
    self.isLabelOverridden = isLabelOverridden
  }
}

public struct SettingsProviderGroup: Sendable, Equatable, Identifiable {
  public let provider: ProviderID
  public let rows: [SettingsModelRow]
  public let selectedCount: Int
  public let totalCount: Int

  public var id: ProviderID { provider }
  public var selection: SettingsGroupSelection {
    selectedCount == 0 ? .none : selectedCount == totalCount ? .all : .some
  }

  public init(provider: ProviderID, rows: [SettingsModelRow], selectedCount: Int, totalCount: Int) {
    self.provider = provider
    self.rows = rows
    self.selectedCount = selectedCount
    self.totalCount = totalCount
  }
}

public enum SettingsGroupSelection: Sendable, Equatable {
  case none
  case some
  case all
}

public enum ProviderSettingsVisibility {
  public static func providers(
    states: [ProviderID: ProviderState], configured _: Set<ProviderID>, showAll: Bool,
    revealed: ProviderID? = nil
  ) -> [ProviderID] {
    ProviderID.allCases.filter { provider in
      showAll || provider == revealed || discovered(states[provider])
    }
  }

  public static func discovered(_ state: ProviderState?) -> Bool {
    guard let state else { return false }
    if state.snapshot != nil || state.analytics != nil { return true }
    switch state.credentialHealth {
    case .valid: return true
    case .unchecked:
      guard let credential = state.credentialState else { return false }
      if case .valid = credential { return true }
      return false
    case .missing, .expired, .unreadable: return false
    }
  }

  public static func isActive(
    _ provider: ProviderID,
    state: ProviderState?,
    enabled: Set<ProviderID>,
    overridden: Set<ProviderID>
  ) -> Bool {
    guard discovered(state) else { return false }
    return !overridden.contains(provider) || enabled.contains(provider)
  }

  public static func activeProviders(
    states: [ProviderID: ProviderState],
    enabled: Set<ProviderID>,
    overridden: Set<ProviderID>
  ) -> Set<ProviderID> {
    Set(ProviderID.allCases.filter { isActive($0, state: states[$0], enabled: enabled, overridden: overridden) })
  }
}

public enum ShortLabelPolicy {
  public static let limit = 6

  public static func draft(_ label: String) -> String {
    String(label.prefix(limit))
  }

  public static func override(_ label: String, default defaultLabel: String) -> String? {
    let value = draft(label).trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || normalized(value) == normalized(defaultLabel) ? nil : value
  }

  public static func derivedLabels(windows: [WindowKey: QuotaWindow]) -> [WindowKey: String] {
    var labels: [WindowKey: String] = [:]
    var used: Set<String> = []
    for key in windows.keys.sorted() {
      guard let window = windows[key] else { continue }
      let base = StatusItemBuilder.defaultShortLabel(provider: key.provider, window: window)
      labels[key] = unique(base, used: &used)
    }
    return labels
  }

  public static func resolvedLabels(
    windows: [WindowKey: QuotaWindow], overrides: [WindowKey: String]
  ) -> [WindowKey: String] {
    let defaults = derivedLabels(windows: windows)
    var candidates: [WindowKey: String] = [:]
    var candidateValues: Set<String> = []
    for key in windows.keys.sorted() {
      guard let defaultLabel = defaults[key],
        let value = overrides[key].flatMap({ override($0, default: defaultLabel) })
      else { continue }
      let normalizedValue = normalized(value)
      guard candidateValues.insert(normalizedValue).inserted else { continue }
      candidates[key] = value
    }
    while true {
      let fallbackLabels = defaults.filter { candidates[$0.key] == nil }
      let rejected = candidates.keys.filter { key in
        guard let value = candidates[key] else { return false }
        return fallbackLabels.contains { $0.key != key && normalized($0.value) == normalized(value) }
      }
      guard !rejected.isEmpty else { break }
      for key in rejected { candidates[key] = nil }
    }
    return defaults.merging(candidates) { _, candidate in candidate }
  }

  public static func conflictingKey(
    _ label: String, for key: WindowKey, windows: [WindowKey: QuotaWindow], overrides: [WindowKey: String]
  ) -> WindowKey? {
    let defaults = derivedLabels(windows: windows)
    guard let defaultLabel = defaults[key], let value = override(label, default: defaultLabel) else { return nil }
    let normalizedValue = normalized(value)
    var otherOverrides = overrides
    otherOverrides[key] = nil
    let resolved = resolvedLabels(windows: windows, overrides: otherOverrides)
    return windows.keys.sorted().first { other in
      guard other != key else { return false }
      if resolved[other].map({ normalized($0) == normalizedValue }) == true { return true }
      guard let otherDefault = defaults[other],
        let otherValue = otherOverrides[other].flatMap({ override($0, default: otherDefault) })
      else { return false }
      return normalized(otherValue) == normalizedValue
    }
  }

  public static func validOverrides(
    windows: [WindowKey: QuotaWindow], persisted: [WindowKey: String], drafts: [WindowKey: String]
  ) -> [WindowKey: String] {
    let defaults = derivedLabels(windows: windows)
    var result = persisted
    for key in drafts.keys.sorted() {
      guard let draft = drafts[key], let defaultLabel = defaults[key] else { continue }
      guard conflictingKey(draft, for: key, windows: windows, overrides: result) == nil else { continue }
      result[key] = override(draft, default: defaultLabel)
    }
    return result
  }

  static func normalized(_ label: String) -> String {
    label.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .lowercased()
  }

  static func unique(_ base: String, used: inout Set<String>) -> String {
    let base = draft(base)
    if used.insert(normalized(base)).inserted { return base }
    var ordinal = 2
    var candidate: String
    repeat {
      let suffix = String(ordinal, radix: 36).uppercased()
      candidate = String(base.prefix(max(limit - suffix.count, 0))) + suffix
      ordinal += 1
    } while !used.insert(normalized(candidate)).inserted
    return candidate
  }
}

public struct SettingsOrderDraft: Sendable, Equatable {
  public private(set) var providers: [ProviderID]
  public private(set) var models: [WindowKey]

  public init(providers: [ProviderID], models: [WindowKey], available: [WindowKey]) {
    let availableProviders = available.map(\.provider).uniqued()
    self.providers = Self.normalized(providers, available: availableProviders)
    let providerMajor = self.providers.flatMap { provider in available.filter { $0.provider == provider } }
    let normalizedModels = Self.normalized(models, available: providerMajor)
    self.models = self.providers.flatMap { provider in normalizedModels.filter { $0.provider == provider } }
  }

  public mutating func moveProvider(_ provider: ProviderID, before target: ProviderID) {
    Self.move(provider, before: target, in: &providers)
  }

  public mutating func moveModel(_ key: WindowKey, before target: WindowKey) {
    guard key.provider == target.provider else { return }
    Self.move(key, before: target, in: &models)
  }

  public mutating func moveProvider(_ provider: ProviderID, by offset: Int) {
    Self.move(provider, by: offset, in: &providers)
  }

  public mutating func moveModel(_ key: WindowKey, by offset: Int) {
    var providerModels = models.filter { $0.provider == key.provider }
    Self.move(key, by: offset, in: &providerModels)
    var iterator = providerModels.makeIterator()
    models = models.map { $0.provider == key.provider ? iterator.next()! : $0 }
  }

  public func orderedSelection(_ selected: [WindowKey]) -> [WindowKey] {
    let selected = Set(selected)
    return providers.flatMap { provider in models.filter { $0.provider == provider && selected.contains($0) } }
  }

  static func normalized<Value: Hashable>(_ preferred: [Value], available: [Value]) -> [Value] {
    let availableSet = Set(available)
    let preferredSet = Set(preferred)
    return preferred.filter { availableSet.contains($0) }.uniqued()
      + available.filter { !preferredSet.contains($0) }.uniqued()
  }

  static func move<Value: Equatable>(_ value: Value, before target: Value, in values: inout [Value]) {
    guard value != target, values.contains(value), values.contains(target) else { return }
    values.removeAll { $0 == value }
    guard let targetIndex = values.firstIndex(of: target) else { return }
    values.insert(value, at: min(targetIndex, values.count))
  }

  static func move<Value: Equatable>(_ value: Value, by offset: Int, in values: inout [Value]) {
    guard let index = values.firstIndex(of: value) else { return }
    let target = min(max(index + offset, 0), values.count - 1)
    guard target != index else { return }
    values.remove(at: index)
    values.insert(value, at: target)
  }
}

public enum SettingsModelPresentation {
  public static func groups(
    snapshots: [ProviderID: ProviderSnapshot], selected: [WindowKey], labels: [WindowKey: String],
    providerOrder: [ProviderID], modelOrder: [WindowKey], query: String, hideUnused: Bool,
    lastUsedAt: [WindowKey: Date] = [:], revealedKey: WindowKey? = nil, now: Date
  ) -> [SettingsProviderGroup] {
    let availablePairs = snapshots.flatMap { provider, snapshot in
      snapshot.windows.map { (WindowKey(provider, $0), $0) }
    }
    let availableWindows = Dictionary(uniqueKeysWithValues: availablePairs)
    let available = availablePairs.map(\.0)
    let order = SettingsOrderDraft(providers: providerOrder, models: modelOrder, available: available)
    let selectedSet = Set(selected)
    let normalizedQuery = normalized(query)
    let defaultLabels = ShortLabelPolicy.derivedLabels(windows: availableWindows)
    let resolvedLabels = ShortLabelPolicy.resolvedLabels(windows: availableWindows, overrides: labels)
    return order.providers.compactMap { provider in
      guard let snapshot = snapshots[provider] else { return nil }
      let windows = Dictionary(uniqueKeysWithValues: snapshot.windows.map { (WindowKey(provider, $0), $0) })
      let providerKeys = order.models.filter { $0.provider == provider && windows[$0] != nil }
      let rows = order.models.compactMap { key -> SettingsModelRow? in
        guard key.provider == provider, let window = windows[key] else { return nil }
        guard let defaultLabel = defaultLabels[key], let label = resolvedLabels[key] else { return nil }
        let labelOverride = labels[key].flatMap { ShortLabelPolicy.override($0, default: defaultLabel) }
        let isLabelOverridden = labelOverride == label
        guard
          key == revealedKey
            || ((!hideUnused || window.usedPercent > 0 || lastUsedAt[key] != nil)
              && (normalizedQuery.isEmpty
                || [provider.displayName, window.label, window.id, label].contains(where: {
                  normalized($0).contains(normalizedQuery)
                })))
        else { return nil }
        let lastUse = lastUsedAt[key] ?? (window.usedPercent > 0 ? snapshot.fetchedAt : nil)
        return SettingsModelRow(
          key: key, window: window, detail: detail(window), recency: recency(lastUse, now: now),
          isSelected: selectedSet.contains(key), defaultLabel: defaultLabel, label: label,
          isLabelOverridden: isLabelOverridden)
      }
      guard !rows.isEmpty else { return nil }
      return SettingsProviderGroup(
        provider: provider, rows: rows, selectedCount: providerKeys.count(where: { selectedSet.contains($0) }),
        totalCount: providerKeys.count)
    }
  }

  public static func lastUsageDates(_ chronologicalSamples: [UsageSample]) -> [WindowKey: Date] {
    var previous: [WindowKey: UsageSample] = [:]
    var result: [WindowKey: Date] = [:]
    for sample in chronologicalSamples {
      let prior = previous[sample.key]
      if sample.usedPercent > 0,
        prior.map({ sample.resetsAt != $0.resetsAt || sample.usedPercent > $0.usedPercent }) ?? true
      {
        result[sample.key] = sample.timestamp
      }
      previous[sample.key] = sample
    }
    return result
  }

  static func detail(_ window: QuotaWindow) -> String {
    switch window.id {
    case "session", "weekly", "monthly": "window · \(StatusTemplate.windowTag(window))"
    default: window.id
    }
  }

  static func recency(_ date: Date?, now: Date) -> String {
    guard let date else { return "no usage recorded" }
    if Format.calendar.isDate(date, inSameDayAs: now) { return "today" }
    return "last \(date.formatted(.dateTime.month(.abbreviated).day()))"
  }

  static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct SettingsProviderPresentation: Sendable, Equatable {
  public let identity: String?
  public let lastSuccess: String
  public let service: String

  public init(state: ProviderState, now: Date) {
    if let identity = state.snapshot?.identity {
      self.identity = [identity.email, identity.organization, identity.planName, identity.tier]
        .compactMap { $0 }
        .uniqued()
        .joined(separator: " · ")
    } else {
      identity = nil
    }
    lastSuccess =
      state.lastSuccess.map { "Last success \(Format.relativeAge($0, now: now))" } ?? "No successful refresh"
    service = Self.service(state.serviceHealth)
  }

  static func service(_ health: ProviderServiceHealth) -> String {
    switch health {
    case .unchecked: "Service not checked"
    case .checking: "Checking service"
    case .available: "Service available"
    case .offline(let detail): "Offline · \(detail)"
    case .rateLimited(let retryAt, let detail):
      retryAt.map { "Rate limited · retry \($0.formatted(date: .abbreviated, time: .shortened)) · \(detail)" }
        ?? "Rate limited · \(detail)"
    case .unavailable(let detail): "Unavailable · \(detail)"
    }
  }
}
