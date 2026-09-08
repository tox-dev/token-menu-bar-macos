import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

@Test(arguments: [
  (176_400.0, "2d 1h"), (7260, "2 hr 1 min"), (120, "2 min"), (30, "< 1 min"),
])
func limitNoticeShowsCountdownAndLocalResetTime(seconds: TimeInterval, countdown: String) {
  let reset = fixedNow.addingTimeInterval(seconds)
  let notice = Notice(kind: .limitReached, text: "Weekly limit reached.", resetsAt: reset)
  #expect(
    notice.text(at: fixedNow)
      == "Weekly limit reached. Resets in \(countdown) · \(Format.resetClock(reset, now: fixedNow)).")
}

@Test func limitNoticeCountdownAdvancesWithoutAnotherFetch() {
  let notice = Notice(
    kind: .limitReached, text: "Weekly limit reached.", resetsAt: fixedNow.addingTimeInterval(7260))
  #expect(notice.text(at: fixedNow.addingTimeInterval(60)).contains("Resets in 2 hr 0 min"))
}

@Test(arguments: [0.0, -60.0])
func elapsedLimitResetWaitsForProviderConfirmation(seconds: TimeInterval) {
  let notice = Notice(
    kind: .limitReached, text: "Weekly limit reached.", resetsAt: fixedNow.addingTimeInterval(seconds))
  #expect(notice.text(at: fixedNow) == "Weekly limit reached. Reset due · Awaiting provider refresh.")
}

@Test func limitNoticeWithoutResetKeepsItsOriginalMessage() {
  let notice = Notice(kind: .limitReached, text: "Usage limit reached.")
  #expect(notice.text(at: fixedNow) == "Usage limit reached.")
  #expect(notice.resetDeadline == nil)
}

@Test func limitNoticePreservesItsDeadlineInCachedSnapshots() throws {
  let notice = Notice(kind: .limitReached, text: "Weekly limit reached.", windowID: "weekly", resetsAt: fixedNow)
  #expect(try JSONDecoder().decode(Notice.self, from: JSONEncoder().encode(notice)) == notice)
}

@Test func claudeLimitMappingRetainsTheResetInstant() throws {
  let response = try JSONDecoder().decode(
    ClaudeAPI.UsageResponse.self,
    from: Data(
      #"{"limits":[{"kind":"weekly_all","percent":100,"severity":"critical","resets_at":"2026-09-10T12:00:00Z"}]}"#
        .utf8))
  let notice = try #require(ClaudeMapper.notices(response, now: fixedNow).first)
  #expect(notice.resetsAt == ISODate.parse("2026-09-10T12:00:00Z"))
  #expect(notice.text == "All models limit reached.")
}

@Test(arguments: ProviderID.allCases)
func hiddenLimitNoticesUseCachedWindowDeadlines(provider: ProviderID) throws {
  let reset = fixedNow.addingTimeInterval(95)
  let snapshot = ProviderSnapshot(
    provider: provider,
    windows: [QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 100, resetsAt: reset)],
    notices: [Notice(kind: .limitReached, text: "Weekly limit reached; resets later.", windowID: "weekly")],
    fetchedAt: fixedNow)
  let presentation = UsagePresenter.presentation(
    state: [provider: ProviderState(snapshot: snapshot, availability: .current)], enabled: [provider],
    selected: [], samples: [:], analytics: [:], lastRefresh: nil, iconTone: .attention, isRefreshing: false,
    now: fixedNow)
  let card = try #require(presentation.cards.first)
  #expect(card.rows.isEmpty)
  #expect(card.notices.first?.text(at: fixedNow).hasPrefix("Weekly limit reached. Resets in 1 min") == true)
  let deadline = try #require(presentation.nextDeadline(after: fixedNow))
  #expect(deadline > fixedNow.addingTimeInterval(35))
  #expect(deadline < fixedNow.addingTimeInterval(35.001))
  #expect(card.notices.first?.text(at: deadline).contains("Resets in < 1 min") == true)
}

@Test(arguments: [120.0, 125, 86400, 176425])
func countdownWakesOncePerDisplayedChange(remaining: TimeInterval) throws {
  let deadline = UsageDeadline.reset(fixedNow.addingTimeInterval(remaining))
  let update = try #require(deadline.nextUpdate(after: fixedNow))
  #expect(deadline.lines(at: update) != deadline.lines(at: fixedNow))
  let next = try #require(deadline.nextUpdate(after: update))
  #expect(next.timeIntervalSince(update) > 59)
}

@Test func multiDayCountdownDoesNotWakeForInvisibleMinutes() throws {
  let deadline = UsageDeadline.reset(fixedNow.addingTimeInterval(176375))
  let update = try #require(deadline.nextUpdate(after: fixedNow))
  #expect(update.timeIntervalSince(fixedNow) > 3500)
  #expect(deadline.lines(at: update) != deadline.lines(at: fixedNow))
}

@Test(arguments: ProviderID.allCases, [ResetPrecision.instant, .day])
func limitNotificationsOnlyCountDownKnownInstants(provider: ProviderID, precision: ResetPrecision) throws {
  let reset = fixedNow.addingTimeInterval(3600)
  func snapshot(percent: Double) -> ProviderSnapshot {
    ProviderSnapshot(
      provider: provider,
      windows: [
        QuotaWindow(
          id: "session", label: "Session", group: .session, usedPercent: percent, resetsAt: reset,
          duration: 18000, resetPrecision: precision)
      ], fetchedAt: fixedNow)
  }
  let events = NotificationPlanner.events(
    previous: snapshot(percent: 95), current: snapshot(percent: 100), previousAvailability: .current,
    currentAvailability: .current, provider: provider, settings: NotificationSettings(notifyOnPace: false),
    now: fixedNow)
  let event = try #require(events.first { $0.kind == .threshold })
  #expect(event.body.contains("Resets in 1 hr 0 min") == (precision == .instant))
  #expect(event.body.contains(Format.resetClock(reset, precision: precision, now: fixedNow)))
}

@Test func dayPrecisionNoticeDoesNotInventAnExactResetTime() throws {
  let notice = Notice(kind: .limitReached, text: "Monthly limit reached; resets Sep 10.", windowID: "monthly")
  let card = UsagePresenter.card(
    provider: .copilot,
    state: ProviderState(
      snapshot: ProviderSnapshot(
        provider: .copilot,
        windows: [
          QuotaWindow(
            id: "monthly", label: "Monthly", group: .monthly, usedPercent: 90,
            resetsAt: fixedNow.addingTimeInterval(86400), resetPrecision: .day)
        ], notices: [notice], fetchedAt: fixedNow), availability: .current), samples: [:], now: fixedNow)
  #expect(try #require(card.notices.first).text(at: fixedNow) == notice.text)
}
