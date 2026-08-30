import Foundation

enum CopilotAPI {
  static let editorVersion = "vscode/1.96.2"
  static let pluginVersion = "copilot-chat/0.26.7"

  static func userURL(host: String) -> URL {
    let apiHost = host == "github.com" ? "api.github.com" : "api.\(host)"
    return URL(string: "https://\(apiHost)/copilot_internal/user")!
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
    let resetsAt = date(user["quota_reset_date"]?.stringValue)
    var windows: [QuotaWindow] = []
    if let snapshots = user["quota_snapshots"]?.objectValue {
      let ordered =
        CopilotAPI.snapshotOrder.filter { snapshots[$0] != nil }
        + snapshots.keys.sorted().filter { !CopilotAPI.snapshotOrder.contains($0) }
      for key in ordered {
        guard let snapshot = snapshots[key], let percent = percentUsed(snapshot) else { continue }
        windows.append(
          QuotaWindow(id: key, label: label(key), group: .monthly, usedPercent: percent, resetsAt: resetsAt))
      }
    }
    if let limited = user["limited_user_quotas"]?.objectValue, let monthly = user["monthly_quotas"]?.objectValue {
      let freeReset = date(user["limited_user_reset_date"]?.stringValue) ?? resetsAt
      for key in limited.keys.sorted() {
        guard let remaining = limited[key]?.doubleValue, let limit = monthly[key]?.doubleValue, limit > 0 else {
          continue
        }
        windows.append(
          QuotaWindow(
            id: "free:\(key)", label: label(key), group: .monthly, usedPercent: (1 - remaining / limit) * 100,
            resetsAt: freeReset))
      }
    }
    return windows
  }

  static func percentUsed(_ snapshot: JSONValue) -> Double? {
    if snapshot["unlimited"]?.boolValue == true { return nil }
    let entitlement = number(snapshot["entitlement"])
    let remaining = number(snapshot["remaining"])
    if let percent = number(snapshot["percent_remaining"]) { return 100 - percent }
    guard let entitlement, entitlement > 0, let remaining else { return nil }
    return (1 - remaining / entitlement) * 100
  }

  static func number(_ value: JSONValue?) -> Double? {
    value?.doubleValue ?? value?.stringValue.flatMap(Double.init)
  }

  static func label(_ key: String) -> String {
    switch key {
    case "premium_interactions": "Premium requests"
    default: Format.humanize(key)
    }
  }

  static func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    return ISODate.parse(text) ?? DayStamp.date(text)
  }

  static func identity(_ user: JSONValue, auth: CopilotAuth) -> ProviderIdentity {
    let plan = user["copilot_plan"]?.stringValue ?? user["access_type_sku"]?.stringValue ?? "Copilot"
    return ProviderIdentity(
      planName: Format.humanize(plan), tier: user["access_type_sku"]?.stringValue, email: auth.user,
      subscriptionActiveUntil: nil)
  }

  static func notices(_ user: JSONValue) -> [Notice] {
    var notices: [Notice] = []
    let snapshots = user["quota_snapshots"]?.objectValue ?? [:]
    let credits = snapshots.values.compactMap { number($0["credits_used"]) }.reduce(0, +)
    if user["token_based_billing"]?.boolValue == true {
      notices.append(Notice(kind: .info, text: "Token-based billing: \(Int(credits)) credits used this cycle."))
    }
    for key in CopilotAPI.snapshotOrder {
      guard let snapshot = snapshots[key], let percent = percentUsed(snapshot), percent > 100 else { continue }
      let overage = number(snapshot["overage_count"]) ?? 0
      notices.append(
        Notice(
          kind: snapshot["overage_permitted"]?.boolValue == true ? .info : .limitReached,
          text: "\(label(key)): quota exceeded, \(Int(overage)) overage requests."))
    }
    return notices
  }
}
