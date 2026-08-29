import Foundation
import ServiceManagement
import Testing
import TokenMenuBarCore
import UserNotifications

@testable import TokenMenuBarUI

private func event(_ kind: NotificationEvent.Kind, id: String = UUID().uuidString) -> NotificationEvent {
  NotificationEvent(id: id, kind: kind, provider: .claude, title: "t", body: "b")
}

@Test @MainActor func notifierDeliversWhenAuthorized() async {
  let center = FakeNotificationCenter()
  let notifier = Notifier(center: center, log: makeLog())
  await notifier.deliver([event(.credits)])
  #expect(center.requests.isEmpty)
  await notifier.requestAuthorization()
  #expect(notifier.authorized)
  await notifier.deliver([event(.threshold, id: "a"), event(.threshold, id: "b")])
  #expect(center.requests.map(\.identifier) == ["a", "b"])
  #expect(center.requests[0].content.threadIdentifier == "claude")
  await notifier.deliver([event(.reset, id: "r")])
  #expect(Set(center.removed) == ["a", "b"])
  #expect(notifier.delivered.map(\.kind) == [.credits, .reset])
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

@Test func launchAtLoginServiceMapsStatuses() {
  #expect(LaunchAtLoginService.status(.enabled) == .enabled)
  #expect(LaunchAtLoginService.status(.notRegistered) == .notRegistered)
  #expect(LaunchAtLoginService.status(.notFound) == .notFound)
  #expect(LaunchAtLoginService.status(.requiresApproval) == .requiresApproval)
  let backend = LaunchAtLoginService.backend()
  #expect([.notRegistered, .notFound, .enabled, .requiresApproval].contains(backend.status()))
  _ = backend.setEnabled(false)
  #expect([.notRegistered, .notFound, .enabled, .requiresApproval].contains(backend.status()))
}

@Test func realNotificationCenterConforms() {
  #expect((UNUserNotificationCenter.self as Any) is any NotificationCenterProtocol.Type)
}
