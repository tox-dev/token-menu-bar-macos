import AppKit

public enum SystemLoginLauncher {
  @MainActor public static func open(_ url: URL) async throws {
    // Opening a Terminal document avoids Apple Events and its separate Automation consent.
    _ = try await NSWorkspace.shared.open(
      [url], withApplicationAt: URL(filePath: "/System/Applications/Utilities/Terminal.app"),
      configuration: NSWorkspace.OpenConfiguration())
  }
}
