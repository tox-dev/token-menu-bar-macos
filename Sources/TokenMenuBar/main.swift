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

let launchPolicy = LaunchPolicy()
if SingleInstanceGuard.handOff(policy: launchPolicy) { exit(0) }
let appInfo = AppInfo.from(bundle: .main, distribution: .direct)
ApplicationMenu.install(on: NSApplication.shared, appName: appInfo.name)
let transport: any HTTPTransport =
  launchPolicy.mode == .verification ? DisabledHTTPTransport() : SystemHTTPTransport.make()
let keychain: KeychainCredentialClient = launchPolicy.mode == .verification ? .empty : .system
let launchAtLogin: LaunchAtLoginBackend =
  launchPolicy.mode == .verification ? .inMemory() : LaunchAtLoginService.backend()
let paths =
  if let supportDirectory = launchPolicy.supportDirectory {
    LiveDependencies.Paths(
      home: supportDirectory, supportDirectory: supportDirectory,
      environment: launchPolicy.environment, userName: "verification", arguments: CommandLine.arguments,
      verificationProfile: launchPolicy.verificationProfile)
  } else {
    LiveDependencies.Paths(environment: launchPolicy.environment)
  }
let delegate = AppRunner.bootstrapDeferred(
  distribution: appInfo.distribution,
  notificationCenter: launchPolicy.mode == .verification || Bundle.main.bundleIdentifier == nil
    ? nil : UNUserNotificationCenter.current(),
  updater: launchPolicy.mode == .verification ? nil : Updater.make(appInfo: appInfo),
  isSandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil, paths: paths,
  defaults: launchPolicy.defaults(), transport: transport, keychain: keychain, launchAtLogin: launchAtLogin
)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
