import Foundation

public struct Clock: Sendable {
  public let now: @Sendable () -> Date
  public let sleep: @Sendable (TimeInterval) async throws -> Void

  public init(
    now: @escaping @Sendable () -> Date,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void
  ) {
    self.now = now
    self.sleep = sleep
  }

  public static let system = Clock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })

  public static func fixed(_ date: Date) -> Clock {
    Clock(now: { date }, sleep: { _ in })
  }
}

public enum ShutdownPolicy {
  public static let persistenceTimeout = Duration.seconds(1)

  public static func waitForCompletion(
    timeout: Duration = persistenceTimeout,
    pollInterval: Duration = .milliseconds(10),
    operation: @escaping @Sendable () async -> Void
  ) async -> Bool {
    let completion = Completion()
    let task = Task {
      await operation()
      await completion.finish()
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await completion.finished), clock.now < deadline {
      try? await clock.sleep(for: pollInterval)
    }
    let finished = await completion.finished
    if !finished { task.cancel() }
    return finished
  }

  private actor Completion {
    private(set) var finished = false

    func finish() {
      finished = true
    }
  }
}
