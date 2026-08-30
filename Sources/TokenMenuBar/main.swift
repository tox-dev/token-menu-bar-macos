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

// `--export-popover <dir>` renders each tab on demo data for the website, with no shadow or desktop behind it.
if let index = CommandLine.arguments.firstIndex(of: "--export-popover"), index + 1 < CommandLine.arguments.count {
  let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
  let defaults = UserDefaults(suiteName: "dev.tox.token-menu-bar.export")!
  defaults.removePersistentDomain(forName: "dev.tox.token-menu-bar.export")
  do {
    let delegate = try AppRunner.bootstrap(
      isAppStore: false, notificationCenter: nil, updater: nil, isSandboxed: false,
      paths: LiveDependencies.Paths(
        supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("tmb-export"),
        environment: ["TOKEN_MENU_BAR_DEMO": "1"]),
      defaults: defaults)
    let controller = delegate.controller
    await controller.coordinator.refresh(RefreshRequest(force: true, analytics: true))
    controller.environment.historyPresenter.reload()
    try await Task.sleep(for: .seconds(2))
    await controller.environment.loadRecentSamples()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for tab in PopoverTab.allCases {
      controller.environment.settings.lastTab = tab
      for (suffix, dark) in [("light", false), ("dark", true)] {
        let size = CGSize(width: PopoverGeometry.contentWidth(for: tab) + 2 * PopoverGeometry.contentPadding, height: 0)
        let view = RootView(environment: controller.environment, onMeasure: { _, _ in }, onTabChange: { _ in })
        let height = PopoverExporter.height(view, width: size.width)
        guard
          let data = PopoverExporter.png(
            view, size: CGSize(width: size.width, height: max(height, 400)), dark: dark)
        else { continue }
        try data.write(to: directory.appendingPathComponent("popover-\(tab.rawValue.lowercased())-\(suffix).png"))
      }
    }
    print("wrote popover shots to \(directory.path)")
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("popover export failed: \(error)\n".utf8))
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
