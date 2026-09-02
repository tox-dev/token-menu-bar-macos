import Foundation
import Testing
import TokenMenuBarCore

@MainActor
private func codexFetch(
  usage: StubTransport.Response, analytics: Bool = false, stub: (StubTransport) -> Void = { _ in }
) async -> (result: ProviderFetchResult, transport: StubTransport) {
  let transport = StubTransport()
  transport.on(path: "/wham/usage", usage)
  transport.on(path: "rate-limit-reset-credits", .json("codex_reset_credits"))
  stub(transport)
  let provider = codexProvider(MemoryCodexStore(validCodex), transport: transport)
  let options = FetchOptions(includeAnalytics: analytics, analyticsDays: 30)
  return (await provider.fetch(now: fixedNow, options: options), transport)
}

@MainActor
private func codexSnapshot(usage: StubTransport.Response) async -> ProviderSnapshot? {
  guard case .success(let snapshot) = await codexFetch(usage: usage).result.outcome else {
    Issue.record("expected a snapshot")
    return nil
  }
  return snapshot
}

@Test func codexReportsPrimaryAdditionalAndCodeReviewWindows() async throws {
  let snapshot = try #require(await codexSnapshot(usage: .json("codex_usage")))
  #expect(
    snapshot.windows.map(\.id) == [
      "additional:gpt-5-3-codex-spark:session", "additional:gpt-5-3-codex-spark:weekly", "weekly",
    ])
  #expect(snapshot.window("weekly")?.label == "Weekly")
  #expect(snapshot.window("weekly")?.usedPercent == 62)
  #expect(snapshot.window("weekly")?.resetsAt == Date(timeIntervalSince1970: 1_788_558_705))
  let spark = try #require(snapshot.window("additional:gpt-5-3-codex-spark:session"))
  #expect(spark.label == "GPT-5.3-Codex-Spark 5-hour")
  #expect(spark.scope == "GPT-5.3-Codex-Spark")
  #expect(spark.group == .session)
}

@Test func codexReportsMonthlyAndCodeReviewWindows() async throws {
  let usage = #"""
    {"rate_limit": {"allowed": false, "limit_reached": true,
      "primary_window": {"used_percent": 100, "limit_window_seconds": 18000, "reset_after_seconds": 10, "reset_at": 1},
      "secondary_window": {"used_percent": 40, "limit_window_seconds": 2592000}},
     "code_review_rate_limit": {"allowed": true, "limit_reached": false,
      "primary_window": {"used_percent": 5, "limit_window_seconds": 3600}}}
    """#
  let snapshot = try #require(await codexSnapshot(usage: .text(usage)))
  #expect(snapshot.windows.map(\.id) == ["session", "monthly", "code_review:window-3600"])
  #expect(snapshot.window("session")?.severity == .critical)
  #expect(snapshot.window("monthly")?.group == .monthly)
  #expect(snapshot.window("code_review:window-3600")?.label == "Code review 1h")
  #expect(snapshot.window("code_review:window-3600")?.group == .other)
}

@Test func codexReportsNoWindowsWithoutRateLimits() async throws {
  let snapshot = try #require(await codexSnapshot(usage: .text("{}")))
  #expect(snapshot.windows.isEmpty)
}

@Test func codexTreatsAWindowWithoutADurationAsTheSession() async throws {
  let usage = #"{"rate_limit": {"primary_window": {"used_percent": 3}}}"#
  let snapshot = try #require(await codexSnapshot(usage: .text(usage)))
  #expect(snapshot.windows.map(\.id) == ["session"])
  #expect(snapshot.windows[0].duration == 18000)
}

@Test func codexReportsTheCreditBalance() async throws {
  let snapshot = try #require(await codexSnapshot(usage: .json("codex_usage")))
  #expect(snapshot.credits?.balance == 0)
  #expect(snapshot.credits?.hasCredits == false)
  #expect(snapshot.credits?.approxLocalMessages == 0...0)
}

@Test func codexReportsUnlimitedCreditsWithoutAMessageRange() async throws {
  let usage = #"""
    {"credits": {"has_credits": true, "unlimited": true, "balance": "12.5", "approx_local_messages": [5, 2]}}
    """#
  let snapshot = try #require(await codexSnapshot(usage: .text(usage)))
  #expect(snapshot.credits?.balance == Decimal(string: "12.5"))
  #expect(snapshot.credits?.unlimited == true)
  #expect(snapshot.credits?.approxLocalMessages == nil)
  #expect(snapshot.credits?.approxCloudMessages == nil)
}

@Test func codexReportsTheIndividualSpendLimit() async throws {
  let usage = #"""
    {"spend_control": {"reached": true, "individual_limit": {"limit": "100", "used": "42.5", "remaining": "57.5",
      "used_percent": 42.5, "reset_at": 1788558705}}}
    """#
  let snapshot = try #require(await codexSnapshot(usage: .text(usage)))
  let spend = try #require(snapshot.spend)
  #expect(spend.used == Money(amountMinor: 4250, currency: "USD"))
  #expect(spend.limit == Money(amountMinor: 10000, currency: "USD"))
  #expect(spend.percent == 42.5)
  #expect(spend.limitReached)
  #expect(spend.resetsAt == Date(timeIntervalSince1970: 1_788_558_705))
}

@Test(
  arguments: [
    "{}", #"{"spend_control": {"reached": false}}"#,
  ])
func codexReportsNoSpendWithoutALimit(usage: String) async throws {
  let snapshot = try #require(await codexSnapshot(usage: .text(usage)))
  #expect(snapshot.spend == nil)
}

@Test func codexIgnoresAnUnreadableSpendLimit() async throws {
  let usage = #"{"spend_control": {"individual_limit": {"limit": "x"}}}"#
  let snapshot = try #require(await codexSnapshot(usage: .text(usage)))
  #expect(snapshot.spend?.limit == nil)
}

@Test func codexReportsTheResetCreditsSummary() async throws {
  let snapshot = try #require(await codexSnapshot(usage: .json("codex_usage")))
  #expect(
    snapshot.resetCredits == ResetCredits(available: 0, applicable: 0, totalEarned: 0, immediatePurchaseEligible: false)
  )
}

@Test func codexFallsBackToTheAvailableCountForApplicableCredits() async throws {
  let transport = StubTransport()
  transport.on(path: "/wham/usage", .json("codex_usage"))
  transport.on(path: "rate-limit-reset-credits", .text(#"{"available_count": 2}"#))
  let provider = codexProvider(MemoryCodexStore(validCodex), transport: transport)
  guard case .success(let snapshot) = await provider.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected a snapshot")
    return
  }
  #expect(snapshot.resetCredits?.applicable == 2)
}

@Test func codexNoticesCoverLimitSpendPromoAndOverage() async throws {
  let usage = #"""
    {"rate_limit": {"allowed": false, "limit_reached": true},
     "credits": {"overage_limit_reached": true},
     "spend_control": {"reached": true},
     "rate_limit_reached_type": {"type": "workspace_owner_credits_depleted"},
     "promo": {"text": "Double limits this week"}}
    """#
  let snapshot = try #require(await codexSnapshot(usage: .text(usage)))
  let notices = snapshot.notices
  #expect(notices.map(\.kind) == [.limitReached, .spendControl, .promotion, .spendControl])
  #expect(notices[0].text == "Limit reached: Workspace Owner Credits Depleted.")
  #expect(notices[2].text == "Double limits this week")
}

@Test func codexNoticesReadAPromoAndALimitInWhateverShapeTheyArrive() async throws {
  let untyped = #"""
    {"rate_limit": {"allowed": false, "limit_reached": true}, "rate_limit_reached_type": null,
     "promo": {"title": "Promo"}}
    """#
  let plain = try #require(await codexSnapshot(usage: .text(untyped)))
  #expect(plain.notices.map(\.text) == ["Usage limit reached.", "Promo"])
  let odd = #"{"rate_limit_reached_type": "odd", "promo": {"pct": 2}}"#
  let strange = try #require(await codexSnapshot(usage: .text(odd)))
  #expect(strange.notices.map(\.text) == ["Limit reached: Odd.", "pct: 2"])
}

@Test func codexReportsNoNoticesOnAHealthyAccount() async throws {
  let snapshot = try #require(await codexSnapshot(usage: .json("codex_usage")))
  #expect(snapshot.notices.isEmpty)
}

@Test(
  arguments: [
    ("", "ChatGPT"), ("pro", "Pro"), ("prolite", "Pro Lite"), ("plus", "Plus"),
    ("go", "Go"), ("free", "Free"), ("team", "Team"), ("free_workspace", "Team"), ("business", "Business"),
    ("self_serve_business_prolite", "Business"), ("enterprise", "Enterprise"), ("edu", "Education"),
    ("education", "Education"), ("k12", "K12"), ("quorum_plus", "Quorum Plus"),
  ])
func codexNamesThePlanFromItsType(planType: String, expected: String) async throws {
  let snapshot = try #require(await codexSnapshot(usage: .text(#"{"plan_type": "\#(planType)"}"#)))
  #expect(snapshot.identity?.planName == expected)
}

@Test func codexFallsBackToThePlanInTheToken() async throws {
  let snapshot = try #require(await codexSnapshot(usage: .text("{}")))
  #expect(snapshot.identity?.planName == "Pro")
}

@Test func codexIdentityMergesTheResponseAndTheToken() async throws {
  let snapshot = try #require(await codexSnapshot(usage: .json("codex_usage")))
  let identity = try #require(snapshot.identity)
  #expect(identity.planName == "Pro")
  #expect(identity.tier == "pro")
  #expect(identity.email == "user@example.com")
  #expect(identity.subscriptionActiveUntil == CodexAuth(document: Fixtures.codexAuth())?.subscriptionActiveUntil)
}

@MainActor
private func codexAnalytics(_ stub: @escaping (StubTransport) -> Void = { _ in }) async -> ProviderAnalytics? {
  let (result, _) = await codexFetch(
    usage: .json("codex_usage"), analytics: true,
    stub: { transport in
      stub(transport)
      stubCodexAnalytics(transport)
    })
  return result.analytics
}

@Test func codexAnalyticsCarryUsageBySurfaceAndModel() async throws {
  let points = try #require(await codexAnalytics()).points.filter { $0.day == "2026-08-29" }
  #expect(points.first { $0.metric == .surfaceUsagePercent && $0.series == "cli" }?.value.rounded() == 38)
  #expect(points.contains { $0.metric == .modelCredits && $0.series == "gpt-5.6-sol" })
}

@Test func codexAnalyticsSkipARowWithoutUsage() async throws {
  let points = try #require(
    await codexAnalytics { $0.on(path: "daily-token-usage-breakdown", .text(#"{"data": [{"models": []}]}"#)) })
  #expect(!points.points.contains { $0.metric == .modelCredits })
}

@Test func codexAnalyticsCarryWorkspaceTokenCounts() async throws {
  let points = try #require(await codexAnalytics()).points
  let day = points.filter { $0.day == "2026-08-29" }
  #expect(day.first { $0.metric == .inputTokens }?.value == 23_112_562)
  #expect(day.first { $0.metric == .cachedInputTokens }?.value == 1_218_464_768)
  #expect(day.first { $0.metric == .outputTokens }?.value == 2_018_632)
  #expect(day.contains { $0.metric == .credits && $0.series == "surface:CODEX_CLI" })
  #expect(points.contains { $0.metric == .turns && $0.series.hasPrefix("model:") })
  #expect(points.contains { $0.day == "2026-08-28" && $0.metric == .turns && $0.series == "total" && $0.value == 42 })
}

@Test func codexAnalyticsSkipAWorkspaceRowWithoutTotals() async throws {
  let sparse = #"{"data": [{"date": "2026-01-01", "models": [{"turns": 1}]}]}"#
  let points = try #require(await codexAnalytics { $0.on(path: "daily-workspace-usage-counts", .text(sparse)) })
  #expect(!points.points.contains { $0.metric == .inputTokens })
}

@Test func codexAnalyticsCarrySkillsPluginsAndCodeReviews() async throws {
  let points = try #require(await codexAnalytics()).points
  #expect(points.contains { $0.day == "2026-08-29" && $0.series == "Simp" && $0.value == 38 })
  let github = points.filter {
    $0.day == "2026-08-07" && $0.series == "github" && $0.metric == .pluginInvocations
  }
  #expect(github.map(\.value) == [10])
  let review = #"{"data": [{"date": "2026-08-01", "reviews": 3, "note": "x"}]}"#
  let reviewed = try #require(await codexAnalytics { $0.on(path: "daily-code-review-metrics", .text(review)) })
  #expect(
    reviewed.points.contains(AnalyticsPoint(day: "2026-08-01", metric: .codeReviews, series: "reviews", value: 3)))
}

@Test func codexAnalyticsSkipASkillOrPluginWithoutAName() async throws {
  let skills = #"""
    {"data": [{"date": "2026-08-29", "skill_usage_overviews": [{"skill_name": "raw", "invocation_counts": 1},
     {"invocation_counts": 2}]}]}
    """#
  let plugins = #"""
    {"data": [{"date": "2026-08-29",
      "plugin_usage_overviews": [{"display_name": "Disp", "invocation_counts": 1}, {}]}]}
    """#
  let points = try #require(
    await codexAnalytics {
      $0.on(path: "daily-skill-usage-metrics", .text(skills))
      $0.on(path: "daily-plugin-usage-metrics", .text(plugins))
    }
  ).points
  #expect(points.filter { $0.metric == .skillInvocations }.map(\.series) == ["raw"])
  #expect(points.filter { $0.metric == .pluginInvocations }.map(\.series) == ["Disp"])
}

@Test func codexCreditEventsTolerateEveryShapeTheAPIReturns() async throws {
  let rows = #"""
    {"data": [{"id": "e1", "date": "2026-08-01", "service": "Codex", "credits_used": 3},
     {"created_at": "2026-08-02T10:00:00Z", "product": "Review", "credits": 1.5},
     {"timestamp": "2026-08-03T00:00:00Z", "amount": 2}, {"note": "no date"}]}
    """#
  let analytics = try #require(await codexAnalytics { $0.on(path: "credit-usage-events", .text(rows)) })
  #expect(analytics.creditEvents.map(\.id) == ["e1", "2026-08-02T10:00:00Z-1", "2026-08-03T00:00:00Z-2"])
  #expect(analytics.creditEvents.map(\.service) == ["Codex", "Review", "Codex"])
  #expect(analytics.creditEvents.map(\.creditsUsed) == [3, 1.5, 2])
}

@Test func codexAsksEachAnalyticsEndpointForTheRangeItNeeds() async throws {
  let (_, transport) = await codexFetch(usage: .json("codex_usage"), analytics: true, stub: stubCodexAnalytics)
  let skills = try #require(transport.requests(matching: "daily-skill-usage-metrics").first?.url)
  #expect(skills.query?.contains("group_by=day&workspace_user=true&top_skill_limit=20") == true)
  #expect(
    transport.requests(matching: "daily-plugin-usage-metrics").first?.url?.query?.contains("top_plugin_limit=20")
      == true)
  #expect(
    transport.requests(matching: "daily-token-usage-breakdown").first?.url?.query?.hasSuffix("group_by=day") == true)
  #expect(
    transport.requests(matching: "daily-code-review-metrics").first?.url?.query?.hasSuffix("workspace_user=true")
      == true)
  #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct" })
}
