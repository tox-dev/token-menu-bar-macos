import Foundation

public actor ClaudeProvider: UsageProvider {
  public static let profileCacheInterval: TimeInterval = 6 * 3600

  public nonisolated let id: ProviderID = .claude
  public nonisolated let pollingPolicy = PollingPolicy(idleInterval: 300, activeInterval: 120)
  private let credentials: any ClaudeCredentialStore
  private let localAccountURL: URL?
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @Sendable () -> Bool
  private var cachedProfile: (profile: ClaudeAPI.ProfileResponse, at: Date)?

  public init(
    credentials: any ClaudeCredentialStore,
    localAccountURL: URL?,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @Sendable () -> Bool
  ) {
    self.credentials = credentials
    self.localAccountURL = localAccountURL
    self.client = client
    self.log = log
    self.allowRefresh = allowRefresh
  }

  public nonisolated var credentialDescription: String {
    credentials.description
  }

  public nonisolated func credentialState(now: Date) -> CredentialState {
    do {
      guard let stored = try credentials.load() else { return .missing("no Claude Code sign-in found") }
      return stored.state(now: now)
    } catch {
      return .missing("\(error)")
    }
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let stored: ClaudeOAuthCredentials
    do {
      guard let loaded = try credentials.load() else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Claude Code credentials. \(id.loginHint)"))
      }
      stored = loaded
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Claude credentials: \(error)"))
    }
    var warnings: [String] = []
    var active = stored
    if case .expired = stored.state(now: now) {
      guard allowRefresh() else {
        return ProviderFetchResult(outcome: .notAuthenticated("Claude token expired. \(id.loginHint)"))
      }
      do {
        active = try await refresh(stored, now: now)
      } catch {
        return ProviderFetchResult(outcome: .notAuthenticated("Claude token refresh failed: \(error.message)"))
      }
    }
    if !active.hasProfileScope {
      warnings.append("Token lacks the user:profile scope; sign in with `claude` rather than `claude setup-token`.")
    }
    let headers = ClaudeAPI.headers(token: active.accessToken)
    async let usageTask = usage(headers: headers)
    async let profileTask = profile(headers: headers, now: now)
    let (usageResult, profileResult) = await (usageTask, profileTask)
    let local = localAccountURL.flatMap(ClaudeLocalAccount.load(from:))
    var profile: ClaudeAPI.ProfileResponse?
    switch profileResult {
    case .success(let value): profile = value
    case .failure(let error): warnings.append("Profile unavailable: \(error.message)")
    }
    let identity = ClaudeMapper.identity(profile: profile, credentials: active, local: local)
    switch usageResult {
    case .success(let response):
      let snapshot = ProviderSnapshot(
        provider: .claude,
        identity: identity,
        windows: ClaudeMapper.windows(response),
        spend: ClaudeMapper.spend(response, now: now),
        notices: ClaudeMapper.notices(response),
        fetchedAt: now
      )
      return ProviderFetchResult(outcome: .success(snapshot), warnings: warnings)
    case .failure(let error):
      return ProviderFetchResult(
        outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint), warnings: warnings)
    }
  }

  private func usage(headers: [String: String]) async -> Result<ClaudeAPI.UsageResponse, APIError> {
    do {
      return .success(
        try await client.getJSON(
          ClaudeAPI.UsageResponse.self, ClaudeAPI.usageURL, headers: headers, operation: "claude.usage"))
    } catch {
      return .failure(error)
    }
  }

  private func profile(headers: [String: String], now: Date) async -> Result<ClaudeAPI.ProfileResponse, APIError> {
    if let cachedProfile, now.timeIntervalSince(cachedProfile.at) < Self.profileCacheInterval {
      return .success(cachedProfile.profile)
    }
    do {
      let profile = try await client.getJSON(
        ClaudeAPI.ProfileResponse.self, ClaudeAPI.profileURL, headers: headers, operation: "claude.profile")
      cachedProfile = (profile, now)
      return .success(profile)
    } catch {
      if let cachedProfile { return .success(cachedProfile.profile) }
      return .failure(error)
    }
  }

  private func refresh(_ stored: ClaudeOAuthCredentials, now: Date) async throws(APIError) -> ClaudeOAuthCredentials {
    guard let refreshToken = stored.refreshToken else {
      throw APIError.http(status: 401, body: "no refresh token", retryAfter: nil)
    }
    let body = try! JSONEncoder().encode(
      ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": ClaudeAPI.clientID]
    )
    let data = try await client.post(
      ClaudeAPI.tokenURL, json: body, headers: ["User-Agent": ClaudeAPI.userAgent], operation: "claude.refresh")
    let token = try client.decode(ClaudeAPI.TokenResponse.self, data, operation: "claude.refresh")
    let refreshed = stored.refreshed(
      accessToken: token.accessToken, refreshToken: token.refreshToken, expiresIn: token.expiresIn ?? 3600, now: now)
    do {
      try credentials.save(refreshed)
      log.log("claude token refreshed and stored")
    } catch {
      log.logError("claude token refreshed but could not be stored: \(error)")
    }
    return refreshed
  }
}
