import AppKit
import ObjectiveC
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Suite(.serialized)
struct StartupCoverageTests {
  @Test @MainActor func launchPopoverWaitsWhileTheStatusItemIsDetached() async throws {
    let providers = [
      ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude)))),
      ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex)))),
    ]
    let (dependencies, _) = try makeDependencies(providers: providers)
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    let button = try #require(controller.statusItem?.item.button)

    button.removeFromSuperview()
    try await Task.sleep(for: .milliseconds(1_100))

    #expect(button.window == nil)
    #expect(controller.popover?.isShown == false)
  }

  @Test @MainActor func launchPopoverOpensOnceAfterStableAttachment() async throws {
    let providers = [
      ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude)))),
      ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex)))),
    ]
    let (dependencies, _) = try makeDependencies(providers: providers)
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    let button = try #require(controller.statusItem?.item.button)
    let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let window = NSWindow(
      contentRect: CGRect(x: visibleFrame.midX, y: visibleFrame.maxY - 24, width: 24, height: 24),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    button.removeFromSuperview()
    button.frame = window.contentView?.bounds ?? CGRect(x: 0, y: 0, width: 24, height: 24)
    window.contentView?.addSubview(button)
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let popover = try #require(controller.popover)

    await waitUntil(within: 1) { popover.isShown }

    #expect(popover.isShown)
    popover.close()
    #expect(!popover.isShown)
  }

  @Test @MainActor func applicationActivationNotificationRediscoversProviders() async throws {
    let dateSource = StartupDateSource()
    let clock = Clock(
      now: { dateSource.now }, sleep: { _ in try await CancellationSuspension.wait() })
    let (dependencies, _) = try makeDependencies(clock: clock)
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    dateSource.advance(by: ProviderRediscoveryPolicy.activationInterval + 1)

    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)

    await waitUntil { controller.dependencies.registry.ids == [.codex] }
    #expect(controller.dependencies.registry.ids == [.codex])
  }

  @Test @MainActor func popoverUsesTheVisibleFrameWhenItsAnchorHasNoFrame() {
    quietTestApp()
    let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let window = NSWindow(
      contentRect: CGRect(x: visibleFrame.midX, y: visibleFrame.maxY - 20, width: 20, height: 20),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let anchor = NSView(frame: .zero)
    window.contentView?.addSubview(anchor)
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let controller = PopoverController(
      content: AnyView(Text("fallback")), animates: false, presentsWindow: false)

    controller.show(relativeTo: anchor, anchorFrame: nil, visibleFrame: visibleFrame)
    defer { controller.close() }

    let fallbackAnchor = CGRect(x: visibleFrame.midX, y: visibleFrame.maxY, width: 1, height: 1)
    #expect(
      controller.maximum
        == PopoverGeometry.maxSize(
          anchor: fallbackAnchor, visibleFrame: visibleFrame, popoverChromeSize: controller.popoverChromeSize))
  }

  @Test @MainActor func appDelegateDefersRepeatedTerminationRequestsUntilPersistenceFinishes() async throws {
    let (dependencies, _) = try makeDependencies()
    let controller = AppController(dependencies: dependencies)
    controller.coordinator.start()
    let delegate = AppDelegate(controller: controller)

    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
    await waitUntil { !controller.coordinator.isRunning }
    await mainActorTurn()
    await mainActorTurn()

    #expect(!controller.coordinator.isRunning)
  }

  @Test @MainActor func deferredAppDelegateReportsLoadingFailuresAndRemovesItsShell() async {
    var failures: [String] = []
    let delegate = DeferredAppDelegate {
      throw StartupFailure.failed
    } failureHandler: {
      failures.append($0)
    }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

    await waitUntil { failures.count == 1 }

    #expect(failures == ["failed"])
    #expect(!delegate.statusShellVisible)
    #expect(delegate.controller == nil)
  }

  @Test @MainActor func deferredAppDelegateTerminatesImmediatelyBeforeLoadingStarts() {
    let delegate = DeferredAppDelegate {
      throw StartupFailure.failed
    } failureHandler: { _ in
    }

    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
  }

  @Test @MainActor func deferredAppDelegateCancelsBeforeTheLoaderStarts() async {
    var loads = 0
    let delegate = DeferredAppDelegate {
      loads += 1
      throw StartupFailure.failed
    } failureHandler: { _ in
    }

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    await mainActorTurn()

    #expect(loads == 0)
    #expect(!delegate.statusShellVisible)
  }

  @Test @MainActor func deferredAppDelegateReopensAndDefersTerminationAfterLoading() async throws {
    let (dependencies, _) = try makeDependencies()
    let delegate = DeferredAppDelegate {
      dependencies
    } failureHandler: {
      Issue.record("unexpected startup failure: \($0)")
    }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    await waitUntil { delegate.controller != nil }
    let controller = try #require(delegate.controller)

    #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
    await waitUntil { !controller.coordinator.isRunning }
    await mainActorTurn()
    await mainActorTurn()

    #expect(!controller.coordinator.isRunning)
  }

  @Test @MainActor func deferredBootstrapShowsFailureThenRequestsTermination() async {
    quietTestApp()
    let application = NSApplication.shared
    let previousDelegate = application.delegate
    let terminationCanceller = TerminationCancellingDelegate()
    application.delegate = terminationCanceller
    let original = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))!
    let replacement = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.startupCoverageRunModal))!
    method_exchangeImplementations(original, replacement)
    let delegate = AppRunner.bootstrapDeferred(
      distribution: .appStore, notificationCenter: nil, updater: nil, isSandboxed: false,
      paths: LiveDependencies.Paths(
        home: URL(fileURLWithPath: "/dev/null"), supportDirectory: URL(fileURLWithPath: "/dev/null"), environment: [:],
        userName: "tester"),
      defaults: UserDefaults(suiteName: "deferred-failure-\(UUID().uuidString)")!, transport: NoNetworkTransport(),
      keychain: testKeychain, launchAtLogin: .inMemory())
    defer {
      method_exchangeImplementations(replacement, original)
      delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
      application.delegate = previousDelegate
    }

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    await waitUntil { terminationCanceller.requests == 1 }

    #expect(terminationCanceller.requests == 1)
    #expect(!delegate.statusShellVisible)
    #expect(delegate.controller == nil)
  }

  @Test @MainActor func deferredBootstrapStartsTheDemoGraph() async throws {
    quietTestApp()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let delegate = AppRunner.bootstrapDeferred(
      distribution: .direct, notificationCenter: nil, updater: nil, isSandboxed: false,
      paths: LiveDependencies.Paths(
        home: root, supportDirectory: root.appendingPathComponent("support"),
        environment: ["TOKEN_MENU_BAR_DEMO": "1"], userName: "tester"),
      defaults: UserDefaults(suiteName: "deferred-success-\(UUID().uuidString)")!, transport: NoNetworkTransport(),
      keychain: testKeychain, launchAtLogin: .inMemory())
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

    await waitUntil(within: 30) { delegate.controller != nil }

    #expect(delegate.controller != nil)
    #expect(!delegate.statusShellVisible)
  }

  @Test @MainActor func brandAccentResolvesToTheAppearanceSpecificIris() throws {
    let cases: [(NSAppearance.Name, BrandColor)] = [(.aqua, Brand.iris), (.darkAqua, Brand.irisDark)]

    for (name, expectedBrand) in cases {
      let appearance = try #require(NSAppearance(named: name))
      var resolved: NSColor?
      appearance.performAsCurrentDrawingAppearance {
        resolved = NSColor(Color.brandAccent).usingColorSpace(.sRGB)
      }
      let actual = try #require(resolved)
      let expected = try #require(NSColor(cgColor: expectedBrand.cgColor)?.usingColorSpace(.sRGB))

      #expect(abs(actual.redComponent - expected.redComponent) < 0.001)
      #expect(abs(actual.greenComponent - expected.greenComponent) < 0.001)
      #expect(abs(actual.blueComponent - expected.blueComponent) < 0.001)
      #expect(abs(actual.alphaComponent - expected.alphaComponent) < 0.001)
    }
  }

  @Test @MainActor func deferredDependenciesAssembleAndCapTheVerificationFrame() async throws {
    let screen = try #require(NSScreen.main)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-deferred-live-\(UUID().uuidString)")
    let support = root.appendingPathComponent("support")
    let dependencies = try await LiveDependencies.makeDeferred(
      appInfo: testAppInfo,
      paths: LiveDependencies.Paths(
        home: root, supportDirectory: support, environment: ["TOKEN_MENU_BAR_DEMO": "1"], userName: "tester",
        arguments: [],
        verificationProfile: VerificationProfile(
          fixture: .longText, visibleFrameWidth: Double(screen.visibleFrame.width + 100))),
      defaults: UserDefaults(suiteName: "deferred-live-\(UUID().uuidString)")!, notificationCenter: nil, updater: nil,
      isSandboxed: false, transport: NoNetworkTransport(), keychain: testKeychain, launchAtLogin: .inMemory())

    #expect(dependencies.history.location == support.appendingPathComponent("usage-demo.sqlite"))
    #expect(dependencies.registry.ids == ProviderID.allCases.sorted())
    #expect(
      dependencies.state.state(for: .codex).credentialHealth.source?.detail
        .hasSuffix("account-profile-with-a-deliberately-long-file-name.json") == true)
    let visibleFrame = try #require(dependencies.screenVisibleFrame())
    #expect(visibleFrame.width == screen.visibleFrame.width)
    #expect(visibleFrame.maxX == screen.visibleFrame.maxX)
    #expect(visibleFrame.minY == screen.visibleFrame.minY)
    #expect(visibleFrame.height == screen.visibleFrame.height)
  }

  @Test @MainActor func liveChooserDefaultsReturnNilWhenTheirNativePanelsAreAborted() {
    quietTestApp()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-native-panels-\(UUID().uuidString)")
    let paths = LiveDependencies.Paths(home: root, supportDirectory: root, environment: [:], userName: "tester")
    let chooseExport = LiveDependencies.exportChooser(profile: nil, supportDirectory: root)
    let saveOriginal = class_getInstanceMethod(NSSavePanel.self, #selector(NSSavePanel.runModal))!
    let saveReplacement = class_getInstanceMethod(NSSavePanel.self, #selector(NSSavePanel.startupCoverageRunModal))!
    method_exchangeImplementations(saveOriginal, saveReplacement)
    let export = chooseExport()
    method_exchangeImplementations(saveReplacement, saveOriginal)
    #expect(export == nil)

    let chooseDirectory = LiveDependencies.directoryChooser(profile: nil, paths: paths, supportDirectory: root)
    let openOriginal = class_getInstanceMethod(NSOpenPanel.self, #selector(NSOpenPanel.runModal))!
    let openReplacement = class_getInstanceMethod(
      NSOpenPanel.self, #selector(NSOpenPanel.startupCoverageOpenPanelRunModal))!
    method_exchangeImplementations(openOriginal, openReplacement)
    let directory = chooseDirectory(ProviderID.codex.sandboxResources[0])
    method_exchangeImplementations(openReplacement, openOriginal)
    #expect(directory == nil)
  }
}

private enum StartupFailure: Error {
  case failed
}

private final class StartupDateSource: @unchecked Sendable {
  private let lock = NSLock()
  private var date = fixedNow

  var now: Date { lock.withLock { date } }

  func advance(by interval: TimeInterval) {
    lock.withLock { date.addTimeInterval(interval) }
  }
}

@MainActor
private final class TerminationCancellingDelegate: NSObject, NSApplicationDelegate {
  private(set) var requests = 0

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    requests += 1
    return .terminateCancel
  }
}

extension NSAlert {
  @objc fileprivate func startupCoverageRunModal() -> NSApplication.ModalResponse {
    .cancel
  }
}

extension NSSavePanel {
  @objc fileprivate func startupCoverageRunModal() -> NSApplication.ModalResponse {
    .cancel
  }
}

extension NSOpenPanel {
  @objc fileprivate func startupCoverageOpenPanelRunModal() -> NSApplication.ModalResponse {
    .cancel
  }
}
