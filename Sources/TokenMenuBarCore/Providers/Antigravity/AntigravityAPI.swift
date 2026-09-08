import Foundation

enum AntigravityAPI {
  static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  static let cloudBases = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]
  static let serverSchemes = ["https", "http"]
  static let serverService = "exa.language_server_pb.LanguageServerService"

  static let serverQuotaBody = Data(#"{"forceRefresh":true}"#.utf8)
  static let serverStatusBody = Data(
    #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8)
  static let cloudQuotaBody = Data("{}".utf8)
  static let cloudAssistBody = Data(
    #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)

  static func serverURL(port: UInt16, scheme: String, method: String) -> URL {
    URL(string: "\(scheme)://127.0.0.1:\(port)/\(serverService)/\(method)")!
  }

  static func serverHeaders(csrfToken: String?) -> [String: String] {
    var headers = ["Connect-Protocol-Version": "1"]
    headers["X-Codeium-Csrf-Token"] = csrfToken
    return headers
  }

  static func cloudURL(base: String, method: String) -> URL {
    URL(string: "\(base)/v1internal:\(method)")!
  }

  static func cloudHeaders(token: String) -> [String: String] {
    ["Authorization": "Bearer \(token)", "Accept": "application/json", "User-Agent": "antigravity"]
  }

  struct Bucket: Decodable, Sendable, Equatable {
    let bucketId: String?
    let displayName: String?
    let window: String?
    let remainingFraction: Double?
    let remaining: JSONValue?
    let resetTime: String?
    let disabled: Bool?
    let description: String?

    var remainingShare: Double? {
      if let remainingFraction { return remainingFraction }
      if let fraction = remaining?["remainingFraction"]?.doubleValue { return fraction }
      if remaining?["case"]?.stringValue == "remainingFraction", let value = remaining?["value"]?.doubleValue {
        return value
      }
      return nil
    }

    var remainingAmount: String? {
      let amount =
        remaining?["case"]?.stringValue == "remainingAmount"
        ? remaining?["value"] : remaining?["remainingAmount"]
      return amount?.stringValue ?? amount?.doubleValue.map { Format.compactNumber($0) }
    }
  }

  struct Group: Decodable, Sendable, Equatable {
    let displayName: String?
    let buckets: [Bucket]?
  }

  struct QuotaPayload: Decodable, Sendable, Equatable {
    let groups: [Group]?
  }

  struct QuotaSummary: Decodable, Sendable, Equatable {
    let code: JSONValue?
    let response: QuotaPayload?
    let groups: [Group]?
    let summary: QuotaPayload?

    var allGroups: [Group] { response?.groups ?? summary?.groups ?? groups ?? [] }
    var isUnauthenticated: Bool {
      code?.doubleValue == 16 || ["16", "unauthenticated"].contains(code?.stringValue?.lowercased() ?? "")
    }
    var failure: APIError? {
      if isUnauthenticated { return .http(status: 401, body: "unauthenticated", retryAfter: nil) }
      if let code, !code.isNull, code.doubleValue != 0,
        !["0", "ok", "success"].contains(code.stringValue?.lowercased() ?? "")
      {
        return .decoding("Antigravity quota request failed at the RPC layer")
      }
      guard response?.groups != nil || summary?.groups != nil || groups != nil else {
        return .decoding("Antigravity response contains no quota groups")
      }
      return nil
    }
  }

  struct Tier: Decodable, Sendable, Equatable {
    let id: String?
    let name: String?
  }

  struct PlanInfo: Decodable, Sendable, Equatable {
    let planName: String?
  }

  struct PlanStatus: Decodable, Sendable, Equatable {
    let planInfo: PlanInfo?
  }

  struct UserStatus: Decodable, Sendable, Equatable {
    let email: String?
    let userTier: Tier?
    let planStatus: PlanStatus?
  }

  struct UserStatusResponse: Decodable, Sendable, Equatable {
    let userStatus: UserStatus?
  }

  struct LoadCodeAssistResponse: Decodable, Sendable, Equatable {
    let currentTier: Tier?
  }
}

enum AntigravityMapper {
  struct WindowSpec {
    let id: String
    let label: String
    let group: WindowGroup
    let duration: TimeInterval?
  }

  static func windows(_ groups: [AntigravityAPI.Group]) -> [QuotaWindow] {
    groups.flatMap { $0.buckets ?? [] }.compactMap(window)
  }

  static func window(_ bucket: AntigravityAPI.Bucket) -> QuotaWindow? {
    guard let bucketID = bucket.bucketId, bucket.disabled != true, let remaining = bucket.remainingShare else {
      return nil
    }
    let spec = spec(for: bucketID, displayName: bucket.displayName)
    return QuotaWindow(
      id: spec.id, label: spec.label, group: spec.group, usedPercent: (1 - remaining) * 100,
      resetsAt: ISODate.parse(bucket.resetTime), duration: spec.duration, detail: bucket.description)
  }

  static func details(_ groups: [AntigravityAPI.Group]) -> [ProviderDetail] {
    groups.flatMap { $0.buckets ?? [] }.compactMap { bucket in
      guard let id = bucket.bucketId, bucket.disabled == true || bucket.remainingShare == nil else { return nil }
      let values = [bucket.disabled == true ? "Disabled" : nil, bucket.remainingAmount.map { "\($0) remaining" }]
        .compactMap { $0 }
      return ProviderDetail(
        id: id, title: spec(for: id, displayName: bucket.displayName).label,
        value: values.isEmpty ? "Usage percentage unavailable" : values.joined(separator: " · "),
        explanation: [
          bucket.description, bucket.resetTime.map { "Resets \($0)." },
          "The local source did not report a usable percentage for this quota.",
        ]
        .compactMap { $0 }.joined(separator: " "))
    }
  }

  static func spec(for bucketID: String, displayName: String?) -> WindowSpec {
    switch bucketID {
    case "gemini-5h": WindowSpec(id: "gemini:session", label: "Gemini 5-hour", group: .session, duration: 5 * 3600)
    case "gemini-weekly": WindowSpec(id: "gemini:weekly", label: "Gemini weekly", group: .weekly, duration: 7 * 86400)
    case "3p-5h": WindowSpec(id: "3p:session", label: "Claude and GPT 5-hour", group: .session, duration: 5 * 3600)
    case "3p-weekly":
      WindowSpec(id: "3p:weekly", label: "Claude and GPT weekly", group: .weekly, duration: 7 * 86400)
    default: WindowSpec(id: bucketID, label: displayName ?? bucketID, group: .other, duration: nil)
    }
  }

  // `planInfo.planName` says Pro for Ultra accounts, so the tier name wins when the server reports one.
  static func identity(_ status: AntigravityAPI.UserStatus?) -> ProviderIdentity {
    ProviderIdentity(
      planName: status?.userTier?.name ?? status?.planStatus?.planInfo?.planName ?? "Antigravity",
      tier: status?.userTier?.id, email: status?.email)
  }

  static func identity(_ tier: AntigravityAPI.Tier?) -> ProviderIdentity {
    ProviderIdentity(planName: tier?.name ?? "Antigravity", tier: tier?.id)
  }
}
