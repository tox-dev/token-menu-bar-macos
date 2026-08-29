import Foundation
import TokenMenuBarCore
import UserNotifications

public protocol NotificationCenterProtocol: AnyObject, Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func add(_ request: UNNotificationRequest) async throws
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: @retroactive @unchecked Sendable {}
extension UNUserNotificationCenter: NotificationCenterProtocol {}

@MainActor
public final class Notifier {
  private let center: (any NotificationCenterProtocol)?
  private let log: LogBuffer
  private(set) var authorized = false
  private(set) var delivered: [NotificationEvent] = []

  public init(center: (any NotificationCenterProtocol)?, log: LogBuffer) {
    self.center = center
    self.log = log
  }

  public func requestAuthorization() async {
    guard let center else { return }
    do {
      authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
      log.logDebug("notifications authorized=\(authorized)")
    } catch {
      log.logError("notification authorization failed: \(error.localizedDescription)")
    }
  }

  public func deliver(_ events: [NotificationEvent]) async {
    delivered += events
    guard let center, authorized else { return }
    for event in events {
      let content = UNMutableNotificationContent()
      content.title = event.title
      content.body = event.body
      content.threadIdentifier = event.provider.rawValue
      content.sound = .default
      do {
        try await center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
      } catch {
        log.logError("notification delivery failed: \(error.localizedDescription)")
      }
    }
    let resets = events.filter { $0.kind == .reset }.map(\.provider)
    if !resets.isEmpty {
      let stale = delivered.filter { $0.kind == .threshold && resets.contains($0.provider) }.map(\.id)
      center.removeDeliveredNotifications(withIdentifiers: stale)
      delivered.removeAll { stale.contains($0.id) }
    }
  }
}
