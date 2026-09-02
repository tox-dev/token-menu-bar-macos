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

  public func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    auth.credentialHealth(now: now)
  }

  public func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let resolved: (auth: CopilotAuth, source: CredentialSource)
    do {
      guard let loaded = try auth.loadWithSource() else {
        return ProviderFetchResult(outcome: .notAuthenticated("No Copilot credentials. \(id.loginHint)"))
          .withCredentialStatus(.missing("no Copilot sign-in found", provider: id))
      }
      resolved = loaded
    } catch {
      return ProviderFetchResult(outcome: .notAuthenticated("Cannot read Copilot credentials: \(error)"))
        .withCredentialStatus(.unreadable(error, provider: id, fallbackSource: auth.source))
    }
    let stored = resolved.auth
    let credentialStatus = ProviderCredentialStatus.resolved(
      stored.state(now: now), provider: id, source: resolved.source)
    guard !stored.host.isEmpty else {
      return ProviderFetchResult(
        outcome: .notAuthenticated("The GitHub host in Copilot credentials is invalid."),
        recoveryIssue: ProviderRecoveryIssue(
          kind: .credentialUnreadable,
          title: "GitHub Copilot credentials could not be read",
          detail: "Sign in again with a valid GitHub or GitHub Enterprise host.",
          action: id.setup.missingCredentialIssue.action)
      )
      .withCredentialStatus(credentialStatus)
    }
    let user: JSONValue
    do {
      user = try await client.getJSON(
        JSONValue.self, CopilotAPI.userURL(host: stored.host), headers: CopilotAPI.headers(token: stored.token),
        operation: "copilot.user")
    } catch {
      return ProviderFetchResult(outcome: ProviderOutcomeBuilder.outcome(for: error, hint: id.loginHint))
        .withCredentialStatus(credentialStatus)
    }
    let snapshot = ProviderSnapshot(
      provider: .copilot,
      identity: CopilotMapper.identity(user, auth: stored),
      windows: CopilotMapper.windows(user),
      notices: CopilotMapper.notices(user),
      fetchedAt: now
    )
    return ProviderFetchResult(outcome: .success(snapshot))
      .withCredentialStatus(credentialStatus)
  }
}
