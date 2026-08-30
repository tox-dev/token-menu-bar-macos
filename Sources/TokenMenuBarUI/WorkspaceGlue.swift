import AppKit

// Launching a replacement instance asks LaunchServices to open a bundle, which a test cannot do without opening a
// real app, so this one call lives here and the coverage gate skips it.
extension LiveDependencies {
  @MainActor
  public static func workspaceLauncher(
    _ url: URL, _ configuration: NSWorkspace.OpenConfiguration, _ done: @escaping @Sendable () -> Void
  ) {
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done() }
  }
}
