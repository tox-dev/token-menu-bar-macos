import UserNotifications

@MainActor
final class NotificationResponseDelegate: NSObject, UNUserNotificationCenterDelegate {
  var onResponse: (() -> Void)?

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    await MainActor.run { onResponse?() }
  }
}
