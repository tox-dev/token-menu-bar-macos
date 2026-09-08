import AppKit
import ObjectiveC
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Suite(.serialized)
struct StartupCoverageTests {
  @Test(arguments: [false, true], [false, true]) @MainActor
  func startupOnlyEnablesActivationForPresentedWindows(deferred: Bool, presentsWindows: Bool) throws {
    var (dependencies, _) = try makeDependencies()
    dependencies.presentsWindows = presentsWindows
    let delegate: any NSApplicationDelegate =
      deferred
      ? DeferredAppDelegate(presentsWindows: presentsWindows, persistsStatusItemPosition: false) {
        dependencies
      } failureHandler: {
        Issue.record("\($0)")
      }
      : AppDelegate(controller: AppController(dependencies: dependencies))
    let original = try #require(
      class_getInstanceMethod(NSApplication.self, #selector(NSApplication.setActivationPolicy(_:))))
    let replacement = try #require(
      class_getInstanceMethod(NSApplication.self, #selector(NSApplication.startupCaptureActivationPolicy(_:))))
    capturedActivationPolicies = []
    method_exchangeImplementations(original, replacement)
    defer {
      delegate.applicationWillTerminate?(Notification(name: NSApplication.willTerminateNotification))
      method_exchangeImplementations(replacement, original)
      capturedActivationPolicies = []
    }

    delegate.applicationDidFinishLaunching?(Notification(name: NSApplication.didFinishLaunchingNotification))

    #expect(capturedActivationPolicies == (presentsWindows ? [.accessory] : []))
  }

  @Test @MainActor func launchPopoverWaitsWhileTheStatusItemIsDetached() async throws {
    let providers = [
      ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude)))),
      ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex)))),
    ]
    let clock = ManualClock()
    let (dependencies, _) = try makeDependencies(providers: providers, clock: clock.clock)
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    let button = try #require(controller.statusItem?.item.button)
    let popover = try #require(controller.popover)
    let polls = { clock.sleeps.count(where: { $0 == AppController.attachmentPollInterval }) }

    button.removeFromSuperview()
    await clock.advance(by: AppController.attachmentPollInterval) { polls() >= 10 }

    #expect(button.window == nil)
    #expect(!popover.isShown)

    let window = detachedStatusWindow(holding: button)
    controller.statusItem?.visibleItemFrame = { _ in window.frame }
    defer { window.orderOut(nil) }
    await clock.advance(by: AppController.attachmentPollInterval) { popover.isShown }

    #expect(popover.isShown)
  }

  @Test @MainActor func launchPreparationUsesTheScreenCapBeforeAttachmentPolling() throws {
    let (dependencies, _) = try makeDependencies(clock: sleepingClock)
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    let window = detachedStatusWindow(holding: try #require(controller.statusItem?.item.button))
    defer { window.orderOut(nil) }

    controller.reopen()

    let geometry = controller.popoverGeometry()
    let popover = try #require(controller.popover)
    let anchor = try #require(geometry.anchorFrame)
    let visibleFrame = try #require(geometry.visibleFrame)
    #expect(popover.maximum == PopoverGeometry.maxSize(anchor: anchor, visibleFrame: visibleFrame))
    #expect(!popover.isShown)
  }

  @Test @MainActor func launchPreparationHoldsStatusWidthUntilCancellation() throws {
    let (dependencies, _) = try makeDependencies(clock: sleepingClock)
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    let item = try #require(controller.statusItem)
    let window = detachedStatusWindow(holding: try #require(item.item.button))
    defer { window.orderOut(nil) }
    let width = item.item.length

    controller.reopen()
    item.update(statusModel(format: .stacked))
    #expect(item.item.length == width)
    controller.popover?.close()

    #expect(!controller.dependencies.state.popoverVisible)
    #expect(item.item.length > width)
  }

  @Test @MainActor func launchRecoveryCanShrinkThePreparedStatusItem() throws {
    let (dependencies, _) = try makeDependencies(clock: sleepingClock)
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    let item = try #require(controller.statusItem)
    item.update(ladder: [statusModel(format: .stacked), .empty])
    let width = item.item.length
    controller.reopen()

    #expect(!controller.retryOpening(remainingAttempts: 12, previousButtonFrame: nil, forcedNarrowest: false))

    #expect(item.item.length < width)
    #expect(item.popoverVisible)
    #expect(controller.popover?.isShown == false)
  }

  @Test @MainActor func launchPopoverOpensOnceAfterStableAttachment() async throws {
    let providers = [
      ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude)))),
      ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex)))),
    ]
    let clock = ManualClock()
    var (dependencies, _) = try makeDependencies(providers: providers, clock: clock.clock)
    var activations = 0
    dependencies.beginPopoverActivation = {
      activations += 1
      #expect(!clock.sleeps.contains(AppController.attachmentPollInterval))
      return nil
    }
    let controller = AppController(dependencies: dependencies)
    controller.start()
    defer { controller.stop() }
    let button = try #require(controller.statusItem?.item.button)
    let window = detachedStatusWindow(holding: button)
    controller.statusItem?.visibleItemFrame = { _ in window.frame }
    defer { window.orderOut(nil) }
    let popover = try #require(controller.popover)

    await clock.advance(by: AppController.attachmentPollInterval) { popover.isShown }

    #expect(popover.isShown)
    #expect(activations == 1)
    // The frame has to repeat before the popover opens, so a single poll can never be enough.
    #expect(clock.sleeps.count(where: { $0 == AppController.attachmentPollInterval }) >= 2)
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
    prepareTestApp()
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
      content: AnyView(Text("fallback")), animates: false, presentsWindow: true, beginActivation: { nil })

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
    let delegate = DeferredAppDelegate(presentsWindows: false, persistsStatusItemPosition: false) {
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
    let delegate = DeferredAppDelegate(presentsWindows: false, persistsStatusItemPosition: false) {
      throw StartupFailure.failed
    } failureHandler: { _ in
    }

    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
  }

  @Test @MainActor func deferredAppDelegateCancelsBeforeTheLoaderStarts() async {
    var loads = 0
    let delegate = DeferredAppDelegate(presentsWindows: false, persistsStatusItemPosition: false) {
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
    let delegate = DeferredAppDelegate(presentsWindows: false, persistsStatusItemPosition: false) {
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
    prepareTestApp()
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
        userName: "tester", verificationProfile: VerificationProfile()),
      defaults: testDefaults(), transport: NoNetworkTransport(),
      keychain: testKeychain, launchAtLogin: .inMemory(), presentsWindows: false)
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
    prepareTestApp()
    let original = try #require(
      class_getInstanceMethod(NSStatusItem.self, #selector(setter: NSStatusItem.autosaveName)))
    let replacement = try #require(
      class_getInstanceMethod(NSStatusItem.self, #selector(NSStatusItem.startupCaptureAutosaveName)))
    method_exchangeImplementations(original, replacement)
    defer {
      method_exchangeImplementations(replacement, original)
      capturedStatusAutosaveNames = []
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let delegate = AppRunner.bootstrapDeferred(
      distribution: .direct, notificationCenter: nil, updater: nil, isSandboxed: false,
      paths: LiveDependencies.Paths(
        home: root, supportDirectory: root.appendingPathComponent("support"),
        environment: ["TOKEN_MENU_BAR_DEMO": "1"], userName: "tester"),
      defaults: testDefaults(), transport: NoNetworkTransport(),
      keychain: testKeychain, launchAtLogin: .inMemory(), presentsWindows: false)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }

    await waitUntil(within: 30) { delegate.controller != nil }

    #expect(delegate.controller != nil)
    #expect(delegate.controller?.dependencies.presentsWindows == false)
    #expect(!delegate.statusShellVisible)
  }

  @Test(arguments: [true, false]) @MainActor
  func deferredBootstrapOnlyPersistsRealStatusItemPositions(verification: Bool) throws {
    prepareTestApp()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("status-position-\(UUID().uuidString)")
    let delegate = AppRunner.bootstrapDeferred(
      distribution: .direct, notificationCenter: nil, updater: nil, isSandboxed: false,
      paths: LiveDependencies.Paths(
        home: root, supportDirectory: root, environment: [:], userName: "fixture",
        verificationProfile: verification ? VerificationProfile() : nil),
      defaults: testDefaults(), transport: NoNetworkTransport(), keychain: testKeychain, launchAtLogin: .inMemory(),
      presentsWindows: false)
    let original = try #require(
      class_getInstanceMethod(NSStatusItem.self, #selector(setter: NSStatusItem.autosaveName)))
    let replacement = try #require(
      class_getInstanceMethod(NSStatusItem.self, #selector(NSStatusItem.startupCaptureAutosaveName)))
    capturedStatusAutosaveNames = []
    method_exchangeImplementations(original, replacement)
    defer {
      delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
      method_exchangeImplementations(replacement, original)
      capturedStatusAutosaveNames = []
    }

    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

    #expect(
      capturedStatusAutosaveNames
        == (verification ? [] : [StatusItemController.autosaveName(bundleIdentifier: Bundle.main.bundleIdentifier)]))
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
      defaults: testDefaults(), notificationCenter: nil, updater: nil,
      isSandboxed: false, transport: NoNetworkTransport(), keychain: testKeychain, launchAtLogin: .inMemory())

    let now = dependencies.clock.now()
    try await dependencies.clock.sleep(0.001)
    #expect(dependencies.clock.now() == now)
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

  @Test @MainActor func liveChooserDefaultsReturnNilWhenTheirNativePanelsAreAborted() async {
    prepareTestApp()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-native-panels-\(UUID().uuidString)")
    let paths = LiveDependencies.Paths(home: root, supportDirectory: root, environment: [:], userName: "tester")
    let chooseExport = LiveDependencies.exportChooser(profile: nil, supportDirectory: root, run: { $1(.cancel) })
    let export = await chooseExport()
    #expect(export == nil)

    let chooseDirectory = LiveDependencies.directoryChooser(
      profile: nil, paths: paths, supportDirectory: root, run: { $1(.cancel) })
    let directory = await chooseDirectory(ProviderID.codex.sandboxResources[0])
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

@MainActor private var capturedStatusAutosaveNames: [String] = []
@MainActor private var capturedActivationPolicies: [NSApplication.ActivationPolicy] = []

extension NSApplication {
  @objc fileprivate func startupCaptureActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
    MainActor.assumeIsolated {
      capturedActivationPolicies.append(policy)
      return true
    }
  }
}

extension NSStatusItem {
  @objc fileprivate func startupCaptureAutosaveName(_ name: String?) {
    MainActor.assumeIsolated {
      if let name { capturedStatusAutosaveNames.append(name) }
    }
  }
}
