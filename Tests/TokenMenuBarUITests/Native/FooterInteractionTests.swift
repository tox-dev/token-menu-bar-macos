import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore

@testable import TokenMenuBarUI

@Test(arguments: [548.0, 880], ["footer-copy-diagnostics", "footer-source"]) @MainActor
func footerSettingsButtonsRunTheirInjectedActions(width: CGFloat, identifier: String) async throws {
  _ = nativeAccessibilityApplication
  let environment = try makeEnvironment(populate: false)
  environment.settings.lastTab = .settings
  var copied = 0
  var opened: [URL] = []
  environment.actions.copyDiagnostics = { copied += 1 }
  environment.actions.openURL = { opened.append($0) }
  let fixture = NativeHosting(
    PopoverFooter(environment: environment), width: width, height: PopoverGeometry.footerHeight)
  defer { fixture.close() }
  fixture.show()
  await mainActorTurn()
  let accessibility = await Task.detached {
    let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    var windows: CFTypeRef?
    return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
  }.value
  try #require(accessibility == .success)
  var visited: Set<ObjectIdentifier> = []
  #expect(pressFooterAction(identifier, in: fixture.view, visited: &visited))
  await mainActorTurn()
  #expect(copied == (identifier == "footer-copy-diagnostics" ? 1 : 0))
  #expect(opened == (identifier == "footer-source" ? [environment.appInfo.repository] : []))
}

@MainActor private func pressFooterAction(
  _ identifier: String, in element: AnyObject, visited: inout Set<ObjectIdentifier>
) -> Bool {
  guard visited.insert(ObjectIdentifier(element)).inserted else { return false }
  if element.accessibilityIdentifier?() == identifier, element.accessibilityPerformPress?() == true { return true }
  for child in element.accessibilityChildren?() ?? [] {
    if pressFooterAction(identifier, in: child as AnyObject, visited: &visited) { return true }
  }
  return false
}
