import SwiftUI
import TokenMenuBarCore

public struct ProviderCardView: View {
  public let card: ProviderCard
  @Bindable var environment: UIEnvironment
  public let onRefreshProvider: (ProviderID) -> Void

  public init(
    card: ProviderCard, environment: UIEnvironment, onRefreshProvider: @escaping (ProviderID) -> Void = { _ in }
  ) {
    self.card = card
    self.environment = environment
    self.onRefreshProvider = onRefreshProvider
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        ResponsivePanelLayout {
          HStack(alignment: .center, spacing: 8) {
            ProviderHeaderIdentity(provider: card.provider)
            Spacer(minLength: 8)
            ProviderStatusText(card: card, environment: environment)
            headerActions
          }
          .frame(minWidth: 600)
        } narrow: {
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
              ProviderHeaderIdentity(provider: card.provider)
              Spacer(minLength: 8)
              headerActions
            }
            ProviderStatusText(card: card, environment: environment)
          }
        }
        if !card.chips.isEmpty {
          WrappingHStack(horizontalSpacing: 5, verticalSpacing: 4) {
            ForEach(card.chips) { chip in
              UsageIdentityChip(chip: chip, provider: card.provider, onCopy: environment.actions.copy)
            }
          }
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Color.primary.opacity(0.035))

      VStack(alignment: .leading, spacing: 5) {
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
        }
        ForEach(card.groups) { group in
          VStack(alignment: .leading, spacing: 2) {
            ForEach(group.rows) { row in
              WindowRowView(row: row, environment: environment, showsReset: group.isSingle)
            }
            if !group.isSingle, group.resetDeadline != nil {
              GroupResetText(group: group, environment: environment)
            }
          }
        }
        if let spend = card.spendPresentation {
          Divider()
          SpendView(presentation: spend)
        }
        if let credits = card.creditsPresentation {
          CreditsView(presentation: credits)
        }
        if let local = card.localPresentation {
          Divider()
          LocalUsageView(presentation: local)
        }
        if let reviews = card.codeReviews {
          HStack(spacing: 6) {
            Text("Code reviews").semanticForeground(.secondary)
            Text(reviews).monospacedDigit()
          }
          .font(.caption)
          .richHelp(
            TooltipContent(
              title: "Code reviews", body: "Code reviews counted today and over the last seven days.")
          )
          .accessibilityElement(children: .combine)
        }
      }
      .padding(.horizontal, 11)
      .padding(.top, 4)
      .padding(.bottom, 7)
    }
    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 9))
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("usage-provider-\(card.provider.rawValue)")
  }

  public func refresh() {
    onRefreshProvider(card.provider)
  }

  public func showProviders() {
    environment.actions.showProviders(card.provider)
  }

  var shouldShowProviders: Bool {
    switch card.availability {
    case .authenticationRequired, .disabled, .unavailable: true
    default: false
    }
  }

  @ViewBuilder private var headerActions: some View {
    if card.isRefreshing {
      ProgressView().controlSize(.small).accessibilityLabel("Refreshing \(card.provider.displayName)")
    }
    NativeIconButton(
      symbol: "arrow.clockwise", accessibilityLabel: "Refresh \(card.provider.displayName)",
      explanation:
        "Fetches current quota data from \(card.provider.displayName). "
        + "Last-known values remain visible if the refresh fails."
    ) { refresh() }
    .controlSize(.small)
    .disabled(card.isRefreshing || card.availability == .disabled)
    if shouldShowProviders {
      NativeIconButton(
        symbol: "slider.horizontal.3", accessibilityLabel: "Set up \(card.provider.displayName)",
        explanation:
          "Opens setup and recovery for \(card.provider.displayName). "
          + "Last-known usage remains visible while access is repaired."
      ) { showProviders() }
      .controlSize(.small)
    }
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

struct UsageIdentityChip: View {
  let chip: Chip
  let provider: ProviderID
  let onCopy: (String) -> Void

  var primaryHelp: TooltipContent {
    TooltipContent(
      title: chip.text,
      body:
        "Shows \(provider.displayName) plan, account, renewal, or data-source information. Copies the displayed value."
    )
  }

  var copyHelp: TooltipContent {
    TooltipContent(title: "Copy \(chip.text)", body: "Copies this value to the clipboard.")
  }

  var body: some View {
    HStack(spacing: 4) {
      Button(action: primaryAction) {
        Text(chip.text)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: 240, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .richHelp(primaryHelp)
      .accessibilityLabel(chip.text)
      .accessibilityValue(chip.text)
      Button(action: copyAction) {
        Label("Copy \(chip.text)", systemImage: "doc.on.doc").labelStyle(.iconOnly)
      }
      .richHelp(copyHelp)
      .accessibilityLabel("Copy \(chip.text)")
    }
    .frame(maxWidth: 280, alignment: .leading)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .semanticControl(.action)
    .contextMenu {
      Button("Copy", systemImage: "doc.on.doc", action: copyAction)
        .accessibilityHint(copyHelp.accessibilityHint)
    }
  }

  func primaryAction() {
    onCopy(chip.text)
  }

  func copyAction() {
    onCopy(chip.text)
  }
}

private struct ProviderHeaderIdentity: View {
  let provider: ProviderID

  var body: some View {
    HStack(spacing: 7) {
      ProviderMarkView(provider, size: CGSize(width: 22, height: 18)).accessibilityHidden(true)
      Text(provider.displayName)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
  }
}

private struct ProviderStatusText: View {
  let card: ProviderCard
  @Bindable var environment: UIEnvironment

  var body: some View {
    let status = card.statusText(at: environment.usageDeadlineNow)
    Text(status)
      .font(.caption)
      .semanticForeground(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .richHelp(TooltipContent(title: "\(card.provider.displayName) status", body: card.statusHelp))
      .accessibilityLabel("\(card.provider.displayName) status")
      .accessibilityValue(status)
  }
}

private struct GroupResetText: View {
  let group: WindowRowGroup
  @Bindable var environment: UIEnvironment

  var body: some View {
    if let deadline = group.resetDeadline {
      ResetDeadlineText(deadline: deadline, now: environment.usageDeadlineNow, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}
