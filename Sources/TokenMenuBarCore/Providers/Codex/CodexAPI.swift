import Foundation

enum CodexAPI {
  static let base = URL(string: "https://chatgpt.com/backend-api")!
  static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let originator = "codex_cli_rs"
  static let terminalRefreshErrors: Set<String> = [
    "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated", "invalid_grant",
  ]

  static var usageURL: URL { base.appendingPathComponent("wham/usage") }
  static var resetCreditsURL: URL { base.appendingPathComponent("wham/rate-limit-reset-credits") }
  static var creditEventsURL: URL { base.appendingPathComponent("wham/usage/credit-usage-events") }

  enum Analytics: String, CaseIterable, Sendable {
    case tokenUsage = "wham/usage/daily-token-usage-breakdown"
    case workspaceCounts = "wham/analytics/daily-workspace-usage-counts"
    case skills = "wham/analytics/daily-skill-usage-metrics"
    case plugins = "wham/analytics/daily-plugin-usage-metrics"
    case codeReview = "wham/analytics/daily-code-review-metrics"

    var metrics: Set<AnalyticsMetric> {
      switch self {
      case .tokenUsage: [.surfaceUsagePercent, .modelCredits]
      case .workspaceCounts: [.inputTokens, .cachedInputTokens, .outputTokens, .turns, .threads, .credits]
      case .skills: [.skillInvocations]
      case .plugins: [.pluginInvocations]
      case .codeReview: [.codeReviews]
      }
    }

    func url(start: String, end: String) -> URL {
      var components = URLComponents(
        url: CodexAPI.base.appendingPathComponent(rawValue), resolvingAgainstBaseURL: false)!
      var items = [
        URLQueryItem(name: "start_date", value: start), URLQueryItem(name: "end_date", value: end),
        URLQueryItem(name: "group_by", value: "day"),
      ]
      switch self {
      case .tokenUsage: break
      case .skills:
        items += [
          URLQueryItem(name: "workspace_user", value: "true"), URLQueryItem(name: "top_skill_limit", value: "20"),
        ]
      case .plugins:
        items += [
          URLQueryItem(name: "workspace_user", value: "true"), URLQueryItem(name: "top_plugin_limit", value: "20"),
        ]
      case .workspaceCounts, .codeReview: items.append(URLQueryItem(name: "workspace_user", value: "true"))
      }
      components.queryItems = items
      return components.url!
    }
  }

  static func headers(token: String, accountID: String?) -> [String: String] {
    var headers = [
      "Authorization": "Bearer \(token)", "originator": originator, "User-Agent": "\(originator)/token-menu-bar",
    ]
    if let accountID { headers["ChatGPT-Account-Id"] = accountID }
    return headers
  }

  struct Window: Decodable, Sendable, Equatable {
    let usedPercent: Double
    let limitWindowSeconds: Double?
    let resetAfterSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
      case usedPercent = "used_percent"
      case limitWindowSeconds = "limit_window_seconds"
      case resetAfterSeconds = "reset_after_seconds"
      case resetAt = "reset_at"
    }

    init(usedPercent: Double, limitWindowSeconds: Double?, resetAfterSeconds: Double?, resetAt: Double?) {
      self.usedPercent = usedPercent
      self.limitWindowSeconds = limitWindowSeconds
      self.resetAfterSeconds = resetAfterSeconds
      self.resetAt = resetAt
    }
  }

  struct RateLimit: Decodable, Sendable, Equatable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: Window?
    let secondaryWindow: Window?

    enum CodingKeys: String, CodingKey {
      case allowed
      case limitReached = "limit_reached"
      case primaryWindow = "primary_window"
      case secondaryWindow = "secondary_window"
    }

    init(allowed: Bool?, limitReached: Bool?, primaryWindow: Window?, secondaryWindow: Window?) {
      self.allowed = allowed
      self.limitReached = limitReached
      self.primaryWindow = primaryWindow
      self.secondaryWindow = secondaryWindow
    }
  }

  struct AdditionalRateLimit: Decodable, Sendable, Equatable {
    let limitName: String
    let meteredFeature: String?
    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
      case limitName = "limit_name"
      case meteredFeature = "metered_feature"
      case rateLimit = "rate_limit"
    }
  }

  struct Credits: Decodable, Sendable, Equatable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let overageLimitReached: Bool?
    let balance: String?
    let approxLocalMessages: [Int]?
    let approxCloudMessages: [Int]?

    enum CodingKeys: String, CodingKey {
      case unlimited, balance
      case hasCredits = "has_credits"
      case overageLimitReached = "overage_limit_reached"
      case approxLocalMessages = "approx_local_messages"
      case approxCloudMessages = "approx_cloud_messages"
    }
  }

  struct IndividualLimit: Decodable, Sendable, Equatable {
    let limit: String?
    let used: String?
    let remaining: String?
    let usedPercent: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
      case limit, used, remaining
      case usedPercent = "used_percent"
      case resetAt = "reset_at"
    }
  }

  struct SpendControl: Decodable, Sendable, Equatable {
    let reached: Bool?
    let individualLimit: IndividualLimit?

    enum CodingKeys: String, CodingKey {
      case reached
      case individualLimit = "individual_limit"
    }
  }

  struct ResetCreditsSummary: Decodable, Sendable, Equatable {
    let availableCount: Int?
    let applicableAvailableCount: Int?
    let totalEarnedCount: Int?
    let immediateResetPurchaseEligible: Bool?

    enum CodingKeys: String, CodingKey {
      case availableCount = "available_count"
      case applicableAvailableCount = "applicable_available_count"
      case totalEarnedCount = "total_earned_count"
      case immediateResetPurchaseEligible = "immediate_reset_purchase_eligible"
    }
  }

  struct UsageResponse: Decodable, Sendable, Equatable {
    let email: String?
    let planType: String?
    let rateLimit: RateLimit?
    let codeReviewRateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    let credits: Credits?
    let spendControl: SpendControl?
    let rateLimitReachedType: JSONValue?
    let promo: JSONValue?
    let rateLimitResetCredits: ResetCreditsSummary?

    enum CodingKeys: String, CodingKey {
      case email, credits, promo
      case planType = "plan_type"
      case rateLimit = "rate_limit"
      case codeReviewRateLimit = "code_review_rate_limit"
      case additionalRateLimits = "additional_rate_limits"
      case spendControl = "spend_control"
      case rateLimitReachedType = "rate_limit_reached_type"
      case rateLimitResetCredits = "rate_limit_reset_credits"
    }
  }

  struct TokenResponse: Decodable, Sendable, Equatable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
      case error
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case idToken = "id_token"
    }
  }

  struct DailyRows: Decodable, Sendable, Equatable {
    let data: [JSONValue]
    let dataFreshness: String?

    enum CodingKeys: String, CodingKey {
      case data
      case dataFreshness = "data_freshness_ts"
    }
  }
}

enum CodexMapper {
  static func planName(_ planType: String?) -> String {
    switch planType?.lowercased() {
    case nil, "": "ChatGPT"
    case "pro": "Pro"
    case "prolite": "Pro Lite"
    case "plus": "Plus"
    case "go": "Go"
    case "free": "Free"
    case "team", "free_workspace": "Team"
    case "business", "self_serve_business_prolite": "Business"
    case "enterprise": "Enterprise"
    case "edu", "education": "Education"
    case .some(let other): Format.humanize(other)
    }
  }

  static func windows(_ response: CodexAPI.UsageResponse) -> [QuotaWindow] {
    var windows = rateLimitWindows(response.rateLimit, idPrefix: "", labelPrefix: "")
    windows += rateLimitWindows(response.codeReviewRateLimit, idPrefix: "code_review:", labelPrefix: "Code review ")
    for extra in response.additionalRateLimits ?? [] {
      windows += rateLimitWindows(
        extra.rateLimit, idPrefix: "additional:\(Format.slug(extra.limitName)):", labelPrefix: "\(extra.limitName) ",
        scope: extra.limitName)
    }
    return windows
  }

  static func rateLimitWindows(
    _ limit: CodexAPI.RateLimit?, idPrefix: String, labelPrefix: String, scope: String? = nil
  ) -> [QuotaWindow] {
    guard let limit else { return [] }
    return [limit.primaryWindow, limit.secondaryWindow].compactMap { $0 }.map { window in
      let seconds = window.limitWindowSeconds ?? 18000
      let (suffix, group): (String, WindowGroup) =
        switch seconds {
        case 18000: ("session", .session)
        case 604_800: ("weekly", .weekly)
        case 2_592_000, 2_678_400: ("monthly", .monthly)
        default: ("window-\(Int(seconds))", .other)
        }
      return QuotaWindow(
        id: idPrefix + suffix,
        label: labelPrefix + Format.windowLabel(seconds: seconds),
        group: group,
        usedPercent: window.usedPercent,
        resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) },
        duration: seconds,
        severity: limit.limitReached == true ? .critical : nil,
        scope: scope
      )
    }
  }

  static func credits(_ credits: CodexAPI.Credits?) -> CreditBalance? {
    guard let credits else { return nil }
    return CreditBalance(
      balance: credits.balance.flatMap { Decimal(string: $0) },
      unlimited: credits.unlimited ?? false,
      hasCredits: credits.hasCredits ?? false,
      overageLimitReached: credits.overageLimitReached ?? false,
      approxLocalMessages: range(credits.approxLocalMessages),
      approxCloudMessages: range(credits.approxCloudMessages)
    )
  }

  static func range(_ values: [Int]?) -> ClosedRange<Int>? {
    guard let values, let low = values.first, let high = values.last, low <= high else { return nil }
    return low...high
  }

  static func spend(_ control: CodexAPI.SpendControl?) -> SpendControl? {
    guard let control, let limit = control.individualLimit else { return nil }
    func money(_ text: String?) -> Money? {
      text.flatMap { Decimal(string: $0) }.map {
        Money(amountMinor: Int((NSDecimalNumber(decimal: $0 * 100)).doubleValue.rounded()), currency: "USD")
      }
    }
    return SpendControl(
      enabled: true,
      used: money(limit.used),
      limit: money(limit.limit),
      percent: limit.usedPercent,
      resetsAt: limit.resetAt.map { Date(timeIntervalSince1970: $0) },
      limitReached: control.reached ?? false
    )
  }

  static func resetCredits(_ summary: CodexAPI.ResetCreditsSummary?) -> ResetCredits? {
    guard let summary else { return nil }
    return ResetCredits(
      available: summary.availableCount ?? 0,
      applicable: summary.applicableAvailableCount ?? summary.availableCount ?? 0,
      totalEarned: summary.totalEarnedCount,
      immediatePurchaseEligible: summary.immediateResetPurchaseEligible ?? false
    )
  }

  static func notices(_ response: CodexAPI.UsageResponse) -> [Notice] {
    var notices: [Notice] = []
    if let reached = response.rateLimitReachedType, !reached.isNull {
      let type = reached["type"]?.stringValue ?? reached.summary
      notices.append(Notice(kind: .limitReached, text: "Limit reached: \(Format.humanize(type))."))
    } else if response.rateLimit?.limitReached == true {
      notices.append(Notice(kind: .limitReached, text: "Usage limit reached."))
    }
    if response.spendControl?.reached == true {
      notices.append(Notice(kind: .spendControl, text: "Workspace spend limit reached."))
    }
    if let promo = response.promo, !promo.isNull {
      notices.append(
        Notice(kind: .promotion, text: promo["text"]?.stringValue ?? promo["title"]?.stringValue ?? promo.summary))
    }
    if response.credits?.overageLimitReached == true {
      notices.append(Notice(kind: .spendControl, text: "Credit overage limit reached."))
    }
    return notices
  }

  static func identity(_ response: CodexAPI.UsageResponse?, auth: CodexAuth?) -> ProviderIdentity {
    let planType = response?.planType ?? auth?.planType
    return ProviderIdentity(
      planName: planName(planType),
      tier: planType,
      email: response?.email ?? auth?.email,
      subscriptionActiveUntil: auth?.subscriptionActiveUntil
    )
  }

  static func analytics(_ endpoint: CodexAPI.Analytics, rows: [JSONValue]) -> [AnalyticsPoint] {
    rows.flatMap { row -> [AnalyticsPoint] in
      guard let day = row["date"]?.stringValue else { return [] }
      switch endpoint {
      case .tokenUsage:
        let surfaces = (row["product_surface_usage_values"]?.objectValue ?? [:]).compactMap { key, value in
          value.doubleValue.map { AnalyticsPoint(day: day, metric: .surfaceUsagePercent, series: key, value: $0) }
        }
        let models = (row["models"]?.arrayValue ?? []).compactMap { model in
          model["model"]?.stringValue.flatMap { name in
            model["credits"]?.doubleValue.map {
              AnalyticsPoint(day: day, metric: .modelCredits, series: name, value: $0)
            }
          }
        }
        return surfaces + models
      case .workspaceCounts:
        var points: [AnalyticsPoint] = []
        let totals = row["totals"]
        let tokenMetrics: [(String, AnalyticsMetric)] = [
          ("uncached_text_input_tokens", .inputTokens), ("cached_text_input_tokens", .cachedInputTokens),
          ("text_output_tokens", .outputTokens),
        ]
        for (key, metric) in tokenMetrics {
          if let value = totals?[key]?.doubleValue {
            points.append(AnalyticsPoint(day: day, metric: metric, series: "total", value: value))
          }
        }
        for (key, metric) in [
          ("turns", AnalyticsMetric.turns), ("threads", .threads), ("credits", .credits),
        ] {
          if let value = totals?[key]?.doubleValue {
            points.append(AnalyticsPoint(day: day, metric: metric, series: "total", value: value))
          }
        }
        for (collection, prefix, nameKey) in [("models", "model", "model"), ("clients", "surface", "client_id")] {
          for entry in row[collection]?.arrayValue ?? [] {
            guard let name = entry[nameKey]?.stringValue else { continue }
            let series = "\(prefix):\(name)"
            for (key, metric) in [("turns", AnalyticsMetric.turns), ("threads", .threads), ("credits", .credits)] {
              if let value = entry[key]?.doubleValue {
                points.append(AnalyticsPoint(day: day, metric: metric, series: series, value: value))
              }
            }
          }
        }
        return points
      case .skills:
        return (row["skill_usage_overviews"]?.arrayValue ?? []).compactMap { skill in
          let name = skill["display_name"]?.stringValue ?? skill["skill_name"]?.stringValue
          return name.flatMap { series in
            skill["invocation_counts"]?.doubleValue.map {
              AnalyticsPoint(day: day, metric: .skillInvocations, series: series, value: $0)
            }
          }
        }
      case .plugins:
        var invocations: [String: Double] = [:]
        for plugin in row["plugin_usage_overviews"]?.arrayValue ?? [] {
          guard let name = plugin["plugin_name"]?.stringValue ?? plugin["display_name"]?.stringValue,
            let count = plugin["invocation_counts"]?.doubleValue
          else { continue }
          invocations[name, default: 0] += count
        }
        return invocations.sorted { $0.key < $1.key }.map { name, count in
          AnalyticsPoint(day: day, metric: .pluginInvocations, series: name, value: count)
        }
      case .codeReview:
        return row.objectValue!.compactMap { key, value in
          key == "date"
            ? nil : value.doubleValue.map { AnalyticsPoint(day: day, metric: .codeReviews, series: key, value: $0) }
        }
      }
    }
  }

  static func creditEvents(_ rows: [JSONValue]) -> [CreditEvent] {
    rows.enumerated().compactMap { index, row in
      let dateText = row["date"]?.stringValue ?? row["created_at"]?.stringValue ?? row["timestamp"]?.stringValue
      guard let date = dateText.flatMap({ ISODate.parse($0) ?? DayStamp.date($0) }) else { return nil }
      let used = row["credits_used"]?.doubleValue ?? row["credits"]?.doubleValue ?? row["amount"]?.doubleValue ?? 0
      let service = row["service"]?.stringValue ?? row["product"]?.stringValue ?? "Codex"
      return CreditEvent(
        id: row["id"]?.stringValue ?? "\(dateText!)-\(index)", date: date, service: service, creditsUsed: used)
    }
  }
}
