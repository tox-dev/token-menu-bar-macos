import Foundation

public struct NotificationSettings: Sendable, Equatable, Codable {
  public static let defaultThresholds = [75, 90, 100]

  public var enabled: Bool
  public var thresholds: [Int]
  public var notifyOnReset: Bool
  public var notifyOnAuthProblems: Bool

  public init(
    enabled: Bool = true, thresholds: [Int] = defaultThresholds, notifyOnReset: Bool = true,
    notifyOnAuthProblems: Bool = true
  ) {
    self.enabled = enabled
    self.thresholds = thresholds.filter { (1...100).contains($0) }.sorted()
    self.notifyOnReset = notifyOnReset
    self.notifyOnAuthProblems = notifyOnAuthProblems
  }
}

public struct NotificationEvent: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable {
    case threshold
    case reset
    case authentication
    case credits
  }

  public let id: String
  public let kind: Kind
  public let provider: ProviderID
  public let window: WindowKey?
  public let title: String
  public let body: String

  public init(
    id: String, kind: Kind, provider: ProviderID, window: WindowKey? = nil, title: String, body: String
  ) {
    self.id = id
    self.kind = kind
    self.provider = provider
    self.window = window
    self.title = title
    self.body = body
  }
}

public enum NotificationPlanner {
  public static func events(
    previous: ProviderSnapshot?,
    current: ProviderSnapshot?,
    previousAvailability: QuotaAvailability,
    currentAvailability: QuotaAvailability,
    provider: ProviderID,
    settings: NotificationSettings,
    credentialMissing: Bool = false,
    now: Date
  ) -> [NotificationEvent] {
    guard settings.enabled else { return [] }
    var events: [NotificationEvent] = []
    if settings.notifyOnAuthProblems, !credentialMissing, previousAvailability != currentAvailability {
      if currentAvailability == .authenticationRequired {
        events.append(
          NotificationEvent(
            id: "\(provider.rawValue):auth:\(Int(now.timeIntervalSince1970))", kind: .authentication,
            provider: provider, title: "\(provider.displayName) sign-in needed", body: provider.loginHint))
      }
    }
    guard let current else { return events }
    if let previous {
      events += thresholdEvents(previous: previous, current: current, settings: settings)
      if settings.notifyOnReset { events += resetEvents(previous: previous, current: current, settings: settings) }
      if previous.credits?.hasCredits == true, current.credits?.hasCredits == false {
        events.append(
          NotificationEvent(
            id: "\(provider.rawValue):credits:\(Int(now.timeIntervalSince1970))", kind: .credits, provider: provider,
            title: "\(provider.displayName) credits depleted", body: "Usage credits ran out; plan limits now apply."))
      }
    }
    return events
  }

  static func thresholdEvents(
    previous: ProviderSnapshot, current: ProviderSnapshot, settings: NotificationSettings
  ) -> [NotificationEvent] {
    current.windows.flatMap { window -> [NotificationEvent] in
      guard let before = previous.window(window.id), !window.hasReset(since: before) else { return [] }
      let crossed = settings.thresholds.filter { before.usedPercent < Double($0) && window.usedPercent >= Double($0) }
      guard let highest = crossed.max() else { return [] }
      let resets = window.resetsAt.map { " Resets \(Format.resetClock($0, now: current.fetchedAt))." } ?? ""
      return [
        NotificationEvent(
          id:
            "\(current.provider.rawValue):\(window.id):\(highest):\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))",
          kind: .threshold,
          provider: current.provider,
          window: WindowKey(current.provider, window),
          title: "\(current.provider.displayName) \(window.label) at \(Format.percent(window.usedPercent))",
          body: highest >= 100
            ? "Limit reached.\(resets)" : "Crossed \(highest)% of the \(window.label.lowercased()) limit.\(resets)"
        )
      ]
    }
  }

  static func resetEvents(
    previous: ProviderSnapshot, current: ProviderSnapshot, settings: NotificationSettings
  ) -> [NotificationEvent] {
    let floor = Double(settings.thresholds.first ?? 75)
    return current.windows.compactMap { window in
      guard let before = previous.window(window.id), window.hasReset(since: before), before.usedPercent >= floor else {
        return nil
      }
      return NotificationEvent(
        id: "\(current.provider.rawValue):\(window.id):reset:\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))",
        kind: .reset,
        provider: current.provider,
        window: WindowKey(current.provider, window),
        title: "\(current.provider.displayName) \(window.label) reset",
        body: "Usage is back to \(Format.percent(window.usedPercent))."
      )
    }
  }
}
