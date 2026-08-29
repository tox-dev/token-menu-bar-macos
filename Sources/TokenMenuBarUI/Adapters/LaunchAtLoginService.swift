import AppKit
import ServiceManagement
import TokenMenuBarCore

public enum LaunchAtLoginService {
  public static func backend(service: @escaping @Sendable () -> SMAppService = { .mainApp }) -> LaunchAtLoginBackend {
    LaunchAtLoginBackend(
      status: { status(service().status) },
      register: { try service().register() },
      unregister: { try service().unregister() },
      openSettings: { SMAppService.openSystemSettingsLoginItems() }
    )
  }

  public static func status(_ status: SMAppService.Status) -> LaunchAtLoginBackend.Status {
    switch status {
    case .enabled: .enabled
    case .notRegistered: .notRegistered
    case .notFound: .notFound
    case .requiresApproval: .requiresApproval
    @unknown default: .unknown
    }
  }
}
