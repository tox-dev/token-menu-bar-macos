import Foundation

public enum ClaudeAPI {
  public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
  public static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
  public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  public static let betaHeader = "oauth-2025-04-20"
  public static let userAgent = "claude-code/2.1.251"

  public static func headers(token: String) -> [String: String] {
    ["Authorization": "Bearer \(token)", "anthropic-beta": betaHeader, "User-Agent": userAgent]
  }

  public struct Window: Decodable, Sendable, Equatable {
    public let utilization: Double?
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
      case utilization
      case resetsAt = "resets_at"
    }
  }

  public struct Limit: Decodable, Sendable, Equatable {
    public struct Scope: Decodable, Sendable, Equatable {
      public struct Model: Decodable, Sendable, Equatable {
        public let id: String?
        public let displayName: String?

        enum CodingKeys: String, CodingKey {
          case id
          case displayName = "display_name"
        }
      }

      public let model: Model?
      public let surface: String?
    }

    public let kind: String
    public let group: String?
    public let percent: Double
    public let severity: String?
    public let resetsAt: String?
    public let scope: Scope?
    public let isActive: Bool?

    enum CodingKeys: String, CodingKey {
      case kind, group, percent, severity, scope
      case resetsAt = "resets_at"
      case isActive = "is_active"
    }
  }

  public struct MoneyDTO: Decodable, Sendable, Equatable {
    public let amountMinor: Int
    public let currency: String?
    public let exponent: Int?

    enum CodingKeys: String, CodingKey {
      case amountMinor = "amount_minor"
      case currency, exponent
    }

    func money(defaultCurrency: String) -> Money {
      Money(amountMinor: amountMinor, currency: currency ?? defaultCurrency, exponent: exponent ?? 2)
    }
  }

  public struct Spend: Decodable, Sendable, Equatable {
    public let used: MoneyDTO?
    public let limit: MoneyDTO?
    public let percent: Double?
    public let severity: String?
    public let enabled: Bool?
    public let disabledReason: String?
    public let balance: MoneyDTO?
    public let autoReload: JSONValue?
    public let canPurchaseCredits: Bool?
    public let canToggle: Bool?

    enum CodingKeys: String, CodingKey {
      case used, limit, percent, severity, enabled, balance
      case disabledReason = "disabled_reason"
      case autoReload = "auto_reload"
      case canPurchaseCredits = "can_purchase_credits"
      case canToggle = "can_toggle"
    }
  }

  public struct ExtraUsage: Decodable, Sendable, Equatable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?
    public let currency: String?
    public let decimalPlaces: Int?
    public let disabledReason: String?
    public let spendLimitReached: Bool?

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

  public struct UsageResponse: Decodable, Sendable, Equatable {
    public static let knownWindowKeys: [String: (id: String, label: String, group: WindowGroup)] = [
      "five_hour": ("session", "Current session", .session),
      "seven_day": ("weekly", "All models", .weekly),
      "seven_day_opus": ("weekly:opus", "Opus", .weekly),
      "seven_day_sonnet": ("weekly:sonnet", "Sonnet", .weekly),
      "seven_day_oauth_apps": ("weekly:oauth-apps", "OAuth apps", .weekly),
      "seven_day_cowork": ("weekly:cowork", "Cowork", .weekly),
    ]

    public let limits: [Limit]
    public let windows: [String: Window]
    public let spend: Spend?
    public let extraUsage: ExtraUsage?

    struct DynamicKey: CodingKey {
      var stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
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

    public init(limits: [Limit], windows: [String: Window], spend: Spend?, extraUsage: ExtraUsage?) {
      self.limits = limits
      self.windows = windows
      self.spend = spend
      self.extraUsage = extraUsage
    }
  }

  public struct ProfileResponse: Decodable, Sendable, Equatable {
    public struct Account: Decodable, Sendable, Equatable {
      public let email: String?
      public let displayName: String?
      public let hasClaudeMax: Bool?
      public let hasClaudePro: Bool?

      enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name"
        case hasClaudeMax = "has_claude_max"
        case hasClaudePro = "has_claude_pro"
      }
    }

    public struct Organization: Decodable, Sendable, Equatable {
      public let name: String?
      public let organizationType: String?
      public let rateLimitTier: String?
      public let hasExtraUsageEnabled: Bool?
      public let subscriptionStatus: String?

      enum CodingKeys: String, CodingKey {
        case name
        case organizationType = "organization_type"
        case rateLimitTier = "rate_limit_tier"
        case hasExtraUsageEnabled = "has_extra_usage_enabled"
        case subscriptionStatus = "subscription_status"
      }
    }

    public let account: Account?
    public let organization: Organization?
  }

  public struct TokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }
}

public enum ClaudeMapper {
  public static let sessionDuration: TimeInterval = 5 * 3600
  public static let weeklyDuration: TimeInterval = 7 * 86400

  public static func windows(_ response: ClaudeAPI.UsageResponse) -> [QuotaWindow] {
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

  public static func spend(
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

  public static func identity(
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

  public static func notices(_ response: ClaudeAPI.UsageResponse) -> [Notice] {
    var notices: [Notice] = []
    if response.extraUsage?.spendLimitReached == true {
      notices.append(Notice(kind: .spendControl, text: "Monthly usage-credit spend limit reached."))
    }
    let critical = response.limits.filter { Severity(raw: $0.severity) == .critical }
    for limit in critical {
      notices.append(
        Notice(kind: .limitReached, text: "\(window(limit).label) limit reached; resets \(limit.resetsAt ?? "later")."))
    }
    return notices
  }
}
