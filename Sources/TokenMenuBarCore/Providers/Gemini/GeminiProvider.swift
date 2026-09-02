import Foundation

public actor GeminiProvider: UsageProvider {
  public nonisolated let id: ProviderID = .gemini
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .gemini)
  private let auth: any GeminiAuthStore
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @MainActor @Sendable () -> Bool
  private let oauthClient: @Sendable () -> GeminiOAuthClient?
  private var cachedAssist: (fingerprint: String, assist: GeminiAPI.LoadCodeAssistResponse, at: Date)?
  private var pendingCredentialSave: PendingCredentialSave<GeminiAuth>?

  public init(
    auth: any GeminiAuthStore,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @MainActor @Sendable () -> Bool,
    oauthClient: @escaping @Sendable () -> GeminiOAuthClient? = { GeminiOAuthConfig.resolve() }
  ) {
    self.auth = auth
    self.client = client
    self.log = log
    self.allowRefresh = allowRefresh
    self.oauthClient = oauthClient
  }

  public nonisolated var credentialDescription: String {
    auth.description
  }

  public nonisolated func credentialState(now: Date) -> CredentialState {
    do {
      guard let stored = try auth.load() else { return .missing("no Gemini CLI sign-in found") }
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
    let resolved: ResolvedCredential<GeminiAuth>
    do {
      resolved = try resolveCredential(
        pending: &pendingCredentialSave,
        provider: id,
        load: { try auth.loadWithSource().map { (credential: $0.auth, source: $0.source) } },
        save: { try auth.save($0, replacing: $1) })
      guard resolved.credential != nil else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Gemini credentials. \(id.loginHint)"))
          .withCredentialStatus(.missing("no Gemini CLI sign-in found", provider: id))
      }
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Gemini credentials: \(error)"))
        .withCredentialStatus(.unreadable(error, provider: id, fallbackSource: auth.source))
    }
    let stored = resolved.credential!
    var recoveryIssue = resolved.issue
    var active = stored
    var activeSource = resolved.source!
    if case .expired = stored.state(now: now) {
      guard await allowRefresh() else {
        return ProviderFetchResult(outcome: .notAuthenticated("Gemini token expired. \(id.loginHint)"))
          .withCredentialStatus(
            .resolved(stored.state(now: now), provider: id, source: activeSource))
      }
      do {
        let refreshed = try await refresh(stored, source: activeSource, now: now)
        active = refreshed.credential
        activeSource = refreshed.source
        recoveryIssue = refreshed.issue
      } catch {
        return ProviderFetchResult(
          outcome: .notAuthenticated("Gemini token refresh failed: \(error.message)")
        )
        .withCredentialStatus(
          .resolved(stored.state(now: now), provider: id, source: activeSource))
      }
    }
    let credentialStatus = ProviderCredentialStatus.resolved(
      active.state(now: now), provider: id, source: activeSource)
    let fingerprint = active.cacheFingerprint
    let headers = GeminiAPI.headers(token: active.accessToken)
    var warnings: [String] = []
    let assist: GeminiAPI.LoadCodeAssistResponse?
    do {
      assist = try await loadCodeAssist(headers: headers, fingerprint: fingerprint, now: now)
    } catch {
      if error.isAuthenticationFailure || error.isRateLimited {
        return ProviderFetchResult(
          outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint), recoveryIssue: recoveryIssue
        ).withCredentialStatus(credentialStatus)
      }
      assist = nil
      warnings.append("Plan details unavailable: \(error.message)")
    }
    if let reason = assist?.unsupportedReason {
      return ProviderFetchResult(
        outcome: .notAuthenticated(reason),
        recoveryIssue: .unsupportedAccount(provider: id, detail: reason)
      ).withCredentialStatus(credentialStatus)
    }
    let quota: GeminiAPI.QuotaResponse
    do {
      let data = try await client.post(
        GeminiAPI.quotaURL, json: GeminiAPI.quotaBody(project: assist?.projectID), headers: headers,
        operation: "gemini.quota")
      quota = try client.decode(GeminiAPI.QuotaResponse.self, data, operation: "gemini.quota")
    } catch {
      if case .http(let status, let body, _) = error, status == 403, body.uppercased().contains("SUBSCRIPTION_REQUIRED")
      {
        return ProviderFetchResult(
          outcome: .notAuthenticated(GeminiAPI.unsupportedClientMessage),
          recoveryIssue: .unsupportedAccount(provider: id, detail: GeminiAPI.unsupportedClientMessage)
        ).withCredentialStatus(credentialStatus)
      }
      return ProviderFetchResult(
        outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint), recoveryIssue: recoveryIssue
      ).withCredentialStatus(credentialStatus)
    }
    let snapshot = ProviderSnapshot(
      provider: .gemini,
      identity: GeminiMapper.identity(assist, auth: active),
      windows: GeminiMapper.windows(quota),
      credits: GeminiMapper.credits(assist),
      fetchedAt: now
    )
    return ProviderFetchResult(outcome: .success(snapshot), warnings: warnings, recoveryIssue: recoveryIssue)
      .withCredentialStatus(credentialStatus)
  }

  private func loadCodeAssist(
    headers: [String: String], fingerprint: String, now: Date
  ) async throws(APIError)
    -> GeminiAPI.LoadCodeAssistResponse
  {
    if let cachedAssist, cachedAssist.fingerprint == fingerprint, now.timeIntervalSince(cachedAssist.at) < 3600 {
      return cachedAssist.assist
    }
    let data = try await client.post(
      GeminiAPI.loadCodeAssistURL, json: GeminiAPI.loadCodeAssistBody, headers: headers,
      operation: "gemini.load-code-assist")
    let response = try client.decode(GeminiAPI.LoadCodeAssistResponse.self, data, operation: "gemini.load-code-assist")
    cachedAssist = (fingerprint, response, now)
    return response
  }

  private func refresh(
    _ stored: GeminiAuth,
    source: CredentialSource,
    now: Date
  ) async throws(GeminiRefreshError) -> (
    credential: GeminiAuth,
    source: CredentialSource,
    issue: ProviderRecoveryIssue?
  ) {
    guard let refreshToken = stored.refreshToken else {
      throw GeminiRefreshError.noRefreshToken
    }
    guard let oauth = oauthClient() else {
      throw GeminiRefreshError.oauthClientUnavailable
    }
    let token: GeminiAPI.TokenResponse
    do {
      let data = try await client.post(
        GeminiAPI.tokenURL,
        form: [
          "client_id": oauth.id, "client_secret": oauth.secret, "grant_type": "refresh_token",
          "refresh_token": refreshToken,
        ], headers: [:], operation: "gemini.refresh")
      token = try client.decode(GeminiAPI.TokenResponse.self, data, operation: "gemini.refresh")
    } catch {
      throw GeminiRefreshError.api(error)
    }
    guard let accessToken = token.accessToken else {
      throw GeminiRefreshError.api(
        APIError.http(
          status: 401, body: token.errorDescription ?? token.error ?? "refresh returned no access token",
          retryAfter: nil))
    }
    let refreshed = stored.refreshed(
      accessToken: accessToken, expiresIn: token.expiresIn ?? 3600, idToken: token.idToken, now: now)
    let saveResult: CredentialSaveResult<GeminiAuth>
    do {
      saveResult = try auth.save(refreshed, replacing: stored)
    } catch {
      log.logError("gemini token refreshed but could not be stored: \(error)")
      let detail = credentialPersistenceDetail(error)
      pendingCredentialSave = PendingCredentialSave(
        credential: refreshed, replacing: stored, source: source, detail: detail)
      return (refreshed, source, .credentialPersistence(provider: id, detail: detail))
    }
    switch saveResult {
    case .saved:
      log.log("gemini token refreshed and stored")
    case .changed(let current, let currentSource):
      log.log("gemini token refresh not stored because the credential source changed")
      guard let current else {
        throw GeminiRefreshError.api(
          APIError.http(status: 401, body: "credentials were removed during refresh", retryAfter: nil))
      }
      return (current, currentSource!, nil)
    }
    return (refreshed, source, nil)
  }
}

private enum GeminiRefreshError: Error {
  case api(APIError)
  case noRefreshToken
  case oauthClientUnavailable

  var message: String {
    switch self {
    case .api(let error): error.message
    case .noRefreshToken: "no refresh token"
    case .oauthClientUnavailable: "the Gemini CLI OAuth client could not be read from the installed CLI"
    }
  }
}
