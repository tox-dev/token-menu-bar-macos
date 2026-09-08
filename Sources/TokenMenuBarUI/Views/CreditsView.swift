import SwiftUI
import TokenMenuBarCore

public struct CreditsView: View {
  public let presentation: UsageCreditsPresentation?
  private let disclosures: DisclosureState
  private let provider: ProviderID

  public init(credits: CreditBalance?, resetCredits: ResetCredits?) {
    presentation = UsagePresenter.creditsPresentation(credits, resetCredits: resetCredits)
    disclosures = DisclosureState()
    provider = .codex
  }

  public init(
    presentation: UsageCreditsPresentation, disclosures: DisclosureState = DisclosureState(),
    provider: ProviderID = .codex
  ) {
    self.presentation = presentation
    self.disclosures = disclosures
    self.provider = provider
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let presentation {
        metrics(presentation.primaryMetrics)
        if !presentation.supportingMetrics.isEmpty {
          SupportingDetails(
            "Credit estimates and totals", id: "usage.\(provider.rawValue).creditEstimates", state: disclosures
          ) {
            metrics(presentation.supportingMetrics)
          }
        }
      }
    }
  }

  private func metrics(_ values: [UsageMetricPresentation]) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), alignment: .leading)], spacing: 6) {
      ForEach(values) { metric in
        MetricCell(title: metric.title, value: metric.value, help: metric.help)
      }
    }
  }
}
