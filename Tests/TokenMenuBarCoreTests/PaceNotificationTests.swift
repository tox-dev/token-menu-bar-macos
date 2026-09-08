import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

private let sessionResets = fixedNow.addingTimeInterval(9000)

private func snapshot(
  _ percent: Double, at fetchedAt: Date, resetsAt: Date = sessionResets, duration: TimeInterval = 18000,
  id: String = "session", label: String = "Current session"
) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: .claude,
    windows: [
      QuotaWindow(id: id, label: label, group: .session, usedPercent: percent, resetsAt: resetsAt, duration: duration)
    ],
    fetchedAt: fetchedAt)
}

private func plan(
  _ previous: ProviderSnapshot, _ current: ProviderSnapshot, settings: NotificationSettings = NotificationSettings()
) -> [NotificationEvent] {
  NotificationPlanner.events(
    previous: previous, current: current, previousAvailability: .current, currentAvailability: .current,
    provider: .claude, settings: settings, now: current.fetchedAt)
}

private let onPace = snapshot(45, at: fixedNow.addingTimeInterval(-600))
private let ahead = snapshot(70, at: fixedNow)

@Test(arguments: [(45.0, -600.0, 50.0, 45.0, true), (2.0, -7200.0, 70.0, 69.0, false)])
func paceNotificationsUseTheSameRecentSlopeAsUsage(
  previousPercent: Double, previousOffset: Double, percent: Double, recentPercent: Double, runsOut: Bool
) {
  let previous = snapshot(previousPercent, at: fixedNow.addingTimeInterval(previousOffset))
  let current = snapshot(percent, at: fixedNow)
  let key = WindowKey(provider: .claude, windowID: "session")
  let samples = [
    UsageSample(
      timestamp: fixedNow.addingTimeInterval(-600), key: key, usedPercent: recentPercent, resetsAt: sessionResets),
    UsageSample(timestamp: fixedNow, key: key, usedPercent: percent, resetsAt: sessionResets),
  ]
  let events = NotificationPlanner.events(
    previous: previous, current: current, previousAvailability: .current,
    currentAvailability: .current, provider: .claude, settings: NotificationSettings(), samples: [key: samples],
    now: fixedNow)
  #expect(events.contains { $0.kind == .willRunOut } == runsOut)
  #expect(
    (PaceEstimate.estimate(window: current.windows[0], samples: samples, now: fixedNow).projectedExhaustion != nil)
      == runsOut)
}

@Test func paceNoticesFireWhenAWindowFirstRunsAheadAndShort() {
  let events = plan(onPace, ahead)
  #expect(events.map(\.kind) == [.willRunOut, .aheadOfPace])
  let epoch = Int(sessionResets.timeIntervalSince1970)
  #expect(events[0].id == "claude:session:pace-runout:\(epoch)")
  #expect(events[0].title == "Claude Current session will run out in 1 h")
  #expect(events[0].body == "At this pace it hits 100% before the reset in 2 h.")
  #expect(events[1].id == "claude:session:pace-ahead:\(epoch)")
  #expect(events[1].title == "Claude Current session is ahead of pace")
  #expect(events[1].body == "70% used with 2 hr 30 min left.")
  #expect(events.allSatisfy { $0.window == WindowKey(provider: .claude, windowID: "session") })
}

@Test func paceNoticesFireOncePerEpoch() {
  let later = snapshot(72, at: fixedNow.addingTimeInterval(300))
  #expect(plan(ahead, later).isEmpty)
}

@Test func paceNoticesArmAgainAfterARefreshOnPace() {
  let recovered = snapshot(50, at: fixedNow.addingTimeInterval(600))
  #expect(plan(ahead, recovered).isEmpty)
  let aheadAgain = snapshot(74, at: fixedNow.addingTimeInterval(1200))
  #expect(plan(recovered, aheadAgain).map(\.kind) == [.willRunOut, .aheadOfPace])
}

@Test func paceNoticesArmAcrossAReset() {
  let previousEpoch = snapshot(90, at: fixedNow.addingTimeInterval(-600), resetsAt: fixedNow.addingTimeInterval(-100))
  let events = plan(previousEpoch, ahead)
  #expect(events.map(\.kind) == [.reset, .willRunOut, .aheadOfPace])
}

@Test func paceNoticesStaySilentWhenDisabled() {
  #expect(plan(onPace, ahead, settings: NotificationSettings(notifyOnPace: false)).isEmpty)
}

@Test func paceNoticesStaySilentEarlyInAWindow() {
  let resetsAt = fixedNow.addingTimeInterval(17280)
  let idle = snapshot(0, at: fixedNow.addingTimeInterval(-300), resetsAt: resetsAt)
  let burst = snapshot(50, at: fixedNow, resetsAt: resetsAt)
  #expect(PaceEstimate.estimate(window: burst.windows[0], now: fixedNow).projectedExhaustion != nil)
  #expect(plan(idle, burst).isEmpty)
}

@Test func paceNoticesGiveWayToTheLimitReachedThreshold() {
  let events = plan(ahead, snapshot(100, at: fixedNow.addingTimeInterval(300)))
  #expect(events.map(\.kind) == [.threshold])
}

@Test func paceNoticesCountLongerRunwaysInDays() {
  let resetsAt = fixedNow.addingTimeInterval(302_400)
  let steady = snapshot(
    45, at: fixedNow.addingTimeInterval(-3600), resetsAt: resetsAt, duration: 604_800, id: "weekly", label: "Weekly")
  let heavy = snapshot(60, at: fixedNow, resetsAt: resetsAt, duration: 604_800, id: "weekly", label: "Weekly")
  let events = plan(steady, heavy)
  #expect(events.map(\.kind) == [.willRunOut])
  #expect(events[0].title == "Claude Weekly will run out in 2 d")
  #expect(events[0].body == "At this pace it hits 100% before the reset in 3 d.")
}

@Test func paceNoticesNeedAResetTime() {
  let previous = ProviderSnapshot(
    provider: .claude, windows: [QuotaWindow(id: "w", label: "W", group: .other, usedPercent: 10, resetsAt: nil)],
    fetchedAt: fixedNow.addingTimeInterval(-600))
  let current = ProviderSnapshot(
    provider: .claude, windows: [QuotaWindow(id: "w", label: "W", group: .other, usedPercent: 60, resetsAt: nil)],
    fetchedAt: fixedNow)
  #expect(plan(previous, current).isEmpty)
}

@Test func notificationSettingsSavedBeforePaceNoticesDecodeThemOn() throws {
  let json = #"{"enabled":true,"thresholds":[75],"notifyOnReset":true,"notifyOnAuthProblems":false}"#
  let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(json.utf8))
  #expect(decoded.notifyOnPace)
  #expect(!decoded.notifyOnAuthProblems)
  let stored = try JSONEncoder().encode(NotificationSettings(notifyOnPace: false))
  #expect(try JSONDecoder().decode(NotificationSettings.self, from: stored).notifyOnPace == false)
}
