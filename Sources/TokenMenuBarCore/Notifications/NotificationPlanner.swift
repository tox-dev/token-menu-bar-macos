import Foundation

public struct NotificationSettings: Sendable, Equatable, Codable {
  public static let defaultThresholds = [75, 90, 100]

  public var enabled: Bool
  public var thresholds: [Int]
  public var notifyOnReset: Bool
  public var notifyOnAuthProblems: Bool
  public var notifyOnExpiringCredits: Bool
  public var notifyOnPace: Bool
  public var playSound: Bool

  public init(
    enabled: Bool = true, thresholds: [Int] = defaultThresholds, notifyOnReset: Bool = true,
    notifyOnAuthProblems: Bool = true, notifyOnExpiringCredits: Bool = true, notifyOnPace: Bool = true,
    playSound: Bool = true
  ) {
    self.enabled = enabled
    self.thresholds = thresholds.filter { (1...100).contains($0) }.sorted()
    self.notifyOnReset = notifyOnReset
    self.notifyOnAuthProblems = notifyOnAuthProblems
    self.notifyOnExpiringCredits = notifyOnExpiringCredits
    self.notifyOnPace = notifyOnPace
    self.playSound = playSound
  }

  // Settings saved before these switches existed would otherwise fail to decode and fall back to the defaults.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decode(Bool.self, forKey: .enabled),
      thresholds: try container.decode([Int].self, forKey: .thresholds),
      notifyOnReset: try container.decode(Bool.self, forKey: .notifyOnReset),
      notifyOnAuthProblems: try container.decode(Bool.self, forKey: .notifyOnAuthProblems),
      notifyOnExpiringCredits: try container.decodeIfPresent(Bool.self, forKey: .notifyOnExpiringCredits) ?? true,
      notifyOnPace: try container.decodeIfPresent(Bool.self, forKey: .notifyOnPace) ?? true,
      playSound: try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? true)
  }
}

public struct NotificationEvent: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable {
    case threshold
    case reset
    case authentication
    case credits
    case expiringCredit
    case willRunOut
    case aheadOfPace
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
  public static let creditExpiryWarning: TimeInterval = 24 * 3600

  public static func events(
    previous: ProviderSnapshot?,
    current: ProviderSnapshot?,
    previousAvailability: QuotaAvailability,
    currentAvailability: QuotaAvailability,
    provider: ProviderID,
    settings: NotificationSettings,
    credentialMissing: Bool = false,
    workdays: Int = PaceEstimate.workdayRange.upperBound,
    samples: [WindowKey: [UsageSample]] = [:],
    now: Date
  ) -> [NotificationEvent] {
    guard settings.enabled else { return [] }
    var events: [NotificationEvent] = []
    if settings.notifyOnAuthProblems, !credentialMissing, previousAvailability != currentAvailability {
      if currentAvailability == .authenticationRequired {
        events.append(
          NotificationEvent(
            id: "\(provider.rawValue):auth", kind: .authentication,
            provider: provider, title: "\(provider.displayName) sign-in needed", body: provider.loginHint))
      }
    }
    guard let current else { return events }
    if let previous {
      events += thresholdEvents(previous: previous, current: current, settings: settings)
      if settings.notifyOnReset { events += resetEvents(previous: previous, current: current, settings: settings) }
      if settings.notifyOnPace {
        events += paceEvents(previous: previous, current: current, workdays: workdays, samples: samples, now: now)
      }
      if previous.credits?.hasCredits == true, current.credits?.hasCredits == false {
        events.append(
          NotificationEvent(
            id: "\(provider.rawValue):credits", kind: .credits, provider: provider,
            title: "\(provider.displayName) credits depleted", body: "Usage credits ran out; plan limits now apply."))
      }
    }
    if settings.notifyOnExpiringCredits {
      events += expiringCreditEvents(previous: previous, current: current, now: now)
    }
    return events
  }

  static func thresholdEvents(
    previous: ProviderSnapshot, current: ProviderSnapshot, settings: NotificationSettings
  ) -> [NotificationEvent] {
    let crossings = current.windows.compactMap { window -> (window: QuotaWindow, threshold: Int)? in
      guard let before = previous.window(window.id), !window.hasReset(since: before) else { return nil }
      let crossed = settings.thresholds.filter { before.usedPercent < Double($0) && window.usedPercent >= Double($0) }
      return crossed.max().map { (window, $0) }
    }
    guard crossings.count > 1, let lowest = crossings.map(\.threshold).min() else {
      return crossings.map { thresholdEvent(for: $0.window, threshold: $0.threshold, in: current) }
    }
    let windowIDs = crossings.map(\.window.id).joined(separator: "+")
    let epochs = crossings.map { String(Int($0.window.resetsAt?.timeIntervalSince1970 ?? 0)) }.joined(separator: "+")
    return [
      NotificationEvent(
        id: "\(current.provider.rawValue):thresholds:\(windowIDs):\(lowest):\(epochs)",
        kind: .threshold,
        provider: current.provider,
        title: "\(current.provider.displayName): \(crossings.count) limits crossed \(lowest)%",
        body: crossings.map { "\($0.window.label) at \(Format.percent($0.window.usedPercent))" }
          .joined(separator: ", ") + "."
      )
    ]
  }

  private static func thresholdEvent(
    for window: QuotaWindow, threshold: Int, in current: ProviderSnapshot
  ) -> NotificationEvent {
    let resets =
      window.resetsAt.map {
        threshold >= 100 && window.resetPrecision == .instant
          ? " \(UsageDeadline.reset($0).text(at: current.fetchedAt))."
          : " Resets \(Format.resetClock($0, precision: window.resetPrecision, now: current.fetchedAt))."
      } ?? ""
    return NotificationEvent(
      id: "\(current.provider.rawValue):\(window.id):\(threshold):\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))",
      kind: .threshold,
      provider: current.provider,
      window: WindowKey(current.provider, window),
      title: "\(current.provider.displayName) \(window.label) at \(Format.percent(window.usedPercent))",
      body: threshold >= 100
        ? "Limit reached.\(resets)" : "Crossed \(threshold)% of the \(window.label.lowercased()) limit.\(resets)"
    )
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

  static func paceEvents(
    previous: ProviderSnapshot, current: ProviderSnapshot, workdays: Int, samples: [WindowKey: [UsageSample]], now: Date
  ) -> [NotificationEvent] {
    current.windows.flatMap { window -> [NotificationEvent] in
      guard let before = previous.window(window.id), let resetsAt = window.resetsAt else { return [] }
      let key = WindowKey(current.provider, window)
      let samples = samples[key] ?? []
      let pace = PaceEstimate.estimate(window: window, samples: samples, workdays: workdays, now: now)
      let earlier =
        window.hasReset(since: before)
        ? nil : PaceEstimate.estimate(window: before, samples: samples, workdays: workdays, now: previous.fetchedAt)
      let epoch = Int(resetsAt.timeIntervalSince1970)
      let name = "\(current.provider.displayName) \(window.label)"
      var events: [NotificationEvent] = []
      if let projected = runsOut(pace), earlier.flatMap(runsOut) == nil {
        events.append(
          NotificationEvent(
            id: "\(current.provider.rawValue):\(window.id):pace-runout:\(epoch)", kind: .willRunOut,
            provider: current.provider, window: key,
            title: "\(name) will run out in \(remaining(until: projected, now: now))",
            body: "At this pace it hits 100% before the reset in \(remaining(until: resetsAt, now: now))."))
      }
      if pace.status == .ahead, earlier?.status != .ahead {
        events.append(
          NotificationEvent(
            id: "\(current.provider.rawValue):\(window.id):pace-ahead:\(epoch)", kind: .aheadOfPace,
            provider: current.provider, window: key,
            title: "\(name) is ahead of pace",
            body: "\(Format.percent(window.usedPercent)) used with \(Format.countdown(to: resetsAt, now: now)) left."))
      }
      return events
    }
  }

  /// The projection is meaningful only once the window is past its learning phase and not already exhausted.
  private static func runsOut(_ pace: PaceEstimate) -> Date? {
    switch pace.status {
    case .unknown, .exhausted: nil
    case .onTrack, .ahead, .behind: pace.projectedExhaustion
    }
  }

  static func expiringCreditEvents(
    previous: ProviderSnapshot?, current: ProviderSnapshot, now: Date
  ) -> [NotificationEvent] {
    let warned = Set(previous.map { expiringCredits($0, at: $0.fetchedAt) } ?? [])
    return expiringCredits(current, at: now).filter { !warned.contains($0) }.map { credit in
      let expiresIn = remaining(until: credit.expiresAt, now: now)
      return NotificationEvent(
        id: "\(current.provider.rawValue):reset-credit:\(credit.id):\(Int(credit.expiresAt.timeIntervalSince1970))",
        kind: .expiringCredit,
        provider: current.provider,
        title: "\(current.provider.displayName) reset credit expires in \(expiresIn)",
        body: "Use it before it lapses."
      )
    }
  }

  private static func expiringCredits(_ snapshot: ProviderSnapshot, at now: Date) -> [ResetCreditExpiry] {
    guard let credits = snapshot.resetCredits else { return [] }
    return credits.expiries.filter { $0.expiresAt > now && $0.expiresAt.timeIntervalSince(now) <= creditExpiryWarning }
  }

  private static func remaining(until date: Date, now: Date) -> String {
    let seconds = date.timeIntervalSince(now)
    if seconds >= 86400 { return "\(Int(seconds / 86400)) d" }
    return seconds >= 3600 ? "\(Int(seconds / 3600)) h" : "\(max(Int(seconds / 60), 1)) min"
  }
}
