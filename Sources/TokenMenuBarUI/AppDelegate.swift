import AppKit
import TokenMenuBarCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public let controller: AppController
  private var terminationPending = false

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

  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task { [controller] in
      await controller.prepareToTerminate()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    controller.togglePopover()
    return false
  }
}

@MainActor
public final class DeferredAppDelegate: NSObject, NSApplicationDelegate {
  public typealias Loader = @MainActor @Sendable () async throws -> AppDependencies
  public typealias FailureHandler = @MainActor @Sendable (String) -> Void

  public private(set) var controller: AppController?
  public private(set) var statusShellVisible = false
  private let statusBar: NSStatusBar
  private let loader: Loader
  private let failureHandler: FailureHandler
  private var statusShell: NSStatusItem?
  private var loadingTask: Task<Void, Never>?
  private var terminationPending = false

  public init(
    statusBar: NSStatusBar = .system,
    loader: @escaping Loader,
    failureHandler: @escaping FailureHandler
  ) {
    self.statusBar = statusBar
    self.loader = loader
    self.failureHandler = failureHandler
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    showStatusShell()
    loadingTask = Task { [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      do {
        let dependencies = try await loader()
        guard !Task.isCancelled else { return }
        let controller = AppController(dependencies: dependencies, initialStatusItem: statusShell)
        self.controller = controller
        controller.start()
        statusShell = nil
        statusShellVisible = false
      } catch {
        removeStatusShell()
        failureHandler(String(describing: error))
      }
    }
  }

  public func applicationWillTerminate(_ notification: Notification) {
    loadingTask?.cancel()
    loadingTask = nil
    controller?.stop()
    removeStatusShell()
  }

  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller else {
      loadingTask?.cancel()
      return .terminateNow
    }
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task {
      await controller.prepareToTerminate()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    controller?.togglePopover()
    return false
  }

  private func showStatusShell() {
    let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "…"
    item.button?.toolTip = "Token Menu Bar is starting"
    item.button?.setAccessibilityLabel("Token Menu Bar is starting")
    statusShell = item
    statusShellVisible = true
  }

  private func removeStatusShell() {
    guard let statusShell else { return }
    statusBar.removeStatusItem(statusShell)
    self.statusShell = nil
    statusShellVisible = false
  }
}

public enum AppRunner {
  @MainActor
  public static func bootstrap(
    distribution: DistributionChannel, notificationCenter: (any NotificationCenterProtocol)?,
    updater: (any UpdaterHook)?,
    isSandboxed: Bool, paths: LiveDependencies.Paths = LiveDependencies.Paths(), defaults: UserDefaults = .standard,
    transport: any HTTPTransport, keychain: KeychainCredentialClient, launchAtLogin: LaunchAtLoginBackend
  ) async throws -> AppDelegate {
    let appInfo = AppInfo.from(bundle: .main, distribution: distribution)
    let dependencies = try await LiveDependencies.make(
      appInfo: appInfo, paths: paths, defaults: defaults, notificationCenter: notificationCenter, updater: updater,
      isSandboxed: isSandboxed, transport: transport, keychain: keychain, launchAtLogin: launchAtLogin)
    return AppDelegate(controller: AppController(dependencies: dependencies))
  }

  @MainActor
  public static func bootstrapDeferred(
    distribution: DistributionChannel, notificationCenter: (any NotificationCenterProtocol)?,
    updater: (any UpdaterHook)?,
    isSandboxed: Bool, paths: LiveDependencies.Paths = LiveDependencies.Paths(), defaults: UserDefaults = .standard,
    transport: any HTTPTransport, keychain: KeychainCredentialClient, launchAtLogin: LaunchAtLoginBackend
  ) -> DeferredAppDelegate {
    let appInfo = AppInfo.from(bundle: .main, distribution: distribution)
    return DeferredAppDelegate {
      try await LiveDependencies.makeDeferred(
        appInfo: appInfo, paths: paths, defaults: defaults, notificationCenter: notificationCenter, updater: updater,
        isSandboxed: isSandboxed, transport: transport, keychain: keychain, launchAtLogin: launchAtLogin)
    } failureHandler: { detail in
      let alert = NSAlert()
      alert.messageText = "Token Menu Bar cannot start"
      alert.informativeText = detail
      alert.runModal()
      NSApplication.shared.terminate(nil)
    }
  }
}
