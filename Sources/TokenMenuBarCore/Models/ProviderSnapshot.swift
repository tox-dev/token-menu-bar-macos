import Foundation

public struct Money: Codable, Sendable, Hashable {
  public let amountMinor: Int
  public let currency: String
  public let exponent: Int

  public init(amountMinor: Int, currency: String, exponent: Int = 2) {
    self.amountMinor = amountMinor
    self.currency = currency
    self.exponent = exponent
  }

  public var amount: Decimal {
    Decimal(amountMinor) / pow(10, exponent)
  }

  public var formatted: String {
    amount.formatted(.currency(code: currency).precision(.fractionLength(exponent)))
  }
}

public struct ProviderIdentity: Codable, Sendable, Hashable {
  public let planName: String
  public let tier: String?
  public let email: String?
  public let organization: String?
  public let subscriptionActiveUntil: Date?

  public init(
    planName: String,
    tier: String? = nil,
    email: String? = nil,
    organization: String? = nil,
    subscriptionActiveUntil: Date? = nil
  ) {
    self.planName = planName
    self.tier = tier
    self.email = email
    self.organization = organization
    self.subscriptionActiveUntil = subscriptionActiveUntil
  }
}

public struct CreditBalance: Codable, Sendable, Hashable {
  public let balance: Decimal?
  public let currency: String?
  public let unlimited: Bool
  public let hasCredits: Bool
  public let overageLimitReached: Bool
  public let approxLocalMessages: ClosedRange<Int>?
  public let approxCloudMessages: ClosedRange<Int>?

  public init(
    balance: Decimal?,
    currency: String? = nil,
    unlimited: Bool = false,
    hasCredits: Bool = false,
    overageLimitReached: Bool = false,
    approxLocalMessages: ClosedRange<Int>? = nil,
    approxCloudMessages: ClosedRange<Int>? = nil
  ) {
    self.balance = balance
    self.currency = currency
    self.unlimited = unlimited
    self.hasCredits = hasCredits
    self.overageLimitReached = overageLimitReached
    self.approxLocalMessages = approxLocalMessages
    self.approxCloudMessages = approxCloudMessages
  }

  public var formattedBalance: String {
    guard let balance else { return "—" }
    if let currency { return balance.formatted(.currency(code: currency)) }
    return balance.formatted(.number.precision(.fractionLength(0...2)))
  }
}

public struct SpendControl: Codable, Sendable, Hashable {
  public let enabled: Bool
  public let canToggle: Bool
  public let used: Money?
  public let limit: Money?
  public let percent: Double?
  public let resetsAt: Date?
  public let limitReached: Bool
  public let disabledReason: String?
  public let balance: Money?
  public let autoReload: Bool?
  public let canPurchaseCredits: Bool

  public init(
    enabled: Bool,
    canToggle: Bool = false,
    used: Money? = nil,
    limit: Money? = nil,
    percent: Double? = nil,
    resetsAt: Date? = nil,
    limitReached: Bool = false,
    disabledReason: String? = nil,
    balance: Money? = nil,
    autoReload: Bool? = nil,
    canPurchaseCredits: Bool = false
  ) {
    self.enabled = enabled
    self.canToggle = canToggle
    self.used = used
    self.limit = limit
    self.percent = percent
    self.resetsAt = resetsAt
    self.limitReached = limitReached
    self.disabledReason = disabledReason
    self.balance = balance
    self.autoReload = autoReload
    self.canPurchaseCredits = canPurchaseCredits
  }
}

public struct ResetCredits: Codable, Sendable, Hashable {
  public let available: Int
  public let applicable: Int
  public let totalEarned: Int?
  public let immediatePurchaseEligible: Bool

  public init(available: Int, applicable: Int, totalEarned: Int? = nil, immediatePurchaseEligible: Bool = false) {
    self.available = available
    self.applicable = applicable
    self.totalEarned = totalEarned
    self.immediatePurchaseEligible = immediatePurchaseEligible
  }
}

public struct Notice: Codable, Sendable, Hashable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case promotion
    case limitReached
    case spendControl
    case info
  }

  public let kind: Kind
  public let text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }

  public var id: String {
    "\(kind.rawValue):\(text)"
  }
}

public enum DataSource: String, Codable, Sendable, Hashable {
  case network
  case localLog
  case cache
}

public struct ProviderSnapshot: Codable, Sendable, Hashable {
  public let provider: ProviderID
  public let identity: ProviderIdentity?
  public let windows: [QuotaWindow]
  public let credits: CreditBalance?
  public let spend: SpendControl?
  public let resetCredits: ResetCredits?
  public let notices: [Notice]
  public let localUsage: LocalUsage?
  public let source: DataSource
  public let fetchedAt: Date

  public init(
    provider: ProviderID,
    identity: ProviderIdentity? = nil,
    windows: [QuotaWindow],
    credits: CreditBalance? = nil,
    spend: SpendControl? = nil,
    resetCredits: ResetCredits? = nil,
    notices: [Notice] = [],
    localUsage: LocalUsage? = nil,
    source: DataSource = .network,
    fetchedAt: Date
  ) {
    self.provider = provider
    self.identity = identity
    self.windows = windows.sorted { ($0.group, $0.id) < ($1.group, $1.id) }
    self.credits = credits
    self.spend = spend
    self.resetCredits = resetCredits
    self.notices = notices
    self.localUsage = localUsage
    self.source = source
    self.fetchedAt = fetchedAt
  }

  public func window(_ id: String) -> QuotaWindow? {
    windows.first { $0.id == id }
  }

  public var worstWindow: QuotaWindow? {
    windows.filter(\.isActive).max { $0.usedPercent < $1.usedPercent }
  }
}
