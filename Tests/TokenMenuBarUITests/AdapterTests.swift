import Foundation
import ServiceManagement
import Testing
import UserNotifications

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func notifierDeliversWhenAuthorized() async {
  let center = FakeNotificationCenter()
  let log = makeLog()
  log.debugEnabled = true
  let notifier = Notifier(center: center, log: log)
  let held = event(.credits, id: "held")
  await notifier.deliver([held])
  #expect(center.requests.isEmpty)
  #expect(notifier.pending.count == 1)
  await notifier.requestAuthorization()
  #expect(notifier.authorized)
  #expect(log.text.contains("notifications authorized=true"))
  #expect(log.text.contains("flushing 1 notifications"))
  // the event held during the prompt is delivered once authorization lands
  #expect(center.requests.map(\.identifier) == [held.id])
  #expect(notifier.pending.isEmpty)
  await notifier.deliver([event(.threshold, id: "a"), event(.threshold, id: "b")])
  #expect(center.requests.map(\.identifier).suffix(2) == ["a", "b"])
  #expect(center.requests[0].content.threadIdentifier == "claude")
  let otherWindow = NotificationEvent(
    id: "other", kind: .threshold, provider: .claude, window: WindowKey(provider: .claude, windowID: "weekly"),
    title: "t", body: "b")
  await notifier.deliver([otherWindow])
  await notifier.deliver([event(.reset, id: "r")])
  #expect(Set(center.removed) == ["a", "b"])
  #expect(notifier.delivered.contains { $0.id == "other" })
  #expect(notifier.delivered.map(\.kind) == [.credits, .threshold, .reset])
}

private func event(_ kind: NotificationEvent.Kind, id: String = UUID().uuidString) -> NotificationEvent {
  NotificationEvent(
    id: id, kind: kind, provider: .claude, window: WindowKey(provider: .claude, windowID: "session"), title: "t",
    body: "b")
}

@Test @MainActor func notifierHandlesErrorsAndMissingCenter() async {
  let none = Notifier(center: nil, log: makeLog())
  await none.requestAuthorization()
  await none.deliver([event(.credits)])
  #expect(!none.authorized)
  let failing = FakeNotificationCenter()
  failing.authorizationError = TestError()
  let log = makeLog()
  let notifier = Notifier(center: failing, log: log)
  await notifier.requestAuthorization()
  #expect(!notifier.authorized)
  #expect(log.text.contains("authorization failed"))
  failing.authorizationError = nil
  failing.authorize = false
  await notifier.requestAuthorization()
  #expect(!notifier.authorized)
  failing.authorize = true
  await notifier.requestAuthorization()
  failing.addError = TestError()
  await notifier.deliver([event(.authentication)])
  #expect(log.text.contains("delivery failed"))
}

@Test(
  arguments: [
    (SMAppService.Status.enabled, LaunchAtLoginBackend.Status.enabled), (.notRegistered, .notRegistered),
    (.notFound, .notFound),
    (.requiresApproval, .requiresApproval),
  ])
func launchAtLoginServiceMapsStatuses(status: SMAppService.Status, expected: LaunchAtLoginBackend.Status) {
  #expect(LaunchAtLoginService.status(status) == expected)
}
