import Foundation

public struct LaunchAtLoginBackend: Sendable {
  public enum Status: String, Sendable, Equatable {
    case enabled
    case notRegistered
    case notFound
    case requiresApproval
    case unknown

    public var isEnabled: Bool {
      self == .enabled
    }

    public var explanation: String? {
      switch self {
      case .requiresApproval: "Approve Token Menu Bar under System Settings > General > Login Items."
      case .notFound: "Launch at login needs the app to run from /Applications."
      default: nil
      }
    }
  }

  public let status: @Sendable () -> Status
  public let register: @Sendable () throws -> Void
  public let unregister: @Sendable () throws -> Void
  public let openSettings: @Sendable () -> Void

  public init(
    status: @escaping @Sendable () -> Status,
    register: @escaping @Sendable () throws -> Void,
    unregister: @escaping @Sendable () throws -> Void,
    openSettings: @escaping @Sendable () -> Void = {}
  ) {
    self.status = status
    self.register = register
    self.unregister = unregister
    self.openSettings = openSettings
  }

  public static let unsupported = LaunchAtLoginBackend(status: { .unknown }, register: {}, unregister: {})

  public static func inMemory(initiallyEnabled: Bool = false) -> LaunchAtLoginBackend {
    let state = InMemoryLaunchAtLoginState(enabled: initiallyEnabled)
    return LaunchAtLoginBackend(
      status: state.status,
      register: { state.setEnabled(true) },
      unregister: { state.setEnabled(false) })
  }

  public func setEnabled(_ enabled: Bool) -> Status {
    do {
      if enabled { try register() } else { try unregister() }
    } catch {
      return status()
    }
    return status()
  }
}

private final class InMemoryLaunchAtLoginState: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled: Bool

  init(enabled: Bool) {
    self.enabled = enabled
  }

  func status() -> LaunchAtLoginBackend.Status {
    lock.withLock { enabled ? .enabled : .notRegistered }
  }

  func setEnabled(_ enabled: Bool) {
    lock.withLock { self.enabled = enabled }
  }
}
