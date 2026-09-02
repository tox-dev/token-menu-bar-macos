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
  private var credentialStateCalls = 0
  private var credentialHealthCalls = 0
  private let gate: TestGate?
  var credentials: CredentialState = .valid(expiresAt: nil)
  var health: ProviderCredentialHealth = .unchecked

  init(id: ProviderID, results: [ProviderFetchResult], gate: TestGate? = nil) {
    self.id = id
    queue = results
    self.gate = gate
  }

  var credentialDescription: String { "scripted" }
  var callCount: Int { lock.withLock { calls.count } }
  var credentialStateCallCount: Int { lock.withLock { credentialStateCalls } }
  var credentialHealthCallCount: Int { lock.withLock { credentialHealthCalls } }

  func credentialState(now: Date) -> CredentialState {
    lock.withLock { credentialStateCalls += 1 }
    return credentials
  }

  func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    lock.withLock { credentialHealthCalls += 1 }
    return health
  }

  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    let result = lock.withLock {
      calls.append(options)
      return queue.count > 1 ? queue.removeFirst() : queue[0]
    }
    if let gate { try? await gate.wait() }
    return result
  }
}

final class TestGate: @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var cancelled: Set<UUID> = []
  private var isOpen = false

  func wait() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let state = lock.withLock {
          if isOpen { return 1 }
          if cancelled.remove(id) != nil { return 2 }
          waiters[id] = continuation
          return 0
        }
        if state == 1 { continuation.resume() }
        if state == 2 { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
        guard let waiter = waiters.removeValue(forKey: id) else {
          cancelled.insert(id)
          return nil
        }
        return waiter
      }
      waiter?.resume(throwing: CancellationError())
    }
  }

  func open() {
    let pending = lock.withLock {
      isOpen = true
      defer { waiters.removeAll() }
      return Array(waiters.values)
    }
    for waiter in pending { waiter.resume() }
  }
}

func scriptedProvider(
  _ id: ProviderID, _ result: ProviderFetchResult = ProviderFetchResult(outcome: .failed("unset"))
)
  -> ScriptedProvider
{
  ScriptedProvider(id: id, results: [result])
}
