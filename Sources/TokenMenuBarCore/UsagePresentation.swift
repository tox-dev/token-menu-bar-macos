import Foundation

public enum UsageDeadline: Sendable, Hashable {
  case age(Date?)
  case reset(Date?)

  public func text(at now: Date) -> String {
    lines(at: now).joined(separator: " · ")
  }

  public func lines(at now: Date) -> [String] {
    switch self {
    case .age(let date): [Format.relativeAge(date, now: now)]
    case .reset(let date):
      date.map { ["Resets in \(Format.countdown(to: $0, now: now))", Format.resetClock($0, now: now)] }
        ?? ["No reset scheduled"]
    }
  }

  public func nextUpdate(after now: Date) -> Date? {
    switch self {
    case .age(let date):
      guard let date else { return nil }
      let seconds = max(now.timeIntervalSince(date), 0)
      let interval: TimeInterval
      switch seconds {
      case ..<3600: interval = 60
      case ..<86400: interval = 3600
      default: interval = 86400
      }
      let boundary = date.addingTimeInterval((floor(seconds / interval) + 1) * interval)
      return boundary
    case .reset(let date):
      guard let date, date > now else { return nil }
      let seconds = date.timeIntervalSince(now)
      guard seconds >= 60 else { return date }
      let remainder = seconds.truncatingRemainder(dividingBy: 60)
      return now.addingTimeInterval(max(remainder, 1))
    }
  }
}

public struct UsageMetricPresentation: Sendable, Hashable, Identifiable {
  public let title: String
  public let value: String
  public let help: String

  public var id: String { title }

  public init(title: String, value: String, help: String) {
    self.title = title
    self.value = value
    self.help = help
  }
}

public struct UsageSpendPresentation: Sendable, Hashable {
  public let spend: SpendControl
  public let provider: ProviderID
  public let title: String
  public let summary: String
  public let metrics: [UsageMetricPresentation]

  public init(
    spend: SpendControl, provider: ProviderID, title: String, summary: String, metrics: [UsageMetricPresentation]
  ) {
    self.spend = spend
    self.provider = provider
    self.title = title
    self.summary = summary
    self.metrics = metrics
  }
}

public struct UsageCreditsPresentation: Sendable, Hashable {
  public let credits: CreditBalance?
  public let resetCredits: ResetCredits?
  public let metrics: [UsageMetricPresentation]

  public init(
    credits: CreditBalance?, resetCredits: ResetCredits?, metrics: [UsageMetricPresentation]
  ) {
    self.credits = credits
    self.resetCredits = resetCredits
    self.metrics = metrics
  }
}

public struct UsageLocalPresentation: Sendable, Hashable {
  public let usage: LocalUsage
  public let metrics: [UsageMetricPresentation]

  public init(usage: LocalUsage, metrics: [UsageMetricPresentation]) {
    self.usage = usage
    self.metrics = metrics
  }
}

public struct UsageAnalyticsPresentation: Sendable, Hashable {
  public let codeReviews: String?

  public init(codeReviews: String? = nil) {
    self.codeReviews = codeReviews
  }
}

public struct UsagePresentation: Sendable, Equatable {
  public let builtAt: Date
  public let lastRefresh: Date?
  public let iconTone: StatusIconTone
  public let isRefreshing: Bool
  public let cards: [ProviderCard]
  public let emptyTitle: String
  public let emptyDescription: String

  public init(
    builtAt: Date, lastRefresh: Date?, iconTone: StatusIconTone, isRefreshing: Bool, cards: [ProviderCard],
    emptyTitle: String, emptyDescription: String
  ) {
    self.builtAt = builtAt
    self.lastRefresh = lastRefresh
    self.iconTone = iconTone
    self.isRefreshing = isRefreshing
    self.cards = cards
    self.emptyTitle = emptyTitle
    self.emptyDescription = emptyDescription
  }

  public func updatedText(at now: Date) -> String {
    "Updated \(UsageDeadline.age(lastRefresh).text(at: now))"
  }

  public func nextDeadline(after now: Date) -> Date? {
    var deadlines = cards.flatMap { card in
      card.rows.map(\.resetDeadline) + (card.rows.isEmpty ? [] : [.age(card.fetchedAt)])
    }
    deadlines.append(.age(lastRefresh))
    return deadlines.compactMap { $0.nextUpdate(after: now) }.min()
  }
}
