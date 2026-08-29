import Foundation

public actor GeminiProvider: UsageProvider {
  public nonisolated let id: ProviderID = .gemini
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .gemini)
  private let auth: any GeminiAuthStore
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @Sendable () -> Bool
  private let clientID: String
  private let clientSecret: String
  private var cachedAssist: (GeminiAPI.LoadCodeAssistResponse, Date)?

  public init(
    auth: any GeminiAuthStore,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @Sendable () -> Bool,
    clientID: String = GeminiAPI.defaultClientID,
    clientSecret: String = GeminiAPI.defaultClientSecret
  ) {
    self.auth = auth
    self.client = client
    self.log = log
    self.allowRefresh = allowRefresh
    self.clientID = clientID
    self.clientSecret = clientSecret
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

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let stored: GeminiAuth
    do {
      guard let loaded = try auth.load() else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Gemini credentials. \(id.loginHint)"))
      }
      stored = loaded
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Gemini credentials: \(error)"))
    }
    var active = stored
    if case .expired = stored.state(now: now) {
      guard allowRefresh() else {
        return ProviderFetchResult(outcome: .notAuthenticated("Gemini token expired. \(id.loginHint)"))
      }
      do {
        active = try await refresh(stored, now: now)
      } catch {
        return ProviderFetchResult(outcome: .notAuthenticated("Gemini token refresh failed: \(error.message)"))
      }
    }
    let headers = GeminiAPI.headers(token: active.accessToken)
    var warnings: [String] = []
    let assist: GeminiAPI.LoadCodeAssistResponse?
    do {
      assist = try await loadCodeAssist(headers: headers, now: now)
    } catch {
      if error.isAuthenticationFailure || error.isRateLimited {
        return ProviderFetchResult(outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint))
      }
      assist = nil
      warnings.append("Plan details unavailable: \(error.message)")
    }
    if let reason = assist?.unsupportedReason {
      return ProviderFetchResult(outcome: .notAuthenticated(reason))
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
        return ProviderFetchResult(outcome: .notAuthenticated(GeminiAPI.unsupportedClientMessage))
      }
      return ProviderFetchResult(outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint))
    }
    let snapshot = ProviderSnapshot(
      provider: .gemini,
      identity: GeminiMapper.identity(assist, auth: active),
      windows: GeminiMapper.windows(quota),
      credits: GeminiMapper.credits(assist),
      fetchedAt: now
    )
    return ProviderFetchResult(outcome: .success(snapshot), warnings: warnings)
  }

  private func loadCodeAssist(
    headers: [String: String], now: Date
  ) async throws(APIError)
    -> GeminiAPI.LoadCodeAssistResponse
  {
    if let (cached, at) = cachedAssist, now.timeIntervalSince(at) < 3600 { return cached }
    let data = try await client.post(
      GeminiAPI.loadCodeAssistURL, json: GeminiAPI.loadCodeAssistBody, headers: headers,
      operation: "gemini.load-code-assist")
    let response = try client.decode(GeminiAPI.LoadCodeAssistResponse.self, data, operation: "gemini.load-code-assist")
    cachedAssist = (response, now)
    return response
  }

  private func refresh(_ stored: GeminiAuth, now: Date) async throws(APIError) -> GeminiAuth {
    guard let refreshToken = stored.refreshToken else {
      throw APIError.http(status: 401, body: "no refresh token", retryAfter: nil)
    }
    let data = try await client.post(
      GeminiAPI.tokenURL,
      form: [
        "client_id": clientID, "client_secret": clientSecret, "grant_type": "refresh_token",
        "refresh_token": refreshToken,
      ], headers: [:], operation: "gemini.refresh")
    let token = try client.decode(GeminiAPI.TokenResponse.self, data, operation: "gemini.refresh")
    guard let accessToken = token.accessToken else {
      throw APIError.http(
        status: 401, body: token.errorDescription ?? token.error ?? "refresh returned no access token",
        retryAfter: nil)
    }
    let refreshed = stored.refreshed(
      accessToken: accessToken, expiresIn: token.expiresIn ?? 3600, idToken: token.idToken, now: now)
    do {
      try auth.save(refreshed)
      log.log("gemini token refreshed and stored")
    } catch {
      log.logError("gemini token refreshed but could not be stored: \(error)")
    }
    return refreshed
  }
}
