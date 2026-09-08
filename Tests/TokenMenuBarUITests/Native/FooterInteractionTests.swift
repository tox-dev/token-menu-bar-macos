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
  try await loadNativeAccessibility()
  #expect(pressNativeElement(in: fixture.view) { $0.accessibilityIdentifier?() == identifier })
  await mainActorTurn()
  #expect(copied == (identifier == "footer-copy-diagnostics" ? 1 : 0))
  #expect(opened == (identifier == "footer-source" ? [environment.appInfo.repository] : []))
}
