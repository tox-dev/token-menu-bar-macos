import AppKit
import TokenMenuBarCore
import TokenMenuBarUI
import UserNotifications

let hasBundle = Bundle.main.bundleIdentifier != nil
let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
#if APPSTORE
  let isAppStore = true
#else
  let isAppStore = false
#endif
// `--export-icon <dir>` renders the branded icon set for Scripts/make-icon.sh; it never starts the UI.
if let index = CommandLine.arguments.firstIndex(of: "--export-icon"), index + 1 < CommandLine.arguments.count {
  let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
  do {
    try AppIcon.exportIconSet(to: directory)
    print("wrote icon set to \(directory.path)")
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("icon export failed: \(error)\n".utf8))
    exit(1)
  }
}

// `--export-menubar <dir>` renders the demo status item onto a menu-bar strip for the website screenshots.
if let index = CommandLine.arguments.firstIndex(of: "--export-menubar"), index + 1 < CommandLine.arguments.count {
  let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
  let snapshots = Dictionary(
    uniqueKeysWithValues: [ProviderID.claude, .codex].map { ($0, DemoData.snapshot($0, now: Date())) })
  let model = StatusItemBuilder.build(
    StatusItemInput(
      snapshots: snapshots, availability: snapshots.mapValues { _ in .current },
      selectedKeys: StatusItemBuilder.defaultSelection(snapshots), format: .stacked, customTemplate: "", decimals: 0,
      hideZeroCells: true, order: .provider, labels: [:], now: Date()))
  do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, dark) in [("menubar-light", false), ("menubar-dark", true)] {
      guard let data = StatusItemRenderer.stripData(for: model, dark: dark) else { continue }
      try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
    print("wrote menu bar strips to \(directory.path)")
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("menu bar export failed: \(error)\n".utf8))
    exit(1)
  }
}

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
