import Foundation
import Testing

@testable import TokenMenuBarCore

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

private func presentedCards() -> [ProviderCard] {
  let state: [ProviderID: ProviderState] = [
    .claude: ProviderState(
      snapshot: snapshot(), availability: .current, warnings: ["w"], credentialState: .valid(expiresAt: nil)),
    .codex: ProviderState(availability: .authenticationRequired, lastError: "expired"),
  ]
  return UsagePresenter.cards(state: state, enabled: [.claude, .codex], samples: [:], now: fixedNow)
}

@Test func usagePresenterOrdersCardsByProvider() {
  #expect(presentedCards().map(\.provider) == [.claude, .codex])
  #expect(presentedCards()[0].id == .claude)
}

@Test func usagePresenterBuildsIdentityChips() {
  let claude = presentedCards()[0]
  #expect(
    claude.chips.map(\.text) == [
      "Max 20x", "user@example.com",
      "Renews \(fixedNow.addingTimeInterval(86400).formatted(date: .abbreviated, time: .omitted))",
    ])
  #expect(claude.chips[0].link == ProviderID.claude.usagePage)
}

@Test func usagePresenterBuildsWindowRows() {
  let claude = presentedCards()[0]
  #expect(claude.rows.count == 1)
  #expect(claude.rows[0].percentText == "36%")
  #expect(claude.rows[0].countdown == "1 hr 0 min")
  #expect(claude.rows[0].id == claude.rows[0].key)
  #expect(claude.rows[0].color == UsageColor.color(pace: claude.rows[0].pace.status, percent: 36))
}

@Test func usagePresenterReportsFreshnessAndWarnings() {
  let claude = presentedCards()[0]
  #expect(claude.fetchedAge == "30s ago")
  #expect(!claude.isStale)
  #expect(claude.credentialDescription == "Token present")
  #expect(claude.warnings == ["w"])
  #expect(!claude.isRefreshing)
  #expect(claude.notices.count == 1)
}

@Test func usagePresenterAsksSignedOutProvidersToSignIn() {
  let codex = presentedCards()[1]
  #expect(codex.rows.isEmpty)
  #expect(codex.emptyTitle == "Sign in to Codex")
  #expect(codex.emptyDescription == "expired")
  #expect(codex.chips.isEmpty)
  #expect(!codex.isStale)
}

@Test func usagePresenterFiltersDisabledProvidersWithoutSnapshots() {
  let state: [ProviderID: ProviderState] = [
    .claude: ProviderState(snapshot: snapshot(), availability: .disabled),
    .codex: ProviderState(availability: .disabled),
  ]
  let cards = UsagePresenter.cards(state: state, enabled: [], samples: [:], now: fixedNow)
  #expect(cards.map(\.provider) == [.claude])
  #expect(cards[0].isStale)
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
    (.loading, "Loading Claude"), (.authenticationRequired, "Sign in to Claude"),
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
      == ProviderID.claude.loginHint)
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

@MainActor
private func makePresenter() throws -> (HistoryPresenter, UsageHistoryStore, Settings) {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-presenter-\(UUID().uuidString)")!)
  let history = try UsageHistoryStore(url: nil)
  return (HistoryPresenter(history: history, settings: settings, clock: testClock), history, settings)
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

@Test @MainActor func historyPresenterLoadsOneSeriesPerWindow() async throws {
  let (presenter, _, data) = try await loadedPresenter()
  #expect(data.series.map(\.label) == ["Claude Session", "Codex Session"])
  #expect(presenter.availableWindows.count == 2)
  #expect(presenter.earliest == fixedNow.addingTimeInterval(-3600))
}

@Test @MainActor func historyPresenterGroupsAnalyticsByMetric() async throws {
  let (presenter, _, _) = try await loadedPresenter()
  #expect(presenter.analytics[.codex]?.map(\.metric) == [.surfaceUsagePercent, .turns])
  #expect(presenter.analytics[.codex]?[0].totalText == "40%")
  #expect(presenter.analytics[.codex]?[1].totalText == "3")
  #expect(presenter.analytics[.codex]?[1].bars.first?.date == DayStamp.date(DayStamp.string(fixedNow)))
  #expect(presenter.analytics[.codex]?[1].id == .turns)
  #expect(presenter.analytics[.codex]?[1].bars.first?.id == "\(DayStamp.string(fixedNow))|m")
  #expect(presenter.analytics[.claude] == nil)
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

@Test @MainActor func historyPresenterRangesRollupsAndCustomPaging() async throws {
  let (presenter, _, settings) = try makePresenter()
  presenter.setRollup(.day)
  #expect(settings.historyRange == .week)
  presenter.setRange(.today)
  #expect(settings.historyRollup == .hour)
  presenter.setStacked(true)
  presenter.setUseUTC(true)
  #expect(presenter.timeZone.secondsFromGMT() == 0)
  let today = presenter.request(now: fixedNow)
  #expect(today.stacked)
  #expect(today.timeZone.secondsFromGMT() == 0)
  #expect(
    today.start
      == Calendar(identifier: .gregorian).startOfDay(for: fixedNow).addingTimeInterval(
        TimeInterval(Calendar.current.timeZone.secondsFromGMT(for: fixedNow))) || today.start <= fixedNow)
  presenter.setRange(.month)
  #expect(presenter.request(now: fixedNow).start == fixedNow.addingTimeInterval(-30 * 86400))
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
  #expect(HistoryPresenter.sections([]).isEmpty)
}

@Test func cardsHideProvidersThatNeverSignedIn() {
  let missing = ProviderState(availability: .authenticationRequired, credentialState: .missing("none"))
  let expired = ProviderState(availability: .authenticationRequired, credentialState: .expired(fixedNow))
  let cached = ProviderState(
    snapshot: DemoData.snapshot(.copilot, now: fixedNow), availability: .stale, credentialState: .missing("none"))
  let cards = UsagePresenter.cards(
    state: [.gemini: missing, .cursor: expired, .copilot: cached], enabled: [.gemini, .cursor, .copilot],
    samples: [:], now: fixedNow)
  #expect(cards.map(\.provider) == [.copilot, .cursor])
  #expect(!UsagePresenter.isVisible(missing, enabled: true))
  #expect(!UsagePresenter.isVisible(expired, enabled: false))
  #expect(UsagePresenter.isVisible(ProviderState(), enabled: true))
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
  #expect(refreshing.statusText == "updating · \(refreshing.fetchedAge)")
  let stale = card(ProviderState(snapshot: snapshot, availability: .rateLimited))
  #expect(stale.statusText == "\(QuotaAvailability.rateLimited.title) · \(stale.fetchedAge)")
  let cached = card(
    ProviderState(
      snapshot: ProviderSnapshot(
        provider: .codex, windows: snapshot.windows, source: .cache, fetchedAt: snapshot.fetchedAt),
      availability: .stale, isRefreshing: true))
  #expect(cached.statusHelp.contains("last ran"))
  let firstRun = card(ProviderState(availability: .loading, isRefreshing: true))
  #expect(firstRun.statusText == "Fetching…")
  #expect(card(ProviderState(availability: .unavailable)).statusText == QuotaAvailability.unavailable.title)
}
