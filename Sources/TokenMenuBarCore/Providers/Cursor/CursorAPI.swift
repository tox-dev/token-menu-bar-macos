import Foundation

public enum CursorAPI {
  public static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
  public static let meURL = URL(string: "https://cursor.com/api/auth/me")!
  public static let periodUsageURL = URL(
    string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

  public static func cookieHeaders(_ auth: CursorAuth) -> [String: String] {
    ["Cookie": auth.sessionCookie, "Origin": "https://cursor.com", "User-Agent": "token-menu-bar"]
  }

  public static func bearerHeaders(_ auth: CursorAuth) -> [String: String] {
    ["Authorization": "Bearer \(auth.accessToken)", "Connect-Protocol-Version": "1", "User-Agent": "token-menu-bar"]
  }

  public struct Bucket: Decodable, Sendable, Equatable {
    public let enabled: Bool?
    public let used: Double?
    public let limit: Double?
    public let remaining: Double?
    public let autoPercentUsed: Double?
    public let apiPercentUsed: Double?
    public let totalPercentUsed: Double?

    public var percentUsed: Double? {
      if let totalPercentUsed { return totalPercentUsed }
      switch (autoPercentUsed, apiPercentUsed) {
      case (let auto?, let api?): return (auto + api) / 2
      case (let auto?, nil): return auto
      case (nil, let api?): return api
      default: break
      }
      guard let used, let limit, limit > 0 else { return nil }
      return used / limit * 100
    }
  }

  public struct IndividualUsage: Decodable, Sendable, Equatable {
    public let plan: Bucket?
    public let onDemand: Bucket?
    public let overall: Bucket?
  }

  public struct TeamUsage: Decodable, Sendable, Equatable {
    public let onDemand: Bucket?
    public let pooled: Bucket?
  }

  public struct UsageSummary: Decodable, Sendable, Equatable {
    public let billingCycleStart: String?
    public let billingCycleEnd: String?
    public let membershipType: String?
    public let isUnlimited: Bool?
    public let individualUsage: IndividualUsage?
    public let teamUsage: TeamUsage?
  }

  public struct PeriodUsage: Decodable, Sendable, Equatable {
    public let billingCycleStart: String?
    public let billingCycleEnd: String?
    public let planUsage: Bucket?
    public let displayMessage: String?

    public var summary: UsageSummary {
      UsageSummary(
        billingCycleStart: billingCycleStart, billingCycleEnd: billingCycleEnd, membershipType: nil, isUnlimited: nil,
        individualUsage: IndividualUsage(plan: planUsage, onDemand: nil, overall: nil), teamUsage: nil)
    }
  }

  public struct Me: Decodable, Sendable, Equatable {
    public let email: String?
    public let name: String?
    public let sub: String?
  }
}

public enum CursorMapper {
  public static func windows(_ summary: CursorAPI.UsageSummary) -> [QuotaWindow] {
    let resetsAt = ISODate.parse(summary.billingCycleEnd)
    let start = ISODate.parse(summary.billingCycleStart)
    let duration = start.flatMap { start in resetsAt.map { $0.timeIntervalSince(start) } }
    var windows: [QuotaWindow] = []
    func add(_ id: String, _ label: String, _ bucket: CursorAPI.Bucket?) {
      guard let bucket, bucket.enabled != false, let percent = bucket.percentUsed else { return }
      windows.append(
        QuotaWindow(id: id, label: label, group: .monthly, usedPercent: percent, resetsAt: resetsAt, duration: duration)
      )
    }
    add("plan", "Plan usage", summary.individualUsage?.plan)
    if summary.individualUsage?.onDemand?.limit ?? 0 > 0 {
      add("on_demand", "On-demand", summary.individualUsage?.onDemand)
    }
    add("overall", "Overall", summary.individualUsage?.overall)
    add("team_pool", "Team pool", summary.teamUsage?.pooled)
    return windows
  }

  public static func spend(_ summary: CursorAPI.UsageSummary) -> SpendControl? {
    guard let onDemand = summary.individualUsage?.onDemand, onDemand.enabled != false else { return nil }
    return SpendControl(
      enabled: true,
      used: onDemand.used.map { Money(amountMinor: Int($0.rounded()), currency: "USD") },
      limit: onDemand.limit.map { Money(amountMinor: Int($0.rounded()), currency: "USD") },
      percent: onDemand.limit.flatMap { limit in onDemand.used.map { limit > 0 ? $0 / limit * 100 : 0 } },
      resetsAt: ISODate.parse(summary.billingCycleEnd),
      limitReached: (onDemand.remaining ?? 1) <= 0 && (onDemand.limit ?? 0) > 0)
  }

  public static func identity(
    _ summary: CursorAPI.UsageSummary, auth: CursorAuth, me: CursorAPI.Me?
  )
    -> ProviderIdentity
  {
    let plan = summary.membershipType ?? auth.membershipType ?? "Cursor"
    return ProviderIdentity(planName: Format.humanize(plan), email: me?.email ?? auth.email)
  }

  public static func notices(_ summary: CursorAPI.UsageSummary, period: CursorAPI.PeriodUsage?) -> [Notice] {
    var notices: [Notice] = []
    if summary.isUnlimited == true { notices.append(Notice(kind: .info, text: "This plan has unlimited usage.")) }
    if let message = period?.displayMessage, !message.isEmpty { notices.append(Notice(kind: .info, text: message)) }
    return notices
  }
}
