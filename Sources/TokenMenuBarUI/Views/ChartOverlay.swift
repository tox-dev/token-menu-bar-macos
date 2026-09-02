import Charts
import SwiftUI
import TokenMenuBarCore

struct ChartOverlay: View {
  let chart: UsageChart
  let proxy: ChartProxy

  var body: some View {
    GeometryReader { geometry in
      if let plotFrame = proxy.plotFrame {
        let plot = geometry[plotFrame]
        let drag = DragGesture(minimumDistance: 0)
        ZStack(alignment: .topLeading) {
          if let selected = chart.presenter.selectedDate,
            let x = proxy.position(forX: selected)
          {
            Path { path in
              path.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
              path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
            }
            .stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .accessibilityHidden(true)
            ForEach(chart.selectionPoints(at: selected)) { selection in
              if let y = proxy.position(forY: selection.point.value) {
                HistorySelectionPoint(variant: selection.series.style.variant)
                  .fill(UsageChart.color(index: selection.series.style.hueIndex))
                  .frame(width: 8, height: 8)
                  .position(x: plot.minX + x, y: plot.minY + y)
                  .accessibilityHidden(true)
              }
            }
          }
          Rectangle().fill(Color.clear).contentShape(Rectangle())
            .gesture(
              drag.onChanged(
                ChartDragAction(chart: chart, plot: plot, location: \DragGesture.Value.location).callAsFunction)
            )
            .onContinuousHover(perform: ChartHoverAction(chart: chart, plot: plot).callAsFunction)
        }
      }
    }
  }
}

@MainActor struct ChartDragAction<Value> {
  let chart: UsageChart
  let plot: CGRect
  let location: KeyPath<Value, CGPoint>

  func callAsFunction(_ value: Value) {
    chart.pick(value[keyPath: location], in: plot)
  }
}

@MainActor struct ChartHoverAction {
  let chart: UsageChart
  let plot: CGRect

  func callAsFunction(_ phase: HoverPhase) {
    chart.hover(phase, in: plot)
  }
}

private struct HistorySelectionPoint: Shape {
  let variant: Int

  func path(in rect: CGRect) -> Path {
    switch variant % 3 {
    case 1:
      Path(rect)
    case 2:
      Path { path in
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
      }
    default:
      Path(ellipseIn: rect)
    }
  }
}
