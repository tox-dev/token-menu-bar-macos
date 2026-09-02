import Foundation

/// Consecutive windows that reset together. Claude's weekly models share one reset, so the card printed the same
/// "Resets in 6d 14h · Sep 6 at 1:00 AM" under three rows running; the group carries it once.
public struct WindowRowGroup: Sendable, Hashable, Identifiable {
  public let rows: [WindowRow]
  public let resetText: String?

  public init(rows: [WindowRow], resetText: String?) {
    self.rows = rows
    self.resetText = resetText
  }

  public var id: WindowKey { rows[0].key }

  /// True when the group is a single window, which reads better with its reset on its own row than under a header.
  public var isSingle: Bool { rows.count == 1 }

  public var resetDeadline: UsageDeadline? {
    rows[0].window.resetsAt.map { .reset($0) }
  }

  public func resetText(at now: Date) -> String? {
    resetDeadline?.text(at: now)
  }
}

public struct WindowRow: Sendable, Hashable, Identifiable {
  public let key: WindowKey
  public let window: QuotaWindow
  public let pace: PaceEstimate
  public let countdown: String
  public let resetClock: String
  public let detail: String
  public let paceLabel: String
  public let paceText: String
  public let helpText: String
  public let isSelected: Bool

  public init(
    key: WindowKey, window: QuotaWindow, pace: PaceEstimate, countdown: String, resetClock: String,
    detail: String? = nil, paceLabel: String? = nil, paceText: String? = nil, helpText: String? = nil,
    isSelected: Bool = true
  ) {
    self.key = key
    self.window = window
    self.pace = pace
    self.countdown = countdown
    self.resetClock = resetClock
    self.detail = detail ?? window.id
    self.paceLabel = paceLabel ?? pace.status.title
    self.paceText = paceText ?? pace.status.title
    self.helpText = helpText ?? paceText ?? pace.status.title
    self.isSelected = isSelected
  }

  public var id: WindowKey { key }

  public var percentText: String {
    Format.percent(window.usedPercent)
  }

  public var color: HSBColor {
    UsageColor.color(pace: pace.status, percent: window.usedPercent)
  }

  public var resetDeadline: UsageDeadline {
    .reset(window.resetsAt)
  }

  public func resetText(at now: Date) -> String {
    resetDeadline.text(at: now)
  }

  public func accessibilityValue(at now: Date) -> String {
    let inactive = window.isActive ? "" : ", inactive"
    let selection = isSelected ? "" : ", not shown in the menu bar"
    return
      "\(percentText) used\(inactive)\(selection), \(resetText(at: now).lowercased()), \(pace.comparison(now: now))"
  }
}

public struct Chip: Sendable, Hashable, Identifiable {
  public let text: String

  public init(text: String) {
    self.text = text
  }

  public var id: String { text }
}

public struct ProviderCard: Sendable, Hashable, Identifiable {
  public let provider: ProviderID
  public let availability: QuotaAvailability
  public let identity: ProviderIdentity?
  public let chips: [Chip]
  public let rows: [WindowRow]
  public let credits: CreditBalance?
  public let spend: SpendControl?
  public let resetCredits: ResetCredits?
  public let notices: [Notice]
  public let warnings: [String]
  public let lastError: String?
  public let presentedAt: Date
  public let fetchedAt: Date?
  public let fetchedAge: String
  public let source: DataSource?
  public let emptyTitle: String
  public let emptyDescription: String
  public let isRefreshing: Bool
  public let localUsage: LocalUsage?
  public let codeReviews: String?
  public let groups: [WindowRowGroup]
  public let spendPresentation: UsageSpendPresentation?
  public let creditsPresentation: UsageCreditsPresentation?
  public let localPresentation: UsageLocalPresentation?

  public var id: ProviderID { provider }

  public var isStale: Bool {
    availability != .current && !rows.isEmpty
  }

  /// What sits where the fetch time normally goes. A refresh keeps the numbers it already has on screen, so this
  /// says the values below are the previous ones and when they were read.
  public var statusText: String {
    statusText(at: presentedAt)
  }

  public func statusText(at now: Date) -> String {
    if rows.isEmpty { return isRefreshing ? "Refreshing…" : availability.title }
    let fetchedAge = Format.relativeAge(fetchedAt, now: now)
    // A refresh keeps the numbers it is replacing on screen, so this says they are the previous ones and how old
    // they are. Being offline or rate limited still leads, because it explains why they are not moving.
    guard isRefreshing else {
      return availability == .current ? "fetched \(fetchedAge)" : "\(availability.title) · \(fetchedAge)"
    }
    // "showing <age>" already says the values are old, so only a reason the refresh may not fix leads.
    let explains: Set<QuotaAvailability> = [.networkUnavailable, .rateLimited, .authenticationRequired, .unavailable]
    let prefix = explains.contains(availability) ? "\(availability.title) · " : ""
    return "\(prefix)refreshing… · showing \(fetchedAge)"
  }

  public var statusHelp: String {
    if source == .cache { return "Values stored when the app last ran; refreshing now." }
    if isRefreshing {
      return rows.isEmpty
        ? "Fetching the first values." : "Fetching new values; the ones below are from the last successful fetch."
    }
    return "Values as of the last successful fetch."
  }
}

public enum UsagePresenter {
  public static func iconTone(_ state: [ProviderID: ProviderState]) -> StatusIconTone {
    let availability = state.values.map(\.availability)
    return availability.contains(.authenticationRequired)
      ? .attention : availability.contains(.networkUnavailable) ? .offline : .normal
  }

  /// Groups neighbouring rows that share a reset instant, preserving the order they were selected in.
  public static func groups(_ rows: [WindowRow]) -> [WindowRowGroup] {
    var result: [WindowRowGroup] = []
    for row in rows {
      let reset = row.window.resetsAt
      if let last = result.last, last.rows[0].window.resetsAt == reset, reset != nil {
        result[result.count - 1] = WindowRowGroup(rows: last.rows + [row], resetText: last.resetText)
      } else {
        let text = reset == nil ? nil : "Resets in \(row.countdown) · \(row.resetClock)"
        result.append(WindowRowGroup(rows: [row], resetText: text))
      }
    }
    return result
  }

  public static func cards(
    state: [ProviderID: ProviderState], enabled: Set<ProviderID>, samples: [WindowKey: [UsageSample]], now: Date
  ) -> [ProviderCard] {
    state.keys.sorted().filter { isVisible(state[$0]!, enabled: enabled.contains($0)) }.map { provider in
      card(provider: provider, state: state[provider]!, samples: samples, now: now)
    }
  }

  public static func presentation(
    state: [ProviderID: ProviderState], enabled: Set<ProviderID>, selected: Set<WindowKey>,
    samples: [WindowKey: [UsageSample]], analytics: [ProviderID: UsageAnalyticsPresentation], lastRefresh: Date?,
    iconTone: StatusIconTone, isRefreshing: Bool, now: Date
  ) -> UsagePresentation {
    let cards = state.keys.sorted().filter { isVisible(state[$0]!, enabled: enabled.contains($0)) }.map { provider in
      card(
        provider: provider, state: state[provider]!, samples: samples, selected: selected,
        analytics: analytics[provider] ?? UsageAnalyticsPresentation(), now: now)
    }
    return UsagePresentation(
      builtAt: now, lastRefresh: lastRefresh, iconTone: iconTone, isRefreshing: isRefreshing, cards: cards,
      emptyTitle: enabled.isEmpty ? "No providers enabled" : "No usage available",
      emptyDescription: "Set up providers under Settings > Providers.")
  }

  public static func isVisible(_ state: ProviderState, enabled: Bool) -> Bool {
    guard enabled else { return false }
    if state.snapshot != nil || state.analytics != nil || state.credentialHealth.isUsable { return true }
    if case .valid = state.credentialState { return true }
    return false
  }

  public static func card(
    provider: ProviderID, state: ProviderState, samples: [WindowKey: [UsageSample]], now: Date
  ) -> ProviderCard {
    card(
      provider: provider, state: state, samples: samples, selected: nil,
      analytics: analyticsPresentation(state.analytics, now: now), now: now)
  }

  static func card(
    provider: ProviderID, state: ProviderState, samples: [WindowKey: [UsageSample]], selected: Set<WindowKey>?,
    analytics: UsageAnalyticsPresentation, now: Date
  ) -> ProviderCard {
    let snapshot = state.snapshot
    let rows = (snapshot?.windows ?? []).filter { window in
      selected?.contains(WindowKey(provider, window)) ?? true
    }.map { window -> WindowRow in
      let key = WindowKey(provider, window)
      let pace = PaceEstimate.estimate(window: window, samples: samples[key] ?? [], now: now)
      return WindowRow(
        key: key,
        window: window,
        pace: pace,
        countdown: Format.countdown(to: window.resetsAt, now: now),
        resetClock: Format.resetClock(window.resetsAt, now: now),
        detail: detail(window),
        paceLabel: pace.status.title,
        paceText: pace.summary(now: now),
        helpText: helpText(window: window, pace: pace, now: now),
        isSelected: selected?.contains(key) ?? true
      )
    }
    let (title, description) = emptyState(provider: provider, state: state)
    let spend = snapshot?.spend.map { spendPresentation($0, provider: provider, now: now) }
    let credits = creditsPresentation(snapshot?.credits, resetCredits: snapshot?.resetCredits)
    let local = snapshot?.localUsage.map(localPresentation)
    return ProviderCard(
      provider: provider,
      availability: state.availability,
      identity: snapshot?.identity,
      chips: chips(provider: provider, snapshot: snapshot),
      rows: rows,
      credits: snapshot?.credits,
      spend: snapshot?.spend,
      resetCredits: snapshot?.resetCredits,
      notices: snapshot?.notices ?? [],
      warnings: state.warnings,
      lastError: state.lastError,
      presentedAt: now,
      fetchedAt: snapshot?.fetchedAt,
      fetchedAge: Format.relativeAge(snapshot?.fetchedAt, now: now),
      source: snapshot?.source,
      emptyTitle: title,
      emptyDescription: description,
      isRefreshing: state.isRefreshing,
      localUsage: snapshot?.localUsage,
      codeReviews: analytics.codeReviews,
      groups: groups(rows),
      spendPresentation: spend,
      creditsPresentation: credits,
      localPresentation: local
    )
  }

  public static func analyticsPresentation(_ analytics: ProviderAnalytics?, now: Date) -> UsageAnalyticsPresentation {
    UsageAnalyticsPresentation(codeReviews: codeReviewSummary(analytics, now: now))
  }

  static func codeReviewSummary(_ analytics: ProviderAnalytics?, now: Date) -> String? {
    guard let analytics else { return nil }
    // UIEnvironment caches this by analytics revision and UTC day, avoiding another 60-day scan on quota updates.
    let today = DayStamp.string(now)
    let weekStart = DayStamp.string(now.addingTimeInterval(-6 * 86400))
    var todayCount = 0.0
    var weekCount = 0.0
    var any = false
    for point in analytics.points where point.metric == .codeReviews {
      any = true
      if point.day == today { todayCount += point.value }
      if point.day >= weekStart { weekCount += point.value }
    }
    guard any else { return nil }
    return "\(Int(todayCount)) today · \(Int(weekCount)) this week"
  }

  public static func spendPresentation(
    _ spend: SpendControl, provider: ProviderID, now: Date
  ) -> UsageSpendPresentation {
    var metrics: [UsageMetricPresentation] = []
    if let limit = spend.limit {
      metrics.append(
        UsageMetricPresentation(
          title: "Monthly limit", value: limit.formatted, help: "Spend cap for credits beyond plan limits."))
    }
    if let used = spend.used {
      metrics.append(
        UsageMetricPresentation(title: "Spent", value: used.formatted, help: "Credits consumed this month."))
    }
    if let balance = spend.balance {
      metrics.append(
        UsageMetricPresentation(title: "Balance", value: balance.formatted, help: "Prepaid credit balance."))
    }
    if let resets = spend.resetsAt {
      metrics.append(
        UsageMetricPresentation(
          title: "Resets", value: Format.resetClock(resets, now: now),
          help: "When the monthly spend counter resets."))
    }
    if let autoReload = spend.autoReload {
      metrics.append(
        UsageMetricPresentation(
          title: "Auto-reload", value: autoReload ? "On" : "Off", help: "Whether credits top up automatically."))
    }
    metrics.append(
      UsageMetricPresentation(
        title: "Purchase", value: spend.canPurchaseCredits ? "Available" : "Website only",
        help: "Credits are bought on the provider website; the app displays their state."))
    return UsageSpendPresentation(
      spend: spend, provider: provider, title: provider == .claude ? "Usage credits" : "Spend control",
      summary: spendSummary(spend), metrics: metrics)
  }

  public static func creditsPresentation(
    _ credits: CreditBalance?, resetCredits: ResetCredits?
  ) -> UsageCreditsPresentation? {
    var metrics: [UsageMetricPresentation] = []
    if let credits {
      metrics.append(
        UsageMetricPresentation(
          title: "Credits", value: creditsSummary(credits), help: "Credits extend usage beyond plan limits."))
      if credits.overageLimitReached {
        metrics.append(
          UsageMetricPresentation(
            title: "Overage", value: "Limit reached", help: "The credit overage cap has been hit."))
      }
      if let cloud = credits.approxCloudMessages, cloud.upperBound > 0 {
        metrics.append(
          UsageMetricPresentation(
            title: "Cloud messages", value: "~\(cloud.lowerBound)–\(cloud.upperBound)",
            help: "Estimated cloud task messages the balance covers."))
      }
    }
    if let resetCredits {
      metrics.append(
        UsageMetricPresentation(
          title: "Limit resets", value: "\(resetCredits.available) available",
          help: "Usage-limit resets available to redeem; \(resetCredits.applicable) apply now."))
      if let earned = resetCredits.totalEarned {
        metrics.append(
          UsageMetricPresentation(title: "Resets earned", value: "\(earned)", help: "Reset credits earned so far."))
      }
    }
    return metrics.isEmpty
      ? nil : UsageCreditsPresentation(credits: credits, resetCredits: resetCredits, metrics: metrics)
  }

  public static func localPresentation(_ usage: LocalUsage) -> UsageLocalPresentation {
    UsageLocalPresentation(
      usage: usage,
      metrics: [
        UsageMetricPresentation(
          title: "5-hour block", value: Format.compactNumber(Double(usage.windowTokens)) + " tokens",
          help: "Tokens the CLI logged since the session window started, including cache reads."),
        UsageMetricPresentation(
          title: "Block cost", value: localMoney(usage.windowCost),
          help: "API list-price equivalent for the same traffic; subscriptions are not billed per token."),
        UsageMetricPresentation(
          title: "Burn rate", value: localMoney(usage.costPerHour) + "/hr",
          help: "API-equivalent spend per hour over the current block."),
        UsageMetricPresentation(
          title: "Today", value: Format.compactNumber(Double(usage.todayTokens)) + " tokens",
          help: "Tokens logged today, including cache reads."),
        UsageMetricPresentation(
          title: "Messages today", value: "\(usage.todayMessages)", help: "Assistant messages logged today."),
        UsageMetricPresentation(
          title: "Today cost", value: localMoney(usage.todayCost), help: "API-equivalent cost of today's traffic."),
      ])
  }

  public static func localMoney(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
  }

  static func detail(_ window: QuotaWindow) -> String {
    switch window.id {
    case "session", "weekly", "monthly":
      window.duration.map { "window · \(Format.duration($0))" } ?? "window"
    default: window.id
    }
  }

  static func helpText(window: QuotaWindow, pace: PaceEstimate, now: Date) -> String {
    var parts = [
      "Used \(Format.percent(window.usedPercent, decimals: 1)); "
        + "\(Format.percent(window.remainingPercent, decimals: 1)) remains."
    ]
    if let duration = window.duration { parts.append("Window duration: \(Format.duration(duration)).") }
    if let expected = pace.expectedPercent {
      parts.append("Even pace would be \(Format.percent(expected)) by now.")
    }
    if let ratio = pace.ratio {
      parts.append("Pace ratio: \(ratio.formatted(.number.precision(.fractionLength(2))))×.")
    }
    parts.append(pace.summary(now: now) + ".")
    parts.append("Severity: \(window.severity.rawValue).")
    return parts.joined(separator: " ")
  }

  static func chips(provider: ProviderID, snapshot: ProviderSnapshot?) -> [Chip] {
    guard let snapshot else { return [] }
    var chips: [Chip] = []
    if let plan = snapshot.identity?.planName { chips.append(Chip(text: plan)) }
    if let email = snapshot.identity?.email { chips.append(Chip(text: email)) }
    if let organization = snapshot.identity?.organization,
      organization != snapshot.identity?.email.map({ "\($0)'s Organization" })
    {
      chips.append(Chip(text: organization))
    }
    if let until = snapshot.identity?.subscriptionActiveUntil {
      chips.append(Chip(text: "Renews \(until.formatted(date: .abbreviated, time: .omitted))"))
    }
    if snapshot.source == .localLog { chips.append(Chip(text: "From local logs")) }
    return chips
  }

  static func emptyState(provider: ProviderID, state: ProviderState) -> (String, String) {
    switch state.availability {
    case .loading: ("Loading \(provider.displayName)", "Fetching usage from \(provider.displayName)…")
    case .authenticationRequired:
      ("No usage available", "Review \(provider.displayName) under Settings > Providers.")
    case .networkUnavailable: ("\(provider.displayName) is offline", state.lastError ?? "No network connection.")
    case .disabled: ("\(provider.displayName) disabled", "Enable it under Settings > Providers.")
    case .unavailable:
      ("\(provider.displayName) unavailable", state.lastError ?? "The usage endpoint returned an error.")
    case .rateLimited:
      ("\(provider.displayName) rate limited", state.lastError ?? "The usage endpoint asked us to slow down.")
    case .current, .stale: ("No usage yet", "\(provider.displayName) reports no active limits.")
    }
  }

  public static func spendSummary(_ spend: SpendControl) -> String {
    guard spend.enabled else { return spend.disabledReason.map { "Off (\(Format.humanize($0)))" } ?? "Off" }
    let used = spend.used?.formatted ?? "—"
    let limit = spend.limit?.formatted ?? "no limit"
    let percent = spend.percent.map { " (\(Format.percent($0)))" } ?? ""
    return "\(used) of \(limit)\(percent)"
  }

  public static func creditsSummary(_ credits: CreditBalance) -> String {
    if credits.unlimited { return "Unlimited" }
    guard credits.hasCredits, let balance = credits.balance, balance > 0 else { return "No credits" }
    var text = credits.formattedBalance
    if let local = credits.approxLocalMessages, local.upperBound > 0 {
      text += " · ~\(local.lowerBound)–\(local.upperBound) local messages"
    }
    return text
  }
}
