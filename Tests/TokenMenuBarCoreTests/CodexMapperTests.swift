import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func codexUsageDecodesFixture() {
  let response = Fixtures.decode(CodexAPI.UsageResponse.self, "codex_usage")
  #expect(response.planType == "pro")
  #expect(response.rateLimit?.primaryWindow?.limitWindowSeconds == 604_800)
  #expect(response.rateLimit?.secondaryWindow == nil)
  #expect(response.additionalRateLimits?.first?.limitName == "GPT-5.3-Codex-Spark")
  #expect(response.credits?.balance == "0")
  #expect(response.rateLimitResetCredits?.availableCount == 0)
  #expect(response.promo == nil)
}

@Test func codexWindowsCoverPrimaryAdditionalAndCodeReview() {
  var response = Fixtures.decode(CodexAPI.UsageResponse.self, "codex_usage")
  let windows = CodexMapper.windows(response)
  #expect(
    windows.map(\.id) == ["weekly", "additional:gpt-5-3-codex-spark:session", "additional:gpt-5-3-codex-spark:weekly"])
  #expect(windows[0].label == "Weekly")
  #expect(windows[0].usedPercent == 62)
  #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_788_558_705))
  #expect(windows[1].label == "GPT-5.3-Codex-Spark 5-hour")
  #expect(windows[1].scope == "GPT-5.3-Codex-Spark")
  #expect(windows[1].group == .session)
  response = CodexAPI.UsageResponse(
    email: nil, planType: nil,
    rateLimit: .init(
      allowed: false, limitReached: true,
      primaryWindow: .init(usedPercent: 100, limitWindowSeconds: 18000, resetAfterSeconds: 10, resetAt: 1),
      secondaryWindow: .init(usedPercent: 40, limitWindowSeconds: 2_592_000, resetAfterSeconds: nil, resetAt: nil)),
    codeReviewRateLimit: .init(
      allowed: true, limitReached: false,
      primaryWindow: .init(usedPercent: 5, limitWindowSeconds: 3600, resetAfterSeconds: nil, resetAt: nil),
      secondaryWindow: nil),
    additionalRateLimits: nil, credits: nil, spendControl: nil, rateLimitReachedType: nil, promo: nil,
    rateLimitResetCredits: nil
  )
  let more = CodexMapper.windows(response)
  #expect(more.map(\.id) == ["session", "monthly", "code_review:window-3600"])
  #expect(more[0].severity == .critical)
  #expect(more[1].group == .monthly)
  #expect(more[2].label == "Code review 1h")
  #expect(more[2].group == .other)
  #expect(
    CodexMapper.windows(
      CodexAPI.UsageResponse(
        email: nil, planType: nil, rateLimit: nil, codeReviewRateLimit: nil, additionalRateLimits: nil, credits: nil,
        spendControl: nil, rateLimitReachedType: nil, promo: nil, rateLimitResetCredits: nil)
    ).isEmpty)
}

@Test func codexWindowDefaultsToSessionWithoutDuration() {
  let limit = CodexAPI.RateLimit(
    allowed: nil, limitReached: nil,
    primaryWindow: .init(usedPercent: 3, limitWindowSeconds: nil, resetAfterSeconds: nil, resetAt: nil),
    secondaryWindow: nil)
  let windows = CodexMapper.rateLimitWindows(limit, idPrefix: "", labelPrefix: "")
  #expect(windows.map(\.id) == ["session"])
  #expect(windows[0].duration == 18000)
}

@Test func codexCreditsMap() {
  let credits = CodexMapper.credits(Fixtures.decode(CodexAPI.UsageResponse.self, "codex_usage").credits)!
  #expect(credits.balance == 0)
  #expect(!credits.hasCredits)
  #expect(credits.approxLocalMessages == 0...0)
  #expect(CodexMapper.credits(nil) == nil)
  let odd = CodexMapper.credits(
    .init(
      hasCredits: true, unlimited: true, overageLimitReached: nil, balance: "12.5", approxLocalMessages: [5, 2],
      approxCloudMessages: nil))!
  #expect(odd.balance == Decimal(string: "12.5"))
  #expect(odd.unlimited)
  #expect(odd.approxLocalMessages == nil)
  #expect(odd.approxCloudMessages == nil)
}

@Test func codexSpendControlMaps() {
  #expect(CodexMapper.spend(nil) == nil)
  #expect(CodexMapper.spend(.init(reached: false, individualLimit: nil)) == nil)
  let spend = CodexMapper.spend(
    .init(
      reached: true,
      individualLimit: .init(limit: "100", used: "42.5", remaining: "57.5", usedPercent: 42.5, resetAt: 1_788_558_705)))!
  #expect(spend.used == Money(amountMinor: 4250, currency: "USD"))
  #expect(spend.limit == Money(amountMinor: 10000, currency: "USD"))
  #expect(spend.percent == 42.5)
  #expect(spend.limitReached)
  #expect(spend.resetsAt == Date(timeIntervalSince1970: 1_788_558_705))
  #expect(
    CodexMapper.spend(
      .init(reached: nil, individualLimit: .init(limit: "x", used: nil, remaining: nil, usedPercent: nil, resetAt: nil))
    )?.limit == nil)
}

@Test func codexResetCreditsMap() {
  #expect(CodexMapper.resetCredits(nil) == nil)
  let summary = Fixtures.decode(CodexAPI.ResetCreditsSummary.self, "codex_reset_credits")
  #expect(
    CodexMapper.resetCredits(summary)
      == ResetCredits(available: 0, applicable: 0, totalEarned: 0, immediatePurchaseEligible: false))
  #expect(
    CodexMapper.resetCredits(
      .init(
        availableCount: 2, applicableAvailableCount: nil, totalEarnedCount: nil, immediateResetPurchaseEligible: nil))?
      .applicable == 2)
  #expect(
    CodexMapper.resetCredits(
      .init(
        availableCount: nil, applicableAvailableCount: nil, totalEarnedCount: nil, immediateResetPurchaseEligible: true)
    )?.available == 0)
}

@Test func codexNoticesCoverLimitSpendPromoAndOverage() {
  #expect(CodexMapper.notices(Fixtures.decode(CodexAPI.UsageResponse.self, "codex_usage")).isEmpty)
  let typed = CodexAPI.UsageResponse(
    email: nil, planType: nil,
    rateLimit: .init(allowed: false, limitReached: true, primaryWindow: nil, secondaryWindow: nil),
    codeReviewRateLimit: nil, additionalRateLimits: nil,
    credits: .init(
      hasCredits: nil, unlimited: nil, overageLimitReached: true, balance: nil, approxLocalMessages: nil,
      approxCloudMessages: nil),
    spendControl: .init(reached: true, individualLimit: nil),
    rateLimitReachedType: .object(["type": .string("workspace_owner_credits_depleted")]),
    promo: .object(["text": .string("Double limits this week")]), rateLimitResetCredits: nil
  )
  let notices = CodexMapper.notices(typed)
  #expect(notices.map(\.kind) == [.limitReached, .spendControl, .promotion, .spendControl])
  #expect(notices[0].text == "Limit reached: Workspace Owner Credits Depleted.")
  #expect(notices[2].text == "Double limits this week")
  let untyped = CodexAPI.UsageResponse(
    email: nil, planType: nil,
    rateLimit: .init(allowed: false, limitReached: true, primaryWindow: nil, secondaryWindow: nil),
    codeReviewRateLimit: nil, additionalRateLimits: nil,
    credits: nil, spendControl: nil, rateLimitReachedType: .null, promo: .object(["title": .string("Promo")]),
    rateLimitResetCredits: nil
  )
  let fallback = CodexMapper.notices(untyped)
  #expect(fallback.map(\.text) == ["Usage limit reached.", "Promo"])
  let summary = CodexAPI.UsageResponse(
    email: nil, planType: nil, rateLimit: nil, codeReviewRateLimit: nil, additionalRateLimits: nil, credits: nil,
    spendControl: nil, rateLimitReachedType: .string("odd"), promo: .object(["pct": .number(2)]),
    rateLimitResetCredits: nil)
  #expect(CodexMapper.notices(summary).map(\.text) == ["Limit reached: Odd.", "pct: 2"])
}

private let planCases: [(String?, String)] = [
  (nil, "ChatGPT"), ("", "ChatGPT"), ("pro", "Pro"), ("prolite", "Pro Lite"), ("plus", "Plus"), ("go", "Go"),
  ("free", "Free"),
  ("team", "Team"), ("free_workspace", "Team"), ("business", "Business"), ("self_serve_business_prolite", "Business"),
  ("enterprise", "Enterprise"), ("edu", "Education"), ("education", "Education"), ("k12", "K12"),
  ("quorum_plus", "Quorum Plus"),
]

@Test(arguments: planCases)
func codexPlanNames(planType: String?, expected: String) {
  #expect(CodexMapper.planName(planType) == expected)
}

@Test func codexIdentityMergesResponseAndAuth() {
  let auth = CodexAuth(document: Fixtures.json("codex_auth"))!
  let response = Fixtures.decode(CodexAPI.UsageResponse.self, "codex_usage")
  let identity = CodexMapper.identity(response, auth: auth)
  #expect(identity.planName == "Pro")
  #expect(identity.tier == "pro")
  #expect(identity.email == "user@example.com")
  #expect(identity.subscriptionActiveUntil == auth.subscriptionActiveUntil)
  #expect(CodexMapper.identity(nil, auth: auth).planName == "Pro")
  #expect(CodexMapper.identity(nil, auth: nil) == ProviderIdentity(planName: "ChatGPT"))
}

@Test func codexAnalyticsTokenUsageBreakdown() {
  let rows = Fixtures.decode(CodexAPI.DailyRows.self, "codex_daily_token_usage")
  let points = CodexMapper.analytics(.tokenUsage, rows: rows.data)
  let last = points.filter { $0.day == "2026-08-29" }
  #expect(last.first { $0.metric == .surfaceUsagePercent && $0.series == "cli" }?.value.rounded() == 38)
  #expect(last.first { $0.metric == .modelCredits && $0.series == "gpt-5.6-sol" } != nil)
  #expect(Set(last.map(\.metric)) == [.surfaceUsagePercent, .modelCredits])
  #expect(CodexMapper.analytics(.tokenUsage, rows: [.object(["models": .array([])])]).isEmpty)
}

@Test func codexAnalyticsWorkspaceCounts() {
  let rows = Fixtures.decode(CodexAPI.DailyRows.self, "codex_daily_workspace_usage")
  let points = CodexMapper.analytics(.workspaceCounts, rows: rows.data)
  let day = points.filter { $0.day == "2026-08-29" }
  #expect(day.first { $0.metric == .inputTokens }?.value == 23_112_562)
  #expect(day.first { $0.metric == .cachedInputTokens }?.value == 1_218_464_768)
  #expect(day.first { $0.metric == .outputTokens }?.value == 2_018_632)
  #expect(day.contains { $0.metric == .credits && $0.series == "surface:CODEX_CLI" })
  #expect(points.contains { $0.metric == .turns && $0.series.hasPrefix("model:") })
  let sparse = CodexMapper.analytics(
    .workspaceCounts,
    rows: [.object(["date": .string("2026-01-01"), "models": .array([.object(["turns": .number(1)])])])])
  #expect(sparse.isEmpty)
}

@Test func codexAnalyticsSkillsPluginsAndCodeReview() {
  let skills = CodexMapper.analytics(.skills, rows: Fixtures.decode(CodexAPI.DailyRows.self, "codex_daily_skills").data)
  #expect(skills.contains { $0.day == "2026-08-29" && $0.series == "Simp" && $0.value == 38 })
  let plugins = CodexMapper.analytics(
    .plugins, rows: Fixtures.decode(CodexAPI.DailyRows.self, "codex_daily_plugins").data)
  #expect(plugins.contains { $0.series == "github" && $0.metric == .pluginInvocations })
  let review = CodexMapper.analytics(
    .codeReview, rows: [.object(["date": .string("2026-08-01"), "reviews": .number(3), "note": .string("x")])])
  #expect(review == [AnalyticsPoint(day: "2026-08-01", metric: .codeReviews, series: "reviews", value: 3)])
  let unnamed = CodexMapper.analytics(
    .skills,
    rows: [
      .object([
        "date": .string("d"),
        "skill_usage_overviews": .array([
          .object(["skill_name": .string("raw"), "invocation_counts": .number(1)]),
          .object(["invocation_counts": .number(2)]),
        ]),
      ])
    ])
  #expect(unnamed.map(\.series) == ["raw"])
  let unnamedPlugin = CodexMapper.analytics(
    .plugins,
    rows: [
      .object([
        "date": .string("d"),
        "plugin_usage_overviews": .array([
          .object(["display_name": .string("Disp"), "invocation_counts": .number(1)]), .object([:]),
        ]),
      ])
    ])
  #expect(unnamedPlugin.map(\.series) == ["Disp"])
}

@Test func codexCreditEventsTolerateShapes() {
  let rows: [JSONValue] = [
    .object([
      "id": .string("e1"), "date": .string("2026-08-01"), "service": .string("Codex"), "credits_used": .number(3),
    ]),
    .object(["created_at": .string("2026-08-02T10:00:00Z"), "product": .string("Review"), "credits": .number(1.5)]),
    .object(["timestamp": .string("2026-08-03T00:00:00Z"), "amount": .number(2)]),
    .object(["note": .string("no date")]),
  ]
  let events = CodexMapper.creditEvents(rows)
  #expect(events.map(\.id) == ["e1", "2026-08-02T10:00:00Z-1", "2026-08-03T00:00:00Z-2"])
  #expect(events.map(\.service) == ["Codex", "Review", "Codex"])
  #expect(events.map(\.creditsUsed) == [3, 1.5, 2])
  #expect(CodexMapper.creditEvents(Fixtures.decode(CodexAPI.DailyRows.self, "codex_credit_events").data).isEmpty)
}

@Test func codexAnalyticsURLsCarryExpectedQueries() {
  let skills = CodexAPI.Analytics.skills.url(start: "2026-08-01", end: "2026-08-29")
  #expect(
    skills.absoluteString
      == "https://chatgpt.com/backend-api/wham/analytics/daily-skill-usage-metrics?start_date=2026-08-01&end_date=2026-08-29&group_by=day&workspace_user=true&top_skill_limit=20"
  )
  #expect(CodexAPI.Analytics.plugins.url(start: "a", end: "b").query?.contains("top_plugin_limit=20") == true)
  #expect(CodexAPI.Analytics.tokenUsage.url(start: "a", end: "b").query == "start_date=a&end_date=b&group_by=day")
  #expect(CodexAPI.Analytics.codeReview.url(start: "a", end: "b").query?.hasSuffix("workspace_user=true") == true)
  #expect(CodexAPI.headers(token: "t", accountID: nil)["ChatGPT-Account-Id"] == nil)
  #expect(CodexAPI.headers(token: "t", accountID: "a")["ChatGPT-Account-Id"] == "a")
}
