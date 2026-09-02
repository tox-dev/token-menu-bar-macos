import AppKit
import TokenMenuBarCore
import TokenMenuBarUI
import UserNotifications

// Exporting never starts the UI, so the screenshot script can run it while the app is open.
if let (command, directory) = ExportCommand.parse(CommandLine.arguments) {
  do {
    let written = try await ExportRunner.run(command, directory: directory)
    print("wrote \(written.count) files to \(directory.path)")
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("\(command.failureMessage): \(error)\n".utf8))
    exit(1)
  }
}

let app = NSApplication.shared
let launchPolicy = LaunchPolicy()
let appInfo = AppInfo.from(bundle: .main, distribution: .direct)
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
app.delegate = delegate
app.run()
