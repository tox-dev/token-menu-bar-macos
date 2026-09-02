import SwiftUI
import TokenMenuBarCore

public struct CreditsView: View {
  public let presentation: UsageCreditsPresentation?

  public init(credits: CreditBalance?, resetCredits: ResetCredits?) {
    presentation = UsagePresenter.creditsPresentation(credits, resetCredits: resetCredits)
  }

  public init(presentation: UsageCreditsPresentation) {
    self.presentation = presentation
  }

  public var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), alignment: .leading)], spacing: 6) {
      if let presentation {
        ForEach(presentation.metrics) { metric in
          MetricCell(title: metric.title, value: metric.value, help: metric.help)
        }
      }
    }
  }
}
