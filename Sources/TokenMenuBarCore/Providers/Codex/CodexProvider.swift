import Foundation

public actor CodexProvider: UsageProvider {
  public static let resetCreditsTTL: TimeInterval = 15 * 60
  public static let resetCreditsFailureTTL: TimeInterval = 5 * 60

  public nonisolated let id: ProviderID = .codex
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .codex)
  private let auth: any CodexAuthStore
  private let rollouts: CodexRolloutReader?
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @MainActor @Sendable () -> Bool
  private let analyticsWatermarks: CodexAnalyticsWatermarkStore
  private var activeAccount: String?
  private var resetCreditsCache: CachedResetCredits?
  private var resetCreditsTask: Task<Result<ResetCredits?, APIError>, Never>?
  private var analyticsCoverage: [CodexAPI.Analytics: CodexAnalyticsCoverage] = [:]
  private var pendingCredentialSave: PendingCredentialSave<CodexAuth>?

  public init(
    auth: any CodexAuthStore,
    rollouts: CodexRolloutReader?,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @MainActor @Sendable () -> Bool,
    analyticsWatermarkPersistence: CodexAnalyticsWatermarkPersistence = .standard
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

  public nonisolated func credentialState(now: Date) -> CredentialState {
    do {
      guard let stored = try auth.load() else { return .missing("no Codex sign-in found") }
      return stored.state(now: now)
    } catch {
      return .missing("\(error)")
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
      return await fallback(
        reason: "Cannot read Codex credentials: \(error)", auth: nil, now: now, notAuthenticated: true,
        credentialStatus: .unreadable(error, provider: id, fallbackSource: auth.source))
    }
    let stored = resolved.credential!
    var recoveryIssue = resolved.issue
    var active = stored
    var activeSource = resolved.source!
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
    let (resetCredits, resetCreditsWarning) = await resetCredits(
      response: response, account: account, headers: headers, now: now)
    if let resetCreditsWarning { warnings.append(resetCreditsWarning) }
    let snapshot = ProviderSnapshot(
      provider: .codex,
      identity: CodexMapper.identity(response, auth: active),
      windows: CodexMapper.windows(response),
      credits: CodexMapper.credits(response.credits),
      spend: CodexMapper.spend(response.spendControl),
      resetCredits: resetCredits,
      notices: CodexMapper.notices(response),
      fetchedAt: now
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
    let task: Task<Result<ResetCredits?, APIError>, Never>
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
      let resolved = value!
      if activeAccount == account {
        resetCreditsCache = CachedResetCredits(
          value: resolved, warning: nil, expiresAt: now.addingTimeInterval(Self.resetCreditsTTL))
      }
      return (resolved, nil)
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
      events = CodexMapper.creditEvents(rows.data).filter { $0.date >= cutoffDate && $0.date < endDate }
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
  ) async -> Result<ResetCredits?, APIError> {
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
    guard let reading = await rollouts?.latest(now: now) else {
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
      fetchedAt: reading.observedAt ?? now
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
  ) async throws(APIError) -> (
    credential: CodexAuth,
    source: CredentialSource,
    issue: ProviderRecoveryIssue?
  ) {
    guard let refreshToken = stored.refreshToken else {
      throw APIError.http(status: 401, body: "no refresh token", retryAfter: nil)
    }
    let body = try! JSONEncoder().encode([
      "client_id": CodexAPI.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
    ])
    let data = try await client.post(CodexAPI.tokenURL, json: body, headers: [:], operation: "codex.refresh")
    let token = try client.decode(CodexAPI.TokenResponse.self, data, operation: "codex.refresh")
    guard let accessToken = token.accessToken else {
      throw APIError.http(status: 401, body: token.error ?? "refresh returned no access token", retryAfter: nil)
    }
    let refreshed = stored.refreshed(
      accessToken: accessToken, refreshToken: token.refreshToken, idToken: token.idToken, now: now)
    let saveResult: CredentialSaveResult<CodexAuth>
    do {
      saveResult = try auth.save(refreshed, replacing: stored)
    } catch {
      log.logError("codex token refreshed but could not be stored: \(error)")
      let detail = credentialPersistenceDetail(error)
      pendingCredentialSave = PendingCredentialSave(
        credential: refreshed, replacing: stored, source: source, detail: detail)
      return (refreshed, source, .credentialPersistence(provider: id, detail: detail))
    }
    switch saveResult {
    case .saved:
      log.log("codex token refreshed and stored")
    case .changed(let current, let currentSource):
      log.log("codex token refresh not stored because the credential source changed")
      guard let current else {
        throw APIError.http(status: 401, body: "credentials were removed during refresh", retryAfter: nil)
      }
      return (current, currentSource!, nil)
    }
    return (refreshed, source, nil)
  }
}

private struct CachedResetCredits {
  let value: ResetCredits?
  let warning: String?
  let expiresAt: Date
}
