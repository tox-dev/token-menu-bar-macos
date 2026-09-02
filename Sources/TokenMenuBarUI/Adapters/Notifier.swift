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
  // Threshold events are dropped once their window resets, but authentication and credit ones have no such trigger,
  // and a denied permission prompt means nothing ever drains `pending`. Both are capped so neither grows for the
  // lifetime of the process.
  static let historyLimit = 50
  private(set) var delivered: [NotificationEvent] = []
  private(set) var pending: [NotificationEvent] = []

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
    let queued = pending
    pending = []
    guard authorized, !queued.isEmpty else { return }
    log.logDebug("flushing \(queued.count) notifications held during authorization")
    await deliver(queued)
  }

  public func deliver(_ events: [NotificationEvent]) async {
    guard let center else { return }
    guard authorized else {
      // The refresh loop starts before the permission prompt is answered; holding the events means the first
      // threshold crossing still arrives once the user allows notifications.
      pending = (pending + events).suffix(Self.historyLimit)
      return
    }
    delivered = (delivered + events).suffix(Self.historyLimit)
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
    let reset = Set(events.filter { $0.kind == .reset }.compactMap(\.window))
    if !reset.isEmpty {
      let stale = Set(delivered.filter { $0.kind == .threshold && $0.window.map(reset.contains) == true }.map(\.id))
      center.removeDeliveredNotifications(withIdentifiers: Array(stale))
      delivered.removeAll { stale.contains($0.id) }
    }
  }
}
