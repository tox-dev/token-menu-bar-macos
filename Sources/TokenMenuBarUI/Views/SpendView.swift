import SwiftUI
import TokenMenuBarCore

public struct SpendView: View {
  public let presentation: UsageSpendPresentation
  private let disclosures: DisclosureState
  private let provider: ProviderID

  public init(spend: SpendControl, provider: ProviderID, now: Date) {
    presentation = UsagePresenter.spendPresentation(spend, provider: provider, now: now)
    self.provider = provider
    disclosures = DisclosureState()
  }

  public init(
    presentation: UsageSpendPresentation, disclosures: DisclosureState = DisclosureState(),
    provider: ProviderID = .claude
  ) {
    self.presentation = presentation
    self.disclosures = disclosures
    self.provider = provider
  }

  public var title: String {
    presentation.title
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.callout.weight(.medium))
        // Red alone carried "limit reached", which neither VoiceOver nor a colour-blind reader picks up.
        if presentation.spend.limitReached {
          Image(systemName: "exclamationmark.octagon.fill").semanticForeground(.destructive).accessibilityHidden(true)
          Text("Limit reached").font(.callout.weight(.medium))
        }
        Text(presentation.summary)
          .font(.callout.monospacedDigit())
          .semanticForeground(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
      if let percent = presentation.spend.percent {
        UsageBar(percent: percent, color: Color(UsageColor.color(percent: percent)), label: title)
      }
      if !presentation.metrics.isEmpty {
        SupportingDetails("Credit details", id: "usage.\(provider.rawValue).credit", state: disclosures) {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), alignment: .leading)], spacing: 6) {
            ForEach(presentation.metrics) { metric in
              MetricCell(title: metric.title, value: metric.value, help: metric.help)
            }
          }
        }
      }
    }
  }
}

public struct SpendSummaryTiles: View {
  public let summary: SpendSummary

  public init(summary: SpendSummary) {
    self.summary = summary
  }

  public var body: some View {
    HStack(spacing: 8) {
      ForEach(summary.tiles) { tile in
        VStack(alignment: .leading, spacing: 2) {
          Text(tile.title).font(.callout).semanticForeground(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(tile.text).font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.title): \(tile.text)")
        .accessibilityIdentifier("spend-\(tile.id)")
      }
    }
    .richHelp(TooltipContent(title: summary.attribution, body: summary.breakdown))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("spend-summary")
  }
}

struct ProviderCostSummary: View {
  let summary: SpendSummary
  let provider: ProviderID
  let disclosures: DisclosureState

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(summary.attribution).font(.caption).semanticForeground(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      SpendSummaryTiles(summary: summary)
      SupportingDetails("Model cost estimates", id: "usage.\(provider.rawValue).cost", state: disclosures) {
        Text("Estimated from recorded tokens at API rates, not your subscription bill. Last 30 days, UTC.")
          .font(.caption).fixedSize(horizontal: false, vertical: true)
        ForEach(summary.models) { model in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.model).font(.callout.monospaced()).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(Format.currency(model.cost)).font(.callout.monospacedDigit()).fixedSize()
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(model.text)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("provider-cost-\(provider.rawValue)")
    .accessibilityValue(summary.breakdown)
  }
}
