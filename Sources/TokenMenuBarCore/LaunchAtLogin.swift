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

  public func setEnabled(_ enabled: Bool) -> Status {
    do {
      if enabled { try register() } else { try unregister() }
    } catch {
      return status()
    }
    return status()
  }
}
