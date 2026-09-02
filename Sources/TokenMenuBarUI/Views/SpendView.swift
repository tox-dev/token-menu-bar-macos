import SwiftUI
import TokenMenuBarCore

public struct SpendView: View {
  public let presentation: UsageSpendPresentation

  public init(spend: SpendControl, provider: ProviderID, now: Date) {
    presentation = UsagePresenter.spendPresentation(spend, provider: provider, now: now)
  }

  public init(presentation: UsageSpendPresentation) {
    self.presentation = presentation
  }

  public var title: String {
    presentation.title
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title).font(.callout.weight(.medium))
        Spacer()
        // Red alone carried "limit reached", which neither VoiceOver nor a colour-blind reader picks up.
        if presentation.spend.limitReached {
          Image(systemName: "exclamationmark.octagon.fill").semanticForeground(.destructive).accessibilityHidden(true)
          Text("Limit reached").font(.callout.weight(.medium))
        }
        Text(presentation.summary)
          .font(.callout.monospacedDigit())
          .semanticForeground(.primary)
      }
      .accessibilityElement(children: .combine)
      if presentation.spend.enabled, let percent = presentation.spend.percent {
        UsageBar(percent: percent, color: Color(UsageColor.color(percent: percent)), label: title)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), alignment: .leading)], spacing: 6) {
        ForEach(presentation.metrics) { metric in
          MetricCell(title: metric.title, value: metric.value, help: metric.help)
        }
      }
    }
  }
}
