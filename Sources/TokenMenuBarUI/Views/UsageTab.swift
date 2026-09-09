import SwiftUI
import TokenMenuBarCore

public struct UsageTab: View {
  @Bindable var environment: UIEnvironment
  public let spend: SpendSummaryModel
  public let onRefreshProvider: (ProviderID) -> Void

  public init(
    environment: UIEnvironment, spend: SpendSummaryModel? = nil,
    onRefreshProvider: ((ProviderID) -> Void)? = nil
  ) {
    self.environment = environment
    self.spend = spend ?? environment.spendSummary
    self.onRefreshProvider = onRefreshProvider ?? environment.actions.refreshProvider
  }

  public var body: some View {
    ScrollingTab(tab: .usage) {
      let presentation = environment.usagePresentation
      VStack(alignment: .leading, spacing: 8) {
        header(presentation)
        if let card = environment.firstRunCard {
          FirstRunCardView(environment: environment, card: card)
        }
        if presentation.cards.isEmpty {
          HStack(alignment: .center, spacing: 12) {
            EmptyStateView(
              title: presentation.emptyTitle, systemImage: "slider.horizontal.3",
              description: presentation.emptyDescription)
            NativeActionButton("Open Providers") { environment.actions.showProviders(nil) }
              .controlSize(.small)
              .richHelp(
                TooltipContent(
                  title: "Open Providers",
                  body:
                    "Opens provider setup so usage sources can be enabled or repaired. "
                    + "Usage remains empty until a provider supplies data."
                ))
          }
        }
        ForEach(presentation.cards) { card in
          ProviderCardView(card: card, environment: environment, onRefreshProvider: onRefreshProvider, spend: spend)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(SpendSummaryActivity(environment: environment, spend: spend))
  }

  private func header(_ presentation: UsagePresentation) -> some View {
    HStack(spacing: 8) {
      AppIconView(size: 22, tone: presentation.iconTone)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(environment.appInfo.name).font(.headline)
        UsageUpdatedText(lastRefresh: presentation.lastRefresh, environment: environment)
      }
      .accessibilityElement(children: .combine)
      if environment.isDemo {
        DisableDemoButton(environment: environment)
      }
      Spacer(minLength: 8)
      if presentation.isRefreshing {
        ProgressView().controlSize(.small).accessibilityLabel("Refreshing")
      }
      NativeIconButton(
        symbol: "arrow.clockwise", accessibilityLabel: "Refresh usage",
        explanation:
          "Fetches current quota data from every enabled provider. "
          + "Last-known values remain visible if a refresh fails.",
        action: environment.actions.refresh
      )
      .accessibilityIdentifier("usage-refresh")
    }
  }
}

private struct SpendSummaryActivity: View {
  let environment: UIEnvironment
  let spend: SpendSummaryModel

  var body: some View {
    Color.clear.allowsHitTesting(false)
      .task(id: schedule) { await loadSpend(schedule) }
  }

  private var schedule: SpendSummarySchedule {
    SpendSummarySchedule(
      visible: environment.state.popoverVisible && environment.settings.lastTab == .usage,
      revision: environment.state.historyRevision, useUTC: environment.settings.historyUseUTC,
      day: DayStamp.string(environment.now),
      providers: environment.settings.activeProviders(states: environment.state.providers))
  }

  private func loadSpend(_ schedule: SpendSummarySchedule) async {
    guard schedule.visible else { return }
    await spend.load(
      history: environment.history, providers: schedule.providers, now: environment.clock.now(),
      timeZone: schedule.useUTC ? TimeZone(identifier: "UTC")! : .current)
  }
}

struct DisableDemoButton: View {
  let environment: UIEnvironment

  var body: some View {
    NativeActionButton("Turn Off Demo Data") { environment.actions.setDemoMode(false) }
      .controlSize(.small)
      .accessibilityIdentifier("disable-demo-data")
      .richHelp(
        TooltipContent(
          title: "Disable demo data",
          body:
            "Turns off generated data and relaunches. Normal sessions resume provider discovery; verification sessions stay isolated."
        ))
  }
}

private struct SpendSummarySchedule: Equatable {
  let visible: Bool
  let revision: UInt64
  let useUTC: Bool
  let day: String
  let providers: Set<ProviderID>
}

struct FirstRunCardView: View {
  @Bindable var environment: UIEnvironment
  let card: FirstRunCard

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "sparkles").font(.system(size: 22)).semanticForeground(.secondary).frame(width: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(card.title).font(.headline)
        Text(card.description).font(.callout).semanticForeground(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          NativeActionButton("Review providers", action: review)
            .controlSize(.small)
            .accessibilityIdentifier("first-run-review-providers")
            .richHelp(
              TooltipContent(
                title: "Review providers",
                body: "Opens the Providers section of Settings, where each provider can be turned on or off."))
          NativeActionButton("Got it", action: dismiss)
            .controlSize(.small)
            .accessibilityIdentifier("first-run-dismiss")
            .richHelp(TooltipContent(title: "Got it", body: "Hides this card. It does not come back."))
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("first-run-card")
  }

  func review() {
    environment.actions.showProviders(nil)
  }

  func dismiss() {
    environment.settings.firstRunCardDismissed = true
    environment.firstRunCard = nil
  }
}

private struct UsageUpdatedText: View {
  let lastRefresh: Date?
  @Bindable var environment: UIEnvironment

  var body: some View {
    Text("Updated \(UsageDeadline.age(lastRefresh).text(at: environment.usageDeadlineNow))")
      .font(.callout)
      .semanticForeground(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .richHelp(
        TooltipContent(
          title: "Last refresh",
          body: "Shows when the latest provider refresh finished. Individual cards identify stale or cached values."
        ))
  }
}
