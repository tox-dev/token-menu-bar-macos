import Foundation

public actor CodexProvider: UsageProvider {
  public static let resetCreditsTTL: TimeInterval = 15 * 60
  public static let resetCreditsFailureTTL: TimeInterval = 5 * 60

  public nonisolated let id: ProviderID = .codex
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .codex)
  private let auth: any CodexAuthStore
  private let rollouts: CodexRolloutReader?
  private var discoveredRollouts: (root: URL, reader: CodexRolloutReader)?
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @MainActor @Sendable () -> Bool
  private let analyticsWatermarks: CodexAnalyticsWatermarkStore
  private var activeAccount: String?
  private var resetCreditsCache: CachedResetCredits?
  private var resetCreditsTask: Task<Result<ResetCredits, APIError>, Never>?
  private var analyticsCoverage: [CodexAPI.Analytics: CodexAnalyticsCoverage] = [:]
  private var acceptedWindows: [String: QuotaWindow] = [:]
  private var pendingResets: Set<String> = []
  private var pendingCredentialSave: PendingCredentialSave<CodexAuth>?
  private var refreshRejection = RefreshRejection<CodexAuth>()

  public init(
    auth: any CodexAuthStore,
    rollouts: CodexRolloutReader?,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @MainActor @Sendable () -> Bool,
    analyticsWatermarkPersistence: CodexAnalyticsWatermarkPersistence
  ) {
    self.auth = auth
    self.rollouts = rollouts
    self.client = client
    self.log = log
    self.allowRefresh = allowRefresh
    analyticsWatermarks = CodexAnalyticsWatermarkStore(persistence: analyticsWatermarkPersistence)
  }

  public nonisolated var credentialDescription: String {
    auth.description
  }

  public func resetAnalyticsHistory() async {
    analyticsWatermarks.clear()
    analyticsCoverage = [:]
  }

  public nonisolated func credentialState(now: Date) -> CredentialState {
    do {
      guard let stored = try auth.load() else { return .missing("no Codex sign-in found") }
      return stored.state(now: now)
    } catch {
      return .missing(CredentialReadFailure(source: auth.source, error: error).detail)
    }
  }

  public func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    if let pendingCredentialSave {
      return .from(
        pendingCredentialSave.credential.state(now: now), source: pendingCredentialSave.source,
        expected: id.setup.credentialSources)
    }
    return auth.credentialHealth(now: now)
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let resolved: ResolvedCredential<CodexAuth>
    do {
      resolved = try resolveCredential(
        pending: &pendingCredentialSave,
        provider: id,
        load: { try auth.loadWithSource().map { (credential: $0.auth, source: $0.source) } },
        save: { try auth.save($0, replacing: $1) })
      guard resolved.credential != nil else {
        return await fallback(
          reason: "No Codex credentials. \(id.loginHint)", auth: nil, now: now, notAuthenticated: true,
          credentialStatus: .missing("no Codex sign-in found", provider: id))
      }
    } catch {
      let failure = CredentialReadFailure(source: auth.source, error: error)
      return await fallback(
        reason: "Cannot read Codex credentials: \(failure.detail)", auth: nil, now: now, notAuthenticated: true,
        credentialStatus: .unreadable(error, provider: id, fallbackSource: auth.source))
    }
    let stored = resolved.credential!
    var recoveryIssue = resolved.issue
    var active = stored
    var activeSource = resolved.source!
    guard stored.supportsUsageAPI else {
      return await fallback(
        reason: "Codex API-key sign-in has no usage endpoint. Sign in with the Codex CLI to view usage.",
        auth: stored, now: now, notAuthenticated: true, recoveryIssue: recoveryIssue,
        credentialStatus: .resolved(stored.state(now: now), provider: id, source: activeSource))
    }
    if case .expired = stored.state(now: now) {
      guard await allowRefresh() else {
        return await fallback(
          reason: "Codex token expired. \(id.loginHint)", auth: stored, now: now, notAuthenticated: true,
          credentialStatus: .resolved(stored.state(now: now), provider: id, source: activeSource))
      }
      do {
        let refreshed = try await refresh(stored, source: activeSource, now: now)
        active = refreshed.credential
        activeSource = refreshed.source
        recoveryIssue = refreshed.issue
      } catch {
        return await fallback(
          reason: "Codex token refresh failed: \(error.message)", auth: stored, now: now, notAuthenticated: true,
          recoveryIssue: recoveryIssue,
          credentialStatus: .resolved(stored.state(now: now), provider: id, source: activeSource))
      }
    }
    let credentialStatus = ProviderCredentialStatus.resolved(
      active.state(now: now), provider: id, source: activeSource)
    let account = active.accountFingerprint
    activate(account: account, now: now, retentionDays: options.analyticsDays)
    let headers = CodexAPI.headers(token: active.accessToken, accountID: active.accountID)
    let response: CodexAPI.UsageResponse
    do {
      response = try await client.getJSON(
        CodexAPI.UsageResponse.self, CodexAPI.usageURL, headers: headers, operation: "codex.usage")
    } catch {
      let outcome = ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint)
      switch outcome {
      case .failed, .rateLimited:
        return ProviderFetchResult(outcome: outcome, recoveryIssue: recoveryIssue)
          .withCredentialStatus(credentialStatus)
      default: break
      }
      return await fallback(
        reason: outcome.errorDescription!, auth: active, now: now,
        notAuthenticated: error.isAuthenticationFailure, recoveryIssue: recoveryIssue,
        credentialStatus: credentialStatus)
    }
    var warnings: [String] = []
    if response.droppedAdditionalCount > 0 {
      warnings.append(
        "Skipped \(response.droppedAdditionalCount) unreadable Codex model limits. Other reported quotas remain visible."
      )
    }
    let (resetCredits, resetCreditsWarning) = await resetCredits(
      response: response, account: account, headers: headers, now: now)
    if let resetCreditsWarning { warnings.append(resetCreditsWarning) }
    let snapshot = ProviderSnapshot(
      provider: .codex,
      identity: CodexMapper.identity(response, auth: active),
      windows: confirmResets(CodexMapper.windows(response), now: now),
      credits: CodexMapper.credits(response.credits),
      spend: CodexMapper.spend(response.spendControl, now: now),
      resetCredits: resetCredits,
      notices: CodexMapper.notices(response),
      fetchedAt: now, accountFingerprint: account
    )
    var analytics: ProviderAnalytics?
    if options.includeAnalytics {
      let (result, analyticsWarnings) = await fetchAnalytics(
        account: account, headers: headers, now: now, days: options.analyticsDays)
      analytics = result
      warnings += analyticsWarnings
    }
    return ProviderFetchResult(
      outcome: .success(snapshot), warnings: warnings, analytics: analytics, recoveryIssue: recoveryIssue
    ).withCredentialStatus(credentialStatus)
  }

  private func resetCredits(
    response: CodexAPI.UsageResponse,
    account: String,
    headers: [String: String],
    now: Date
  ) async -> (ResetCredits?, String?) {
    let inline = CodexMapper.resetCredits(response.rateLimitResetCredits)
    if let summary = response.rateLimitResetCredits,
      summary.totalEarnedCount != nil,
      summary.immediateResetPurchaseEligible != nil,
      let inline
    {
      if activeAccount == account {
        resetCreditsCache = CachedResetCredits(
          value: inline, warning: nil, expiresAt: now.addingTimeInterval(Self.resetCreditsTTL))
      }
      return (inline, nil)
    }
    if activeAccount == account, let cached = resetCreditsCache, cached.expiresAt > now {
      return (cached.value ?? inline, cached.warning)
    }
    let stale = resetCreditsCache?.value ?? inline
    let task: Task<Result<ResetCredits, APIError>, Never>
    if activeAccount == account, let current = resetCreditsTask {
      task = current
    } else {
      task = Task { [client] in await Self.fetchResetCredits(client, headers: headers) }
      if activeAccount == account { resetCreditsTask = task }
    }
    let result = await task.value
    if activeAccount == account { resetCreditsTask = nil }
    switch result {
    case .success(let value):
      if activeAccount == account {
        resetCreditsCache = CachedResetCredits(
          value: value, warning: nil, expiresAt: now.addingTimeInterval(Self.resetCreditsTTL))
      }
      return (value, nil)
    case .failure(let error):
      let warning = "Reset credits unavailable: \(error.message)"
      if activeAccount == account {
        resetCreditsCache = CachedResetCredits(
          value: stale, warning: warning, expiresAt: now.addingTimeInterval(Self.resetCreditsFailureTTL))
      }
      return (stale, warning)
    }
  }

  private func fetchAnalytics(
    account: String, headers: [String: String], now: Date, days: Int
  ) async -> (ProviderAnalytics?, [String]) {
    let end = DayStamp.string(now)
    let defaultStart = DayStamp.string(now.addingTimeInterval(-Double(max(days - 1, 0)) * 86400))
    let cutoffDate = DayStamp.date(defaultStart)!
    let endDate = DayStamp.date(end)!.addingTimeInterval(86400)
    analyticsCoverage = analyticsCoverage.filter { _, coverage in
      coverage.start <= coverage.through && coverage.through >= defaultStart && coverage.through <= end
    }.mapValues { coverage in
      CodexAnalyticsCoverage(start: max(coverage.start, defaultStart), through: coverage.through)
    }
    var points: [AnalyticsPoint] = []
    var warnings: [String] = []
    var starts: [CodexAPI.Analytics: String] = [:]
    var successful: Set<CodexAPI.Analytics> = []
    await withTaskGroup(of: (CodexAPI.Analytics, Result<CodexAPI.DailyRows, APIError>).self) { group in
      for endpoint in CodexAPI.Analytics.allCases {
        let start = analyticsStart(endpoint: endpoint, fallback: defaultStart)
        starts[endpoint] = start
        group.addTask { [client] in
          (
            endpoint,
            await Self.rows(
              client, endpoint.url(start: start, end: end), headers: headers, operation: "codex.\(endpoint)")
          )
        }
      }
      for await (endpoint, result) in group {
        switch result {
        case .success(let rows):
          points += CodexMapper.analytics(endpoint, rows: rows.data).filter { $0.day >= defaultStart && $0.day <= end }
          successful.insert(endpoint)
        case .failure(let error):
          warnings.append("\(Format.humanize(String(describing: endpoint))) analytics unavailable: \(error.message)")
        }
      }
    }
    let coveredScopes: [AnalyticsCoverageScope] = CodexAPI.Analytics.allCases.compactMap { endpoint in
      guard successful.contains(endpoint), let start = starts[endpoint] else { return nil }
      return AnalyticsCoverageScope(metrics: endpoint.metrics, startDay: start, endDay: end)
    }
    if activeAccount == account, !successful.isEmpty {
      for endpoint in successful {
        let start = starts[endpoint]!
        let coveredStart = min(analyticsCoverage[endpoint]?.start ?? start, start)
        analyticsCoverage[endpoint] = CodexAnalyticsCoverage(start: coveredStart, through: end)
      }
      analyticsWatermarks.update(
        account: account, coverage: analyticsCoverage, now: now, retentionDays: days)
    }
    var events: [CreditEvent] = []
    switch await Self.rows(client, CodexAPI.creditEventsURL, headers: headers, operation: "codex.credit-events") {
    case .success(let rows):
      let mapping = CodexMapper.creditEventMapping(rows.data)
      events = mapping.events.filter { $0.date >= cutoffDate && $0.date < endDate }
      if mapping.missingAmountCount > 0 {
        let noun = mapping.missingAmountCount == 1 ? "event" : "events"
        warnings.append("Skipped \(mapping.missingAmountCount) Codex credit \(noun) without a credit amount.")
      }
    case .failure(let error): warnings.append("Credit usage history unavailable: \(error.message)")
    }
    guard !points.isEmpty || !events.isEmpty || !coveredScopes.isEmpty else { return (nil, warnings) }
    return (
      ProviderAnalytics(
        provider: .codex,
        points: points,
        creditEvents: events,
        fetchedAt: now,
        accountFingerprint: account,
        coveredScopes: coveredScopes),
      warnings
    )
  }

  // wham/usage occasionally answers with a freshly reset window that the next call contradicts, so a drop to zero
  // ahead of the known reset time is held back until a second fetch agrees.
  private func confirmResets(_ windows: [QuotaWindow], now: Date) -> [QuotaWindow] {
    let confirmed = windows.map { window -> QuotaWindow in
      let wasPending = pendingResets.remove(window.id) != nil
      guard !wasPending, let previous = acceptedWindows[window.id], window.usedPercent < 1, previous.usedPercent >= 1,
        let resetsAt = previous.resetsAt, resetsAt > now
      else { return window }
      pendingResets.insert(window.id)
      return previous.withDetail("Confirming reset")
    }
    acceptedWindows = confirmed.reduce(into: [:]) { $0[$1.id] = $1 }
    return confirmed
  }

  private func analyticsStart(endpoint: CodexAPI.Analytics, fallback: String) -> String {
    guard let coverage = analyticsCoverage[endpoint], coverage.start <= fallback,
      let date = DayStamp.date(coverage.through)
    else { return fallback }
    let through = DayStamp.string(date.addingTimeInterval(-86400))
    return max(fallback, through)
  }

  private func activate(account: String, now: Date, retentionDays: Int) {
    guard activeAccount != account else { return }
    resetCreditsTask?.cancel()
    activeAccount = account
    resetCreditsCache = nil
    resetCreditsTask = nil
    acceptedWindows = [:]
    pendingResets = []
    analyticsCoverage = analyticsWatermarks.load(account: account, now: now, retentionDays: retentionDays)
  }

  private static func rows(
    _ client: APIClient, _ url: URL, headers: [String: String], operation: String
  ) async -> Result<CodexAPI.DailyRows, APIError> {
    do {
      return .success(try await client.getJSON(CodexAPI.DailyRows.self, url, headers: headers, operation: operation))
    } catch {
      return .failure(error)
    }
  }

  private static func fetchResetCredits(
    _ client: APIClient, headers: [String: String]
  ) async -> Result<ResetCredits, APIError> {
    do {
      let summary = try await client.getJSON(
        CodexAPI.ResetCreditsSummary.self,
        CodexAPI.resetCreditsURL,
        headers: headers,
        operation: "codex.reset-credits")
      return .success(CodexMapper.resetCredits(summary))
    } catch {
      return .failure(error)
    }
  }

  private func fallback(
    reason: String,
    auth: CodexAuth?,
    now: Date,
    notAuthenticated: Bool,
    recoveryIssue: ProviderRecoveryIssue? = nil,
    credentialStatus: ProviderCredentialStatus
  ) async -> ProviderFetchResult {
    if let root = self.auth.localDataRoot, discoveredRollouts?.root != root {
      discoveredRollouts = (root, CodexRolloutReader(sessionsRoot: root.appendingPathComponent("sessions")))
    }
    let reader = discoveredRollouts?.reader ?? rollouts
    guard let reading = await reader?.latest(now: now) else {
      return ProviderFetchResult(
        outcome: notAuthenticated ? .notAuthenticated(reason) : .networkUnavailable(reason),
        recoveryIssue: recoveryIssue
      ).withCredentialStatus(credentialStatus)
    }
    let response = CodexAPI.UsageResponse(
      email: nil, planType: reading.planType, rateLimit: reading.rateLimit, codeReviewRateLimit: nil,
      additionalRateLimits: nil,
      credits: reading.credits, spendControl: nil, rateLimitReachedType: nil, promo: nil, rateLimitResetCredits: nil
    )
    let snapshot = ProviderSnapshot(
      provider: .codex,
      identity: CodexMapper.identity(response, auth: auth),
      windows: CodexMapper.windows(response),
      credits: CodexMapper.credits(reading.credits),
      source: .localLog,
      fetchedAt: reading.observedAt ?? now,
      accountFingerprint: auth?.accountFingerprint
    )
    return ProviderFetchResult(
      outcome: .partial(snapshot, reason), warnings: ["Showing the last values Codex CLI logged locally."],
      recoveryIssue: recoveryIssue
    ).withCredentialStatus(credentialStatus)
  }

  private func refresh(
    _ stored: CodexAuth,
    source: CredentialSource,
    now: Date
  ) async throws(CredentialRefreshError) -> (
    credential: CodexAuth,
    source: CredentialSource,
    issue: ProviderRecoveryIssue?
  ) {
    guard let refreshToken = stored.refreshToken else {
      throw .missingRefreshToken
    }
    try refreshRejection.check(stored)
    let body = try! JSONEncoder().encode([
      "client_id": CodexAPI.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
    ])
    let token: CodexAPI.TokenResponse
    do {
      let data = try await client.post(CodexAPI.tokenURL, json: body, headers: [:], operation: "codex.refresh")
      token = try client.decode(CodexAPI.TokenResponse.self, data, operation: "codex.refresh")
    } catch {
      throw refreshRejection.failure(error, refreshing: stored)
    }
    guard let accessToken = token.accessToken else {
      throw .invalidResponse(token.error ?? "refresh returned no access token")
    }
    let refreshed = stored.refreshed(
      accessToken: accessToken, refreshToken: token.refreshToken, idToken: token.idToken, now: now)
    return try persistRefreshedCredential(
      refreshed, replacing: stored, source: source, provider: id, pending: &pendingCredentialSave, log: log,
      save: { try auth.save($0, replacing: $1) })
  }
}

private struct CachedResetCredits {
  let value: ResetCredits?
  let warning: String?
  let expiresAt: Date
}
