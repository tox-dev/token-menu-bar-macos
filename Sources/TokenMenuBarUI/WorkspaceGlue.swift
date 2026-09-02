import AppKit

// Launching a replacement instance asks LaunchServices to open a bundle, which a test cannot do without opening a
// real app, so this one call lives here and the coverage gate skips it.
extension LiveDependencies {
  struct RuntimeActions {
    let openURL: @MainActor (URL) -> Void
    let copy: @MainActor (String) -> Void
    let reveal: @MainActor (URL) -> Void
    let terminate: @MainActor () -> Void
  }

  @MainActor static func resolvedWorkspaceOpen(_ open: WorkspaceOpen?) -> WorkspaceOpen {
    guard let open else {
      return { url, configuration, done in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done() }
      }
    }
    return open
  }

  @MainActor static func windowPresentation(enabled: Bool) -> @MainActor (NSWindow, Any?) -> Void {
    if enabled { return { window, sender in window.makeKeyAndOrderFront(sender) } }
    return { _, _ in }
  }

  @MainActor static func runtimeActions(verification: Bool) -> RuntimeActions {
    if verification {
      return RuntimeActions(openURL: { _ in }, copy: { _ in }, reveal: { _ in }, terminate: {})
    }
    return RuntimeActions(
      openURL: { NSWorkspace.shared.open($0) },
      copy: { copy($0, to: .general) },
      reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
      terminate: { NSApplication.shared.terminate(nil) })
  }

  @MainActor
  public static func workspaceLauncher(
    _ url: URL, _ configuration: NSWorkspace.OpenConfiguration, _ done: @escaping @Sendable () -> Void
  ) {
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in done() }
  }

}
