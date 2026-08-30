import AppKit
import TokenMenuBarCore

@MainActor
public enum ExportRunner {
  public static func run(
    _ command: ExportCommand, directory: URL, now: Date = Date(), settle: Duration = .seconds(2)
  ) async throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    switch command {
    case .icons: return try exportIcons(to: directory)
    case .menuBar: return try exportMenuBar(to: directory, now: now)
    case .popover: return try await exportPopover(to: directory, settle: settle)
    }
  }

  private static func exportIcons(to directory: URL) throws -> [URL] {
    try AppIcon.exportIconSet(to: directory)
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted {
      $0.path < $1.path
    }
  }

  private static func exportMenuBar(to directory: URL, now: Date) throws -> [URL] {
    let snapshots = Dictionary(
      uniqueKeysWithValues: [ProviderID.claude, .codex].map { ($0, DemoData.snapshot($0, now: now)) })
    let model = StatusItemBuilder.build(
      StatusItemInput(
        snapshots: snapshots, availability: snapshots.mapValues { _ in .current },
        selectedKeys: StatusItemBuilder.defaultSelection(snapshots), format: .stacked, customTemplate: "", decimals: 0,
        hideZeroCells: true, order: .provider, labels: [:], now: now))
    var written: [URL] = []
    for (name, dark) in [("menubar-light", false), ("menubar-dark", true)] {
      guard let data = StatusItemRenderer.stripData(for: model, dark: dark) else { continue }
      let url = directory.appendingPathComponent("\(name).png")
      try data.write(to: url)
      written.append(url)
    }
    return written
  }

  // demo data, so no account details reach the website
  private static func exportPopover(to directory: URL, settle: Duration) async throws -> [URL] {
    let suite = "dev.tox.token-menu-bar.export"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let delegate = try AppRunner.bootstrap(
      isAppStore: false, notificationCenter: nil, updater: nil, isSandboxed: false,
      paths: LiveDependencies.Paths(
        supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("tmb-export"),
        environment: ["TOKEN_MENU_BAR_DEMO": "1"]),
      defaults: defaults)
    let controller = delegate.controller
    await controller.coordinator.refresh(RefreshRequest(force: true, analytics: true))
    controller.environment.historyPresenter.reload()
    try? await Task.sleep(for: settle)
    await controller.environment.loadRecentSamples()
    var written: [URL] = []
    for tab in PopoverTab.allCases {
      controller.environment.settings.lastTab = tab
      for (suffix, dark) in [("light", false), ("dark", true)] {
        let measured = MeasuredSize()
        let view = RootView(
          environment: controller.environment, onMeasure: { _, size in measured.value = size },
          onTabChange: { _ in })
        // Render once to let the tab report its natural size, then again at that size, so the shot carries the whole
        // tab rather than the slice the popover would clamp it to. SwiftUI reports the size a run loop turn later.
        _ = PopoverExporter.image(view, dark: dark, size: shotSize)
        try? await Task.sleep(for: .milliseconds(50))
        let size = CGSize(
          width: max(measured.value.width, shotSize.width), height: max(measured.value.height, shotSize.height))
        guard let data = PopoverExporter.png(view, dark: dark, size: size) else { continue }
        let url = directory.appendingPathComponent("popover-\(tab.rawValue.lowercased())-\(suffix).png")
        try data.write(to: url)
        written.append(url)
      }
    }
    return written
  }

  /// The popover as it opens on a 14-inch display. A tab taller than this grows to fit, so the website can show the
  /// whole tab inside a scrolling frame.
  static var shotSize: CGSize {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let anchor = CGRect(x: screen.midX, y: screen.maxY - 24, width: 40, height: 24)
    return CGSize(
      width: PopoverGeometry.preferredWidth(visibleFrame: screen),
      height: min(PopoverGeometry.maxSize(anchor: anchor, visibleFrame: screen).height, 760))
  }
}

@MainActor
final class MeasuredSize {
  var value: CGSize = .zero
}
