import SwiftUI
import TokenMenuBarCore

public struct LocalUsageView: View {
  public let presentation: UsageLocalPresentation

  public init(usage: LocalUsage) {
    presentation = UsagePresenter.localPresentation(usage)
  }

  public init(presentation: UsageLocalPresentation) {
    self.presentation = presentation
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Local session logs").font(.callout.weight(.medium)).accessibilityAddTraits(.isHeader)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), alignment: .leading)], spacing: 6) {
        ForEach(presentation.metrics) { metric in
          MetricCell(title: metric.title, value: metric.value, help: metric.help)
        }
      }
    }
  }

  static func money(_ value: Double) -> String {
    UsagePresenter.localMoney(value)
  }
}
