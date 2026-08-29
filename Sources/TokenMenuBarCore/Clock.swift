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
