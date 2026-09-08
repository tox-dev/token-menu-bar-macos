import SwiftUI
import TokenMenuBarCore

public struct ProviderCardView: View {
  public let card: ProviderCard
  @Bindable var environment: UIEnvironment
  public let onRefreshProvider: (ProviderID) -> Void
  private let spend: SpendSummaryModel

  public init(
    card: ProviderCard, environment: UIEnvironment, onRefreshProvider: @escaping (ProviderID) -> Void,
    spend: SpendSummaryModel? = nil
  ) {
    self.card = card
    self.environment = environment
    self.onRefreshProvider = onRefreshProvider
    self.spend = spend ?? environment.spendSummary
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
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
        if !card.primaryChips.isEmpty {
          WrappingHStack(horizontalSpacing: 5, verticalSpacing: 4) {
            ForEach(card.primaryChips) { chip in
              UsageIdentityChip(chip: chip, provider: card.provider, onCopy: environment.actions.copy)
            }
          }
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(Color.primary.opacity(0.035))

      VStack(alignment: .leading, spacing: 3) {
        if let error = environment.providerLoginErrors[card.provider] { Banner(error) }
        if !card.supportingChips.isEmpty {
          SupportingDetails(
            "Account details", id: "usage.\(card.provider.rawValue).account", state: environment.disclosures
          ) {
            WrappingHStack(horizontalSpacing: 5, verticalSpacing: 4) {
              ForEach(card.supportingChips) { chip in
                UsageIdentityChip(chip: chip, provider: card.provider, onCopy: environment.actions.copy)
              }
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
          ProviderNoticeBanner(notice: notice, environment: environment)
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
          .environment(\.usageValueAppearance, card.valueAppearance)
        }
        if let summary = spend.byProvider[card.provider] {
          ProviderCostSummary(summary: summary, provider: card.provider, disclosures: environment.disclosures)
        } else if HistoryMetric.analytics(.costUSD).suppliers.contains(card.provider) {
          Text(
            spend.isLoading
              ? "Loading cost history…"
              : spend.error == nil ? "No cost history in the last 30 days" : "Cost history unavailable"
          )
          .font(.callout).semanticForeground(.secondary)
        }
        if let error = spend.error,
          spend.byProvider[card.provider] != nil || HistoryMetric.analytics(.costUSD).suppliers.contains(card.provider)
        {
          Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        if let spend = card.spendPresentation {
          Divider()
          SpendView(presentation: spend, disclosures: environment.disclosures, provider: card.provider)
            .environment(\.usageValueAppearance, card.valueAppearance)
        }
        if let credits = card.creditsPresentation {
          CreditsView(presentation: credits, disclosures: environment.disclosures, provider: card.provider)
            .environment(\.usageValueAppearance, card.valueAppearance)
          if let details = credits.resetCredits?.details, !details.isEmpty {
            SupportingDetails(
              "Reset credit details", id: "usage.\(card.provider.rawValue).resets", state: environment.disclosures
            ) {
              ForEach(details) { detail in
                Text(detail.title).font(.callout.weight(.medium))
                Text(detail.value).font(.caption).fixedSize(horizontal: false, vertical: true)
                  .semanticForeground(card.valueAppearance.foreground)
                  .accessibilityValue(card.valueAppearance.accessibilityValue(detail.explanation))
              }
            }
          }
        }
        if !card.details.isEmpty {
          SupportingDetails(
            "Provider details", id: "usage.\(card.provider.rawValue).provider", state: environment.disclosures
          ) {
            ForEach(card.details) { detail in
              VStack(alignment: .leading, spacing: 2) {
                Text(detail.title).font(.callout.weight(.medium))
                Text(detail.value).font(.callout.monospacedDigit())
                  .fixedSize(horizontal: false, vertical: true)
                  .semanticForeground(card.valueAppearance.foreground)
              }
              .richHelp(TooltipContent(title: detail.title, body: detail.explanation))
              .accessibilityElement(children: .combine)
              .accessibilityValue(card.valueAppearance.accessibilityValue(detail.explanation))
            }
          }
        }
        if let local = card.localPresentation {
          Divider()
          SupportingDetails(
            "Local usage details", id: "usage.\(card.provider.rawValue).local", state: environment.disclosures
          ) {
            LocalUsageView(presentation: local)
              .environment(\.usageValueAppearance, card.valueAppearance)
          }
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
    switch primaryAction {
    case .signIn: environment.actions.signInProvider(card.provider)
    case .setup: showProviders()
    case .refresh, .retry: onRefreshProvider(card.provider)
    }
  }

  var primaryAction: ProviderPrimaryAction {
    ProviderPrimaryAction(
      availability: card.availability, issue: environment.state.state(for: card.provider).recoveryIssue)
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
      ProgressView().progressViewStyle(RingProgressViewStyle())
        .accessibilityLabel("Refreshing \(card.provider.displayName)")
    }
    Group {
      if primaryAction == .signIn || primaryAction == .setup {
        NativeActionButton(action: refresh) {
          Label(primaryAction.title, systemImage: primaryAction.symbol)
        }
        .accessibilityLabel("\(primaryAction.title) \(card.provider.displayName)")
        .richHelp(TooltipContent(title: primaryAction.title, body: primaryAction.explanation))
      } else {
        NativeIconButton(
          symbol: primaryAction.symbol, accessibilityLabel: "\(primaryAction.title) \(card.provider.displayName)",
          explanation: primaryAction.explanation
        ) { refresh() }
      }
    }
    .controlSize(.small).disabled(card.isRefreshing)
    if shouldShowProviders, primaryAction != .setup {
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
      WrappingIdentityButton(
        title: chip.text, identifier: "provider-chip-\(provider.rawValue)-\(chip.id)", help: primaryHelp,
        action: primaryAction
      )
      .frame(maxWidth: 240, alignment: .leading)
      .richHelpAccessibility(primaryHelp)
      .accessibilityLabel(chip.text)
      .accessibilityValue(chip.text)
      Button(action: copyAction) {
        Label("Copy \(chip.text)", systemImage: "doc.on.doc").labelStyle(.iconOnly)
      }
      .richHelp(copyHelp)
      .accessibilityLabel("Copy \(chip.text)")
      .accessibilityIdentifier("provider-chip-copy-\(provider.rawValue)-\(chip.id)")
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

private struct WrappingIdentityButton: NSViewRepresentable {
  let title: String
  let identifier: String
  let help: TooltipContent
  let action: () -> Void

  func makeNSView(context: Context) -> NativeButtonContainer {
    let button = NSButton(frame: .zero)
    button.cell = WrappingIdentityButtonCell(textCell: title)
    button.target = context.coordinator
    button.action = #selector(Coordinator.press)
    button.bezelStyle = .flexiblePush
    button.controlSize = .small
    button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    button.alignment = .left
    button.cell!.wraps = true
    button.cell!.usesSingleLineMode = false
    button.cell!.lineBreakMode = .byWordWrapping
    context.coordinator.tooltip.autoresizingMask = [.width, .height]
    button.addSubview(context.coordinator.tooltip)
    return NativeButtonContainer(button: button)
  }

  func updateNSView(_ container: NativeButtonContainer, context: Context) {
    let button = container.button
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    button.attributedTitle = NSAttributedString(
      string: title, attributes: [.font: button.font!, .paragraphStyle: paragraph])
    button.setAccessibilityIdentifier(identifier)
    button.isEnabled = context.environment.isEnabled
    context.coordinator.action = action
    context.coordinator.tooltip.update(content: help, focused: false)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeButtonContainer, context: Context) -> CGSize? {
    let attributes: [NSAttributedString.Key: Any] = [.font: nsView.button.font!]
    let idealWidth = min((title as NSString).size(withAttributes: attributes).width + 24, 240)
    let width = min(max(proposal.width ?? idealWidth, 44), idealWidth)
    let size = nsView.button.cell!.cellSize(
      forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: ceil(size.height))
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action, help: help)
  }

  static func dismantleNSView(_ container: NativeButtonContainer, coordinator: Coordinator) {
    coordinator.tooltip.dismantle()
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void
    let tooltip: TooltipTrackingView

    init(action: @escaping () -> Void, help: TooltipContent) {
      self.action = action
      tooltip = TooltipTrackingView(content: help, presenter: .shared)
    }

    @objc func press() {
      action()
    }
  }
}

private final class WrappingIdentityButtonCell: NSButtonCell {
  // macOS 14 constrains flexible-push titles to one line despite the cell's wrapping flags.
  override func cellSize(forBounds bounds: NSRect) -> NSSize {
    NSSize(width: bounds.width, height: titleHeight(width: bounds.width - 16) + 8)
  }

  override func titleRect(forBounds bounds: NSRect) -> NSRect {
    let height = titleHeight(width: bounds.width - 16)
    return NSRect(x: bounds.minX + 8, y: bounds.midY - height / 2, width: bounds.width - 16, height: height)
  }

  override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
    title.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
    return frame
  }

  private func titleHeight(width: CGFloat) -> CGFloat {
    ceil(
      attributedTitle.boundingRect(
        with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      ).height)
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

private struct ProviderNoticeBanner: View {
  let notice: Notice
  @Bindable var environment: UIEnvironment

  var body: some View {
    Banner(notice.text(at: environment.usageDeadlineNow), tone: notice.kind == .promotion ? .info : .warning)
  }
}
