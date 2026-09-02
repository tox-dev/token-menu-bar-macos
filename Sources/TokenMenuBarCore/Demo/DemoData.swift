import Foundation

public enum DemoData {
  public static let email = "you@example.com"
  public static let historyDays = 30
  static let seedInterval: TimeInterval = 1800

  public static func snapshot(
    _ provider: ProviderID, now: Date, fixture: VerificationProfile.Fixture = .standard
  ) -> ProviderSnapshot {
    let snapshot =
      switch provider {
      case .claude: claude(now: now)
      case .codex: codex(now: now)
      case .gemini: gemini(now: now)
      case .cursor: cursor(now: now)
      case .copilot: copilot(now: now)
      }
    return fixture == .longText ? longText(snapshot) : snapshot
  }

  public static func analytics(
    _ provider: ProviderID, now: Date, days: Int, fixture: VerificationProfile.Fixture = .standard
  ) -> ProviderAnalytics? {
    guard provider == .claude || provider == .codex else { return nil }
    let stamps = (0..<days).reversed().map { DayStamp.string(now.addingTimeInterval(-Double($0) * 86400)) }
    var points: [AnalyticsPoint] = []
    for (index, day) in stamps.enumerated() {
      let activity = self.activity(index)
      switch provider {
      case .claude:
        for (model, share) in [("fable", 0.6), ("sonnet", 0.3), ("haiku", 0.1)] {
          points.append(
            AnalyticsPoint(day: day, metric: .inputTokens, series: model, value: 900_000 * share * activity))
          points.append(
            AnalyticsPoint(day: day, metric: .cachedInputTokens, series: model, value: 4_000_000 * share * activity))
          points.append(
            AnalyticsPoint(day: day, metric: .outputTokens, series: model, value: 120_000 * share * activity))
          points.append(
            AnalyticsPoint(day: day, metric: .cacheWriteTokens, series: model, value: 300_000 * share * activity))
          points.append(AnalyticsPoint(day: day, metric: .costUSD, series: model, value: 38 * share * activity))
          points.append(
            AnalyticsPoint(day: day, metric: .messages, series: model, value: (140 * share * activity).rounded()))
          points.append(
            AnalyticsPoint(day: day, metric: .toolCalls, series: model, value: (260 * share * activity).rounded()))
        }
        points.append(AnalyticsPoint(day: day, metric: .sessions, series: "sessions", value: (6 * activity).rounded()))
      case .codex:
        for (surface, share) in [("cli", 0.55), ("vscode", 0.3), ("web", 0.15)] {
          points.append(
            AnalyticsPoint(day: day, metric: .surfaceUsagePercent, series: surface, value: 40 * share * activity))
          points.append(
            AnalyticsPoint(day: day, metric: .turns, series: surface, value: (90 * share * activity).rounded()))
        }
        for (model, share) in [("gpt-5.3-codex", 0.7), ("gpt-5.3-codex-spark", 0.3)] {
          points.append(AnalyticsPoint(day: day, metric: .modelCredits, series: model, value: 12 * share * activity))
          points.append(
            AnalyticsPoint(day: day, metric: .threads, series: model, value: (14 * share * activity).rounded()))
        }
        points.append(
          AnalyticsPoint(day: day, metric: .skillInvocations, series: "review", value: (5 * activity).rounded()))
        points.append(
          AnalyticsPoint(day: day, metric: .pluginInvocations, series: "github", value: (3 * activity).rounded()))
        points.append(
          AnalyticsPoint(day: day, metric: .codeReviews, series: "reviews", value: (2 * activity).rounded()))
      case .gemini, .cursor, .copilot: break
      }
    }
    if fixture == .longText {
      points = points.map {
        AnalyticsPoint(
          day: $0.day, metric: $0.metric,
          series: "\($0.series)-verification-series-with-a-deliberately-long-identifier", value: $0.value)
      }
    }
    return ProviderAnalytics(provider: provider, points: points, fetchedAt: now)
  }

  static func activity(_ dayIndex: Int) -> Double {
    0.55 + 0.45 * sin(Double(dayIndex) * 1.7 + 0.4) * sin(Double(dayIndex) * 0.6)
  }

  static func claude(now: Date) -> ProviderSnapshot {
    let session = window(
      id: "session", label: "Current session", group: .session, duration: 5 * 3600, offset: 0, pace: 1.15, now: now)
    let weekly = window(
      id: "weekly", label: "All models", group: .weekly, duration: 7 * 86400, offset: 3 * 86400 + 8 * 3600, pace: 0.9,
      now: now)
    let fable = window(
      id: "weekly:fable", label: "Fable", group: .weekly, duration: 7 * 86400, offset: 3 * 86400 + 8 * 3600, pace: 1.05,
      now: now, scope: "Fable")
    let sonnet = window(
      id: "weekly:sonnet", label: "Sonnet", group: .weekly, duration: 7 * 86400, offset: 3 * 86400 + 8 * 3600,
      pace: 0.4, now: now, scope: "Sonnet")
    let monthReset = boundary(now: now, duration: 30 * 86400, offset: 12 * 86400)
    return ProviderSnapshot(
      provider: .claude,
      identity: ProviderIdentity(planName: "Max 20x", tier: "default_claude_max_20x", email: email),
      windows: [session, weekly, fable, sonnet],
      spend: SpendControl(
        enabled: true, canToggle: true, used: Money(amountMinor: 1240, currency: "USD"),
        limit: Money(amountMinor: 5000, currency: "USD"), percent: 24.8, resetsAt: monthReset,
        balance: Money(amountMinor: 3760, currency: "USD"), autoReload: false, canPurchaseCredits: true),
      notices: [Notice(kind: .promotion, text: "Weekly limits are boosted 2x until the next reset.")],
      localUsage: LocalUsage(
        windowTokens: Int(1_840_000 * session.usedPercent / 60), windowCost: 22.4 * session.usedPercent / 60,
        costPerHour: 8.1, todayTokens: 6_200_000, todayCost: 71.3, todayMessages: 214),
      fetchedAt: now
    )
  }

  static func codex(now: Date) -> ProviderSnapshot {
    let session = window(
      id: "session", label: "5-hour", group: .session, duration: 5 * 3600, offset: 0, pace: 0.7, now: now)
    let weekly = window(
      id: "weekly", label: "Weekly", group: .weekly, duration: 7 * 86400, offset: 5 * 86400 + 14 * 3600, pace: 0.95,
      now: now)
    let spark = window(
      id: "additional:gpt-5.3-codex-spark:weekly", label: "GPT-5.3-Codex-Spark Weekly", group: .weekly,
      duration: 7 * 86400, offset: 5 * 86400 + 10 * 3600, pace: 0.2, now: now)
    let review = window(
      id: "code_review", label: "Code review", group: .other, duration: 7 * 86400, offset: 2 * 86400, pace: 0.35,
      now: now)
    return ProviderSnapshot(
      provider: .codex,
      identity: ProviderIdentity(
        planName: "Pro", email: email, subscriptionActiveUntil: now.addingTimeInterval(40 * 86400)),
      windows: [session, weekly, spark, review],
      credits: CreditBalance(
        balance: 42.5, hasCredits: true, approxLocalMessages: 120...260, approxCloudMessages: 60...130),
      spend: SpendControl(enabled: true, limit: Money(amountMinor: 20000, currency: "USD")),
      resetCredits: ResetCredits(available: 1, applicable: 1, totalEarned: 3),
      notices: [Notice(kind: .promotion, text: "Usage limits are doubled through the end of the month.")],
      fetchedAt: now
    )
  }

  static func gemini(now: Date) -> ProviderSnapshot {
    let pro = window(
      id: "model:gemini-2.5-pro", label: "Gemini 2.5 Pro", group: .other, duration: 86400, offset: 7 * 3600, pace: 0.9,
      now: now)
    let flash = window(
      id: "model:gemini-2.5-flash", label: "Gemini 2.5 Flash", group: .other, duration: 86400, offset: 7 * 3600,
      pace: 0.3, now: now)
    return ProviderSnapshot(
      provider: .gemini, identity: ProviderIdentity(planName: "Google AI Pro", email: email), windows: [pro, flash],
      credits: CreditBalance(balance: 1500, hasCredits: true), fetchedAt: now)
  }

  static func cursor(now: Date) -> ProviderSnapshot {
    let plan = window(
      id: "plan", label: "Plan usage", group: .monthly, duration: 30 * 86400, offset: 0, pace: 0.8, now: now)
    let onDemand = window(
      id: "on_demand", label: "On-demand", group: .monthly, duration: 30 * 86400, offset: 0, pace: 0.25, now: now)
    return ProviderSnapshot(
      provider: .cursor, identity: ProviderIdentity(planName: "Pro", email: email), windows: [plan, onDemand],
      spend: SpendControl(
        enabled: true, used: Money(amountMinor: Int(onDemand.usedPercent * 50), currency: "USD"),
        limit: Money(amountMinor: 5000, currency: "USD"), percent: onDemand.usedPercent, resetsAt: onDemand.resetsAt),
      fetchedAt: now)
  }

  static func copilot(now: Date) -> ProviderSnapshot {
    let premium = window(
      id: "premium_interactions", label: "Premium requests", group: .monthly, duration: 30 * 86400, offset: 0,
      pace: 1.1, now: now)
    return ProviderSnapshot(
      provider: .copilot, identity: ProviderIdentity(planName: "Pro", email: "octocat"), windows: [premium],
      notices: [Notice(kind: .info, text: "Chat and completions are unlimited on this plan.")], fetchedAt: now)
  }

  static func window(
    id: String, label: String, group: WindowGroup, duration: TimeInterval, offset: TimeInterval, pace: Double,
    now: Date, scope: String? = nil
  ) -> QuotaWindow {
    let resetsAt = boundary(now: now, duration: duration, offset: offset)
    let start = resetsAt.addingTimeInterval(-duration)
    return QuotaWindow(
      id: id, label: label, group: group,
      usedPercent: min(100, max(0, burned(from: start, to: now, of: duration) * pace * 100)), resetsAt: resetsAt,
      duration: duration, scope: scope)
  }

  /// Quota burns while someone works, so the demo curve climbs through office hours and flattens overnight and at
  /// weekends. A flat ramp reads as synthetic the moment it lands on a chart. Sampling a fixed number of steps keeps
  /// this cheap enough to run for every point the seeded history holds.
  static func burned(from start: Date, to now: Date, of duration: TimeInterval) -> Double {
    let step = max(duration / 48, 900)
    var spent = 0.0
    var total = 0.0
    for offset in stride(from: 0.0, to: duration, by: step) {
      let moment = start.addingTimeInterval(offset)
      let weight = intensity(at: moment)
      total += weight
      if moment <= now { spent += weight }
    }
    return total > 0 ? spent / total : 0
  }

  /// Hour and weekday from the epoch rather than Calendar: the seed asks for this hundreds of thousands of times.
  static func intensity(at date: Date) -> Double {
    let seconds = date.timeIntervalSince1970
    let day = (seconds / 86400).rounded(.down)
    let hour = (seconds - day * 86400) / 3600
    let workday =
      switch hour {
      case 9..<12, 14..<18: 1.0
      case 12..<14: 0.55
      case 18..<22: 0.35
      case 8..<9: 0.5
      default: 0.05
      }
    // 1 January 1970 was a Thursday, so index 0 lands on Sunday
    let weekday = Int(day.truncatingRemainder(dividingBy: 7) + 4).quotientAndRemainder(dividingBy: 7).remainder
    let weekend = weekday == 0 || weekday == 6
    return workday * (weekend ? 0.3 : 1)
  }

  static func boundary(now: Date, duration: TimeInterval, offset: TimeInterval) -> Date {
    let elapsed = now.timeIntervalSince1970 - offset
    return Date(timeIntervalSince1970: (floor(elapsed / duration) + 1) * duration + offset)
  }

  public static func seed(
    _ history: UsageHistoryStore, providers: [ProviderID], now: Date,
    fixture: VerificationProfile.Fixture = .standard
  ) async throws {
    let start = now.addingTimeInterval(-Double(historyDays) * 86400)
    var snapshots: [(ProviderSnapshot, Date)] = []
    for provider in providers {
      for stamp in stride(from: start, to: now, by: seedInterval) {
        snapshots.append((snapshot(provider, now: stamp, fixture: fixture), stamp))
      }
      if let analytics = analytics(provider, now: now, days: historyDays, fixture: fixture) {
        try await history.record(analytics)
      }
    }
    try await history.seed(snapshots)
  }

  private static func longText(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
    let suffix = "verification-fixture-with-a-deliberately-long-identifier"
    let identity = snapshot.identity.map {
      ProviderIdentity(
        planName: "\($0.planName) plan for a large multi-team organization",
        tier: $0.tier.map { "\($0)-\(suffix)" },
        email: "automation-account-with-a-long-address@engineering.example.com",
        organization: "Example Engineering Platform and Developer Experience Organization",
        subscriptionActiveUntil: $0.subscriptionActiveUntil)
    }
    let windows = snapshot.windows.map {
      QuotaWindow(
        id: "\($0.id)-\(suffix)", label: "\($0.label) usage window with a deliberately long model name",
        group: $0.group, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, duration: $0.duration,
        severity: $0.severity, isActive: $0.isActive,
        scope: $0.scope.map { "\($0) model scope with a deliberately long identifier" })
    }
    let notices =
      snapshot.notices + [
        Notice(
          kind: .info,
          text:
            "Verification warning text is intentionally long so wrapping, accessibility values, and panel sizing "
            + "can be checked without exposing account data."
        )
      ]
    return ProviderSnapshot(
      provider: snapshot.provider, identity: identity, windows: windows, credits: snapshot.credits,
      spend: snapshot.spend, resetCredits: snapshot.resetCredits, notices: notices,
      localUsage: snapshot.localUsage, source: snapshot.source, fetchedAt: snapshot.fetchedAt)
  }
}

public struct DemoProvider: UsageProvider {
  public let id: ProviderID
  public let fixture: VerificationProfile.Fixture
  public let pollingPolicy = PollingPolicy(minimumInterval: 60, activeInterval: 60, defaultInterval: 60)

  public init(id: ProviderID, fixture: VerificationProfile.Fixture = .standard) {
    self.id = id
    self.fixture = fixture
  }

  public var credentialDescription: String {
    fixture == .longText
      ? "/private/tmp/token-menu-bar-verification/credentials/\(id.rawValue)"
        + "/account-profile-with-a-deliberately-long-file-name.json"
      : "Demo data"
  }

  public func credentialState(now: Date) -> CredentialState {
    .valid(expiresAt: nil)
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    ProviderFetchResult(
      outcome: .success(DemoData.snapshot(id, now: now, fixture: fixture)),
      analytics: options.includeAnalytics
        ? DemoData.analytics(id, now: now, days: options.analyticsDays, fixture: fixture) : nil,
      recoveryIssue: fixture == .controlAudit ? controlAuditIssue : nil
    )
  }

  private var controlAuditIssue: ProviderRecoveryIssue {
    switch id {
    case .claude:
      ProviderRecoveryIssue(
        kind: .resourceAccess, title: "File access needed",
        detail: "Grant access to the isolated Claude verification directory.",
        action: .grantAccess(id.sandboxResources[0]))
    case .codex:
      ProviderRecoveryIssue(
        kind: .credentialExpired, title: "Codex sign-in expired",
        detail: "Run the deterministic verification command.", action: .copyCommand("codex login"))
    case .gemini:
      ProviderRecoveryIssue(
        kind: .network, title: "Gemini check required",
        detail: "Check the isolated verification provider again.", action: .checkAgain)
    case .cursor:
      ProviderRecoveryIssue(
        kind: .service, title: "Cursor check required",
        detail: "Refresh only the isolated verification provider.", action: .refreshProvider(.cursor))
    case .copilot:
      ProviderRecoveryIssue(
        kind: .accountUnsupported, title: "Copilot administrator check required",
        detail: "Copy the deterministic administrator guidance.", action: .contactAdministrator)
    }
  }
}
