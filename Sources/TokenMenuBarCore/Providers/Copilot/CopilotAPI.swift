import Foundation

enum CopilotAPI {
  static let editorVersion = "vscode/1.96.2"
  static let pluginVersion = "copilot-chat/0.26.7"

  static func userURL(host: String) -> URL {
    if host == "github.com" { return URL(string: "https://api.github.com/copilot_internal/user")! }
    if host.hasSuffix(".ghe.com") {
      let apiHost = host.hasPrefix("api.") ? host : "api.\(host)"
      return URL(string: "https://\(apiHost)/copilot_internal/user")!
    }
    return URL(string: "https://\(host)/api/v3/copilot_internal/user")!
  }

  static func headers(token: String) -> [String: String] {
    [
      "Authorization": "token \(token)", "Editor-Version": editorVersion, "Editor-Plugin-Version": pluginVersion,
      "User-Agent": "GitHubCopilotChat/0.26.7", "X-Github-Api-Version": "2025-04-01",
    ]
  }

  static let snapshotOrder = ["premium_interactions", "chat", "completions"]
}

enum CopilotMapper {
  static func windows(_ user: JSONValue) -> [QuotaWindow] {
    let cycleReset =
      reset(user["quota_reset_date_utc"]?.stringValue)
      ?? reset(user["quota_reset_date"]?.stringValue) ?? reset(user["limited_user_reset_date"]?.stringValue)
    var windows: [QuotaWindow] = []
    if let snapshots = user["quota_snapshots"]?.objectValue {
      let ordered =
        CopilotAPI.snapshotOrder.filter { snapshots[$0] != nil }
        + snapshots.keys.sorted().filter { !CopilotAPI.snapshotOrder.contains($0) }
      for key in ordered {
        guard let snapshot = snapshots[key], let percent = percentUsed(snapshot) else { continue }
        let categoryReset =
          number(snapshot["quota_reset_at"]).map {
            Reset(date: Date(timeIntervalSince1970: $0), precision: .instant)
          } ?? cycleReset
        windows.append(
          QuotaWindow(
            id: key, label: label(key, credits: user["token_based_billing"]?.boolValue == true), group: .monthly,
            usedPercent: percent, resetsAt: categoryReset?.date,
            resetPrecision: categoryReset?.precision ?? .instant))
      }
    }
    if let limited = user["limited_user_quotas"]?.objectValue, let monthly = user["monthly_quotas"]?.objectValue {
      let freeReset = reset(user["limited_user_reset_date"]?.stringValue) ?? cycleReset
      for key in limited.keys.sorted() {
        guard !windows.contains(where: { $0.id == key }) else { continue }
        guard let remaining = limited[key]?.doubleValue, let limit = monthly[key]?.doubleValue, limit > 0 else {
          continue
        }
        windows.append(
          QuotaWindow(
            id: "free:\(key)", label: label(key), group: .monthly, usedPercent: (1 - remaining / limit) * 100,
            resetsAt: freeReset?.date, resetPrecision: freeReset?.precision ?? .instant))
      }
    }
    return windows
  }

  static func percentUsed(_ snapshot: JSONValue) -> Double? {
    if snapshot["unlimited"]?.boolValue == true { return nil }
    let entitlement = number(snapshot["entitlement"])
    let remaining = number(snapshot["quota_remaining"]) ?? number(snapshot["remaining"])
    if let entitlement, entitlement <= 0 { return nil }
    if let entitlement, let remaining { return (entitlement - remaining) * 100 / entitlement }
    if let percent = number(snapshot["percent_remaining"]) { return 100 - percent }
    return nil
  }

  static func number(_ value: JSONValue?) -> Double? {
    value?.doubleValue ?? value?.stringValue.flatMap(Double.init)
  }

  static func label(_ key: String, credits: Bool = false) -> String {
    switch key {
    case "premium_interactions": credits ? "Premium credits" : "Premium requests"
    default: Format.humanize(key)
    }
  }

  struct Reset {
    let date: Date
    let precision: ResetPrecision
  }

  static func reset(_ text: String?) -> Reset? {
    guard let text else { return nil }
    if let instant = ISODate.parse(text) { return Reset(date: instant, precision: .instant) }
    return DayStamp.date(text).map { Reset(date: $0, precision: .day) }
  }

  static func identity(_ user: JSONValue, auth: CopilotAuth) -> ProviderIdentity {
    let sku = user["copilot_plan"]?.stringValue ?? user["access_type_sku"]?.stringValue ?? "Copilot"
    let plan: String =
      switch sku {
      case "individual": "Pro"
      case "individual_pro": "Pro+"
      case "individual_max": "Max"
      case "individual_edu": "Student"
      default: Format.humanize(sku)
      }
    let organizations = user["organization_login_list"]?.arrayValue?.compactMap(\.stringValue) ?? []
    return ProviderIdentity(
      planName: organizations.isEmpty ? plan : "\(plan) via \(organizations.joined(separator: ", "))",
      tier: user["access_type_sku"]?.stringValue, email: auth.user, subscriptionActiveUntil: nil)
  }

  static func notices(_ user: JSONValue) -> [Notice] {
    var notices: [Notice] = []
    let snapshots = user["quota_snapshots"]?.objectValue ?? [:]
    let tokenBilling = user["token_based_billing"]?.boolValue == true
    for key in CopilotAPI.snapshotOrder {
      guard let snapshot = snapshots[key], let percent = percentUsed(snapshot), percent > 100 else { continue }
      let overage = number(snapshot["overage_count"]) ?? 0
      notices.append(
        Notice(
          kind: snapshot["overage_permitted"]?.boolValue == true ? .info : .limitReached,
          text:
            "\(label(key, credits: tokenBilling)): quota exceeded, \(overage.formatted()) overage \(tokenBilling ? "credits" : "requests")."
        ))
    }
    return notices
  }

  static func details(_ user: JSONValue) -> [ProviderDetail] {
    let tokenBilling = user["token_based_billing"]?.boolValue == true
    return (user["quota_snapshots"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.compactMap { key, snapshot in
      var values: [String] = []
      if snapshot["unlimited"]?.boolValue == true { values.append("Unlimited") }
      let unit = tokenBilling ? "credits" : "requests"
      for (field, title) in [
        ("entitlement", "Included"), ("quota_remaining", "Remaining"), ("credits_used", "Credits used"),
        ("overage_count", "Overage used"), ("overage_entitlement", "Overage allowance"),
      ] {
        if let value = number(snapshot[field]) {
          values.append(
            "\(title): \(value.formatted(.number.precision(.fractionLength(0...6)))) \(field == "credits_used" ? "credits" : unit)"
          )
        }
      }
      if let allowed = snapshot["overage_permitted"]?.boolValue {
        values.append("Overage \(allowed ? "allowed" : "off")")
      }
      guard !values.isEmpty else { return nil }
      return ProviderDetail(
        id: "quota:\(key)", title: label(key, credits: tokenBilling), value: values.joined(separator: " · "),
        explanation:
          "Provider-reported category totals. Categories may overlap and are not added together. \(tokenBilling ? "Token-based credit billing." : "Request-based billing.")"
      )
    }
  }
}
