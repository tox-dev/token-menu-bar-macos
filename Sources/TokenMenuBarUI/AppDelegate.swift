import AppKit
import TokenMenuBarCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public let controller: AppController

  public init(controller: AppController) {
    self.controller = controller
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    controller.start()
  }

  public func applicationWillTerminate(_ notification: Notification) {
    controller.stop()
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    controller.togglePopover()
    return false
  }
}

public enum AppRunner {
  @MainActor
  public static func bootstrap(
    isAppStore: Bool, notificationCenter: (any NotificationCenterProtocol)?, updater: (any UpdaterHook)?,
    isSandboxed: Bool, paths: LiveDependencies.Paths = LiveDependencies.Paths(), defaults: UserDefaults = .standard
  ) throws -> AppDelegate {
    let appInfo = AppInfo.from(bundle: .main, isAppStore: isAppStore)
    let dependencies = try LiveDependencies.make(
      appInfo: appInfo, paths: paths, defaults: defaults, notificationCenter: notificationCenter, updater: updater,
      isSandboxed: isSandboxed)
    return AppDelegate(controller: AppController(dependencies: dependencies))
  }
}
