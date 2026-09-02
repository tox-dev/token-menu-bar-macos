import Foundation
import Testing
import TokenMenuBarCore

@Test func plannerIsSilentWhenDisabledOrWithoutHistory() {
  #expect(plan(nil, snapshot(99)).isEmpty)
  #expect(plan(snapshot(10), snapshot(99), settings: NotificationSettings(enabled: false)).isEmpty)
  #expect(plan(snapshot(10), nil).isEmpty)
}

private func snapshot(
  _ percent: Double, resets: TimeInterval = 3600, credits: Bool? = nil, extra: [QuotaWindow] = []
) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: .claude,
    windows: [
      QuotaWindow(
        id: "session", label: "Current session", group: .session, usedPercent: percent,
        resetsAt: fixedNow.addingTimeInterval(resets), duration: 18000)
    ] + extra,
    credits: credits.map { CreditBalance(balance: nil, hasCredits: $0) },
    fetchedAt: fixedNow
  )
}

private func plan(
  _ previous: ProviderSnapshot?, _ current: ProviderSnapshot?, from: QuotaAvailability = .current,
  to: QuotaAvailability = .current, settings: NotificationSettings = NotificationSettings()
) -> [NotificationEvent] {
  NotificationPlanner.events(
    previous: previous, current: current, previousAvailability: from, currentAvailability: to, provider: .claude,
    settings: settings, now: fixedNow)
}

@Test func plannerReportsHighestCrossedThreshold() {
  let events = plan(snapshot(70), snapshot(92))
  #expect(events.count == 1)
  #expect(events[0].kind == .threshold)
  #expect(events[0].title == "Claude Current session at 92%")
  #expect(events[0].body.hasPrefix("Crossed 90% of the current session limit."))
  #expect(events[0].body.contains("Resets"))
  #expect(events[0].id.hasPrefix("claude:session:90:"))
  #expect(plan(snapshot(92), snapshot(93)).isEmpty)
  #expect(plan(snapshot(95), snapshot(100))[0].body.hasPrefix("Limit reached."))
}

@Test func plannerSkipsThresholdsAcrossResetAndReportsReset() {
  let events = plan(snapshot(95, resets: 60), snapshot(5, resets: 18060))
  #expect(events.map(\.kind) == [.reset])
  #expect(events[0].title == "Claude Current session reset")
  #expect(events[0].body == "Usage is back to 5%.")
  #expect(plan(snapshot(20, resets: 60), snapshot(5, resets: 18060)).isEmpty)
  #expect(
    plan(snapshot(95, resets: 60), snapshot(5, resets: 18060), settings: NotificationSettings(notifyOnReset: false))
      .isEmpty)
}

@Test func plannerDetectsResetWithoutResetDates() {
  let previous = ProviderSnapshot(
    provider: .claude, windows: [QuotaWindow(id: "w", label: "W", group: .other, usedPercent: 80, resetsAt: nil)],
    fetchedAt: fixedNow)
  let current = ProviderSnapshot(
    provider: .claude, windows: [QuotaWindow(id: "w", label: "W", group: .other, usedPercent: 3, resetsAt: nil)],
    fetchedAt: fixedNow)
  #expect(plan(previous, current).map(\.kind) == [.reset])
  #expect(plan(previous, current)[0].id == "claude:w:reset:0")
}

@Test func plannerIgnoresNewWindowsWithoutPrevious() {
  let extra = QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 99, resetsAt: nil)
  #expect(plan(snapshot(10), snapshot(10, extra: [extra])).isEmpty)
}

@Test func plannerReportsAuthenticationAndCredits() {
  let auth = plan(snapshot(10), snapshot(10), from: .current, to: .authenticationRequired)
  #expect(auth.map(\.kind) == [.authentication])
  #expect(auth[0].title == "Claude sign-in needed")
  #expect(plan(snapshot(10), snapshot(10), from: .authenticationRequired, to: .current).isEmpty)
  #expect(plan(nil, nil, from: .current, to: .authenticationRequired).count == 1)
  #expect(
    plan(
      nil, nil, from: .current, to: .authenticationRequired, settings: NotificationSettings(notifyOnAuthProblems: false)
    ).isEmpty)
  let credits = plan(snapshot(10, credits: true), snapshot(10, credits: false))
  #expect(credits.map(\.kind) == [.credits])
  #expect(plan(snapshot(10, credits: false), snapshot(10, credits: true)).isEmpty)
}

@Test func notificationSettingsSanitizeThresholds() {
  let settings = NotificationSettings(thresholds: [150, 90, 0, 50])
  #expect(settings.thresholds == [50, 90])
  #expect(NotificationSettings().thresholds == [75, 90, 100])
}

@Test func plannerStaysQuietForProvidersThatNeverSignedIn() {
  let settings = NotificationSettings(enabled: true, thresholds: [], notifyOnReset: false, notifyOnAuthProblems: true)
  let events = NotificationPlanner.events(
    previous: nil, current: nil, previousAvailability: .loading, currentAvailability: .authenticationRequired,
    provider: .gemini, settings: settings, credentialMissing: true, now: fixedNow)
  #expect(events.isEmpty)
  let signedOut = NotificationPlanner.events(
    previous: nil, current: nil, previousAvailability: .loading, currentAvailability: .authenticationRequired,
    provider: .gemini, settings: settings, now: fixedNow)
  #expect(signedOut.map(\.kind) == [.authentication])
}
