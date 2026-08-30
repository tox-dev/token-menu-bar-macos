import Foundation
import TokenMenuBarCore

// The provider seam for every test that drives the refresh loop: hand it the results a case needs, in order, and it
// replays them while recording the options it was called with.
final class ScriptedProvider: UsageProvider, @unchecked Sendable {
  let id: ProviderID
  var pollingPolicy = PollingPolicy(minimumInterval: 0, activeInterval: 0, defaultInterval: 0)
  private let lock = NSLock()
  private var queue: [ProviderFetchResult]
  private(set) var calls: [FetchOptions] = []
  var credentials: CredentialState = .valid(expiresAt: nil)

  init(id: ProviderID, results: [ProviderFetchResult]) {
    self.id = id
    queue = results
  }

  var credentialDescription: String { "scripted" }

  func credentialState(now: Date) -> CredentialState { credentials }

  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    lock.withLock {
      calls.append(options)
      return queue.count > 1 ? queue.removeFirst() : queue[0]
    }
  }
}

func scriptedProvider(
  _ id: ProviderID, _ result: ProviderFetchResult = ProviderFetchResult(outcome: .failed("unset"))
)
  -> ScriptedProvider
{
  ScriptedProvider(id: id, results: [result])
}
