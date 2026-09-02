import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func usagePresenterOrdersCardsByProvider() {
  #expect(presentedCards().map(\.provider) == [.claude, .codex])
  #expect(presentedCards()[0].id == .claude)
  #expect(UsagePresenter.iconTone([.claude: ProviderState(availability: .authenticationRequired)]) == .attention)
  #expect(UsagePresenter.iconTone([.claude: ProviderState(availability: .networkUnavailable)]) == .offline)
  #expect(UsagePresenter.iconTone([.claude: ProviderState(availability: .current)]) == .normal)
}

private func presentedCards() -> [ProviderCard] {
  let state: [ProviderID: ProviderState] = [
    .claude: ProviderState(
      snapshot: snapshot(), availability: .current, warnings: ["w"], credentialState: .valid(expiresAt: nil)),
    .codex: ProviderState(
      availability: .networkUnavailable, lastError: "offline", credentialState: .valid(expiresAt: nil)),
  ]
  return UsagePresenter.cards(state: state, enabled: [.claude, .codex], samples: [:], now: fixedNow)
}

@Test func usagePresenterBuildsIdentityChips() {
  let claude = presentedCards()[0]
  #expect(
    claude.chips.map(\.text) == [
      "Max 20x", "user@example.com",
      "Renews \(fixedNow.addingTimeInterval(86400).formatted(date: .abbreviated, time: .omitted))",
    ])
}

@Test func usagePresenterBuildsWindowRows() {
  let claude = presentedCards()[0]
  #expect(claude.rows.count == 1)
  #expect(claude.rows[0].percentText == "36%")
  #expect(claude.rows[0].countdown == "1 hr 0 min")
  #expect(claude.rows[0].id == claude.rows[0].key)
  #expect(claude.rows[0].color == UsageColor.color(pace: claude.rows[0].pace.status, percent: 36))
  #expect(claude.rows[0].detail == "window · 5h")
  #expect(claude.groups.map(\.rows.count) == [1])
  #expect(claude.groups[0].resetText(at: fixedNow)?.contains("Resets in") == true)
}

@Test func usagePresenterReportsFreshnessAndWarnings() {
  let claude = presentedCards()[0]
  #expect(claude.fetchedAge == "30s ago")
  #expect(!claude.isStale)
  #expect(claude.warnings == ["w"])
  #expect(!claude.isRefreshing)
  #expect(claude.notices.count == 1)
}

@Test func usagePresentationKeepsQuotaAndSupplementaryData() throws {
  let state = ProviderState(
    snapshot: snapshot(),
    analytics: ProviderAnalytics(
      provider: .claude,
      points: [
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .codeReviews, series: "reviews", value: 4)
      ], fetchedAt: fixedNow),
    availability: .current)
  let key = WindowKey(provider: .claude, windowID: "session")
  let presentation = UsagePresenter.presentation(
    state: [.claude: state], enabled: [.claude], selected: [key], samples: [:],
    analytics: [.claude: UsagePresenter.analyticsPresentation(state.analytics, now: fixedNow)],
    lastRefresh: fixedNow.addingTimeInterval(-30), iconTone: .attention, isRefreshing: true, now: fixedNow)
  let card = try #require(presentation.cards.first)
  let row = try #require(card.rows.first)
  #expect(presentation.iconTone == .attention)
  #expect(presentation.isRefreshing)
  #expect(row.key == key)
  #expect(row.isSelected)
  #expect(row.window == state.snapshot?.windows.first)
  #expect(card.identity == state.snapshot?.identity)
  #expect(card.creditsPresentation?.credits == state.snapshot?.credits)
  #expect(card.spendPresentation?.spend == state.snapshot?.spend)
  #expect(card.codeReviews == "4 today · 4 this week")
  #expect(card.notices == state.snapshot?.notices)
  #expect(card.source == state.snapshot?.source)
}

@Test func usagePresentationOmitsModelsOutsideTheCuratedSelection() throws {
  let state = ProviderState(snapshot: snapshot(), availability: .current)
  let presentation = UsagePresenter.presentation(
    state: [.claude: state], enabled: [.claude], selected: [], samples: [:], analytics: [:],
    lastRefresh: nil, iconTone: .normal, isRefreshing: false, now: fixedNow)
  #expect(try #require(presentation.cards.first).rows.isEmpty)
}

@Test func usageDeadlinesScheduleTheirNextVisibleChange() {
  let age = UsageDeadline.age(fixedNow.addingTimeInterval(-30))
  #expect(age.text(at: fixedNow) == "30s ago")
  #expect(age.nextUpdate(after: fixedNow) == fixedNow.addingTimeInterval(30))
  #expect(UsageDeadline.age(fixedNow).nextUpdate(after: fixedNow) == fixedNow.addingTimeInterval(60))
  let minuteAge = UsageDeadline.age(fixedNow.addingTimeInterval(-120))
  #expect(minuteAge.nextUpdate(after: fixedNow) == fixedNow.addingTimeInterval(60))
  #expect(UsageDeadline.age(nil).nextUpdate(after: fixedNow) == nil)
  #expect(
    UsageDeadline.age(fixedNow.addingTimeInterval(-2 * 3600)).nextUpdate(after: fixedNow)
      == fixedNow.addingTimeInterval(3600))
  #expect(
    UsageDeadline.age(fixedNow.addingTimeInterval(-2 * 86400)).nextUpdate(after: fixedNow)
      == fixedNow.addingTimeInterval(86400))
  let reset = UsageDeadline.reset(fixedNow.addingTimeInterval(3601))
  #expect(reset.text(at: fixedNow).hasPrefix("Resets in 1 hr 0 min"))
  #expect(reset.lines(at: fixedNow).count == 2)
  #expect(reset.lines(at: fixedNow).joined(separator: " · ") == reset.text(at: fixedNow))
  #expect(reset.nextUpdate(after: fixedNow) == fixedNow.addingTimeInterval(1))
  #expect(
    UsageDeadline.reset(fixedNow.addingTimeInterval(30)).nextUpdate(after: fixedNow)
      == fixedNow.addingTimeInterval(30))
  #expect(UsageDeadline.reset(nil).text(at: fixedNow) == "No reset scheduled")
  #expect(UsageDeadline.age(nil).lines(at: fixedNow) == ["never"])
  #expect(UsageDeadline.reset(fixedNow).nextUpdate(after: fixedNow) == nil)
}

@Test func usagePresentationFormatsItsLastRefresh() {
  let presentation = UsagePresentation(
    builtAt: fixedNow, lastRefresh: fixedNow.addingTimeInterval(-30), iconTone: .normal, isRefreshing: false,
    cards: [], emptyTitle: "", emptyDescription: "")
  #expect(presentation.updatedText(at: fixedNow) == "Updated 30s ago")
}

@Test func usagePresenterHidesAuthenticationOnlyRecoveryCards() {
  let state = ProviderState(availability: .authenticationRequired, lastError: "expired")
  #expect(UsagePresenter.cards(state: [.codex: state], enabled: [.codex], samples: [:], now: fixedNow).isEmpty)
}

@Test func usagePresenterFiltersDisabledProvidersWithoutSnapshots() {
  let state: [ProviderID: ProviderState] = [
    .claude: ProviderState(snapshot: snapshot(), availability: .disabled),
    .codex: ProviderState(availability: .disabled),
  ]
  let cards = UsagePresenter.cards(state: state, enabled: [], samples: [:], now: fixedNow)
  #expect(cards.isEmpty)
}

private func snapshot(source: DataSource = .network) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: .claude,
    identity: ProviderIdentity(
      planName: "Max 20x", tier: "t", email: "user@example.com", organization: "user@example.com's Organization",
      subscriptionActiveUntil: fixedNow.addingTimeInterval(86400)),
    windows: [
      QuotaWindow(
        id: "session", label: "Current session", group: .session, usedPercent: 36,
        resetsAt: fixedNow.addingTimeInterval(3600), duration: 18000)
    ],
    credits: CreditBalance(balance: 12.5, currency: "USD", hasCredits: true, approxLocalMessages: 5...10),
    spend: SpendControl(
      enabled: true, used: Money(amountMinor: 100, currency: "USD"), limit: Money(amountMinor: 1000, currency: "USD"),
      percent: 10),
    resetCredits: ResetCredits(available: 1, applicable: 1),
    notices: [Notice(kind: .info, text: "hi")],
    source: source,
    fetchedAt: fixedNow.addingTimeInterval(-30)
  )
}

@Test func usagePresenterChipsAndEmptyStates() {
  let local = snapshot(source: .localLog)
  #expect(UsagePresenter.chips(provider: .codex, snapshot: local).last?.text == "From local logs")
  let plain = ProviderSnapshot(
    provider: .codex, identity: ProviderIdentity(planName: "Pro", organization: "Org"), windows: [], fetchedAt: fixedNow
  )
  #expect(UsagePresenter.chips(provider: .codex, snapshot: plain).map(\.text) == ["Pro", "Org"])
  #expect(UsagePresenter.chips(provider: .codex, snapshot: nil).isEmpty)
  let states: [(QuotaAvailability, String)] = [
    (.loading, "Loading Claude"), (.authenticationRequired, "No usage available"),
    (.networkUnavailable, "Claude is offline"),
    (.disabled, "Claude disabled"), (.unavailable, "Claude unavailable"), (.rateLimited, "Claude rate limited"),
    (.current, "No usage yet"),
    (.stale, "No usage yet"),
  ]
  for (availability, title) in states {
    #expect(UsagePresenter.emptyState(provider: .claude, state: ProviderState(availability: availability)).0 == title)
  }
  #expect(
    UsagePresenter.emptyState(provider: .claude, state: ProviderState(availability: .networkUnavailable)).1
      == "No network connection.")
  #expect(
    UsagePresenter.emptyState(provider: .claude, state: ProviderState(availability: .unavailable)).1
      == "The usage endpoint returned an error.")
  #expect(
    UsagePresenter.emptyState(provider: .claude, state: ProviderState(availability: .authenticationRequired)).1
      == "Review Claude under Settings > Providers.")
}

@Test func usagePresenterCodeReviewSummary() {
  #expect(UsagePresenter.codeReviewSummary(nil, now: fixedNow) == nil)
  let empty = ProviderAnalytics(
    provider: .codex, points: [AnalyticsPoint(day: "d", metric: .turns, series: "m", value: 1)], fetchedAt: fixedNow)
  #expect(UsagePresenter.codeReviewSummary(empty, now: fixedNow) == nil)
  let today = DayStamp.string(fixedNow)
  let old = DayStamp.string(fixedNow.addingTimeInterval(-3 * 86400))
  let ancient = DayStamp.string(fixedNow.addingTimeInterval(-10 * 86400))
  let analytics = ProviderAnalytics(
    provider: .codex,
    points: [
      AnalyticsPoint(day: today, metric: .codeReviews, series: "reviews", value: 2),
      AnalyticsPoint(day: old, metric: .codeReviews, series: "reviews", value: 7),
      AnalyticsPoint(day: ancient, metric: .codeReviews, series: "reviews", value: 100),
    ], fetchedAt: fixedNow)
  #expect(UsagePresenter.codeReviewSummary(analytics, now: fixedNow) == "2 today · 9 this week")
  let state = ProviderState(snapshot: snapshot(), analytics: analytics, availability: .current)
  #expect(
    UsagePresenter.card(provider: .codex, state: state, samples: [:], now: fixedNow).codeReviews
      == "2 today · 9 this week")
}

@Test func usagePresenterSummaries() {
  #expect(UsagePresenter.spendSummary(SpendControl(enabled: false)) == "Off")
  #expect(
    UsagePresenter.spendSummary(SpendControl(enabled: false, disabledReason: "org_level_disabled"))
      == "Off (Org Level Disabled)")
  let spend = SpendControl(
    enabled: true, used: Money(amountMinor: 2445, currency: "USD"), limit: Money(amountMinor: 8000, currency: "USD"),
    percent: 31)
  #expect(UsagePresenter.spendSummary(spend).contains("24.45"))
  #expect(UsagePresenter.spendSummary(spend).hasSuffix("(31%)"))
  #expect(UsagePresenter.spendSummary(SpendControl(enabled: true)) == "— of no limit")
  #expect(UsagePresenter.creditsSummary(CreditBalance(balance: nil, unlimited: true)) == "Unlimited")
  #expect(UsagePresenter.creditsSummary(CreditBalance(balance: 0, hasCredits: false)) == "No credits")
  #expect(UsagePresenter.creditsSummary(CreditBalance(balance: 3, currency: "USD", hasCredits: true)).contains("3.00"))
  #expect(
    UsagePresenter.creditsSummary(CreditBalance(balance: 3, hasCredits: true, approxLocalMessages: 1...4))
      == "3 · ~1–4 local messages")
  #expect(Chip(text: "x").id == "x")
}

@Test @MainActor func historyPresenterLoadsOneSeriesPerWindow() async throws {
  let (presenter, _, data) = try await loadedPresenter()
  #expect(data.series.map(\.label) == ["Claude Session", "Codex Session"])
  #expect(presenter.availableWindows.count == 2)
  #expect(presenter.earliest == fixedNow.addingTimeInterval(-3600))
}

@MainActor
private func loadedPresenter() async throws -> (HistoryPresenter, Settings, HistoryRenderData) {
  let (presenter, history, settings) = try makePresenter()
  try await history.record(
    sample(.claude, 10, at: fixedNow.addingTimeInterval(-3600)), now: fixedNow.addingTimeInterval(-3600))
  try await history.record(
    sample(.claude, 40, at: fixedNow.addingTimeInterval(-600)), now: fixedNow.addingTimeInterval(-600))
  try await history.record(
    sample(.codex, 20, at: fixedNow.addingTimeInterval(-600)), now: fixedNow.addingTimeInterval(-600))
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "m", value: 3),
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .surfaceUsagePercent, series: "cli", value: 40),
      ], fetchedAt: fixedNow))
  #expect(presenter.state == .loading)
  presenter.reload()
  await presenter.waitForLoad()
  guard case .loaded(let data, false, nil) = presenter.state else {
    Issue.record("unexpected state \(presenter.state)")
    throw CancellationError()
  }
  return (presenter, settings, data)
}

@Test @MainActor func historyPresenterGroupsAnalyticsByMetric() async throws {
  let (presenter, _, _) = try await loadedPresenter()
  presenter.setMetric(.analytics(.turns))
  await presenter.waitForLoad()
  #expect(presenter.state.data?.series.map(\.id.provider) == [.codex])
  #expect(presenter.state.data?.series.flatMap(\.points).map(\.value) == [3])
  presenter.setMetric(.analytics(.surfaceUsagePercent))
  await presenter.waitForLoad()
  #expect(presenter.state.data?.summaryText == "1 series · latest Aug 29")
}

@Test @MainActor func historyPresenterReloadInvalidatesCachedMetrics() async throws {
  let (presenter, history, _) = try makePresenter()
  try await history.record(
    sample(.claude, 10, at: fixedNow.addingTimeInterval(-600)), now: fixedNow.addingTimeInterval(-600))
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "m", value: 3)],
      fetchedAt: fixedNow))
  presenter.reload()
  await presenter.waitForLoad()
  presenter.setMetric(.analytics(.turns))
  await presenter.waitForLoad()
  try await history.record(
    sample(.claude, 90, at: fixedNow.addingTimeInterval(-60)), now: fixedNow.addingTimeInterval(-60))

  presenter.reload()
  await presenter.waitForLoad()
  presenter.setMetric(.windowUsagePercent)
  await presenter.waitForLoad()

  let values = presenter.state.data?.series.flatMap(\.points).map(\.value)
  #expect(values?.contains(90) == true)
}

@Test @MainActor func historyPresenterReadsTheSelectedPoint() async throws {
  let (presenter, _, data) = try await loadedPresenter()
  #expect(presenter.value(for: data.series[0]) == "40%")
  presenter.select(x: fixedNow.addingTimeInterval(-3500))
  #expect(presenter.selectedDate == data.series[0].points.first?.date)
  #expect(presenter.value(for: data.series[0]) == "10%")
  presenter.select(x: nil)
  #expect(presenter.selectedDate == nil)
  #expect(
    presenter.value(for: HistorySeries(key: WindowKey(provider: .claude, windowID: "session"), label: "x", points: []))
      == "—")
}

@Test @MainActor func historyPresenterMovesSelectionAcrossVisibleDates() async throws {
  let (presenter, _, data) = try await loadedPresenter()

  for date in data.timeline {
    presenter.moveSelection(1)
    #expect(presenter.selectedDate == date)
  }
  presenter.moveSelection(1)
  #expect(presenter.selectedDate == data.timeline.last)
  for date in data.timeline.dropLast().reversed() {
    presenter.moveSelection(-1)
    #expect(presenter.selectedDate == date)
  }
  presenter.selectedDate = nil
  presenter.moveSelection(-1)
  #expect(presenter.selectedDate == data.timeline.last)
}

@Test @MainActor func historyPresenterKeepsWindowAndAnalyticsHoverStateConsistent() async throws {
  let (presenter, _, data) = try await loadedPresenter()
  let window = data.series[0].id

  presenter.setHovered(window)
  #expect(presenter.hoveredSeriesID == window)
  #expect(presenter.hoveredKey == data.series[0].key)
  let analytics = HistorySeriesID.analytics(provider: .codex, series: "cli")
  presenter.setHovered(analytics)
  #expect(presenter.hoveredSeriesID == analytics)
  #expect(presenter.hoveredKey == nil)
  presenter.setHovered(nil)
  #expect(presenter.hoveredSeriesID == nil)
  #expect(presenter.hoveredKey == nil)
}

@Test @MainActor func historyPresenterDescribesASelectedReset() async throws {
  let (presenter, history, _) = try makePresenter()
  let earlier = fixedNow.addingTimeInterval(-3600)
  let later = fixedNow.addingTimeInterval(-600)
  try await history.record(sample(.claude, 80, at: earlier), now: earlier)
  try await history.record(sample(.claude, 5, at: later), now: later)
  presenter.reload()
  await presenter.waitForLoad()
  let series = try #require(presenter.state.data?.series.first)
  let reset = try #require(series.points.first { $0.isReset })

  presenter.select(x: reset.date)

  #expect(presenter.resetDescription(for: series)?.hasPrefix("Reset ") == true)
}

@Test @MainActor func historyPresenterInterpolatesAcrossMissingBuckets() throws {
  let (presenter, _, _) = try makePresenter()
  let first = fixedNow.addingTimeInterval(-600)
  let series = HistorySeries(
    id: .window(WindowKey(provider: .claude, windowID: "session")), label: "Session",
    points: [
      SeriesPoint(date: first, value: 10, segment: 0),
      SeriesPoint(date: fixedNow, value: 40, segment: 1),
    ], summaryValue: 40)
  presenter.selectedDate = fixedNow.addingTimeInterval(-300)

  #expect(presenter.value(for: series) == "10%")
}

@Test @MainActor func historyPresenterLimitsHistoryToEnabledModels() async throws {
  let (presenter, _, _) = try await loadedPresenter()
  let selected = WindowKey(provider: .claude, windowID: "session")

  presenter.setDataScope(HistoryDataScope(activeProviders: [.claude], selectedWindows: [selected]))
  await presenter.waitForLoad()

  #expect(presenter.state.data?.series.map(\.id) == [.window(selected)])
  #expect(presenter.request(now: fixedNow).allKeys == [selected])
}

@Test @MainActor func historyPresenterHidesAndIsolatesWindows() async throws {
  let (presenter, settings, _) = try await loadedPresenter()
  let key = WindowKey(provider: .claude, windowID: "session")
  let codex = WindowKey(provider: .codex, windowID: "session")
  presenter.toggleVisibility(key)
  await presenter.waitForLoad()
  #expect(!presenter.isVisible(key))
  #expect(presenter.request(now: fixedNow).keys == [codex])
  presenter.toggleVisibility(codex)
  await presenter.waitForLoad()
  #expect(presenter.isVisible(codex))
  presenter.toggleVisibility(key)
  await presenter.waitForLoad()
  #expect(presenter.isVisible(key))
  presenter.isolate(key)
  await presenter.waitForLoad()
  #expect(settings.historyHiddenKeys == [codex])
  presenter.isolate(key)
  await presenter.waitForLoad()
  #expect(settings.historyHiddenKeys.isEmpty)
}

@Test @MainActor func historyPresenterPairsRangeWithRollup() async throws {
  let (presenter, _, settings) = try makePresenter()
  presenter.setRollup(.day)
  #expect(settings.historyRange == .week)
  presenter.setRange(.today)
  #expect(settings.historyRollup == .hour)
}

@MainActor
private func makePresenter() throws -> (HistoryPresenter, UsageHistoryStore, Settings) {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-presenter-\(UUID().uuidString)")!)
  let history = try UsageHistoryStore(url: nil)
  return (HistoryPresenter(history: history, settings: settings, clock: testClock), history, settings)
}

@Test @MainActor func historyPresenterLoadsOnFirstDemand() async throws {
  let (presenter, _, _) = try makePresenter()

  presenter.ensureLoaded()
  await presenter.waitForLoad()

  #expect(presenter.state.data?.isEmpty == true)
}

@Test @MainActor func historyPresenterRequestCarriesTheDisplayChoices() async throws {
  let (presenter, _, _) = try makePresenter()
  presenter.setRange(.today)
  presenter.setStacked(true)
  presenter.setUseUTC(true)
  #expect(presenter.timeZone.secondsFromGMT() == 0)
  let today = presenter.request(now: fixedNow)
  #expect(!today.stacked)
  #expect(today.timeZone.secondsFromGMT() == 0)
  #expect(today.start <= fixedNow)
  presenter.setMetric(.analytics(.turns))
  #expect(!presenter.request(now: fixedNow).stacked)
  #expect(presenter.request(now: fixedNow).rollup == .day)
  presenter.setRange(.month)
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let endDay = calendar.startOfDay(for: fixedNow)
  #expect(presenter.request(now: fixedNow).start == calendar.date(byAdding: .day, value: -29, to: endDay))
  await presenter.waitForLoad()
}

@Test @MainActor func historyPresenterPersistsTheSelectedMetric() throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-persistence-\(UUID().uuidString)")!)
  let history = try UsageHistoryStore(url: nil)
  var persisted: HistoryMetric?
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: testClock, initialMetric: .analytics(.turns),
    persistMetric: { persisted = $0 })

  #expect(presenter.selectedMetric == .analytics(.turns))
  presenter.setMetric(.analytics(.surfaceUsagePercent))
  #expect(persisted == .analytics(.surfaceUsagePercent))
}

@Test @MainActor func historyPresenterIsolationRestoresPreviouslyHiddenSeries() async throws {
  let (presenter, settings, _) = try await loadedPresenter()
  let hidden = WindowKey(provider: .gemini, windowID: "retired")
  let claude = WindowKey(provider: .claude, windowID: "session")
  let codex = WindowKey(provider: .codex, windowID: "session")
  settings.historyHiddenKeys = [hidden]
  presenter.redraw()
  await presenter.waitForLoad()

  presenter.isolate(claude)
  await presenter.waitForLoad()
  #expect(settings.historyHiddenKeys == [hidden, codex])
  presenter.isolate(claude)
  await presenter.waitForLoad()
  #expect(settings.historyHiddenKeys == [hidden])
}

@Test @MainActor func historyPresenterCustomRangeFollowsNowUntilPinned() async throws {
  let (presenter, _, _) = try makePresenter()
  presenter.setRange(.custom)
  presenter.customStart = fixedNow.addingTimeInterval(-7200)
  presenter.customEnd = fixedNow.addingTimeInterval(-3600)
  presenter.followNow = false
  let custom = presenter.request(now: fixedNow)
  #expect(custom.start == fixedNow.addingTimeInterval(-7200))
  #expect(custom.end == fixedNow.addingTimeInterval(-3600))
  presenter.followNow = true
  #expect(presenter.request(now: fixedNow).end == fixedNow)
  presenter.customStart = fixedNow.addingTimeInterval(10)
  #expect(presenter.request(now: fixedNow).start == fixedNow.addingTimeInterval(-60))
}

@Test @MainActor func historyPresenterNowPreservesTheCustomDuration() async throws {
  let (presenter, _, _) = try makePresenter()
  presenter.setRange(.custom)
  presenter.customStart = fixedNow.addingTimeInterval(-7200)
  presenter.customEnd = fixedNow.addingTimeInterval(-3600)
  presenter.followNow = false

  presenter.setPeriod(.now)
  await presenter.waitForLoad()

  #expect(presenter.customStart == fixedNow.addingTimeInterval(-3600))
  #expect(presenter.customEnd == fixedNow)
  #expect(presenter.currentViewport.upperBound.timeIntervalSince(presenter.currentViewport.lowerBound) == 3600)
}

@Test @MainActor func historyPresenterResetRestoresRuntimeState() async throws {
  let (presenter, _, settings) = try makePresenter()
  presenter.setMetric(.analytics(.turns))
  presenter.setRange(.custom)
  presenter.followNow = false
  presenter.selectedDate = fixedNow
  settings.historyMetricID = HistoryMetric.windowUsagePercent.storageID

  presenter.reset()
  await presenter.waitForLoad()

  #expect(presenter.selectedMetric == .windowUsagePercent)
  #expect(presenter.followNow)
  #expect(presenter.selectedDate == nil)
  #expect(presenter.customEnd == fixedNow)
  #expect(presenter.customStart == fixedNow.addingTimeInterval(-86400))
}

@Test @MainActor func historyPresenterQueryRollupHasAHardPerSeriesBudget() {
  let request = HistoryRequest(
    keys: [], start: fixedNow.addingTimeInterval(-60 * 86400), end: fixedNow, rollup: .minute)

  let interval = HistoryPresenter.queryRollup(for: request)

  #expect(60 * 86400 / interval <= Double(HistoryPresenter.maxQueryPointsPerSeries))
  #expect(interval.truncatingRemainder(dividingBy: UsageHistoryStore.sampleInterval) == 0)
}

@Test @MainActor func historyPresenterPagesWithinTheCustomRange() async throws {
  let (presenter, _, _) = try makePresenter()
  presenter.setRange(.custom)
  presenter.customStart = fixedNow.addingTimeInterval(-7200)
  presenter.customEnd = fixedNow.addingTimeInterval(-3600)
  presenter.followNow = false
  #expect(!presenter.canPageBack)
  #expect(presenter.canPageForward)
  presenter.page(forward: true, now: fixedNow)
  await presenter.waitForLoad()
  #expect(presenter.followNow)
  #expect(presenter.customEnd == fixedNow)
  #expect(!presenter.canPageForward)
  presenter.page(forward: false, now: fixedNow)
  await presenter.waitForLoad()
  #expect(presenter.customEnd == fixedNow.addingTimeInterval(-3600))
  #expect(!presenter.followNow)
  presenter.select(x: fixedNow)
  #expect(presenter.selectedDate == nil)
}

@Test @MainActor func historyPresenterPagesTodayByCalendarDay() async throws {
  let (presenter, _, settings) = try makePresenter()
  settings.historyUseUTC = true
  presenter.setRange(.today)
  await presenter.waitForLoad()
  presenter.page(forward: false, now: fixedNow)
  await presenter.waitForLoad()
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let yesterday = calendar.date(byAdding: .day, value: -1, to: fixedNow)!
  #expect(presenter.currentViewport.upperBound == calendar.startOfDay(for: fixedNow))
  #expect(presenter.currentViewport.lowerBound == calendar.startOfDay(for: yesterday))
  presenter.page(forward: true, now: fixedNow)
  await presenter.waitForLoad()
  #expect(presenter.followNow)
}

@Test @MainActor func historyPresenterEditingAnEndpointStopsFollowingNow() async throws {
  let (presenter, _, _) = try makePresenter()
  presenter.setRange(.custom)
  presenter.setCustomStart(fixedNow.addingTimeInterval(-9000))
  await presenter.waitForLoad()
  #expect(presenter.customStart == fixedNow.addingTimeInterval(-9000))
  presenter.setFollowNow(true)
  await presenter.waitForLoad()
  #expect(presenter.followNow)
  presenter.setCustomEnd(fixedNow.addingTimeInterval(-100))
  await presenter.waitForLoad()
  #expect(!presenter.followNow)
  #expect(presenter.customEnd == fixedNow.addingTimeInterval(-100))

  presenter.setFollowNow(true)
  await presenter.waitForLoad()
  presenter.setFollowNow(false)
  await presenter.waitForLoad()
  #expect(!presenter.followNow)
  #expect(presenter.currentViewport.upperBound == fixedNow)
}

enum HistoryEndpoint: CaseIterable, Sendable {
  case start
  case end
}

enum HistoryStartingPeriod: CaseIterable, Sendable {
  case today
  case week
  case now
}

@Test(arguments: HistoryStartingPeriod.allCases, HistoryEndpoint.allCases)
@MainActor func historyPresenterEditingDatesEntersCustomWithTheDisplayedViewport(
  startingPeriod: HistoryStartingPeriod,
  endpoint: HistoryEndpoint
) async throws {
  let (presenter, _, settings) = try makePresenter()
  switch startingPeriod {
  case .today:
    presenter.setRange(.today)
  case .week:
    presenter.setRange(.week)
  case .now:
    presenter.setRange(.week)
    presenter.setPeriod(.now)
  }
  let displayed = presenter.currentViewport
  let requested =
    endpoint == .start
    ? displayed.lowerBound.addingTimeInterval(60)
    : displayed.upperBound.addingTimeInterval(-60)

  switch endpoint {
  case .start: presenter.setCustomStart(requested)
  case .end: presenter.setCustomEnd(requested)
  }
  await presenter.waitForLoad()

  let request = presenter.request(now: fixedNow)
  #expect(settings.historyRange == .custom)
  #expect(presenter.period == .range(.custom))
  #expect(!presenter.followNow)
  #expect(request.start == (endpoint == .start ? requested : displayed.lowerBound))
  #expect(request.end == (endpoint == .end ? requested : displayed.upperBound))
  #expect(request.start < request.end)
}

@Test @MainActor func historyPresenterReportsStoreFailures() async throws {
  let (presenter, history, _) = try makePresenter()
  try await history.breakDatabase()
  presenter.reload()
  await presenter.waitForLoad()
  guard case .failed(let message) = presenter.state else {
    Issue.record("expected failure")
    return
  }
  #expect(message.contains("samples"))
  #expect(presenter.state.data == nil)
}

@Test @MainActor func historyPresenterReportsExportFailures() async throws {
  let (presenter, history, _) = try makePresenter()
  try await history.record(sample(.claude, 10, at: fixedNow), now: fixedNow)
  presenter.reload()
  await presenter.waitForLoad()
  try await history.breakDatabase()

  await presenter.exportCSV(to: temporaryDirectory().appendingPathComponent("broken.csv")).value

  #expect(presenter.exportError?.contains("Export failed") == true)
}

@Test @MainActor func historyPresenterCancelsSupersededRendering() async throws {
  let (presenter, _, _) = try await loadedPresenter()

  presenter.redraw()
  presenter.redraw()
  await presenter.waitForLoad()

  #expect(presenter.state.data?.series.count == 2)
}

@Test @MainActor func historyPresenterMarksRefreshingWhileReloading() async throws {
  let (presenter, _, _) = try makePresenter()
  presenter.reload()
  await presenter.waitForLoad()
  presenter.reload()
  guard case .loaded(_, true, _) = presenter.state else {
    Issue.record("expected refreshing state")
    return
  }
  presenter.reload()
  await presenter.waitForLoad()
  #expect(presenter.state.data?.isEmpty == true)
}

@Test func cardsRequireDiscoveredAuthenticationOrData() {
  let missing = ProviderState(availability: .authenticationRequired, credentialState: .missing("none"))
  let expired = ProviderState(availability: .authenticationRequired, credentialState: .expired(fixedNow))
  let cached = ProviderState(
    snapshot: DemoData.snapshot(.copilot, now: fixedNow), availability: .stale, credentialState: .missing("none"))
  let authenticated = ProviderState(credentialState: .valid(expiresAt: nil))
  let authenticatedHealth = ProviderState(
    credentialHealth: .valid(source: ProviderID.claude.setup.credentialSources[0], expiresAt: nil))
  let analytics = ProviderState(
    analytics: ProviderAnalytics(provider: .codex, points: [], fetchedAt: fixedNow))
  let cards = UsagePresenter.cards(
    state: [
      .gemini: missing, .cursor: expired, .copilot: cached, .claude: authenticatedHealth, .codex: analytics,
    ], enabled: Set(ProviderID.allCases),
    samples: [:], now: fixedNow)
  #expect(cards.map(\.provider) == [.claude, .codex, .copilot])
  #expect(!UsagePresenter.isVisible(missing, enabled: true))
  #expect(!UsagePresenter.isVisible(expired, enabled: true))
  #expect(UsagePresenter.isVisible(cached, enabled: true))
  #expect(UsagePresenter.isVisible(authenticated, enabled: true))
  #expect(UsagePresenter.isVisible(authenticatedHealth, enabled: true))
  #expect(UsagePresenter.isVisible(analytics, enabled: true))
  #expect(!UsagePresenter.isVisible(cached, enabled: false))
  #expect(!UsagePresenter.isVisible(ProviderState(), enabled: true))
}

@Test func windowsSharingAResetAreGroupedTogether() {
  let reset = fixedNow.addingTimeInterval(3600)
  func row(_ id: String, resets: Date?) -> WindowRow {
    WindowRow(
      key: WindowKey(provider: .claude, windowID: id),
      window: QuotaWindow(id: id, label: id, group: .weekly, usedPercent: 10, resetsAt: resets),
      pace: PaceEstimate(status: .onTrack, expectedPercent: 10, ratio: 1, projectedExhaustion: nil),
      countdown: "1h", resetClock: "2:00 PM")
  }
  // Claude's weekly models share one reset, so the card printed the same line under three rows running.
  let groups = UsagePresenter.groups([
    row("session", resets: fixedNow.addingTimeInterval(600)),
    row("all", resets: reset), row("fable", resets: reset), row("sonnet", resets: reset),
    row("none", resets: nil),
  ])
  #expect(groups.map(\.rows.count) == [1, 3, 1])
  #expect(groups[1].resetText == "Resets in 1h · 2:00 PM")
  #expect(groups[1].isSingle == false)
  #expect(groups[0].isSingle)
  // A window with no reset never joins a group, because it shares nothing with the one before it.
  #expect(groups[2].resetText == nil)
  #expect(UsagePresenter.groups([]).isEmpty)
}

@Test func cardStatusTextTracksRefreshAndAge() {
  let snapshot = DemoData.snapshot(.codex, now: fixedNow.addingTimeInterval(-120))
  func card(_ state: ProviderState) -> ProviderCard {
    UsagePresenter.card(provider: .codex, state: state, samples: [:], now: fixedNow)
  }
  let current = card(ProviderState(snapshot: snapshot, availability: .current))
  #expect(current.statusText == "fetched \(current.fetchedAge)")
  #expect(current.statusHelp.contains("last successful fetch"))
  let refreshing = card(ProviderState(snapshot: snapshot, availability: .stale, isRefreshing: true))
  #expect(refreshing.statusText == "refreshing… · showing \(refreshing.fetchedAge)")
  // Being offline or rate limited leads, because a refresh will not fix it and the numbers below stay put.
  let offline = card(
    ProviderState(snapshot: snapshot, availability: .networkUnavailable, isRefreshing: true))
  #expect(offline.statusText == "Offline · refreshing… · showing \(offline.fetchedAge)")
  let limited = card(ProviderState(snapshot: snapshot, availability: .rateLimited, isRefreshing: true))
  #expect(limited.statusText == "Rate limited · refreshing… · showing \(limited.fetchedAge)")
  #expect(refreshing.statusHelp.contains("from the last successful fetch"))
  // The rows a refresh is replacing stay on screen while it runs.
  #expect(!refreshing.rows.isEmpty)
  let stale = card(ProviderState(snapshot: snapshot, availability: .rateLimited))
  #expect(stale.statusText == "\(QuotaAvailability.rateLimited.title) · \(stale.fetchedAge)")
  let cached = card(
    ProviderState(
      snapshot: ProviderSnapshot(
        provider: .codex, windows: snapshot.windows, source: .cache, fetchedAt: snapshot.fetchedAt),
      availability: .stale, isRefreshing: true))
  #expect(cached.statusHelp.contains("last ran"))
  #expect(card(ProviderState(availability: .loading, isRefreshing: true)).statusText == "Refreshing…")
  #expect(card(ProviderState(availability: .unavailable)).statusText == QuotaAvailability.unavailable.title)
}

private func sample(_ provider: ProviderID, _ percent: Double, at date: Date) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: provider,
    windows: [
      QuotaWindow(
        id: "session", label: "Session", group: .session, usedPercent: percent, resetsAt: date.addingTimeInterval(3600),
        duration: 18000)
    ], fetchedAt: date)
}
