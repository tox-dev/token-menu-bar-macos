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
    if let open { return open }
    return { url, configuration, done in workspaceLauncher(url, configuration, done) }
  }

  @MainActor static func windowPresentation(enabled: Bool) -> @MainActor (NSWindow, Any?) -> Void {
    if enabled { return { window, sender in window.makeKeyAndOrderFront(sender) } }
    return { _, _ in }
  }

  @MainActor static func runtimeActions(verification: Bool) -> RuntimeActions {
    if verification {
      return RuntimeActions(
        openURL: { _ in }, copy: { _ in }, reveal: { _ in }, terminate: { NSApplication.shared.terminate(nil) })
    }
    return RuntimeActions(
      openURL: { NSWorkspace.shared.open($0) },
      copy: { copy($0, to: .general) },
      reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
      terminate: { NSApplication.shared.terminate(nil) })
  }

  @MainActor
  public static func workspaceLauncher(
    _ url: URL, _ configuration: NSWorkspace.OpenConfiguration,
    _ done: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
      done(error.map { .failure($0) } ?? .success(()))
    }
  }

}

// Inside the .app the marks ship in a nested bundle that only exists once the app is assembled, so package tests can
// never take that branch.
let providerMarkResourceBundle =
  Bundle.main.url(forResource: "TokenMenuBar_TokenMenuBarUI", withExtension: "bundle").flatMap(Bundle.init(url:))
  ?? Bundle.module
