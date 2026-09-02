import AppKit
import Charts
import SwiftUI
import TokenMenuBarCore

public struct HistoryTab: View {
  @Bindable var environment: UIEnvironment
  private let chooseExportURL: @MainActor () -> URL?

  public init(
    environment: UIEnvironment,
    chooseExportURL: @escaping @MainActor () -> URL? = {
      LiveDependencies.chosen(LiveDependencies.exportPanel(), run: { $0.runModal() })
    }
  ) {
    self.environment = environment
    self.chooseExportURL = chooseExportURL
  }

  private var presenter: HistoryPresenter { environment.historyPresenter }
  private var settings: TokenMenuBarCore.Settings { environment.settings }

  public var body: some View {
    ScrollingTab(tab: .history) {
      VStack(alignment: .leading, spacing: 10) {
        periodControls
        viewportControls
        metricControls
        if let data = presenter.state.data, !data.summaryText.isEmpty {
          Text(data.summaryText).font(.title2.monospacedDigit().weight(.semibold))
        }
        chartRow
        footer
        if let error = presenter.exportError {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.circle.fill").semanticForeground(.destructive)
            Text(error).semanticForeground(InterfaceTokens.standard.bodyForeground)
          }
          .font(.caption)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(error)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: dataScope) {
      presenter.setDataScope(dataScope)
      presenter.ensureLoaded()
    }
    .onChange(of: environment.state.historyRevision) { presenter.reload() }
  }

  private var periodControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        periodPicker
        Text("Rollup").font(.caption).semanticForeground(InterfaceTokens.standard.detailForeground)
        rollupPicker
        stackToggle
        Spacer(minLength: 4)
        exportButton
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          periodPicker
          Spacer(minLength: 4)
          exportButton
        }
        HStack(spacing: 10) {
          Text("Rollup").font(.caption).semanticForeground(InterfaceTokens.standard.detailForeground)
          rollupPicker
          stackToggle
          Spacer(minLength: 4)
        }
      }
    }
  }

  private var periodPicker: some View {
    NativeSegmentedControl(
      HistoryPeriod.allCases.map { (value: $0, label: $0.title) },
      selection: Binding(get: { presenter.period }, set: { presenter.setPeriod($0) }),
      accessibilityLabel: "Period",
      accessibilityIdentifier: "history-period"
    )
    .frame(minWidth: 289)
    .richHelp(
      TooltipContent(
        title: "History period",
        body: "Now follows the current period. Paging stops live updates until you choose Now."))
  }

  private var rollupPicker: some View {
    NativeSegmentedControl(
      Rollup.allCases.map { (value: $0, label: $0.rawValue) },
      selection: Binding(get: { presenter.effectiveRollup }, set: { presenter.setRollup($0) }),
      accessibilityLabel: "Rollup",
      accessibilityIdentifier: "history-rollup"
    )
    .frame(minWidth: 152)
    .disabled(presenter.selectedMetric.usesDailyUTC)
    .richHelp(
      TooltipContent(
        title: "Rollup",
        body: "Combines window samples to limit chart work. Provider analytics keeps its daily UTC buckets."))
  }

  private var stackToggle: some View {
    Toggle("Stacked", isOn: stackedBinding)
      .toggleStyle(.checkbox)
      .disabled(!presenter.canStack)
      .accessibilityIdentifier("history-stacked")
      .richHelp(
        TooltipContent(
          title: "Stack series",
          body: "Adds visible bar series into one daily column. Leave it off to compare series side by side."))
  }

  private var exportButton: some View {
    NativeActionButton("Export CSV", action: exportCurrentPeriod)
      .accessibilityIdentifier("history-export")
      .richHelp(
        TooltipContent(
          title: "Export selected period",
          body: "Writes the selected metric and period without loading the full history into memory."))
  }

  private var viewportControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        pageBackButton
        dateRange
        pageForwardButton
        Spacer()
        earliestLabel
      }
      VStack(alignment: .leading, spacing: 6) {
        dateRange
        HStack(spacing: 8) {
          pageBackButton
          pageForwardButton
          Spacer()
          earliestLabel
        }
      }
    }
    .font(.caption)
  }

  private var pageBackButton: some View {
    NativeIconButton(
      symbol: "chevron.left", accessibilityLabel: "Previous period",
      explanation: "Moves back by the selected calendar period and stops following Now.", action: pageBack
    )
    .disabled(!presenter.canPageBack)
    .accessibilityIdentifier("history-previous-period")
  }

  private var dateRange: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        startPicker
        Text("→").semanticForeground(InterfaceTokens.standard.detailForeground)
        endPicker
      }
      VStack(alignment: .leading, spacing: 4) {
        startPicker
        endPicker
      }
    }
  }

  private var startPicker: some View {
    DatePicker(
      "From", selection: startBinding, displayedComponents: dateComponents
    )
    .accessibilityIdentifier("history-from")
    .environment(\.timeZone, presenter.chartTimeZone)
    .richHelp(
      TooltipContent(
        title: "Start date",
        body: "Sets the first instant, switches the period to Custom, and stops following Now.")
    )
  }

  private var endPicker: some View {
    DatePicker(
      "To", selection: endBinding, displayedComponents: dateComponents
    )
    .accessibilityIdentifier("history-to")
    .environment(\.timeZone, presenter.chartTimeZone)
    .richHelp(
      TooltipContent(
        title: "End date",
        body: "Sets the last instant, switches the period to Custom, and stops following Now.")
    )
  }

  private var pageForwardButton: some View {
    NativeIconButton(
      symbol: "chevron.right", accessibilityLabel: "Next period",
      explanation: "Moves toward the current period. The button stops at Now.", action: pageForward
    )
    .disabled(!presenter.canPageForward)
    .accessibilityIdentifier("history-next-period")
  }

  private var earliestLabel: some View {
    Text(earliestText).font(.caption2).semanticForeground(InterfaceTokens.standard.detailForeground)
  }

  private var metricControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        metricPicker
        attribution
        Spacer()
      }
      VStack(alignment: .leading, spacing: 4) {
        metricPicker
        attribution
      }
    }
  }

  private var metricPicker: some View {
    HStack(spacing: 8) {
      Text("Metric").font(.caption).semanticForeground(InterfaceTokens.standard.detailForeground)
      Picker(
        "Metric", selection: Binding(get: { presenter.selectedMetric }, set: { presenter.setMetric($0) })
      ) {
        ForEach(HistoryMetricGroup.allCases, id: \.self) { group in
          Section(group.rawValue) {
            ForEach(HistoryMetric.allCases.filter { $0.group == group }) { metric in
              Text(metric.title).tag(metric)
            }
          }
        }
      }
      .labelsHidden()
      .frame(minWidth: 250, idealWidth: 320, alignment: .leading)
      .accessibilityIdentifier("history-metric")
      .richHelp(
        TooltipContent(
          title: "History metric",
          body: "Chooses the data to load and draw. The groups name which providers supply each metric.")
      )
    }
  }

  private var attribution: some View {
    WrappingHStack(horizontalSpacing: 4, verticalSpacing: 3) {
      ForEach(plottedProviders, id: \.self) { provider in
        ProviderMarkView(provider, size: CGSize(width: 22, height: 16))
          .accessibilityHidden(true)
      }
      Text(presenter.selectedMetric.attribution(providers: plottedProviders))
        .font(.caption2)
        .semanticForeground(InterfaceTokens.standard.detailForeground)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(presenter.selectedMetric.attribution(providers: plottedProviders))
  }

  private var plottedProviders: [ProviderID] {
    let providers = Set(presenter.state.data?.series.filter { !$0.points.isEmpty }.map(\.id.provider) ?? [])
    return presenter.selectedMetric.suppliers.filter(providers.contains)
  }

  private var dataScope: HistoryDataScope {
    HistoryDataScope(
      activeProviders: settings.activeProviders(states: environment.state.providers),
      selectedWindows: settings.hasCustomSelection ? Set(settings.selectedWindows) : nil)
  }

  private var chartRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        chart.frame(minWidth: 600).frame(height: PopoverGeometry.historyChartHeight)
        HistoryInspector(environment: environment)
          .frame(width: 220, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 12) {
        chart.frame(minWidth: 320).frame(height: PopoverGeometry.historyChartHeight)
        HistoryInspector(environment: environment)
      }
    }
  }

  @ViewBuilder private var chart: some View {
    switch presenter.state {
    case .loading:
      ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      VStack(spacing: 8) {
        ContentUnavailableView(
          "History unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        NativeActionButton("Retry", action: presenter.reload)
          .richHelp(
            TooltipContent(
              title: "Retry history",
              body: "Queries the selected period again. Existing stored samples remain unchanged."))
      }
    case .loaded(let data, let refreshing, let error):
      ZStack(alignment: .topTrailing) {
        if data.isEmpty {
          EmptyHistoryView()
        } else {
          UsageChart(
            data: data, presenter: presenter, stacked: settings.historyStacked && presenter.canStack,
            timeZone: presenter.chartTimeZone)
        }
        if refreshing { UpdatingBadge().accessibilityLabel("Updating history") }
        if let error {
          VStack {
            Spacer()
            HStack(spacing: 8) {
              Text("Update failed: \(error)")
                .fixedSize(horizontal: false, vertical: true)
              NativeActionButton("Retry", action: presenter.reload)
                .richHelp(
                  TooltipContent(
                    title: "Retry history",
                    body: "Queries the selected period again. Existing stored samples remain unchanged."))
            }
            .font(.caption)
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
          }
        }
      }
    }
  }

  private var footer: some View {
    let data = presenter.state.data
    let since = earliest.map { " · since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
    return Text(
      "\(data?.dataPointCount ?? 0) samples · \(data?.series.count ?? 0) series" + since
    )
    .font(.caption2)
    .semanticForeground(InterfaceTokens.standard.detailForeground)
  }

  var stackedBinding: Binding<Bool> {
    Binding(get: { settings.historyStacked }, set: { presenter.setStacked($0) })
  }

  var startBinding: Binding<Date> {
    Binding(
      get: { presenter.currentViewport.lowerBound },
      set: { presenter.setCustomStart($0) })
  }

  var endBinding: Binding<Date> {
    Binding(
      get: { presenter.currentViewport.upperBound },
      set: { presenter.setCustomEnd($0) })
  }

  private var dateComponents: DatePickerComponents {
    presenter.effectiveRollup == .day ? [.date] : [.date, .hourAndMinute]
  }

  private var earliest: Date? { presenter.earliest }

  private var earliestText: String {
    earliest.map { "Earliest sample \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "No earlier samples"
  }

  public func pageBack() {
    presenter.page(forward: false, now: environment.clock.now())
  }

  public func pageForward() {
    presenter.page(forward: true, now: environment.clock.now())
  }

  private func exportCurrentPeriod() {
    guard let url = chooseExportURL() else { return }
    presenter.exportCSV(to: url)
  }
}
