import SwiftUI
import TokenMenuBarCore

public struct UsageTab: View {
  @Bindable var environment: UIEnvironment
  public let onRefreshProvider: (ProviderID) -> Void

  public init(
    environment: UIEnvironment, onRefreshProvider: ((ProviderID) -> Void)? = nil
  ) {
    self.environment = environment
    self.onRefreshProvider = onRefreshProvider ?? environment.actions.refreshProvider
  }

  public var body: some View {
    ScrollingTab(tab: .usage) {
      let presentation = environment.usagePresentation
      VStack(alignment: .leading, spacing: 8) {
        header(presentation)
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
          ProviderCardView(card: card, environment: environment, onRefreshProvider: onRefreshProvider)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
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
        NativeActionButton("Disable Demo") { environment.actions.setDemoMode(false) }
          .controlSize(.small)
          .accessibilityIdentifier("disable-demo-data")
          .richHelp(
            TooltipContent(
              title: "Disable demo data",
              body: "Closes this generated-data session and relaunches the app with real provider discovery."))
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
