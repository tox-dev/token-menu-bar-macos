import AppKit
import Charts
import SwiftUI
import TokenMenuBarCore

public struct HistoryTab: View {
  @Bindable var environment: UIEnvironment
  private let chooseExportURL: @MainActor () async -> URL?

  public init(
    environment: UIEnvironment,
    chooseExportURL: @escaping @MainActor () async -> URL? = {
      await LiveDependencies.chosen({ LiveDependencies.exportPanel() }) {
        LiveDependencies.presentFilePanel($0, completion: $1)
      }
    }
  ) {
    self.environment = environment
    self.chooseExportURL = chooseExportURL
  }

  private var presenter: HistoryPresenter { environment.historyPresenter }
  private var settings: TokenMenuBarCore.Settings { environment.settings }

  public var body: some View {
    ScrollingTab(tab: .history) {
      VStack(alignment: .leading, spacing: 9) {
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
      presenter.setActive(environment.state.popoverVisible && settings.lastTab == .history)
      presenter.setDataScope(dataScope)
      presenter.ensureLoaded(whileInactive: environment.state.popoverVisible)
    }
    .onChange(of: environment.state.historyRevision) {
      presenter.reload(whileInactive: environment.state.popoverVisible)
    }
    .onChange(of: settings.hidePersonalInformation) { presenter.redraw() }
    .background(HistoryActivity(environment: environment))
    .environment(\.tooltipPresentationDelay, TooltipTiming.historyPresentationDelay)
  }

  private var periodControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        periodPicker
        aggregationControls
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
          aggregationControls
          stackToggle
          Spacer(minLength: 4)
        }
      }
    }
  }

  @ViewBuilder private var aggregationControls: some View {
    if presenter.selectedMetric.usesDailyUTC {
      Text("Daily · UTC").font(.caption).semanticForeground(.secondary)
    } else {
      Text("Rollup").font(.caption).semanticForeground(.secondary)
      rollupPicker
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
    .richHelp(
      TooltipContent(
        title: "Rollup",
        body: "Combines window samples to limit chart work. Provider analytics keeps its daily UTC buckets."))
  }

  @ViewBuilder private var stackToggle: some View {
    if presenter.canStack {
      Toggle("Stacked", isOn: stackedBinding)
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("history-stacked")
        .richHelp(
          TooltipContent(
            title: "Stack series",
            body: "Adds visible bar series into one daily column. Leave it off to compare series side by side."))
    }
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
      }
      VStack(alignment: .leading, spacing: 6) {
        dateRange
        HStack(spacing: 8) {
          pageBackButton
          pageForwardButton
          Spacer()
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

  @ViewBuilder private var dateRange: some View {
    if presenter.period == .range(.custom) {
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
    } else {
      NativeActionButton(
        presenter.currentViewport.lowerBound.formatted(date: .abbreviated, time: .omitted)
          + " – " + presenter.currentViewport.upperBound.formatted(date: .abbreviated, time: .omitted)
      ) { presenter.setPeriod(.range(.custom)) }
      .accessibilityIdentifier("history-date-range")
      .richHelp(
        TooltipContent(
          title: "Custom dates",
          body: "Shows editable From and To dates for the selected period and stops following Now."))
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
      HistoryMetricPicker(
        metrics: presenter.availableMetrics,
        selection: Binding(get: { presenter.selectedMetric }, set: { presenter.setMetric($0) })
      )
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
      selectedWindows: Set(settings.modelSelection(in: environment.state.snapshots)))
  }

  private var chartRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        chart.frame(minWidth: 600, minHeight: chartHeight, maxHeight: .infinity)
        HistoryInspector(environment: environment)
          .frame(width: 220, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 12) {
        chart.frame(minWidth: 320).frame(height: chartHeight)
        HistoryInspector(environment: environment)
      }
    }
  }

  private var chartHeight: CGFloat {
    if case .loading = presenter.state { return PopoverGeometry.historyChartHeight }
    return presenter.state.data?.series.isEmpty == false ? PopoverGeometry.historyChartHeight : 180
  }

  @ViewBuilder private var chart: some View {
    switch presenter.state {
    case .loading:
      ProgressView("Loading history…").progressViewStyle(RingProgressViewStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    return SupportingDetails("Data details", id: "history.data", state: environment.disclosures) {
      Text(
        "\(data?.dataPointCount ?? 0) samples · \(data?.series.count ?? 0) series" + since
      )
      .font(.caption2)
      .semanticForeground(InterfaceTokens.standard.detailForeground)
    }
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

  public func pageBack() {
    presenter.page(forward: false, now: environment.clock.now())
  }

  public func pageForward() {
    presenter.page(forward: true, now: environment.clock.now())
  }

  private func exportCurrentPeriod() {
    Task {
      guard let url = await chooseExportURL() else { return }
      presenter.exportCSV(to: url)
    }
  }
}

private struct HistoryActivity: View {
  let environment: UIEnvironment

  var body: some View {
    Color.clear
      .onChange(of: environment.state.popoverVisible && environment.settings.lastTab == .history, initial: true) {
        _, active in environment.historyPresenter.setActive(active)
      }
      .onChange(of: environment.state.popoverVisible, initial: true) { _, visible in
        if visible { environment.historyPresenter.ensureLoaded(whileInactive: true) }
      }
      .accessibilityHidden(true)
  }
}
