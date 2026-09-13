import AppKit

@MainActor
func beginApplicationActivation() -> (@MainActor () -> Void)? {
  let previous = NSWorkspace.shared.frontmostApplication
  NSApplication.shared.activate()
  guard let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
  return {
    // Yielding grants permission; the previous app still needs an activation request.
    NSApplication.shared.yieldActivation(to: previous)
    previous.activate(options: [])
  }
}
