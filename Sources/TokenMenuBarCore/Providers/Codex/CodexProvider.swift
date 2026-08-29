import Foundation

public actor CodexProvider: UsageProvider {
  public nonisolated let id: ProviderID = .codex
  private let auth: any CodexAuthStore
  private let rollouts: CodexRolloutReader?
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @Sendable () -> Bool

  public init(
    auth: any CodexAuthStore,
    rollouts: CodexRolloutReader?,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @Sendable () -> Bool
  ) {
    self.auth = auth
    self.rollouts = rollouts
    self.client = client
    self.log = log
    self.allowRefresh = allowRefresh
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

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let stored: CodexAuth
    do {
      guard let loaded = try auth.load() else {
        return fallback(reason: "No Codex credentials. \(id.loginHint)", auth: nil, now: now, notAuthenticated: true)
      }
      stored = loaded
    } catch {
      return fallback(reason: "Cannot read Codex credentials: \(error)", auth: nil, now: now, notAuthenticated: true)
    }
    var active = stored
    if case .expired = stored.state(now: now) {
      guard allowRefresh() else {
        return fallback(reason: "Codex token expired. \(id.loginHint)", auth: stored, now: now, notAuthenticated: true)
      }
      do {
        active = try await refresh(stored, now: now)
      } catch {
        return fallback(
          reason: "Codex token refresh failed: \(error.message)", auth: stored, now: now, notAuthenticated: true)
      }
    }
    let headers = CodexAPI.headers(token: active.accessToken, accountID: active.accountID)
    let response: CodexAPI.UsageResponse
    do {
      response = try await client.getJSON(
        CodexAPI.UsageResponse.self, CodexAPI.usageURL, headers: headers, operation: "codex.usage")
    } catch {
      let outcome = ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint)
      if case .failed = outcome { return ProviderFetchResult(outcome: outcome) }
      return fallback(
        reason: outcome.errorDescription ?? error.message, auth: active, now: now,
        notAuthenticated: error.isAuthenticationFailure)
    }
    var warnings: [String] = []
    var resetCredits = CodexMapper.resetCredits(response.rateLimitResetCredits)
    if let summary = try? await client.getJSON(
      CodexAPI.ResetCreditsSummary.self, CodexAPI.resetCreditsURL, headers: headers, operation: "codex.reset-credits")
    {
      resetCredits = CodexMapper.resetCredits(summary)
    }
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
      let (result, analyticsWarnings) = await fetchAnalytics(headers: headers, now: now, days: options.analyticsDays)
      analytics = result
      warnings += analyticsWarnings
    }
    return ProviderFetchResult(outcome: .success(snapshot), warnings: warnings, analytics: analytics)
  }

  private func fetchAnalytics(headers: [String: String], now: Date, days: Int) async -> (ProviderAnalytics?, [String]) {
    let end = DayStamp.string(now)
    let start = DayStamp.string(now.addingTimeInterval(-Double(max(days - 1, 0)) * 86400))
    var points: [AnalyticsPoint] = []
    var warnings: [String] = []
    await withTaskGroup(of: (CodexAPI.Analytics, Result<CodexAPI.DailyRows, APIError>).self) { group in
      for endpoint in CodexAPI.Analytics.allCases {
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
        case .success(let rows): points += CodexMapper.analytics(endpoint, rows: rows.data)
        case .failure(let error):
          warnings.append("\(Format.humanize(String(describing: endpoint))) analytics unavailable: \(error.message)")
        }
      }
    }
    var events: [CreditEvent] = []
    switch await Self.rows(client, CodexAPI.creditEventsURL, headers: headers, operation: "codex.credit-events") {
    case .success(let rows): events = CodexMapper.creditEvents(rows.data)
    case .failure(let error): warnings.append("Credit usage history unavailable: \(error.message)")
    }
    guard !points.isEmpty || !events.isEmpty else { return (nil, warnings) }
    return (ProviderAnalytics(provider: .codex, points: points, creditEvents: events, fetchedAt: now), warnings)
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

  private func fallback(reason: String, auth: CodexAuth?, now: Date, notAuthenticated: Bool) -> ProviderFetchResult {
    guard let reading = rollouts?.latest() else {
      return ProviderFetchResult(outcome: notAuthenticated ? .notAuthenticated(reason) : .networkUnavailable(reason))
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
      outcome: .partial(snapshot, reason), warnings: ["Showing the last values Codex CLI logged locally."])
  }

  private func refresh(_ stored: CodexAuth, now: Date) async throws(APIError) -> CodexAuth {
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
    do {
      try auth.save(refreshed)
      log.log("codex token refreshed and stored")
    } catch {
      log.logError("codex token refreshed but could not be stored: \(error)")
    }
    return refreshed
  }
}
