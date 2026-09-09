import AppKit
import Foundation
import SwiftUI
import Testing
import TokenMenuBarNativeGuard
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@MainActor let nativeAccessibilityApplication: NSApplication = {
  requireNativeTestDesktop()
  let application = NSApplication.shared
  #expect(application.setActivationPolicy(.accessory))
  application.finishLaunching()
  return application
}()

@MainActor
func detachedStatusWindow(holding button: NSStatusBarButton) -> NSWindow {
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
  return window
}

@MainActor
func makeDependencies(
  providers: [any UsageProvider] = [], updater: FakeUpdater? = FakeUpdater(), history: UsageHistoryStore? = nil,
  widgetStore: WidgetSnapshotStore? = nil, snapshotCache: SnapshotCache = SnapshotCache(url: nil),
  isDemo: Bool = false, clock: Clock = sleepingClock,
  rebuildProviders: (@MainActor @Sendable (TokenMenuBarCore.Settings) async -> ProviderRegistry)? = nil
) throws -> (AppDependencies, Recorder) {
  requireNativeTestDesktop()
  prepareTestApp()
  let recorder = Recorder()
  let history = try history ?? UsageHistoryStore(url: nil)
  let settings = makeSettings()
  let state = AppState()
  for provider in providers {
    state.update(provider.id) { $0.credentialState = .valid(expiresAt: nil) }
  }
  let dependencies = AppDependencies(
    appInfo: testAppInfo,
    settings: settings,
    state: state,
    history: history,
    log: makeLog(),
    registry: ProviderRegistry(providers),
    notifier: Notifier(center: FakeNotificationCenter(), log: makeLog()),
    launchAtLogin: LaunchAtLoginBackend(
      status: { .notRegistered }, register: {},
      unregister: { MainActor.assumeIsolated { recorder.unregisteredLoginItem += 1 } },
      openSettings: { MainActor.assumeIsolated { recorder.openedLoginItems += 1 } }),
    clock: clock,
    updater: updater,
    isSandboxed: true,
    isDemo: isDemo,
    openURL: { recorder.urls.append($0) },
    copyToPasteboard: { recorder.copied.append($0) },
    revealInFinder: { recorder.revealed.append($0) },
    chooseExportURL: { recorder.exportURL },
    chooseDirectory: { _ in recorder.codexHome },
    terminate: { recorder.terminated += 1 },
    relaunch: { recorder.relaunched += 1 },
    widgetStore: widgetStore,
    snapshotCache: snapshotCache,
    reloadWidgets: { recorder.reloadedWidgets += 1 },
    rebuildProviders: { settings in
      recorder.rebuilt += 1
      if let rebuildProviders { return await rebuildProviders(settings) }
      return ProviderRegistry([
        ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.codex))))
      ])
    },
    screenVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
    openPopoverOnLaunch: providers.count > 1,
    presentsWindows: true,
    beginPopoverActivation: { nil },
    persistsStatusItemPosition: false
  )
  return (dependencies, recorder)
}

@MainActor
struct NativeHosting<Content: View> {
  let view: NSHostingView<Content>
  private let window: NSWindow

  init(
    _ content: Content, width: CGFloat = 520, height: CGFloat = 700, styleMask: NSWindow.StyleMask = [.borderless]
  ) {
    requireNativeTestDesktop()
    prepareTestApp()
    view = NSHostingView(rootView: content)
    view.sizingOptions = [.intrinsicContentSize]
    view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    window = NSWindow(contentRect: view.frame, styleMask: styleMask, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
  }

  func close() {
    window.contentView = nil
    window.close()
  }

  func show() {
    if let visible = window.screen?.visibleFrame {
      let size = CGSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
      window.setFrame(
        CGRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height), display: false)
    }
    window.orderFrontRegardless()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
  }
}
