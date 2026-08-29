import Foundation

public enum GeminiAPI {
  public static let base = "https://cloudcode-pa.googleapis.com/v1internal"
  public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  public static let unsupportedClientMessage =
    "Google ended Login with Google for personal Gemini accounts on June 18, 2026; only Workspace and Gemini Code Assist Standard or Enterprise accounts still report quota."

  public static var loadCodeAssistURL: URL { URL(string: "\(base):loadCodeAssist")! }
  public static var quotaURL: URL { URL(string: "\(base):retrieveUserQuota")! }

  public static let loadCodeAssistBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)

  public static func headers(token: String) -> [String: String] {
    ["Authorization": "Bearer \(token)", "User-Agent": "GeminiCLI/token-menu-bar (darwin; arm64; cli)"]
  }

  public static func quotaBody(project: String?) -> Data {
    try! JSONEncoder().encode(project.map { ["project": $0] } ?? [:])
  }

  public struct Credit: Decodable, Sendable, Equatable {
    public let creditType: String?
    public let creditAmount: String?
  }

  public struct Tier: Decodable, Sendable, Equatable {
    public let id: String?
    public let name: String?
    public let availableCredits: [Credit]?
  }

  public struct IneligibleTier: Decodable, Sendable, Equatable {
    public let reasonCode: String?
    public let reasonMessage: String?
  }

  public struct LoadCodeAssistResponse: Decodable, Sendable, Equatable {
    public let currentTier: Tier?
    public let paidTier: Tier?
    public let cloudaicompanionProject: JSONValue?
    public let ineligibleTiers: [IneligibleTier]?

    public var projectID: String? {
      cloudaicompanionProject?.stringValue ?? cloudaicompanionProject?["id"]?.stringValue
        ?? cloudaicompanionProject?["projectId"]?.stringValue
    }

    public var unsupportedReason: String? {
      guard currentTier == nil else { return nil }
      let ineligible = ineligibleTiers ?? []
      guard
        let reason = ineligible.first(where: { $0.reasonCode?.uppercased() == "UNSUPPORTED_CLIENT" })
          ?? ineligible.first
      else { return nil }
      return reason.reasonMessage ?? GeminiAPI.unsupportedClientMessage
    }
  }

  public struct Bucket: Decodable, Sendable, Equatable {
    public let modelId: String?
    public let tokenType: String?
    public let remainingFraction: Double?
    public let remainingAmount: String?
    public let resetTime: String?
  }

  public struct QuotaResponse: Decodable, Sendable, Equatable {
    public let buckets: [Bucket]?
  }

  public struct TokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String?
    public let expiresIn: Double?
    public let idToken: String?
    public let error: String?
    public let errorDescription: String?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case expiresIn = "expires_in"
      case idToken = "id_token"
      case error
      case errorDescription = "error_description"
    }
  }
}

public enum GeminiMapper {
  public static func identity(_ assist: GeminiAPI.LoadCodeAssistResponse?, auth: GeminiAuth) -> ProviderIdentity {
    ProviderIdentity(
      planName: planName(assist, hostedDomain: auth.hostedDomain), tier: assist?.currentTier?.id, email: auth.email,
      organization: auth.hostedDomain)
  }

  public static func planName(_ assist: GeminiAPI.LoadCodeAssistResponse?, hostedDomain: String?) -> String {
    if let paid = assist?.paidTier?.name, !paid.isEmpty { return paid }
    switch assist?.currentTier?.id {
    case "standard-tier": return "Standard"
    case "legacy-tier": return "Legacy"
    case "free-tier": return hostedDomain == nil ? "Free" : "Workspace"
    default: return assist?.currentTier?.name ?? "Gemini"
    }
  }

  public static func credits(_ assist: GeminiAPI.LoadCodeAssistResponse?) -> CreditBalance? {
    let credits = (assist?.paidTier?.availableCredits ?? []) + (assist?.currentTier?.availableCredits ?? [])
    let total = credits.compactMap { $0.creditAmount.flatMap(Double.init) }.reduce(0, +)
    guard !credits.isEmpty else { return nil }
    return CreditBalance(balance: Decimal(total), hasCredits: total > 0)
  }

  public static func windows(_ quota: GeminiAPI.QuotaResponse) -> [QuotaWindow] {
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

  public static func modelLabel(_ model: String) -> String {
    model.split(separator: "-").map { part in
      part.first?.isNumber == true ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
    }.joined(separator: " ")
  }
}
