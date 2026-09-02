import Foundation

enum GeminiAPI {
  static let base = "https://cloudcode-pa.googleapis.com/v1internal"
  static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  static let unsupportedClientMessage =
    """
    Google ended Login with Google for personal Gemini accounts on June 18, 2026. Workspace and Gemini Code Assist \
    Standard or Enterprise accounts still report quota.
    """

  static var loadCodeAssistURL: URL { URL(string: "\(base):loadCodeAssist")! }
  static var quotaURL: URL { URL(string: "\(base):retrieveUserQuota")! }

  static let loadCodeAssistBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)

  static func headers(token: String) -> [String: String] {
    ["Authorization": "Bearer \(token)", "User-Agent": "GeminiCLI/token-menu-bar (darwin; arm64; cli)"]
  }

  static func quotaBody(project: String?) -> Data {
    try! JSONEncoder().encode(project.map { ["project": $0] } ?? [:])
  }

  struct Credit: Decodable, Sendable, Equatable {
    let creditType: String?
    let creditAmount: String?
  }

  struct Tier: Decodable, Sendable, Equatable {
    let id: String?
    let name: String?
    let availableCredits: [Credit]?
  }

  struct IneligibleTier: Decodable, Sendable, Equatable {
    let reasonCode: String?
    let reasonMessage: String?
  }

  struct LoadCodeAssistResponse: Decodable, Sendable, Equatable {
    let currentTier: Tier?
    let paidTier: Tier?
    let cloudaicompanionProject: JSONValue?
    let ineligibleTiers: [IneligibleTier]?

    var projectID: String? {
      cloudaicompanionProject?.stringValue ?? cloudaicompanionProject?["id"]?.stringValue
        ?? cloudaicompanionProject?["projectId"]?.stringValue
    }

    var unsupportedReason: String? {
      guard currentTier == nil else { return nil }
      let ineligible = ineligibleTiers ?? []
      guard
        let reason = ineligible.first(where: { $0.reasonCode?.uppercased() == "UNSUPPORTED_CLIENT" })
          ?? ineligible.first
      else { return nil }
      return reason.reasonMessage ?? GeminiAPI.unsupportedClientMessage
    }
  }

  struct Bucket: Decodable, Sendable, Equatable {
    let modelId: String?
    let tokenType: String?
    let remainingFraction: Double?
    let remainingAmount: String?
    let resetTime: String?
  }

  struct QuotaResponse: Decodable, Sendable, Equatable {
    let buckets: [Bucket]?
  }

  struct TokenResponse: Decodable, Sendable, Equatable {
    let accessToken: String?
    let expiresIn: Double?
    let idToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case expiresIn = "expires_in"
      case idToken = "id_token"
      case error
      case errorDescription = "error_description"
    }
  }
}

enum GeminiMapper {
  static func identity(_ assist: GeminiAPI.LoadCodeAssistResponse?, auth: GeminiAuth) -> ProviderIdentity {
    ProviderIdentity(
      planName: planName(assist, hostedDomain: auth.hostedDomain), tier: assist?.currentTier?.id, email: auth.email,
      organization: auth.hostedDomain)
  }

  static func planName(_ assist: GeminiAPI.LoadCodeAssistResponse?, hostedDomain: String?) -> String {
    if let paid = assist?.paidTier?.name, !paid.isEmpty { return paid }
    switch assist?.currentTier?.id {
    case "standard-tier": return "Standard"
    case "legacy-tier": return "Legacy"
    case "free-tier": return hostedDomain == nil ? "Free" : "Workspace"
    default: return assist?.currentTier?.name ?? "Gemini"
    }
  }

  static func credits(_ assist: GeminiAPI.LoadCodeAssistResponse?) -> CreditBalance? {
    let credits = (assist?.paidTier?.availableCredits ?? []) + (assist?.currentTier?.availableCredits ?? [])
    let total = credits.compactMap { $0.creditAmount.flatMap(Double.init) }.reduce(0, +)
    guard !credits.isEmpty else { return nil }
    return CreditBalance(balance: Decimal(total), hasCredits: total > 0)
  }

  static func windows(_ quota: GeminiAPI.QuotaResponse) -> [QuotaWindow] {
    var lowest: [String: GeminiAPI.Bucket] = [:]
    var order: [String] = []
    for bucket in quota.buckets ?? [] {
      guard let model = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
      if lowest[model] == nil { order.append(model) }
      if (lowest[model]?.remainingFraction ?? 2) > fraction { lowest[model] = bucket }
    }
    return order.map { model in
      let bucket = lowest[model]!
      return QuotaWindow(
        id: "model:\(model)", label: modelLabel(model), group: .other,
        usedPercent: (1 - bucket.remainingFraction!) * 100, resetsAt: ISODate.parse(bucket.resetTime), duration: 86400,
        scope: model)
    }
  }

  static func modelLabel(_ model: String) -> String {
    model.split(separator: "-").map { part in
      part.first?.isNumber == true ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
    }.joined(separator: " ")
  }
}
