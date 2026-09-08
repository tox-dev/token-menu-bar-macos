import Foundation

enum CursorAPI {
  static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
  static let meURL = URL(string: "https://cursor.com/api/auth/me")!
  static let periodUsageURL = URL(
    string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

  static func cookieHeaders(_ auth: CursorAuth) -> [String: String] {
    ["Cookie": auth.sessionCookie, "Origin": "https://cursor.com", "User-Agent": "token-menu-bar"]
  }

  static func bearerHeaders(_ auth: CursorAuth) -> [String: String] {
    ["Authorization": "Bearer \(auth.accessToken)", "Connect-Protocol-Version": "1", "User-Agent": "token-menu-bar"]
  }

  struct Bucket: Decodable, Sendable, Equatable {
    struct Breakdown: Decodable, Sendable, Equatable {
      let included: Double?
      let bonus: Double?
      let total: Double?
    }
    let enabled: Bool?
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
    let breakdown: Breakdown?

    var aggregatePercentUsed: Double? {
      if let totalPercentUsed { return totalPercentUsed }
      guard let used, let limit, limit > 0 else { return nil }
      return used / limit * 100
    }

    var componentPercents: [(id: String, label: String, percent: Double)] {
      var components: [(id: String, label: String, percent: Double)] = []
      if let autoPercentUsed { components.append(("auto", "Auto", autoPercentUsed)) }
      if let apiPercentUsed { components.append(("api", "API", apiPercentUsed)) }
      return components
    }
  }

  struct IndividualUsage: Decodable, Sendable, Equatable {
    let plan: Bucket?
    let onDemand: Bucket?
    let overall: Bucket?
  }

  struct TeamUsage: Decodable, Sendable, Equatable {
    let onDemand: Bucket?
    let pooled: Bucket?
  }

  struct UsageSummary: Decodable, Sendable, Equatable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let isUnlimited: Bool?
    let individualUsage: IndividualUsage?
    let teamUsage: TeamUsage?
    var limitType: String? = nil
    var autoModelSelectedDisplayMessage: String? = nil
    var namedModelSelectedDisplayMessage: String? = nil
  }

  struct PeriodUsage: Decodable, Sendable, Equatable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: Bucket?
    let displayMessage: String?

    var summary: UsageSummary {
      UsageSummary(
        billingCycleStart: billingCycleStart, billingCycleEnd: billingCycleEnd, membershipType: nil, isUnlimited: nil,
        individualUsage: IndividualUsage(plan: planUsage, onDemand: nil, overall: nil), teamUsage: nil)
    }
  }

  struct Me: Decodable, Sendable, Equatable {
    let email: String?
    let name: String?
    let sub: String?
  }
}

enum CursorMapper {
  static func windows(_ summary: CursorAPI.UsageSummary) -> [QuotaWindow] {
    let resetsAt = ISODate.parse(summary.billingCycleEnd)
    let start = ISODate.parse(summary.billingCycleStart)
    let duration = start.flatMap { start in resetsAt.map { $0.timeIntervalSince(start) } }
    var windows: [QuotaWindow] = []
    func add(_ id: String, _ label: String, _ bucket: CursorAPI.Bucket?) {
      guard let bucket, bucket.enabled != false else { return }
      let components = bucket.componentPercents
      if let percent = bucket.aggregatePercentUsed {
        // The provider's aggregate and model-pool allowances can have different denominators.
        let detail =
          components.isEmpty
          ? nil : components.map { "\($0.label) \(Format.percent($0.percent))" }.joined(separator: " · ")
        windows.append(
          QuotaWindow(
            id: id, label: label, group: .monthly, usedPercent: percent, resetsAt: resetsAt, duration: duration,
            detail: detail))
        return
      }
      windows += components.map { component in
        QuotaWindow(
          id: "\(id):\(component.id)", label: "\(label) (\(component.label))", group: .monthly,
          usedPercent: component.percent, resetsAt: resetsAt, duration: duration)
      }
    }
    add("plan", "Plan usage", summary.individualUsage?.plan)
    if summary.individualUsage?.onDemand?.limit ?? 0 > 0 {
      add("on_demand", "On-demand", summary.individualUsage?.onDemand)
    }
    add("overall", "Overall", summary.individualUsage?.overall)
    add("team_pool", "Team pool", summary.teamUsage?.pooled)
    add("team_on_demand", "Team on-demand", summary.teamUsage?.onDemand)
    return windows
  }

  static func spend(_ summary: CursorAPI.UsageSummary) -> SpendControl? {
    guard let onDemand = summary.individualUsage?.onDemand else { return nil }
    return SpendControl(
      enabled: onDemand.enabled,
      used: onDemand.used.map { Money(amountMinor: Int($0.rounded()), currency: "USD") },
      limit: onDemand.limit.map { Money(amountMinor: Int($0.rounded()), currency: "USD") },
      percent: onDemand.limit.flatMap { limit in onDemand.used.map { limit > 0 ? $0 / limit * 100 : 0 } },
      resetsAt: ISODate.parse(summary.billingCycleEnd),
      limitReached: (onDemand.remaining ?? 1) <= 0 && (onDemand.limit ?? 0) > 0)
  }

  static func identity(
    _ summary: CursorAPI.UsageSummary, auth: CursorAuth, me: CursorAPI.Me?
  )
    -> ProviderIdentity
  {
    let plan = summary.membershipType ?? auth.membershipType ?? "Cursor"
    return ProviderIdentity(planName: Format.humanize(plan), email: me?.email ?? auth.email)
  }

  static func notices(_ summary: CursorAPI.UsageSummary, period: CursorAPI.PeriodUsage?) -> [Notice] {
    var notices: [Notice] = []
    if summary.isUnlimited == true { notices.append(Notice(kind: .info, text: "This plan has unlimited usage.")) }
    if let message = period?.displayMessage, !message.isEmpty { notices.append(Notice(kind: .info, text: message)) }
    return notices
  }

  static func details(_ summary: CursorAPI.UsageSummary) -> [ProviderDetail] {
    var details: [ProviderDetail] = []
    for (id, title, bucket) in [
      ("plan", "Included plan", summary.individualUsage?.plan),
      ("on-demand", "Individual on-demand", summary.individualUsage?.onDemand),
      ("overall", "Overall", summary.individualUsage?.overall),
      ("team-on-demand", "Team on-demand", summary.teamUsage?.onDemand),
      ("team-pool", "Team pool", summary.teamUsage?.pooled),
    ] {
      guard let bucket else { continue }
      var values: [String] = []
      if let enabled = bucket.enabled { values.append(enabled ? "On" : "Off") }
      for (name, value) in [
        ("Used", bucket.used), ("Limit", bucket.limit), ("Remaining", bucket.remaining),
        ("Included", bucket.breakdown?.included), ("Bonus", bucket.breakdown?.bonus),
        ("Total", bucket.breakdown?.total),
      ] {
        if let value {
          values.append("\(name): \(Money(amountMinor: Int(value.rounded()), currency: "USD").formatted)")
        }
      }
      guard !values.isEmpty else { continue }
      details.append(
        ProviderDetail(
          id: id, title: title, value: values.joined(separator: " · "),
          explanation: "Provider-reported budget in USD. Individual and team allowances remain separate."))
    }
    for (id, title, value) in [
      ("limit-type", "Limit type", summary.limitType),
      ("auto-pool", "Auto model allowance", summary.autoModelSelectedDisplayMessage),
      ("named-pool", "Named model allowance", summary.namedModelSelectedDisplayMessage),
    ] {
      if let value, !value.isEmpty {
        details.append(
          ProviderDetail(
            id: id, title: title, value: value,
            explanation: "The provider's description of this allowance. Model pools may have different limits."))
      }
    }
    return details
  }
}
