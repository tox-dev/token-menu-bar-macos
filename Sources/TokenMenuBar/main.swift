import AppKit
import TokenMenuBarUI
import UserNotifications

let hasBundle = Bundle.main.bundleIdentifier != nil
let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
#if APPSTORE
  let isAppStore = true
#else
  let isAppStore = false
#endif
let app = NSApplication.shared
do {
  let delegate = try AppRunner.bootstrap(
    isAppStore: isAppStore,
    notificationCenter: hasBundle ? UNUserNotificationCenter.current() : nil,
    updater: Updater.make(),
    isSandboxed: sandboxed
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
