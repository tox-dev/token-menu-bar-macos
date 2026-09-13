import Foundation

public enum StatusIconTone: String, Sendable, Equatable {
  case normal
  case offline
  case attention
}

public struct StatusBar: Hashable, Sendable {
  public let label: String
  public let percent: Double

  public init(label: String, percent: Double) {
    self.label = label
    self.percent = percent
  }
}

public struct StatusCell: Hashable, Sendable, Identifiable {
  public let id: String
  public let provider: ProviderID
  public let lines: [[StatusRun]]
  public let bars: [StatusBar]
  public let percent: Double
  public let tooltip: String
  public let isStale: Bool

  public init(
    id: String, provider: ProviderID, lines: [[StatusRun]], bars: [StatusBar] = [], percent: Double, tooltip: String,
    isStale: Bool = false
  ) {
    self.id = id
    self.provider = provider
    self.lines = lines
    self.bars = bars
    self.percent = percent
    self.tooltip = isStale ? "Stale, last known values. \(tooltip)" : tooltip
    self.isStale = isStale
  }

  public var isMiniBar: Bool {
    !bars.isEmpty
  }
}

public struct StatusItemModel: Hashable, Sendable {
  public let cells: [StatusCell]
  public let iconTone: StatusIconTone
  public let showsIcon: Bool
  public let countdownActive: Bool
  public let accessibilitySummary: String?

  public init(
    cells: [StatusCell], iconTone: StatusIconTone, showsIcon: Bool, countdownActive: Bool,
    accessibilitySummary: String? = nil
  ) {
    self.cells = cells
    self.iconTone = iconTone
    self.showsIcon = showsIcon
    self.countdownActive = countdownActive
    self.accessibilitySummary = accessibilitySummary
  }

  public static let empty = StatusItemModel(cells: [], iconTone: .normal, showsIcon: true, countdownActive: false)

  public var tooltip: String {
    accessibilitySummary ?? cells.map(\.tooltip).joined(separator: "\n")
  }
}

public enum WindowOrder: String, CaseIterable, Codable, Sendable {
  case provider = "By provider"
  case percent = "By percent used"
}

public struct StatusItemInput: Sendable {
  public let snapshots: [ProviderID: ProviderSnapshot]
  public let availability: [ProviderID: QuotaAvailability]
  public let selectedKeys: [WindowKey]
  public let format: StatusFormat
  public let customTemplate: String
  public let decimals: Int
  public let hideZeroCells: Bool
  public let order: WindowOrder
  public let labels: [WindowKey: String]
  public let now: Date
  public let display: UsageDisplay
  public let tier: StatusTier

  public init(
    snapshots: [ProviderID: ProviderSnapshot],
    availability: [ProviderID: QuotaAvailability],
    selectedKeys: [WindowKey],
    format: StatusFormat,
    customTemplate: String,
    decimals: Int,
    hideZeroCells: Bool,
    order: WindowOrder,
    labels: [WindowKey: String],
    now: Date,
    display: UsageDisplay = .used,
    tier: StatusTier = .configured
  ) {
    self.snapshots = snapshots
    self.availability = availability
    self.selectedKeys = selectedKeys
    self.format = format
    self.customTemplate = customTemplate
    self.decimals = decimals
    self.hideZeroCells = hideZeroCells
    self.order = order
    self.labels = labels
    self.now = now
    self.display = display
    self.tier = tier
  }

  public func with(tier: StatusTier) -> StatusItemInput {
    StatusItemInput(
      snapshots: snapshots, availability: availability, selectedKeys: selectedKeys, format: format,
      customTemplate: customTemplate, decimals: decimals, hideZeroCells: hideZeroCells, order: order, labels: labels,
      now: now, display: display, tier: tier)
  }

  var effectiveFormat: StatusFormat {
    switch tier {
    case .configured, .iconOnly: format
    case .stacked, .worstPerProvider: .stacked
    case .miniBars: .miniBars
    }
  }
}

public enum StatusItemBuilder {
  public static func defaultSelection(_ snapshots: [ProviderID: ProviderSnapshot]) -> [WindowKey] {
    snapshots.keys.sorted().flatMap { provider -> [WindowKey] in
      let windows = snapshots[provider]!.windows.filter(\.isActive)
      let preferred = windows.filter { $0.id == "session" || $0.id == "weekly" || $0.id.hasPrefix("weekly:") }
      return (preferred.isEmpty ? Array(windows.prefix(2)) : preferred).map { WindowKey(provider, $0) }
    }
  }

  public static func defaultShortLabel(provider: ProviderID, window: QuotaWindow) -> String {
    if window.scope == nil && ["session", "weekly", "monthly"].contains(window.id) {
      return ShortLabelPolicy.draft("\(provider.shortLabel) \(StatusTemplate.windowTag(window))")
    }
    return ShortLabelPolicy.draft(semanticShortLabel(provider: provider, window: window))
  }

  static func semanticShortLabel(provider: ProviderID, window: QuotaWindow) -> String {
    let source = window.scope ?? window.label
    let words =
      source
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    let normalized = words.joined(separator: " ").lowercased()
    let digits = words.flatMap { $0.filter(\.isNumber) }
    if normalized.contains("opus") { return "OP" + (digits.first.map(String.init) ?? "") }
    if normalized.contains("sonnet") { return "SO" }
    if normalized.contains("haiku") { return "HA" }
    if normalized.contains("fable") { return "FAB" }
    if normalized.contains("spark") { return "SPK" }
    if normalized.contains("flash") { return provider == .gemini ? "GFL" : "FLA" }
    if provider == .gemini, normalized.contains("pro"), !digits.isEmpty { return "G" + String(digits.prefix(2)) }
    if normalized.contains("code review") { return "CR" }
    if normalized.contains("on demand") { return "OND" }
    if normalized.contains("premium") { return "PRE" }
    if provider == .copilot, normalized.contains("completion") { return "GHX" }
    if provider == .copilot, normalized.contains("chat") { return "GHC" }
    let ignored = Set(["claude", "codex", "gemini", "github", "copilot", "model", "models", "window"])
    let meaningful = words.filter { !ignored.contains($0.lowercased()) }
    guard meaningful.count != 1 else { return String(meaningful[0].prefix(3)).uppercased() }
    let initials = meaningful.compactMap(\.first).map(String.init).joined().uppercased()
    if initials.count >= 2 { return String(initials.prefix(3)) }
    return String(source.prefix(3)).uppercased()
  }

  public static func candidates(_ input: StatusItemInput) -> [StatusItemModel] {
    var models: [StatusItemModel] = []
    for tier in StatusTier.allCases {
      let model = build(input.with(tier: tier))
      if !models.contains(model) { models.append(model) }
    }
    return models
  }

  public static func build(_ input: StatusItemInput) -> StatusItemModel {
    var restrictions: [WindowKey: StatusQuotaRestriction] = [:]
    let selectedEntries = input.selectedKeys.compactMap { key -> (WindowKey, ProviderSnapshot, QuotaWindow)? in
      guard let snapshot = input.snapshots[key.provider], let window = snapshot.window(key.windowID) else { return nil }
      let restriction = StatusQuotaRestriction(window: window, snapshot: snapshot, now: input.now)
      restrictions[key] = restriction
      return (key, snapshot, restriction?.projected(window) ?? window)
    }
    let exhausted = selectedEntries.filter {
      (restrictions[$0.0] != nil || $0.2.isActive) && $0.2.usedPercent >= 100
        && ($0.2.resetsAt.map { $0 > input.now } ?? true)
    }
    let tone: StatusIconTone =
      !exhausted.isEmpty
      ? .attention
      : input.availability.values.contains(.authenticationRequired)
        ? .attention : input.availability.values.contains(.networkUnavailable) ? .offline : .normal
    if input.tier == .iconOnly {
      let summary = exhausted.map { key, _, window in
        "\(key.provider.displayName): "
          + (restrictions[key]?.explanation(now: input.now)
            ?? "\(window.label) limit reached; resets \(Format.countdown(to: window.resetsAt, now: input.now)).")
      }.uniqued().joined(separator: "\n")
      return StatusItemModel(
        cells: [], iconTone: tone, showsIcon: true, countdownActive: false,
        accessibilitySummary: summary.isEmpty ? nil : summary)
    }
    let format = input.effectiveFormat
    let template = StatusTemplate.compile(format.template ?? input.customTemplate)
    var availableWindows: [WindowKey: QuotaWindow] = [:]
    for (provider, snapshot) in input.snapshots {
      for window in snapshot.windows { availableWindows[WindowKey(provider, window)] = window }
    }
    let labels = ShortLabelPolicy.resolvedLabels(windows: availableWindows, overrides: input.labels)
    var entries = selectedEntries
    if input.hideZeroCells { entries = entries.filter { $0.2.usedPercent > 0 } }
    if input.tier == .worstPerProvider { entries = worstPerProvider(entries) }
    if input.order == .percent { entries.sort { $0.2.usedPercent > $1.2.usedPercent } }
    let countdown =
      format != .miniBars
      && entries.contains { entry in
        guard let reset = entry.2.resetsAt, reset > input.now else { return false }
        return template.referencesCountdown || template.referencesExhaustedCountdown && entry.2.usedPercent >= 100
      }
    let cells: [StatusCell]
    if format == .miniBars {
      let providers = input.order == .percent ? orderedProviders(entries) : entries.map(\.0.provider).uniqued()
      cells = providers.map { provider in
        let own = entries.filter { $0.0.provider == provider }
        let bars = own.map {
          StatusBar(
            label: labels[$0.0]!,
            percent: $0.2.usedPercent)
        }
        let tooltip = own.map { key, snapshot, window in
          let raw = snapshot.window(key.windowID)!
          return "\(window.label): \(percentText(raw, display: input.display))"
            + (restrictions[key].map { "\n" + $0.explanation(now: input.now) } ?? "")
        }
        .joined(separator: "\n")
        return StatusCell(
          id: provider.rawValue, provider: provider, lines: [], bars: bars,
          percent: own.map(\.2.usedPercent).max()!, tooltip: tooltip,
          isStale: (input.availability[provider] ?? .current) != .current)
      }
    } else {
      let perProvider = Dictionary(grouping: entries, by: \.0.provider).mapValues(\.count)
      cells = entries.map { key, snapshot, window in
        let tag = StatusTemplate.windowTag(window)
        let context = StatusCellContext(
          provider: key.provider,
          window: window,
          cellLabel: perProvider[key.provider]! > 1
            ? "\(key.provider.shortLabel) \(tag)" : key.provider.shortLabel,
          shortLabel: labels[key]!,
          decimals: input.decimals,
          planName: snapshot.identity?.planName,
          credits: snapshot.credits?.formattedBalance,
          now: input.now,
          display: input.display,
          isLimited: restrictions[key] != nil
        )
        var lines = StatusTemplate.render(template, context: context)
        if restrictions[key] != nil, !lines.joined().contains(where: { $0.kind == .usage(100) }) {
          if lines.isEmpty { lines = [[]] }
          lines[0].append(StatusRun(text: " Limit", kind: .usage(100)))
        }
        let raw = snapshot.window(key.windowID)!
        let tooltip =
          "\(key.provider.displayName) \(window.label): \(percentText(raw, display: input.display)), "
          + "resets \(Format.countdown(to: raw.resetsAt, now: input.now))"
          + (restrictions[key].map { "\n" + $0.explanation(now: input.now) } ?? "")
        return StatusCell(
          id: key.storageKey, provider: key.provider, lines: lines, percent: window.usedPercent, tooltip: tooltip,
          isStale: (input.availability[key.provider] ?? .current) != .current)
      }
    }
    return StatusItemModel(
      cells: cells, iconTone: tone, showsIcon: cells.isEmpty,
      countdownActive: countdown && !cells.isEmpty)
  }

  /// A bare percent reads as used, so only the remaining form says which it is.
  static func percentText(_ window: QuotaWindow, display: UsageDisplay) -> String {
    let text = Format.percent(used: window.usedPercent, display: display)
    return display == .used ? text : "\(text) \(display.suffix)"
  }

  static func worstPerProvider(
    _ entries: [(WindowKey, ProviderSnapshot, QuotaWindow)]
  ) -> [(
    WindowKey, ProviderSnapshot, QuotaWindow
  )] {
    var worst: [ProviderID: (WindowKey, ProviderSnapshot, QuotaWindow)] = [:]
    for entry in entries where (worst[entry.0.provider]?.2.usedPercent ?? -1) < entry.2.usedPercent {
      worst[entry.0.provider] = entry
    }
    return entries.map(\.0.provider).uniqued().compactMap { worst[$0] }
  }

  static func orderedProviders(_ entries: [(WindowKey, ProviderSnapshot, QuotaWindow)]) -> [ProviderID] {
    var best: [ProviderID: Double] = [:]
    for entry in entries { best[entry.0.provider] = max(best[entry.0.provider] ?? 0, entry.2.usedPercent) }
    return best.keys.sorted { (best[$0]!, $1) > (best[$1]!, $0) }
  }
}

extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

/// Text metrics for the status item. They live here rather than in the renderer because they are arithmetic on the
/// menu bar height, and the two-line case has to match the proportions of the system's own widgets.
public enum StatusMetrics {
  public static let maxFontSize: Double = 13
  public static let minFontSize: Double = 8

  public static func fontSizes(height: Double, lineCount: Int) -> [Double] {
    switch lineCount {
    case ...1: [maxFontSize]
    case 2: [9, 11.5]
    default: Array(repeating: max(minFontSize, min(9, height / Double(lineCount) * 0.8)), count: lineCount)
    }
  }
}
