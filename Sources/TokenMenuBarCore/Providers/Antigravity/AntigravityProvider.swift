import Foundation

public actor AntigravityProvider: UsageProvider {
  public nonisolated let id: ProviderID = .antigravity
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .antigravity)
  private let auth: any AntigravityAuthStore
  private let client: APIClient
  private let log: LogBuffer
  private let allowRefresh: @MainActor @Sendable () -> Bool
  private let oauthClient: @Sendable () -> GeminiOAuthClient?
  private let processScanner: (any ProcessScanner)?
  // Google refresh tokens do not rotate and Antigravity owns its Keychain item, so a refreshed access token is only
  // remembered here and dropped as soon as the stored credential changes.
  private var refreshed: (replacing: AntigravityAuth, active: AntigravityAuth)?
  private var refreshRejection = RefreshRejection<AntigravityAuth>()
  private var cachedTier: (token: String, tier: AntigravityAPI.Tier?, at: Date)?
  private var cachedServer: LocalLanguageServer?
  private var cachedLocal: ProviderSnapshot?

  private static let localSource = CredentialSource(
    id: "antigravity.local", provider: .antigravity,
    title: "Antigravity local session", detail: "Signed-in app or CLI on this Mac")

  public init(
    auth: any AntigravityAuthStore,
    client: APIClient,
    log: LogBuffer,
    allowRefresh: @escaping @MainActor @Sendable () -> Bool,
    oauthClient: @escaping @Sendable () -> GeminiOAuthClient?,
    processScanner: (any ProcessScanner)? = nil
  ) {
    self.auth = auth
    self.client = client
    self.log = log
    self.allowRefresh = allowRefresh
    self.oauthClient = oauthClient
    self.processScanner = processScanner
  }

  public nonisolated var credentialDescription: String {
    auth.description
  }

  static let missingCredentialDetail = "no Antigravity sign-in found"

  public nonisolated func credentialState(now: Date) -> CredentialState {
    do {
      guard let stored = try auth.load() else {
        return .missing(Self.missingCredentialDetail)
      }
      return stored.state(now: now)
    } catch {
      return .missing(CredentialReadFailure(source: auth.source, error: error).detail)
    }
  }

  public func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    if let processScanner, await localSnapshot(scanner: processScanner, now: now) != nil {
      return .valid(source: Self.localSource, expiresAt: nil)
    }
    return auth.credentialHealth(now: now)
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    if let processScanner, let snapshot = await localSnapshot(scanner: processScanner, now: now) {
      return ProviderFetchResult(outcome: .success(snapshot)).withCredentialStatus(
        .resolved(.valid(expiresAt: nil), provider: id, source: Self.localSource))
    }
    let stored: AntigravityAuth
    do {
      guard let loaded = try auth.load() else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Antigravity credentials. \(id.loginHint)"))
          .withCredentialStatus(.missing(Self.missingCredentialDetail, provider: id))
      }
      stored = loaded
    } catch {
      let failure = CredentialReadFailure(source: auth.source, error: error)
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Antigravity credentials: \(failure.detail)"))
        .withCredentialStatus(.unreadable(error, provider: id, fallbackSource: auth.source))
    }
    if refreshed?.replacing != stored { refreshed = nil }
    var active = refreshed?.active ?? stored
    if case .expired = active.state(now: now) {
      guard await allowRefresh() else {
        return ProviderFetchResult(outcome: .notAuthenticated("Antigravity token expired. \(id.loginHint)"))
          .withCredentialStatus(.resolved(active.state(now: now), provider: id, source: auth.source))
      }
      do {
        active = try await refresh(stored, now: now)
      } catch {
        return ProviderFetchResult(outcome: .notAuthenticated("Antigravity token refresh failed: \(error.message)"))
          .withCredentialStatus(.resolved(stored.state(now: now), provider: id, source: auth.source))
      }
    }
    let status = ProviderCredentialStatus.resolved(active.state(now: now), provider: id, source: auth.source)
    return await cloudResult(active, stored: stored, now: now, status: status, retrying: false)
  }

  private func localSnapshot(scanner: any ProcessScanner, now: Date) async -> ProviderSnapshot? {
    if let cachedLocal, now.timeIntervalSince(cachedLocal.fetchedAt) < 5 { return cachedLocal }
    return await withTaskGroup(of: ProviderSnapshot?.self) { group in
      group.addTask { await self.probeLocal(scanner: scanner, now: now) }
      group.addTask {
        try? await Task.sleep(for: .seconds(3))
        return nil
      }
      let result = await group.next()!
      group.cancelAll()
      return result
    }
  }

  private func probeLocal(scanner: any ProcessScanner, now: Date) async -> ProviderSnapshot? {
    var servers = cachedServer.map { [$0] } ?? AntigravityLanguageServers.discover(using: scanner)
    var index = 0
    while index < servers.count, !Task.isCancelled {
      let server = servers[index]
      index += 1
      if index == 1, cachedServer != nil {
        // Discover alternatives only after a previously working endpoint fails.
        if let local = await localQuota(server), !Task.isCancelled {
          return await localSnapshot(server: server, local: local, now: now)
        }
        cachedServer = nil
        servers += AntigravityLanguageServers.discover(using: scanner).filter { $0 != server }
        continue
      }
      guard let local = await localQuota(server) else { continue }
      guard !Task.isCancelled else { return nil }
      return await localSnapshot(server: server, local: local, now: now)
    }
    return nil
  }

  private func localSnapshot(
    server: LocalLanguageServer,
    local: (summary: AntigravityAPI.QuotaSummary, scheme: String), now: Date
  ) async -> ProviderSnapshot? {
    let status = await localStatus(server, scheme: local.scheme)
    guard !Task.isCancelled else { return nil }
    let snapshot = ProviderSnapshot(
      provider: id, identity: AntigravityMapper.identity(status),
      windows: AntigravityMapper.windows(local.summary.allGroups), fetchedAt: now,
      details: AntigravityMapper.details(local.summary.allGroups))
    cachedServer = server
    cachedLocal = snapshot
    return snapshot
  }

  private func localQuota(
    _ server: LocalLanguageServer
  ) async -> (summary: AntigravityAPI.QuotaSummary, scheme: String)? {
    for scheme in AntigravityAPI.serverSchemes {
      guard !Task.isCancelled else { return nil }
      do {
        let data = try await client.post(
          AntigravityAPI.serverURL(port: server.port, scheme: scheme, method: "RetrieveUserQuotaSummary"),
          json: AntigravityAPI.serverQuotaBody, headers: AntigravityAPI.serverHeaders(csrfToken: server.csrfToken),
          operation: "antigravity.local-quota", timeout: 0.5)
        let summary = try client.decode(AntigravityAPI.QuotaSummary.self, data, operation: "antigravity.local-quota")
        guard summary.failure == nil else {
          log.logDebug("antigravity: local quota response rejected port=\(server.port)", category: .network)
          return nil
        }
        return (summary, scheme)
      } catch {
        log.logDebug(
          "antigravity: language server port=\(server.port) scheme=\(scheme) \(error.message)", category: .network)
      }
    }
    return nil
  }

  private func localStatus(_ server: LocalLanguageServer, scheme: String) async -> AntigravityAPI.UserStatus? {
    do {
      let data = try await client.post(
        AntigravityAPI.serverURL(port: server.port, scheme: scheme, method: "GetUserStatus"),
        json: AntigravityAPI.serverStatusBody, headers: AntigravityAPI.serverHeaders(csrfToken: server.csrfToken),
        operation: "antigravity.local-status", timeout: 0.5)
      return try client.decode(AntigravityAPI.UserStatusResponse.self, data, operation: "antigravity.local-status")
        .userStatus
    } catch {
      log.logDebug("antigravity: user status unavailable port=\(server.port) \(error.message)", category: .network)
      return nil
    }
  }

  private func cloudResult(
    _ active: AntigravityAuth, stored: AntigravityAuth, now: Date, status: ProviderCredentialStatus, retrying: Bool
  ) async -> ProviderFetchResult {
    let headers = AntigravityAPI.cloudHeaders(token: active.accessToken)
    switch await cloudQuota(headers: headers) {
    case .success(let quota):
      let tier = await cloudTier(base: quota.base, headers: headers, token: active.accessToken, now: now)
      let snapshot = ProviderSnapshot(
        provider: id, identity: AntigravityMapper.identity(tier.tier),
        windows: AntigravityMapper.windows(quota.summary.allGroups), fetchedAt: now,
        details: AntigravityMapper.details(quota.summary.allGroups))
      return ProviderFetchResult(outcome: .success(snapshot), warnings: tier.warning.map { [$0] } ?? [])
        .withCredentialStatus(status)
    case .failure(let error) where error.isAuthenticationFailure:
      guard !retrying, await allowRefresh() else {
        return ProviderFetchResult(outcome: .notAuthenticated("\(error.message). \(id.loginHint)"))
          .withCredentialStatus(status)
      }
      do {
        let renewed = try await refresh(stored, now: now)
        return await cloudResult(
          renewed, stored: stored, now: now,
          status: .resolved(renewed.state(now: now), provider: id, source: auth.source), retrying: true)
      } catch {
        return ProviderFetchResult(outcome: .notAuthenticated("Antigravity token refresh failed: \(error.message)"))
          .withCredentialStatus(status)
      }
    case .failure(let error):
      return ProviderFetchResult(outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint))
        .withCredentialStatus(status)
    }
  }

  private func cloudQuota(
    headers: [String: String]
  ) async -> Result<(base: String, summary: AntigravityAPI.QuotaSummary), APIError> {
    var failure: APIError?
    for base in AntigravityAPI.cloudBases {
      do throws(APIError) {
        let data = try await client.post(
          AntigravityAPI.cloudURL(base: base, method: "retrieveUserQuotaSummary"), json: AntigravityAPI.cloudQuotaBody,
          headers: headers, operation: "antigravity.quota")
        let summary = try client.decode(AntigravityAPI.QuotaSummary.self, data, operation: "antigravity.quota")
        if let failure = summary.failure { throw failure }
        return .success((base, summary))
      } catch {
        if error.isAuthenticationFailure { return .failure(error) }
        log.logDebug("antigravity: \(base) \(error.message)", category: .network)
        failure = error
      }
    }
    return .failure(failure!)
  }

  private func cloudTier(
    base: String, headers: [String: String], token: String, now: Date
  ) async -> (tier: AntigravityAPI.Tier?, warning: String?) {
    if let cachedTier, cachedTier.token == token, now.timeIntervalSince(cachedTier.at) < 3600 {
      return (cachedTier.tier, nil)
    }
    do {
      let data = try await client.post(
        AntigravityAPI.cloudURL(base: base, method: "loadCodeAssist"), json: AntigravityAPI.cloudAssistBody,
        headers: headers, operation: "antigravity.load-code-assist")
      let tier = try client.decode(
        AntigravityAPI.LoadCodeAssistResponse.self, data, operation: "antigravity.load-code-assist"
      ).currentTier
      cachedTier = (token, tier, now)
      return (tier, nil)
    } catch {
      return (nil, "Plan details unavailable: \(error.message)")
    }
  }

  private func refresh(_ stored: AntigravityAuth, now: Date) async throws(CredentialRefreshError) -> AntigravityAuth {
    guard let refreshToken = stored.refreshToken else { throw .missingRefreshToken }
    guard let oauth = oauthClient() else { throw .oauthClientUnavailable }
    try refreshRejection.check(stored)
    let token: GeminiAPI.TokenResponse
    do {
      let data = try await client.post(
        AntigravityAPI.tokenURL,
        form: [
          "client_id": oauth.id, "client_secret": oauth.secret, "grant_type": "refresh_token",
          "refresh_token": refreshToken,
        ], headers: [:], operation: "antigravity.refresh")
      token = try client.decode(GeminiAPI.TokenResponse.self, data, operation: "antigravity.refresh")
    } catch {
      throw refreshRejection.failure(error, refreshing: stored)
    }
    guard let accessToken = token.accessToken else {
      throw .invalidResponse(token.errorDescription ?? token.error ?? "refresh returned no access token")
    }
    let active = stored.refreshed(accessToken: accessToken, expiresIn: token.expiresIn ?? 3600, now: now)
    refreshed = (stored, active)
    log.log("antigravity token refreshed and kept in memory")
    return active
  }
}
