import SwiftUI
import TokenMenuBarCore

public struct UsageTab: View {
  @Bindable var environment: UIEnvironment

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  public var body: some View {
    ScrollingTab {
      VStack(alignment: .leading, spacing: 12) {
        header
        let cards = environment.cards
        if cards.isEmpty {
          EmptyStateView(
            title: "No providers enabled", systemImage: "slider.horizontal.3",
            description: "Enable a provider under Settings > Providers.")
        }
        ForEach(cards) { card in
          ProviderCardView(card: card, environment: environment)
        }
      }
      .frame(minWidth: PopoverGeometry.contentWidth(for: .usage), alignment: .leading)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      AppIconView(size: 22, tone: environment.state.statusModel.iconTone)
      VStack(alignment: .leading, spacing: 1) {
        Text(environment.appInfo.name).font(.headline)
        Text("Updated \(Format.relativeAge(environment.state.lastRefresh, now: environment.now))")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if environment.isDemo {
        Text("Demo data")
          .font(.caption.weight(.medium))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.orange.opacity(0.2), in: Capsule())
          .help("Generated sample data; turn it off under Settings > Log.")
      }
      Spacer()
      if environment.state.isRefreshing {
        ProgressView().controlSize(.small)
      }
      Button(action: environment.actions.refresh) { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.borderless)
        .help("Refresh now")
        .accessibilityLabel("Refresh")
    }
  }
}

public struct ProviderCardView: View {
  public let card: ProviderCard
  @Bindable var environment: UIEnvironment

  public init(card: ProviderCard, environment: UIEnvironment) {
    self.card = card
    self.environment = environment
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: ProviderGlyph.symbolName(card.provider))
          .foregroundStyle(ProviderGlyph.color(card.provider))
          .font(.title3)
        Text(card.provider.displayName).font(.title2.weight(.semibold))
        Spacer()
        if card.isRefreshing { ProgressView().controlSize(.small) }
        Text(card.statusText)
          .font(.callout)
          .foregroundStyle(card.availability == .current ? Color.secondary : Color.orange)
          .help(card.statusHelp)
        Button(action: openUsagePage) { Image(systemName: "safari") }
          .buttonStyle(.borderless)
          .help("Open \(card.provider.displayName) usage page")
          .accessibilityLabel("Open usage page")
      }
      if !card.chips.isEmpty {
        WrappingHStack {
          ForEach(card.chips) { chip in
            ChipView(chip: chip, onCopy: environment.actions.copy, onOpen: environment.actions.openURL)
          }
        }
      }
      if card.isStale, !card.isRefreshing, let error = card.lastError {
        Banner("Showing older values: \(error)")
      }
      ForEach(card.warnings, id: \.self) { warning in
        Banner(warning)
      }
      ForEach(card.notices) { notice in
        Banner(notice.text, tone: notice.kind == .promotion ? .info : .warning)
      }
      if card.rows.isEmpty {
        EmptyStateView(
          title: card.emptyTitle, systemImage: icon(for: card.availability), description: card.emptyDescription)
        if card.availability == .authenticationRequired, let description = card.credentialDescription {
          Text(description).font(.callout).foregroundStyle(.secondary)
        }
      }
      ForEach(card.rows) { row in
        WindowRowView(row: row, now: environment.now)
      }
      if let spend = card.spend {
        SpendView(spend: spend, provider: card.provider, now: environment.now)
      }
      if card.credits != nil || card.resetCredits != nil {
        CreditsView(credits: card.credits, resetCredits: card.resetCredits)
      }
      if let local = card.localUsage {
        LocalUsageView(usage: local)
      }
      if let reviews = card.codeReviews {
        MetricCell(
          title: "Code reviews", value: reviews,
          help: "Code reviews the provider counted today and over the last seven days.")
      }
    }
    .padding(12)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
  }

  public func openUsagePage() {
    environment.actions.openURL(card.provider.usagePage)
  }

  func icon(for availability: QuotaAvailability) -> String {
    switch availability {
    case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
    case .networkUnavailable: "wifi.slash"
    case .disabled: "pause.circle"
    case .loading: "hourglass"
    default: "chart.bar"
    }
  }
}

public struct WindowRowView: View {
  public let row: WindowRow
  public let now: Date

  public init(row: WindowRow, now: Date) {
    self.row = row
    self.now = now
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(row.window.label).font(.body.weight(.medium))
        if !row.window.isActive {
          Text("inactive").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(row.percentText + " used")
          .font(.body.monospacedDigit().weight(.semibold))
          .foregroundStyle(Color(row.color))
      }
      UsageBar(percent: row.window.usedPercent, color: Color(row.color), height: 8)
      HStack {
        Text(row.window.resetsAt == nil ? "No reset scheduled" : "Resets in \(row.countdown) · \(row.resetClock)")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer()
        Text(row.pace.summary(now: now)).font(.callout).foregroundStyle(paceColor)
      }
    }
    .hoverHelp { WindowHelpView(row: row) }
    .accessibilityElement(children: .combine)
  }

  var paceColor: Color {
    switch row.pace.status {
    case .ahead, .exhausted: .orange
    case .behind: .secondary
    default: .green
    }
  }
}

public struct WindowHelpView: View {
  public let row: WindowRow

  public init(row: WindowRow) {
    self.row = row
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(row.window.label).font(.headline)
      Text(
        "Used \(Format.percent(row.window.usedPercent, decimals: 1)), \(Format.percent(row.window.remainingPercent, decimals: 1)) left"
      )
      if let duration = row.window.duration { Text("Window: \(Format.duration(duration))") }
      if let expected = row.pace.expectedPercent { Text("Even pace would be \(Format.percent(expected)) by now") }
      if let ratio = row.pace.ratio { Text("Pace ratio: \(ratio.formatted(.number.precision(.fractionLength(2))))×") }
      Text("Severity: \(row.window.severity.rawValue)")
    }
    .font(.callout)
  }
}

public struct SpendView: View {
  public let spend: SpendControl
  public let provider: ProviderID
  public let now: Date

  public init(spend: SpendControl, provider: ProviderID, now: Date) {
    self.spend = spend
    self.provider = provider
    self.now = now
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(provider == .claude ? "Usage credits" : "Spend control").font(.body.weight(.medium))
        Spacer()
        Text(UsagePresenter.spendSummary(spend))
          .font(.body.monospacedDigit())
          .foregroundStyle(spend.limitReached ? Color.red : Color.primary)
      }
      if spend.enabled, let percent = spend.percent {
        UsageBar(percent: percent, color: Color(UsageColor.color(percent: percent)))
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 200), alignment: .leading)], spacing: 8) {
        if let limit = spend.limit {
          MetricCell(title: "Monthly limit", value: limit.formatted, help: "Spend cap for credits beyond plan limits.")
        }
        if let used = spend.used {
          MetricCell(title: "Spent", value: used.formatted, help: "Credits consumed this month.")
        }
        if let balance = spend.balance {
          MetricCell(title: "Balance", value: balance.formatted, help: "Prepaid credit balance.")
        }
        if let resets = spend.resetsAt {
          MetricCell(
            title: "Resets", value: Format.resetClock(resets, now: now), help: "When the monthly spend counter resets.")
        }
        if let autoReload = spend.autoReload {
          MetricCell(
            title: "Auto-reload", value: autoReload ? "On" : "Off", help: "Whether credits top up automatically.")
        }
        MetricCell(
          title: "Purchase", value: spend.canPurchaseCredits ? "Available" : "Website only",
          help: "Credits are bought on the provider website; the app only displays them.")
      }
    }
  }
}

public struct LocalUsageView: View {
  public let usage: LocalUsage

  public init(usage: LocalUsage) {
    self.usage = usage
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Local session logs").font(.body.weight(.medium))
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 200), alignment: .leading)], spacing: 8) {
        MetricCell(
          title: "5-hour block", value: Format.compactNumber(Double(usage.windowTokens)) + " tokens",
          help: "Tokens the CLI logged since the current session window started, including cache reads.")
        MetricCell(
          title: "Block cost", value: Self.money(usage.windowCost),
          help: "What the same traffic would cost at API list prices; the subscription is not billed per token.")
        MetricCell(
          title: "Burn rate", value: Self.money(usage.costPerHour) + "/hr",
          help: "API-equivalent spend per hour over the current block.")
        MetricCell(
          title: "Today", value: Format.compactNumber(Double(usage.todayTokens)) + " tokens",
          help: "Tokens logged today, including cache reads.")
        MetricCell(
          title: "Messages today", value: "\(usage.todayMessages)", help: "Assistant messages logged today.")
        MetricCell(
          title: "Today cost", value: Self.money(usage.todayCost), help: "API-equivalent cost of today's traffic.")
      }
    }
  }

  static func money(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
  }
}

public struct CreditsView: View {
  public let credits: CreditBalance?
  public let resetCredits: ResetCredits?

  public init(credits: CreditBalance?, resetCredits: ResetCredits?) {
    self.credits = credits
    self.resetCredits = resetCredits
  }

  public var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 200), alignment: .leading)], spacing: 8) {
      if let credits {
        MetricCell(
          title: "Credits", value: UsagePresenter.creditsSummary(credits),
          help: "Credits extend usage beyond plan limits.")
        if credits.overageLimitReached {
          MetricCell(title: "Overage", value: "Limit reached", help: "The credit overage cap has been hit.")
        }
        if let cloud = credits.approxCloudMessages, cloud.upperBound > 0 {
          MetricCell(
            title: "Cloud messages", value: "~\(cloud.lowerBound)–\(cloud.upperBound)",
            help: "Estimated cloud task messages the balance covers.")
        }
      }
      if let resetCredits {
        MetricCell(
          title: "Limit resets", value: "\(resetCredits.available) available",
          help: "Usage-limit resets you can redeem on the website; \(resetCredits.applicable) apply right now.")
        if let earned = resetCredits.totalEarned {
          MetricCell(title: "Resets earned", value: "\(earned)", help: "Total reset credits earned so far.")
        }
      }
    }
  }
}
