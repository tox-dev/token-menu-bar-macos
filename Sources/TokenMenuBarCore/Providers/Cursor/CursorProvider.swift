import Foundation

public actor CursorProvider: UsageProvider {
  public static let identityTTL: TimeInterval = 60 * 60
  public static let identityFailureTTL: TimeInterval = 5 * 60

  public nonisolated let id: ProviderID = .cursor
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .cursor)
  private let auth: any CursorAuthStore
  private let client: APIClient
  private let log: LogBuffer
  private var identityCache: CachedCursorIdentity?
  private var identityTask: CursorIdentityTask?

  public init(auth: any CursorAuthStore, client: APIClient, log: LogBuffer) {
    self.auth = auth
    self.client = client
    self.log = log
  }

  public nonisolated var credentialDescription: String {
    auth.description
  }

  public nonisolated func credentialState(now: Date) -> CredentialState {
    do {
      guard let stored = try auth.load() else { return .missing("no Cursor sign-in found") }
      return stored.state(now: now)
    } catch {
      return .missing("\(error)")
    }
  }

  public func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    auth.credentialHealth(now: now)
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let resolved: (auth: CursorAuth, source: CredentialSource)
    do {
      guard let loaded = try auth.loadWithSource() else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Cursor credentials. \(id.loginHint)"))
          .withCredentialStatus(.missing("no Cursor sign-in found", provider: id))
      }
      resolved = loaded
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Cursor credentials: \(error)"))
        .withCredentialStatus(.unreadable(error, provider: id, fallbackSource: auth.source))
    }
    let stored = resolved.auth
    let credentialStatus = ProviderCredentialStatus.resolved(
      stored.state(now: now), provider: id, source: resolved.source)
    if case .expired = stored.state(now: now) {
      return ProviderFetchResult(
        outcome: .notAuthenticated("Cursor session expired; open Cursor to refresh it. \(id.loginHint)")
      )
      .withCredentialStatus(credentialStatus)
    }
    var warnings: [String] = []
    var summary: CursorAPI.UsageSummary
    var period: CursorAPI.PeriodUsage?
    do {
      summary = try await client.getJSON(
        CursorAPI.UsageSummary.self, CursorAPI.usageSummaryURL, headers: CursorAPI.cookieHeaders(stored),
        operation: "cursor.usage-summary")
    } catch {
      do {
        let data = try await client.post(
          CursorAPI.periodUsageURL, json: Data("{}".utf8), headers: CursorAPI.bearerHeaders(stored),
          operation: "cursor.period-usage")
        let usage = try client.decode(CursorAPI.PeriodUsage.self, data, operation: "cursor.period-usage")
        period = usage
        summary = usage.summary
        warnings.append("Dashboard summary unavailable: \(error.message)")
      } catch {
        return ProviderFetchResult(outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint))
          .withCredentialStatus(credentialStatus)
      }
    }
    let me = await identity(stored, now: now)
    let snapshot = ProviderSnapshot(
      provider: .cursor,
      identity: CursorMapper.identity(summary, auth: stored, me: me),
      windows: CursorMapper.windows(summary),
      spend: CursorMapper.spend(summary),
      notices: CursorMapper.notices(summary, period: period),
      fetchedAt: now
    )
    return ProviderFetchResult(outcome: .success(snapshot), warnings: warnings)
      .withCredentialStatus(credentialStatus)
  }

  private func identity(_ auth: CursorAuth, now: Date) async -> CursorAPI.Me? {
    if let identityCache, identityCache.accessToken == auth.accessToken, identityCache.expiresAt > now {
      return identityCache.value
    }
    let task: Task<CursorAPI.Me?, Never>
    if let identityTask, identityTask.accessToken == auth.accessToken {
      task = identityTask.task
    } else {
      identityTask?.task.cancel()
      let headers = CursorAPI.cookieHeaders(auth)
      task = Task { [client] in
        try? await client.getJSON(CursorAPI.Me.self, CursorAPI.meURL, headers: headers, operation: "cursor.me")
      }
      identityTask = CursorIdentityTask(accessToken: auth.accessToken, task: task)
    }
    let value = await task.value
    if identityTask?.accessToken == auth.accessToken {
      identityTask = nil
      identityCache = CachedCursorIdentity(
        accessToken: auth.accessToken,
        value: value,
        expiresAt: now.addingTimeInterval(value == nil ? Self.identityFailureTTL : Self.identityTTL))
    }
    return value
  }
}

private struct CachedCursorIdentity {
  let accessToken: String
  let value: CursorAPI.Me?
  let expiresAt: Date
}

private struct CursorIdentityTask {
  let accessToken: String
  let task: Task<CursorAPI.Me?, Never>
}
