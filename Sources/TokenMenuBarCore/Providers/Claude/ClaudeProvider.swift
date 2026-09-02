import Foundation

public actor ClaudeProvider: UsageProvider {
  static let profileCacheInterval: TimeInterval = 6 * 3600

  public nonisolated let id: ProviderID = .claude
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .claude)
  private let credentials: any ClaudeCredentialStore
  private let localAccountURL: URL?
  private let transcripts: ClaudeTranscriptReader?
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @MainActor @Sendable () -> Bool
  private var cachedProfile: (fingerprint: String, profile: ClaudeAPI.ProfileResponse, at: Date)?
  private var pendingCredentialSave: PendingCredentialSave<ClaudeOAuthCredentials>?

  public init(
    credentials: any ClaudeCredentialStore,
    localAccountURL: URL?,
    transcripts: ClaudeTranscriptReader? = nil,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @MainActor @Sendable () -> Bool
  ) {
    self.credentials = credentials
    self.localAccountURL = localAccountURL
    self.transcripts = transcripts
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

  public func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    if let pendingCredentialSave {
      return .from(
        pendingCredentialSave.credential.state(now: now), source: pendingCredentialSave.source,
        expected: id.setup.credentialSources)
    }
    return credentials.credentialHealth(now: now)
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let resolved: ResolvedCredential<ClaudeOAuthCredentials>
    do {
      resolved = try resolveCredential(
        pending: &pendingCredentialSave,
        provider: id,
        load: {
          try credentials.loadWithSource().map { (credential: $0.credentials, source: $0.source) }
        },
        save: { try credentials.save($0, replacing: $1) })
      guard resolved.credential != nil else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Claude Code credentials. \(id.loginHint)"))
          .withCredentialStatus(.missing("no Claude Code sign-in found", provider: id))
      }
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Claude credentials: \(error)"))
        .withCredentialStatus(.unreadable(error, provider: id, fallbackSource: credentials.source))
    }
    let stored = resolved.credential!
    var recoveryIssue = resolved.issue
    var warnings: [String] = []
    var active = stored
    var activeSource = resolved.source!
    if case .expired = stored.state(now: now) {
      guard await allowRefresh() else {
        return ProviderFetchResult(outcome: .notAuthenticated("Claude token expired. \(id.loginHint)"))
          .withCredentialStatus(
            .resolved(stored.state(now: now), provider: id, source: activeSource))
      }
      do {
        let refreshed = try await refresh(stored, source: activeSource, now: now)
        active = refreshed.credential
        activeSource = refreshed.source
        recoveryIssue = refreshed.issue
      } catch {
        return ProviderFetchResult(outcome: .notAuthenticated("Claude token refresh failed: \(error.message)"))
          .withCredentialStatus(
            .resolved(stored.state(now: now), provider: id, source: activeSource))
      }
    }
    let credentialStatus = ProviderCredentialStatus.resolved(
      active.state(now: now), provider: id, source: activeSource)
    let fingerprint = active.cacheFingerprint
    if !active.hasProfileScope {
      warnings.append("Token lacks the user:profile scope; sign in with `claude` rather than `claude setup-token`.")
    }
    let headers = ClaudeAPI.headers(token: active.accessToken)
    async let usageTask = usage(headers: headers)
    async let profileTask = profile(headers: headers, fingerprint: fingerprint, now: now)
    let (usageResult, profileResult) = await (usageTask, profileTask)
    let local = localAccountURL.flatMap(ClaudeLocalAccount.load(from:))
    var profile: ClaudeAPI.ProfileResponse?
    switch profileResult {
    case .success(let value): profile = value
    case .failure(let error): warnings.append("Profile unavailable: \(error.message)")
    }
    let identity = ClaudeMapper.identity(profile: profile, credentials: active, local: local)
    let transcript = await transcripts?.refresh(now: now, retentionDays: options.analyticsDays)
    switch usageResult {
    case .success(let response):
      let windows = ClaudeMapper.windows(response)
      let session = windows.first { $0.id == "session" }
      let snapshot = ProviderSnapshot(
        provider: .claude,
        identity: identity,
        windows: windows,
        spend: ClaudeMapper.spend(response, now: now),
        notices: ClaudeMapper.notices(response),
        localUsage: transcript?.localUsage(
          windowResetsAt: session?.resetsAt, windowDuration: ClaudeMapper.sessionDuration, now: now),
        fetchedAt: now
      )
      let analytics = options.includeAnalytics ? transcript?.analytics(now: now) : nil
      return ProviderFetchResult(
        outcome: .success(snapshot), warnings: warnings, analytics: analytics, recoveryIssue: recoveryIssue
      ).withCredentialStatus(credentialStatus)
    case .failure(let error):
      return ProviderFetchResult(
        outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint), warnings: warnings,
        recoveryIssue: recoveryIssue
      ).withCredentialStatus(credentialStatus)
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

  private func profile(
    headers: [String: String], fingerprint: String, now: Date
  ) async -> Result<ClaudeAPI.ProfileResponse, APIError> {
    if let cachedProfile, cachedProfile.fingerprint == fingerprint,
      now.timeIntervalSince(cachedProfile.at) < Self.profileCacheInterval
    {
      return .success(cachedProfile.profile)
    }
    do {
      let profile = try await client.getJSON(
        ClaudeAPI.ProfileResponse.self, ClaudeAPI.profileURL, headers: headers, operation: "claude.profile")
      cachedProfile = (fingerprint, profile, now)
      return .success(profile)
    } catch {
      if let cachedProfile, cachedProfile.fingerprint == fingerprint { return .success(cachedProfile.profile) }
      return .failure(error)
    }
  }

  private func refresh(
    _ stored: ClaudeOAuthCredentials,
    source: CredentialSource,
    now: Date
  ) async throws(APIError) -> (
    credential: ClaudeOAuthCredentials,
    source: CredentialSource,
    issue: ProviderRecoveryIssue?
  ) {
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
    let saveResult: CredentialSaveResult<ClaudeOAuthCredentials>
    do {
      saveResult = try credentials.save(refreshed, replacing: stored)
    } catch {
      log.logError("claude token refreshed but could not be stored: \(error)")
      let detail = credentialPersistenceDetail(error)
      pendingCredentialSave = PendingCredentialSave(
        credential: refreshed, replacing: stored, source: source, detail: detail)
      return (refreshed, source, .credentialPersistence(provider: id, detail: detail))
    }
    switch saveResult {
    case .saved:
      log.log("claude token refreshed and stored")
    case .changed(let current, let currentSource):
      log.log("claude token refresh not stored because the credential source changed")
      guard let current else {
        throw APIError.http(status: 401, body: "credentials were removed during refresh", retryAfter: nil)
      }
      return (current, currentSource!, nil)
    }
    return (refreshed, source, nil)
  }
}
