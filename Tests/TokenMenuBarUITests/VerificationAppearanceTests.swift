import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test(arguments: [VerificationProfile.Appearance.light, .dark, nil]) @MainActor
func verificationLaunchAppliesOnlyItsRequestedAppearance(appearance: VerificationProfile.Appearance?) {
  prepareTestApp()
  let previous = NSApp.appearance
  defer { NSApp.appearance = previous }
  NSApp.appearance = NSAppearance(named: .darkAqua)
  let support = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-appearance-\(UUID().uuidString)")
  _ = AppRunner.bootstrapDeferred(
    distribution: .direct, notificationCenter: nil, updater: nil, isSandboxed: false,
    paths: LiveDependencies.Paths(
      home: support, supportDirectory: support, verificationProfile: VerificationProfile(appearance: appearance)),
    defaults: testDefaults(), transport: DisabledHTTPTransport(), keychain: .empty, launchAtLogin: .inMemory(),
    presentsWindows: false)
  #expect(NSApp.appearance?.name == (appearance == .light ? .aqua : .darkAqua))
}

@Test(arguments: [NSAppearance.Name.aqua, .darkAqua, nil]) @MainActor
func popoverPreservesAnExplicitApplicationAppearance(appearance: NSAppearance.Name?) {
  prepareTestApp()
  let previous = NSApp.appearance
  defer { NSApp.appearance = previous }
  NSApp.appearance = appearance.flatMap(NSAppearance.init(named:))

  let controller = PopoverController(content: AnyView(EmptyView()), presentsWindow: false)

  #expect(controller.popover.appearance?.name == appearance)
}

@Test @MainActor func popoverReplacesNativeRootWithRequestedContent() throws {
  prepareTestApp()
  let controller = PopoverController(content: AnyView(EmptyView()), presentsWindow: false)
  controller.setContent(RootView(environment: try makeEnvironment(), onMeasure: { _ in }))

  controller.setContent(AnyView(Text("Replacement content")))

  let view = try #require(controller.popover.contentViewController?.view)
  let png = try #require(PopoverExporter.png(view, dark: false, size: CGSize(width: 480, height: 240)))
  let directory = URL(
    fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOKEN_MENU_BAR_RENDER_ARTIFACTS"]))
  try RenderedText(contains: ["Replacement content"]).capture(
    png, at: directory.appendingPathComponent("replaced-native-root.png"))
  #expect(view.window == nil)
}
