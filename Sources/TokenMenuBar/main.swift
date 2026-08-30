import AppKit
import TokenMenuBarCore
import TokenMenuBarUI
import UserNotifications

#if APPSTORE
  let isAppStore = true
#else
  let isAppStore = false
#endif

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
do {
  let delegate = try AppRunner.bootstrap(
    isAppStore: isAppStore,
    notificationCenter: Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil,
    updater: Updater.make(),
    isSandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  )
  app.delegate = delegate
  app.run()
} catch {
  let alert = NSAlert()
  alert.messageText = "Token Menu Bar cannot start"
  alert.informativeText = "\(error)"
  alert.runModal()
  exit(1)
}
