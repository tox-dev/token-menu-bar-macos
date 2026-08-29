import Foundation

public struct WindowRow: Sendable, Hashable, Identifiable {
  public let key: WindowKey
  public let window: QuotaWindow
  public let pace: PaceEstimate
  public let countdown: String
  public let resetClock: String

  public init(key: WindowKey, window: QuotaWindow, pace: PaceEstimate, countdown: String, resetClock: String) {
    self.key = key
    self.window = window
    self.pace = pace
    self.countdown = countdown
    self.resetClock = resetClock
  }

  public var id: WindowKey { key }

  public var percentText: String {
    Format.percent(window.usedPercent)
  }

  public var color: HSBColor {
    UsageColor.color(pace: pace.status, percent: window.usedPercent)
  }
}

public struct Chip: Sendable, Hashable, Identifiable {
  public let text: String
  public let link: URL?

  public init(text: String, link: URL? = nil) {
    self.text = text
    self.link = link
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
  public let fetchedAge: String
  public let source: DataSource?
  public let credentialDescription: String?
  public let emptyTitle: String
  public let emptyDescription: String
  public let isRefreshing: Bool
  public let localUsage: LocalUsage?
  public let codeReviews: String?

  public var id: ProviderID { provider }

  public var isStale: Bool {
    availability != .current && !rows.isEmpty
  }

  public var statusText: String {
    if isRefreshing && rows.isEmpty { return "Fetching…" }
    if rows.isEmpty { return availability.title }
    if isRefreshing { return "updating · \(fetchedAge)" }
    return availability == .current ? "fetched \(fetchedAge)" : "\(availability.title) · \(fetchedAge)"
  }

  public var statusHelp: String {
    source == .cache
      ? "Values stored when the app last ran; refreshing now." : "Values as of the last successful fetch."
  }
}

public enum UsagePresenter {
  public static func cards(
    state: [ProviderID: ProviderState], enabled: Set<ProviderID>, samples: [WindowKey: [UsageSample]], now: Date
  ) -> [ProviderCard] {
    state.keys.sorted().filter { isVisible(state[$0]!, enabled: enabled.contains($0)) }.map { provider in
      card(provider: provider, state: state[provider]!, samples: samples, now: now)
    }
  }

  public static func isVisible(_ state: ProviderState, enabled: Bool) -> Bool {
    if state.snapshot != nil { return true }
    return enabled && state.credentialState?.isMissing != true
  }

  public static func card(
    provider: ProviderID, state: ProviderState, samples: [WindowKey: [UsageSample]], now: Date
  ) -> ProviderCard {
    let snapshot = state.snapshot
    let rows = (snapshot?.windows ?? []).map { window -> WindowRow in
      let key = WindowKey(provider, window)
      return WindowRow(
        key: key,
        window: window,
        pace: PaceEstimate.estimate(window: window, samples: samples[key] ?? [], now: now),
        countdown: Format.countdown(to: window.resetsAt, now: now),
        resetClock: Format.resetClock(window.resetsAt, now: now)
      )
    }
    let (title, description) = emptyState(provider: provider, state: state)
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
      fetchedAge: Format.relativeAge(snapshot?.fetchedAt, now: now),
      source: snapshot?.source,
      credentialDescription: state.credentialState?.description,
      emptyTitle: title,
      emptyDescription: description,
      isRefreshing: state.isRefreshing,
      localUsage: snapshot?.localUsage,
      codeReviews: codeReviewSummary(state.analytics, now: now)
    )
  }

  static func codeReviewSummary(_ analytics: ProviderAnalytics?, now: Date) -> String? {
    guard let analytics else { return nil }
    let reviews = analytics.points.filter { $0.metric == .codeReviews }
    guard !reviews.isEmpty else { return nil }
    let today = DayStamp.string(now)
    let weekStart = DayStamp.string(now.addingTimeInterval(-6 * 86400))
    let todayCount = reviews.filter { $0.day == today }.reduce(0) { $0 + $1.value }
    let weekCount = reviews.filter { $0.day >= weekStart }.reduce(0) { $0 + $1.value }
    return "\(Int(todayCount)) today · \(Int(weekCount)) this week"
  }

  static func chips(provider: ProviderID, snapshot: ProviderSnapshot?) -> [Chip] {
    guard let snapshot else { return [] }
    var chips: [Chip] = []
    if let plan = snapshot.identity?.planName { chips.append(Chip(text: plan, link: provider.usagePage)) }
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
    case .authenticationRequired: ("Sign in to \(provider.displayName)", state.lastError ?? provider.loginHint)
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
