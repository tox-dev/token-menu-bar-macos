import Foundation

public actor CopilotProvider: UsageProvider {
  public nonisolated let id: ProviderID = .copilot
  public nonisolated let pollingPolicy = PollingPolicy.defaults(for: .copilot)
  private let auth: any CopilotAuthStore
  private let client: APIClient
  private let log: LogBuffer

  public init(auth: any CopilotAuthStore, client: APIClient, log: LogBuffer) {
    self.auth = auth
    self.client = client
    self.log = log
  }

  public nonisolated var credentialDescription: String {
    auth.description
  }

  public nonisolated func credentialState(now: Date) -> CredentialState {
    do {
      guard let stored = try auth.load() else { return .missing("no Copilot sign-in found") }
      return stored.state(now: now)
    } catch {
      return .missing("\(error)")
    }
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let stored: CopilotAuth
    do {
      guard let loaded = try auth.load() else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Copilot credentials. \(id.loginHint)"))
      }
      stored = loaded
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Copilot credentials: \(error)"))
    }
    let user: JSONValue
    do {
      user = try await client.getJSON(
        JSONValue.self, CopilotAPI.userURL(host: stored.host), headers: CopilotAPI.headers(token: stored.token),
        operation: "copilot.user")
    } catch {
      return ProviderFetchResult(outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint))
    }
    let snapshot = ProviderSnapshot(
      provider: .copilot,
      identity: CopilotMapper.identity(user, auth: stored),
      windows: CopilotMapper.windows(user),
      notices: CopilotMapper.notices(user),
      fetchedAt: now
    )
    return ProviderFetchResult(outcome: .success(snapshot))
  }
}
