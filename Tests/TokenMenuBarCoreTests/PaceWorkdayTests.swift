import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

private let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

private func date(_ month: Int, _ day: Int, hour: Int = 0) -> Date {
  utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private func window(used: Double, start: Date, duration: TimeInterval = 7 * 86400) -> QuotaWindow {
  QuotaWindow(
    id: "weekly", label: "Weekly", group: .weekly, usedPercent: used, resetsAt: start.addingTimeInterval(duration),
    duration: duration)
}

private let saturdayStart = date(8, 29)
private let mondayMorning = date(8, 31, hour: 9)

private let workdayCases: [(workdays: Int, expected: Double, status: PaceStatus)] = [
  (7, 57.0 / 168 * 100, .onTrack),
  (6, 33.0 / 144 * 100, .ahead),
  (5, 9.0 / 120 * 100, .ahead),
  (4, 9.0 / 96 * 100, .ahead),
]

@Test(arguments: workdayCases)
func paceExpectsUsageOnlyOnWorkdays(workdays: Int, expected: Double, status: PaceStatus) {
  let estimate = PaceEstimate.estimate(
    window: window(used: 30, start: saturdayStart), workdays: workdays, calendar: utc, now: mondayMorning)
  #expect(estimate.expectedPercent.map { abs($0 - expected) < 0.0001 } == true)
  #expect(estimate.status == status)
}

@Test func paceWorkdaysLeaveWindowsOfADayOrLessLinear() {
  let session = window(used: 30, start: date(8, 30, hour: 20), duration: 18000)
  let estimate = PaceEstimate.estimate(
    window: session, workdays: 5, calendar: utc, now: date(8, 30, hour: 22, minute: 30))
  #expect(estimate.expectedPercent == 50)
}

private func date(_ month: Int, _ day: Int, hour: Int, minute: Int) -> Date {
  utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

@Test func paceWorkdaysFallBackToLinearWhenAWindowHasNoWorkday() {
  let weekend = window(used: 30, start: saturdayStart, duration: 2 * 86400)
  let estimate = PaceEstimate.estimate(
    window: weekend, workdays: 5, calendar: utc, now: date(8, 30, hour: 12))
  #expect(estimate.expectedPercent == 75)
}

@Test func paceWorkdaysCountElapsedTimeOnlyUpToTheReset() {
  let start = date(8, 24)
  let estimate = PaceEstimate.estimate(
    window: window(used: 60, start: start), workdays: 5, calendar: utc, now: date(8, 28, hour: 12))
  #expect(estimate.expectedPercent.map { abs($0 - 4.5 / 5 * 100) < 0.0001 } == true)
  #expect(estimate.status == .behind)
}

// The presenter counts workdays in the user's calendar, so this checks the wiring rather than a fixed percentage.
@Test func paceWorkdaysApplyToPresentedRowsAndDefaultToEveryDay() {
  let weekly = window(used: 30, start: saturdayStart)
  let state = ProviderState(
    snapshot: ProviderSnapshot(provider: .claude, windows: [weekly], fetchedAt: mondayMorning),
    availability: .current)
  let fiveDays = UsagePresenter.card(
    provider: .claude, state: state, samples: [:], options: UsageDisplayOptions(paceWorkdays: 5), now: mondayMorning)
  let everyDay = UsagePresenter.card(provider: .claude, state: state, samples: [:], now: mondayMorning)
  #expect(fiveDays.rows[0].pace == PaceEstimate.estimate(window: weekly, workdays: 5, now: mondayMorning))
  #expect(everyDay.rows[0].pace == PaceEstimate.estimate(window: weekly, now: mondayMorning))
  #expect(fiveDays.rows[0].pace.expectedPercent != everyDay.rows[0].pace.expectedPercent)
  #expect(UsageDisplayOptions.standard.paceWorkdays == PaceEstimate.workdayRange.upperBound)
}
