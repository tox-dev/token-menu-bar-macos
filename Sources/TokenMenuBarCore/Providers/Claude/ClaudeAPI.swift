import Foundation

enum ClaudeAPI {
  static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
  static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
  static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  static let betaHeader = "oauth-2025-04-20"
  static let userAgent = "claude-code/2.1.251"

  static func headers(token: String) -> [String: String] {
    ["Authorization": "Bearer \(token)", "anthropic-beta": betaHeader, "User-Agent": userAgent]
  }

  struct Window: Decodable, Sendable, Equatable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
      case utilization
      case resetsAt = "resets_at"
    }
  }

  struct Limit: Decodable, Sendable, Equatable {
    struct Scope: Decodable, Sendable, Equatable {
      struct Model: Decodable, Sendable, Equatable {
        let id: String?
        let displayName: String?

        enum CodingKeys: String, CodingKey {
          case id
          case displayName = "display_name"
        }
      }

      let model: Model?
      let surface: String?
    }

    let kind: String
    let group: String?
    let percent: Double
    let severity: String?
    let resetsAt: String?
    let scope: Scope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
      case kind, group, percent, severity, scope
      case resetsAt = "resets_at"
      case isActive = "is_active"
    }
  }

  struct MoneyDTO: Decodable, Sendable, Equatable {
    let amountMinor: Int
    let currency: String?
    let exponent: Int?

    enum CodingKeys: String, CodingKey {
      case amountMinor = "amount_minor"
      case currency, exponent
    }

    func money(defaultCurrency: String) -> Money {
      Money(amountMinor: amountMinor, currency: currency ?? defaultCurrency, exponent: exponent ?? 2)
    }
  }

  struct Spend: Decodable, Sendable, Equatable {
    let used: MoneyDTO?
    let limit: MoneyDTO?
    let percent: Double?
    let severity: String?
    let enabled: Bool?
    let disabledReason: String?
    let balance: MoneyDTO?
    let autoReload: JSONValue?
    let canPurchaseCredits: Bool?
    let canToggle: Bool?

    enum CodingKeys: String, CodingKey {
      case used, limit, percent, severity, enabled, balance
      case disabledReason = "disabled_reason"
      case autoReload = "auto_reload"
      case canPurchaseCredits = "can_purchase_credits"
      case canToggle = "can_toggle"
    }
  }

  struct ExtraUsage: Decodable, Sendable, Equatable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    let decimalPlaces: Int?
    let disabledReason: String?
    let spendLimitReached: Bool?

    enum CodingKeys: String, CodingKey {
      case utilization, currency
      case isEnabled = "is_enabled"
      case monthlyLimit = "monthly_limit"
      case usedCredits = "used_credits"
      case decimalPlaces = "decimal_places"
      case disabledReason = "disabled_reason"
      case spendLimitReached = "spend_limit_reached"
    }
  }

  struct UsageResponse: Decodable, Sendable, Equatable {
    static let knownWindowKeys: [String: (id: String, label: String, group: WindowGroup)] = [
      "five_hour": ("session", "Current session", .session),
      "seven_day": ("weekly", "All models", .weekly),
      "seven_day_opus": ("weekly:opus", "Opus", .weekly),
      "seven_day_sonnet": ("weekly:sonnet", "Sonnet", .weekly),
      "seven_day_oauth_apps": ("weekly:oauth-apps", "OAuth apps", .weekly),
      "seven_day_cowork": ("weekly:cowork", "Cowork", .weekly),
    ]

    let limits: [Limit]
    let windows: [String: Window]
    let spend: Spend?
    let extraUsage: ExtraUsage?

    struct DynamicKey: CodingKey {
      var stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: DynamicKey.self)
      var windows: [String: Window] = [:]
      var limits: [Limit] = []
      var spend: Spend?
      var extraUsage: ExtraUsage?
      for key in container.allKeys {
        switch key.stringValue {
        case "limits": limits = try container.decodeIfPresent([Limit].self, forKey: key) ?? []
        case "spend": spend = try container.decodeIfPresent(Spend.self, forKey: key)
        case "extra_usage": extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: key)
        case "member_dashboard_available": continue
        default:
          if let window = try? container.decodeIfPresent(Window.self, forKey: key), window.utilization != nil {
            windows[key.stringValue] = window
          }
        }
      }
      self.limits = limits
      self.windows = windows
      self.spend = spend
      self.extraUsage = extraUsage
    }

    init(limits: [Limit], windows: [String: Window], spend: Spend?, extraUsage: ExtraUsage?) {
      self.limits = limits
      self.windows = windows
      self.spend = spend
      self.extraUsage = extraUsage
    }
  }

  struct ProfileResponse: Decodable, Sendable, Equatable {
    struct Account: Decodable, Sendable, Equatable {
      let email: String?
      let displayName: String?
      let hasClaudeMax: Bool?
      let hasClaudePro: Bool?

      enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name"
        case hasClaudeMax = "has_claude_max"
        case hasClaudePro = "has_claude_pro"
      }
    }

    struct Organization: Decodable, Sendable, Equatable {
      let name: String?
      let organizationType: String?
      let rateLimitTier: String?
      let hasExtraUsageEnabled: Bool?
      let subscriptionStatus: String?

      enum CodingKeys: String, CodingKey {
        case name
        case organizationType = "organization_type"
        case rateLimitTier = "rate_limit_tier"
        case hasExtraUsageEnabled = "has_extra_usage_enabled"
        case subscriptionStatus = "subscription_status"
      }
    }

    let account: Account?
    let organization: Organization?
  }

  struct TokenResponse: Decodable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }
}

enum ClaudeMapper {
  static let sessionDuration: TimeInterval = 5 * 3600
  static let weeklyDuration: TimeInterval = 7 * 86400

  static func windows(_ response: ClaudeAPI.UsageResponse) -> [QuotaWindow] {
    if !response.limits.isEmpty { return response.limits.map(window) }
    return response.windows.map { key, window in
      let known = ClaudeAPI.UsageResponse.knownWindowKeys[key]
      let group: WindowGroup = known?.group ?? (key.hasPrefix("seven_day") ? .weekly : .other)
      return QuotaWindow(
        id: known?.id ?? key,
        label: known?.label ?? Format.humanize(key),
        group: group,
        usedPercent: window.utilization ?? 0,
        resetsAt: ISODate.parse(window.resetsAt),
        duration: group == .session ? sessionDuration : group == .weekly ? weeklyDuration : nil
      )
    }
  }

  static func window(_ limit: ClaudeAPI.Limit) -> QuotaWindow {
    let scopeName = limit.scope?.model?.displayName ?? limit.scope?.surface
    let (id, label, group, duration): (String, String, WindowGroup, TimeInterval?) =
      switch limit.kind {
      case "session": ("session", "Current session", .session, sessionDuration)
      case "weekly_all": ("weekly", "All models", .weekly, weeklyDuration)
      case "weekly_scoped":
        ("weekly:\(Format.slug(scopeName ?? "scoped"))", scopeName ?? "Scoped weekly", .weekly, weeklyDuration)
      default:
        (
          scopeName.map { "\(limit.kind):\(Format.slug($0))" } ?? limit.kind,
          scopeName.map { "\(Format.humanize(limit.kind)) \($0)" } ?? Format.humanize(limit.kind),
          WindowGroup(rawValue: limit.group ?? "") ?? .other,
          nil
        )
      }
    return QuotaWindow(
      id: id,
      label: label,
      group: group,
      usedPercent: limit.percent,
      resetsAt: ISODate.parse(limit.resetsAt),
      duration: duration,
      severity: limit.severity.map { Severity(raw: $0) },
      isActive: limit.isActive ?? true,
      scope: scopeName
    )
  }

  static func spend(
    _ response: ClaudeAPI.UsageResponse, now: Date, calendar: Calendar = .current
  ) -> SpendControl? {
    let extra = response.extraUsage
    let spend = response.spend
    guard extra != nil || spend != nil else { return nil }
    let currency = extra?.currency ?? spend?.used?.currency ?? "USD"
    let exponent = extra?.decimalPlaces ?? 2
    let scale = pow(10, Double(exponent))
    let used =
      spend?.used?.money(defaultCurrency: currency)
      ?? extra?.usedCredits.map {
        Money(amountMinor: Int(($0 * scale).rounded()), currency: currency, exponent: exponent)
      }
    let limit =
      spend?.limit?.money(defaultCurrency: currency)
      ?? extra?.monthlyLimit.map {
        Money(amountMinor: Int(($0 * scale).rounded()), currency: currency, exponent: exponent)
      }
    let enabled = spend?.enabled ?? extra?.isEnabled ?? false
    let percent =
      spend?.percent ?? extra?.utilization
      ?? limit.flatMap { limit in
        used.map { limit.amountMinor > 0 ? Double($0.amountMinor) / Double(limit.amountMinor) * 100 : 0 }
      }
    let autoReload: Bool? = spend?.autoReload.map { !$0.isNull }
    return SpendControl(
      enabled: enabled,
      canToggle: spend?.canToggle ?? false,
      used: used,
      limit: limit,
      percent: percent,
      resetsAt: nextMonthStart(after: now, calendar: calendar),
      limitReached: extra?.spendLimitReached ?? false,
      disabledReason: enabled ? nil : (spend?.disabledReason ?? extra?.disabledReason),
      balance: spend?.balance?.money(defaultCurrency: currency),
      autoReload: autoReload,
      canPurchaseCredits: spend?.canPurchaseCredits ?? false
    )
  }

  static func nextMonthStart(after date: Date, calendar: Calendar) -> Date? {
    let start = calendar.dateInterval(of: .month, for: date)?.start
    return start.flatMap { calendar.date(byAdding: .month, value: 1, to: $0) }
  }

  static func identity(
    profile: ClaudeAPI.ProfileResponse?, credentials: ClaudeOAuthCredentials?, local: ClaudeLocalAccount?
  ) -> ProviderIdentity {
    let tier = profile?.organization?.rateLimitTier ?? credentials?.rateLimitTier ?? local?.rateLimitTier
    let base: String =
      switch profile?.organization?.organizationType ?? credentials?.subscriptionType {
      case "claude_max", "max": "Max"
      case "claude_pro", "pro": "Pro"
      case "claude_team", "team": "Team"
      case "claude_enterprise", "enterprise": "Enterprise"
      case .some(let other): Format.humanize(other.replacingOccurrences(of: "claude_", with: ""))
      case nil:
        profile?.account?.hasClaudeMax == true ? "Max" : profile?.account?.hasClaudePro == true ? "Pro" : "Claude"
      }
    let multiplier = tier.flatMap { try? Regex("(\\d+)x$").firstMatch(in: $0) }.map {
      String($0.output[1].substring ?? "")
    }
    return ProviderIdentity(
      planName: multiplier.map { "\(base) \($0)x" } ?? base,
      tier: tier,
      email: profile?.account?.email ?? local?.email,
      organization: profile?.organization?.name ?? local?.organizationName
    )
  }

  static func notices(_ response: ClaudeAPI.UsageResponse) -> [Notice] {
    var notices: [Notice] = []
    if response.extraUsage?.spendLimitReached == true {
      notices.append(Notice(kind: .spendControl, text: "Monthly usage-credit spend limit reached."))
    }
    for limit in response.limits.filter({ Severity(raw: $0.severity) == .critical }) {
      notices.append(
        Notice(kind: .limitReached, text: "\(window(limit).label) limit reached; resets \(limit.resetsAt ?? "later")."))
    }
    return notices
  }
}
