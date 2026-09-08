import AppKit
import TokenMenuBarCore
import TokenMenuBarUI
import UserNotifications

// Keep AppKit's blocking event loop outside an async entry point.
if let invocation = ExportInvocation.parse(CommandLine.arguments) {
  Task {
    exit(
      await ExportRunner.execute(
        invocation, output: { print($0) },
        errorOutput: { FileHandle.standardError.write(Data($0.utf8)) }))
  }
  CFRunLoopRun()
  exit(1)
}

#if VERIFICATION
  let launchPolicy = LaunchPolicy(verificationOnly: true)
#else
  let launchPolicy = LaunchPolicy()
#endif
if SingleInstanceGuard.handOff(policy: launchPolicy) { exit(0) }
let appInfo = AppInfo.from(bundle: .main, distribution: .direct)
ApplicationMenu.install(on: NSApplication.shared, appName: appInfo.name)
let paths =
  launchPolicy.supportDirectory.map { supportDirectory in
    LiveDependencies.Paths(
      home: supportDirectory, supportDirectory: supportDirectory, environment: launchPolicy.environment,
      userName: "verification", arguments: CommandLine.arguments, verificationProfile: launchPolicy.verificationProfile)
  } ?? LiveDependencies.Paths(environment: launchPolicy.environment)
let delegate = AppRunner.bootstrapDeferred(
  distribution: appInfo.distribution,
  notificationCenter: launchPolicy.mode == .verification || Bundle.main.bundleIdentifier == nil
    ? nil : UNUserNotificationCenter.current(),
  updater: launchPolicy.mode == .verification ? nil : Updater.make(appInfo: appInfo),
  isSandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil, paths: paths,
  defaults: launchPolicy.defaults(),
  transport: launchPolicy.mode == .verification ? DisabledHTTPTransport() : SystemHTTPTransport.make(),
  keychain: launchPolicy.mode == .verification ? .empty : .system,
  launchAtLogin: launchPolicy.mode == .verification ? .inMemory() : LaunchAtLoginService.backend()
)
NSApplication.shared.delegate = delegate
#if VERIFICATION
  let wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
    MainActor.assumeIsolated {
      guard let log = delegate.controller?.dependencies.log, log.debugEnabled, let window = event.window,
        let content = window.contentView
      else { return }
      let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
      let hit = content.hitTest(point)
      var scrolls: [NSScrollView] = []
      var ancestor = hit
      while let view = ancestor {
        if let scroll = view as? NSScrollView { scrolls.append(scroll) }
        ancestor = view.superview
      }
      let targets = scrolls
      log.logDebug(
        "wheel.received time=\(event.timestamp) point=\(event.locationInWindow) delta=\(event.scrollingDeltaY) "
          + "phase=\(event.phase.rawValue) hit=\(String(describing: hit)) "
          + "clips=\(targets.map { $0.contentView.bounds })")
      DispatchQueue.main.async {
        log.logDebug("wheel.applied time=\(event.timestamp) clips=\(targets.map { $0.contentView.bounds })")
      }
    }
    return event
  }
#endif
NSApplication.shared.run()
