import SwiftUI
import TokenMenuBarCore

@MainActor
struct HistoryLegendHoverAction {
  let presenter: HistoryPresenter
  let seriesID: HistorySeriesID

  func callAsFunction(_ hovering: Bool) {
    presenter.setHovered(hovering ? seriesID : nil)
  }
}

public struct HistoryInspector: View {
  @Bindable var environment: UIEnvironment

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  private var presenter: HistoryPresenter { environment.historyPresenter }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(selectionTitle).font(.caption).semanticForeground(InterfaceTokens.standard.detailForeground)
        Spacer()
        if !presenter.selectedMetric.usesDailyUTC {
          Toggle(
            "UTC",
            isOn: useUTCBinding
          )
          .toggleStyle(.checkbox)
          .font(.caption)
          .accessibilityIdentifier("history-utc")
          .richHelp(
            TooltipContent(
              title: "UTC boundaries",
              body:
                "Uses UTC boundaries for window buckets. Provider analytics already arrives as UTC days, "
                + "so the setting does not apply there."
            )
          )
        }
      }
      if let data = presenter.state.data {
        VStack(alignment: .leading, spacing: 7) {
          ForEach(data.series) { series in legendRow(series, metric: data.metric) }
        }
      }
      if presenter.state.data?.series.isEmpty == false {
        Text("Use a checkbox to show or hide a series. Double-click or press I to isolate it.")
          .font(.caption2)
          .semanticForeground(InterfaceTokens.standard.detailForeground)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("history-legend")
  }

  private var selectionTitle: String {
    guard let date = presenter.selectedDate else { return "Range values" }
    var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
    style.timeZone = presenter.chartTimeZone
    return date.formatted(style)
  }

  private func legendRow(_ series: HistorySeries, metric: HistoryMetric) -> some View {
    let isolate = { presenter.isolate(series.id) }
    let reset = presenter.resetDescription(for: series)
    let accessibilityValue =
      "\(presenter.value(for: series)), \(series.isVisible ? "shown" : "hidden")" + (reset.map { ", \($0)" } ?? "")
    let help = TooltipContent(
      title: series.label,
      body: "Shows the value at the selected date. Double-click or press I to isolate this series; "
        + "repeat to restore the others." + (reset.map { "\n\($0)" } ?? ""))
    return HStack(alignment: .firstTextBaseline, spacing: 7) {
      HistoryLegendSwatch(style: series.style, markKind: metric.markKind)
        .frame(width: 18, height: 10)
        .accessibilityHidden(true)
      Text(series.label).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Text(presenter.value(for: series)).monospacedDigit()
      Toggle(
        "Show \(series.label)",
        isOn: visibilityBinding(for: series.id)
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .accessibilityLabel("Show \(series.label)")
      .accessibilityIdentifier(
        "history-series-\(environment.settings.hidePersonalInformation ? ProjectIdentity.anonymous(series.id.storageKey) : series.id.storageKey)"
      )
      .richHelp(
        TooltipContent(
          title: "Show \(series.label)",
          body:
            metric.hasParallelBreakdowns
            ? "Includes this breakdown in the chart. The workspace total remains independent of model "
              + "and surface visibility."
            : "Includes this series in the chart and total. "
              + "Turning it off keeps the data available in this list.")
      )
    }
    .font(.caption)
    .contentShape(Rectangle())
    .padding(.vertical, 2)
    .padding(.horizontal, 4)
    .background {
      RoundedRectangle(cornerRadius: 4)
        .fill(presenter.hoveredSeriesID == series.id ? Color.accentColor.opacity(0.08) : .clear)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 4)
        .stroke(presenter.hoveredSeriesID == series.id ? Color.accentColor.opacity(0.45) : .clear)
    }
    .onHover(perform: HistoryLegendHoverAction(presenter: presenter, seriesID: series.id).callAsFunction)
    .onTapGesture(count: 2, perform: isolate)
    .focusable()
    .onKeyPress("i") {
      isolate()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(series.label)
    .accessibilityValue(accessibilityValue)
    .accessibilityAction(named: "Isolate", isolate)
    .richHelp(help)
  }

  var useUTCBinding: Binding<Bool> {
    Binding(get: { environment.settings.historyUseUTC }, set: { presenter.setUseUTC($0) })
  }

  func visibilityBinding(for seriesID: HistorySeriesID) -> Binding<Bool> {
    Binding(get: { presenter.isVisible(seriesID) }, set: { _ in presenter.toggleVisibility(seriesID) })
  }
}

struct HistoryLegendSwatch: View {
  let style: HistoryStyleSlot
  let markKind: HistoryMarkKind

  var body: some View {
    let color = UsageChart.color(index: style.hueIndex)
    switch markKind {
    case .stepLine, .line:
      ZStack {
        Canvas { context, size in
          var path = Path()
          path.move(to: CGPoint(x: 0, y: size.height / 2))
          path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
          context.stroke(path, with: .color(color), style: UsageChart.stroke(variant: style.variant))
        }
        HistoryLegendPointSymbol(variant: style.variant, color: color).frame(width: 5, height: 5)
      }
    case .bars:
      RoundedRectangle(cornerRadius: 1.5).fill(UsageChart.barStyle(style))
    }
  }
}

private struct HistoryLegendPointSymbol: View {
  let variant: Int
  let color: Color

  var body: some View {
    switch variant % 3 {
    case 1:
      Rectangle().fill(color)
    case 2:
      Rectangle().fill(color).rotationEffect(.degrees(45))
    default:
      Circle().fill(color)
    }
  }
}
