import AppKit

// Launching a replacement instance asks LaunchServices to open a bundle, which a test cannot do without actually
// opening an app, so this one call lives here and is excluded from the coverage gate.
extension LiveDependencies {
  @MainActor
  public static func workspaceLauncher(
    _ url: URL, _ configuration: NSWorkspace.OpenConfiguration, _ done: @escaping @Sendable () -> Void
  ) {
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done() }
  }
}
