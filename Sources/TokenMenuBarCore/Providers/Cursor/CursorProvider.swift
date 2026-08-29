import Foundation

public actor CursorProvider: UsageProvider {
  public nonisolated let id: ProviderID = .cursor
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .cursor)
  private let auth: any CursorAuthStore
  private let client: APIClient
  private let log: LogBuffer

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

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let stored: CursorAuth
    do {
      guard let loaded = try auth.load() else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Cursor credentials. \(id.loginHint)"))
      }
      stored = loaded
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Cursor credentials: \(error)"))
    }
    if case .expired = stored.state(now: now) {
      return ProviderFetchResult(
        outcome: .notAuthenticated("Cursor session expired; open Cursor to refresh it. \(id.loginHint)"))
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
      }
    }
    let me = try? await client.getJSON(
      CursorAPI.Me.self, CursorAPI.meURL, headers: CursorAPI.cookieHeaders(stored), operation: "cursor.me")
    let snapshot = ProviderSnapshot(
      provider: .cursor,
      identity: CursorMapper.identity(summary, auth: stored, me: me),
      windows: CursorMapper.windows(summary),
      spend: CursorMapper.spend(summary),
      notices: CursorMapper.notices(summary, period: period),
      fetchedAt: now
    )
    return ProviderFetchResult(outcome: .success(snapshot), warnings: warnings)
  }
}
