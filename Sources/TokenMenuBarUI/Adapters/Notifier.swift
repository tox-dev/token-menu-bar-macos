import Foundation
import TokenMenuBarCore
import UserNotifications

public protocol NotificationCenterProtocol: AnyObject, Sendable {
  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func add(_ request: UNNotificationRequest) async throws
  func removeDeliveredNotifications(withIdentifiers identifiers: [String])
  var delegate: (any UNUserNotificationCenterDelegate)? { get set }
}

extension UNUserNotificationCenter: @retroactive @unchecked Sendable {}
extension UNUserNotificationCenter: NotificationCenterProtocol {}

@MainActor
public final class Notifier {
  private let center: (any NotificationCenterProtocol)?
  private let log: LogBuffer
  private let responseDelegate = NotificationResponseDelegate()
  private(set) var authorized = false
  public var playSound = true
  // Threshold events are dropped once their window resets, but authentication and credit ones have no such trigger,
  // and a denied permission prompt means nothing ever drains `pending`. Both are capped so neither grows for the
  // lifetime of the process.
  static let historyLimit = 50
  private(set) var delivered: [NotificationEvent] = []
  private(set) var pending: [NotificationEvent] = []

  public init(center: (any NotificationCenterProtocol)?, log: LogBuffer) {
    self.center = center
    self.log = log
    center?.delegate = responseDelegate
  }

  public var onResponse: (() -> Void)? {
    didSet { responseDelegate.onResponse = onResponse }
  }

  public func requestAuthorization(provisional: Bool = false) async {
    guard let center else { return }
    do {
      let options: UNAuthorizationOptions = provisional ? [.alert, .sound, .provisional] : [.alert, .sound]
      authorized = try await center.requestAuthorization(options: options)
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
      content.sound = playSound ? .default : nil
      do {
        try await center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
      } catch {
        log.logError("notification delivery failed: \(error.localizedDescription)")
      }
    }
    let reset = Set(events.filter { $0.kind == .reset }.compactMap(\.window))
    if !reset.isEmpty {
      // A grouped banner names several windows of one provider and has no window of its own; once any of them resets
      // it is out of date.
      let providers = Set(reset.map(\.provider))
      let stale = Set(
        delivered.filter {
          $0.kind == .threshold && ($0.window.map(reset.contains) ?? providers.contains($0.provider))
        }.map(\.id))
      center.removeDeliveredNotifications(withIdentifiers: Array(stale))
      delivered.removeAll { stale.contains($0.id) }
    }
  }
}
