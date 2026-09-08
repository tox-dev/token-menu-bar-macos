import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

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
  to: QuotaAvailability = .current, settings: NotificationSettings = NotificationSettings(enabled: true)
) -> [NotificationEvent] {
  NotificationPlanner.events(
    previous: previous, current: current, previousAvailability: from, currentAvailability: to, provider: .claude,
    settings: settings, now: fixedNow)
}

@Test func plannerReportsHighestCrossedThreshold() {
  let events = plan(snapshot(70), snapshot(92))
  #expect(events.map(\.kind) == [.threshold, .willRunOut])
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
  #expect(auth[0].id == "claude:auth")
  #expect(plan(snapshot(10), snapshot(10), from: .authenticationRequired, to: .current).isEmpty)
  #expect(plan(nil, nil, from: .current, to: .authenticationRequired).count == 1)
  #expect(
    plan(
      nil, nil, from: .current, to: .authenticationRequired, settings: NotificationSettings(notifyOnAuthProblems: false)
    ).isEmpty)
  let credits = plan(snapshot(10, credits: true), snapshot(10, credits: false))
  #expect(credits.map(\.kind) == [.credits])
  #expect(credits[0].id == "claude:credits")
  #expect(plan(snapshot(10, credits: false), snapshot(10, credits: true)).isEmpty)
}

@Test func unknownCreditAvailabilityNeverSendsADepletionAlert() {
  let previous = ProviderSnapshot(
    provider: .codex, windows: [], credits: CreditBalance(balance: 4), fetchedAt: fixedNow)
  let current = ProviderSnapshot(
    provider: .codex, windows: [], credits: CreditBalance(balance: nil), fetchedAt: fixedNow)
  let events = NotificationPlanner.events(
    previous: previous, current: current, previousAvailability: .current,
    currentAvailability: .current, provider: .codex, settings: NotificationSettings(), now: fixedNow)
  #expect(!events.contains { $0.kind == .credits })
}

@Test func notificationSettingsSanitizeThresholds() {
  let settings = NotificationSettings(thresholds: [150, 90, 0, 50])
  #expect(settings.enabled)
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

private func codexSnapshot(expiries: [ResetCreditExpiry]?, fetchedAt: Date = fixedNow) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: .codex, windows: [],
    resetCredits: expiries.map { ResetCredits(available: 1, applicable: 1, expiries: $0) }, fetchedAt: fetchedAt)
}

private func planCodex(
  _ previous: ProviderSnapshot?, _ current: ProviderSnapshot, settings: NotificationSettings = NotificationSettings(),
  now: Date = fixedNow
) -> [NotificationEvent] {
  NotificationPlanner.events(
    previous: previous, current: current, previousAvailability: .current, currentAvailability: .current,
    provider: .codex, settings: settings, now: now)
}

@Test func plannerWarnsOnceAboutAResetCreditExpiringWithinADay() {
  let credit = ResetCreditExpiry(id: "c1", expiresAt: fixedNow.addingTimeInterval(5 * 3600))
  let current = codexSnapshot(expiries: [credit])
  let events = planCodex(nil, current)
  #expect(events.count == 1)
  #expect(events[0].kind == .expiringCredit)
  #expect(events[0].id == "codex:reset-credit:c1:\(Int(credit.expiresAt.timeIntervalSince1970))")
  #expect(events[0].title == "Codex reset credit expires in 5 h")
  #expect(events[0].body == "Use it before it lapses.")
  #expect(events[0].window == nil)
  let later = fixedNow.addingTimeInterval(60)
  #expect(planCodex(current, codexSnapshot(expiries: [credit], fetchedAt: later), now: later).isEmpty)
}

@Test func plannerWarnsWhenAResetCreditEntersTheDayWindow() {
  let credit = ResetCreditExpiry(id: "c1", expiresAt: fixedNow.addingTimeInterval(23 * 3600))
  let earlier = codexSnapshot(expiries: [credit], fetchedAt: fixedNow.addingTimeInterval(-2 * 3600))
  #expect(planCodex(nil, earlier, now: earlier.fetchedAt).isEmpty)
  #expect(planCodex(earlier, codexSnapshot(expiries: [credit])).map(\.kind) == [.expiringCredit])
}

@Test(
  arguments: [
    ("disabled", NotificationSettings(notifyOnExpiringCredits: false), 5 * 3600.0),
    ("beyond a day", NotificationSettings(), 25 * 3600.0),
    ("already expired", NotificationSettings(), -60.0),
  ])
func plannerStaysQuietAboutResetCredits(name: String, settings: NotificationSettings, offset: TimeInterval) {
  let credit = ResetCreditExpiry(id: "c1", expiresAt: fixedNow.addingTimeInterval(offset))
  #expect(planCodex(nil, codexSnapshot(expiries: [credit]), settings: settings).isEmpty, Comment(rawValue: name))
}

@Test func plannerIgnoresSnapshotsWithoutResetCredits() {
  #expect(planCodex(codexSnapshot(expiries: nil), codexSnapshot(expiries: nil)).isEmpty)
}

private let expiryWordings: [(TimeInterval, String)] = [
  (45 * 60, "45 min"), (30, "1 min"), (23 * 3600 + 59 * 60, "23 h"),
]

@Test(arguments: expiryWordings)
func plannerFormatsTheTimeUntilACreditExpires(offset: TimeInterval, expected: String) {
  let credit = ResetCreditExpiry(id: "c1", expiresAt: fixedNow.addingTimeInterval(offset))
  #expect(planCodex(nil, codexSnapshot(expiries: [credit]))[0].title == "Codex reset credit expires in \(expected)")
}

@Test func plannerGroupsSeveralThresholdCrossingsIntoOneNotice() {
  let before = QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 60, resetsAt: nil)
  let after = QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 78, resetsAt: nil)
  let events = plan(snapshot(70, extra: [before]), snapshot(92, extra: [after]))
  #expect(events.map(\.kind) == [.threshold, .willRunOut])
  #expect(events[0].window == nil)
  #expect(events[0].title == "Claude: 2 limits crossed 75%")
  #expect(events[0].body == "Current session at 92%, Weekly at 78%.")
  let epoch = Int(fixedNow.addingTimeInterval(3600).timeIntervalSince1970)
  #expect(events[0].id == "claude:thresholds:session+weekly:75:\(epoch)+0")
}

@Test func notificationSettingsDecodeWithoutTheNewerSwitches() throws {
  let legacy = #"{"enabled":true,"thresholds":[90],"notifyOnReset":false,"notifyOnAuthProblems":true}"#
  let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(legacy.utf8))
  #expect(decoded == NotificationSettings(thresholds: [90], notifyOnReset: false))
  let full = NotificationSettings(notifyOnExpiringCredits: false, playSound: false)
  #expect(try JSONDecoder().decode(NotificationSettings.self, from: JSONEncoder().encode(full)) == full)
}
