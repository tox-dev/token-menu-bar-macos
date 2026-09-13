import AppKit
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func loadingProgressUsesTheRingStyleWithoutNativeSpinnerFilters() throws {
  let fixture = NativeHosting(
    ProgressView("Loading history…").progressViewStyle(RingProgressViewStyle()), width: 220, height: 60)
  defer { fixture.close() }
  let rings: [ActivityRingView] = coverageClosureViews(in: fixture.view)
  let nativeIndicators: [NSProgressIndicator] = coverageClosureViews(in: fixture.view)

  #expect(rings.count == 1 && nativeIndicators.isEmpty)
  #expect(
    (try #require(rings.first).layer?.animation(forKey: "rotation") != nil)
      == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
}

@Test @MainActor func cachedTabsDoNotCreateNativeProgressFilters() throws {
  let fixture = NativeHosting(
    RootView(environment: try makeEnvironment(), onMeasure: { _ in }), width: 880, height: 900)
  defer { fixture.close() }
  let containers: [PersistentTabContainer] = coverageClosureViews(in: fixture.view)
  let container = try #require(containers.first)
  for tab in PopoverTab.allCases { container.present(tab) }
  let fields: [NSTextField] = coverageClosureViews(in: fixture.view)
  #expect(fields.contains { $0.placeholderString == "Filter models…" })
  let indicators: [NSProgressIndicator] = coverageClosureViews(in: fixture.view)
  #expect(indicators.isEmpty)
}

@Test @MainActor func coverageClosureRootTabControlChangesTheSelectedTab() throws {
  let environment = try makeEnvironment()
  var selected: [PopoverTab] = []
  var window: NSWindow?
  var focusAtSelection: NSResponder?
  let hostingFixture = NativeHosting(
    RootView(
      environment: environment, onMeasure: { _ in },
      onTabChange: {
        selected.append($0)
        focusAtSelection = window?.firstResponder
      }),
    width: 880, height: 900)
  defer {
    window = nil
    hostingFixture.close()
  }
  let hosting = hostingFixture.view
  let hostWindow = try #require(hosting.window)
  window = hostWindow
  let control: NSSegmentedControl = try #require(
    coverageClosureViews(in: hosting).first { $0.accessibilityLabel() == "Popover tabs" })
  let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
  hosting.addSubview(editor)
  #expect(hostWindow.makeFirstResponder(editor))

  control.selectedSegment = 2
  NSApp.sendAction(try #require(control.action), to: control.target, from: control)

  #expect(environment.settings.lastTab == .settings)
  #expect(selected == [.settings])
  #expect(focusAtSelection === control)
}

@Test @MainActor func rootStartsKeyboardNavigationAtTheTabPicker() throws {
  let fixture = NativeHosting(
    RootView(environment: try makeEnvironment(), onMeasure: { _ in }), width: 880, height: 900)
  defer { fixture.close() }
  let control: NSSegmentedControl = try #require(
    coverageClosureViews(in: fixture.view).first { $0.accessibilityLabel() == "Popover tabs" })

  #expect(try #require(fixture.view.window).initialFirstResponder === control)
}

@Test(arguments: PopoverTab.allCases) @MainActor
func rootTabContentAcceptsKeyboardFocus(tab: PopoverTab) throws {
  let environment = try makeEnvironment()
  environment.settings.lastTab = tab
  let fixture = NativeHosting(RootView(environment: environment, onMeasure: { _ in }), width: 880, height: 900)
  defer { fixture.close() }
  let hosts: [NSHostingView<AnyView>] = coverageClosureViews(in: fixture.view)
  let content = try #require(hosts.first { !$0.isHiddenOrHasHiddenAncestor })
  let window = try #require(fixture.view.window)

  #expect(window.makeFirstResponder(content))
  let focused = try #require(window.firstResponder as? NSView)
  #expect(focused === content || focused.isDescendant(of: content))
}

@Test @MainActor func rootTabClickPresentsItsContentBeforeReturning() throws {
  let environment = try makeEnvironment()
  let hostingFixture = NativeHosting(RootView(environment: environment, onMeasure: { _ in }), width: 880, height: 900)
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
  let control: NSSegmentedControl = try #require(
    coverageClosureViews(in: hosting).first { $0.accessibilityLabel() == "Popover tabs" })
  let containers: [PersistentTabContainer] = coverageClosureViews(in: hosting)
  let container = try #require(containers.first)
  let usage = try #require(container.subviews.first { !$0.isHidden })

  control.selectedSegment = 2
  NSApp.sendAction(try #require(control.action), to: control.target, from: control)

  let settings = try #require(container.subviews.first { !$0.isHidden })
  #expect(settings !== usage)
  #expect(!settings.isHidden)
  #expect(usage.isHidden)
}

@Test(arguments: [PopoverTab.history, .settings]) @MainActor
func tabMouseHitTestingUsesOnlyTheSelectedHost(tab: PopoverTab) throws {
  let environment = try makeEnvironment()
  let root = RootView(environment: environment, onMeasure: { _ in })
  let fixture = NativeHosting(root, width: 880, height: 900)
  defer { fixture.close() }
  fixture.show()
  let container = try #require(environment.tabContainer)
  let outgoing = try #require(container.subviews.first { !$0.isHidden })
  root.select(tab)
  let label = tab == .history ? "Period" : "Order"
  let control: NSSegmentedControl = try #require(
    coverageClosureViews(in: fixture.view).first { $0.accessibilityLabel() == label })
  let point = control.convert(
    CGPoint(x: control.bounds.minX + 12, y: control.bounds.midY), to: container.superview)
  let actual = try #require(container.hitTest(point))

  #expect(actual === control || actual.isDescendant(of: control))
  #expect(outgoing.hitTest(point) == nil)
}

@Test @MainActor func coverageClosureSettingsConfirmationsAndActionsRemainOperable() throws {
  let environment = try makeEnvironment()
  environment.settings.historyRetentionDays = 7
  var resets = 0
  var cleared = 0
  var launchValues: [Bool] = []
  environment.actions.settingsReset = { resets += 1 }
  environment.actions.clearHistory = { cleared += 1 }
  environment.actions.setLaunchAtLogin = { launchValues.append($0) }
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)

  tab.requestResetDefaults()
  tab.cancelResetAction()
  tab.resetAllSettingsAction()

  tab.requestClearHistory()
  tab.clearHistoryAction()
  tab.launchAtLoginBinding.wrappedValue = true

  #expect(cleared == 1)
  #expect(launchValues == [true])
  #expect(resets == 1)
  #expect(environment.settings.historyRetentionDays == 60)
}

@Test(arguments: [CGFloat(702), 880]) @MainActor
func historyMetricMouseHitTargetsItsVisibleControl(width: CGFloat) throws {
  let environment = try makeEnvironment()
  let root = RootView(environment: environment, onMeasure: { _ in })
  let fixture = NativeHosting(root, width: width, height: 900)
  defer { fixture.close() }
  fixture.show()
  root.select(.history)
  let container = try #require(environment.tabContainer)
  let control: NSPopUpButton = try #require(
    coverageClosureViews(in: fixture.view).first { $0.accessibilityIdentifier() == "history-metric" })
  let center = CGPoint(x: control.bounds.midX, y: control.bounds.midY)
  let hit = container.hitTest(control.convert(center, to: container.superview))
  let window = try #require(control.window)
  let screenPoint = window.convertPoint(toScreen: control.convert(center, to: nil))
  let accessible = window.accessibilityHitTest(screenPoint) as? any NSAccessibilityProtocol
  print(
    "HISTORY_METRIC_HIT width=\(width) native=\(String(describing: hit)) "
      + "axRole=\(String(describing: accessible?.accessibilityRole())) "
      + "axLabel=\(String(describing: accessible?.accessibilityLabel())) "
      + "axFrame=\(String(describing: accessible?.accessibilityFrame())) point=\(screenPoint)")
  #expect(hit === control || hit?.isDescendant(of: control) == true)
}

@Test @MainActor func coverageClosureWindowFilterShortcutAndSettingRemainOperable() async throws {
  let environment = try makeEnvironment()
  let hostingFixture = NativeHosting(WindowSelectionList(environment: environment), width: 880, height: 900)
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
  let window = try #require(hosting.window)
  let event = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f",
      isARepeat: false, keyCode: 3))

  #expect(window.performKeyEquivalent(with: event))
  await Task.yield()
  #expect(window.firstResponder is NSTextView)

  environment.settings.hideUnusedModels.toggle()
  await Task.yield()
  #expect(environment.settings.hideUnusedModels)
}

@Test @MainActor func coverageClosureProviderContextAndAccessibilityActionsReorder() throws {
  let environment = try makeEnvironment()
  environment.settings.windowOrder = .provider
  let list = WindowSelectionList(environment: environment)
  let group = try #require(list.groups.dropFirst().first)
  let hostingFixture = NativeHosting(list.providerHeader(group), width: 880, height: 90)
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
  let original = environment.settings.providerOrder
  let available = Set(list.groups.map(\.provider))

  let menuItem = try #require(coverageClosureMenuItems(in: hosting).first { $0.title == "Move Earlier" })
  #expect(NSApp.sendAction(try #require(menuItem.action), to: menuItem.target, from: menuItem))
  #expect(environment.settings.providerOrder != original)

  let moveLater = try #require(coverageClosureMenuItems(in: hosting).first { $0.title == "Move Later" })
  #expect(NSApp.sendAction(try #require(moveLater.action), to: moveLater.target, from: moveLater))
  #expect(environment.settings.providerOrder == original.filter(available.contains))
}

@Test @MainActor func coverageClosureModelContextAndRevertActionsPersistChanges() throws {
  let environment = try makeEnvironment()
  environment.settings.windowOrder = .provider
  var list = WindowSelectionList(environment: environment)
  let keys = list.orderDraft.models.filter { $0.provider == .claude }
  let second = try #require(keys.dropFirst().first)
  let row = try #require(list.row(second))
  let hostingFixture = NativeHosting(list.modelRow(row), width: 880, height: 100)
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
  let original = environment.settings.modelOrder

  let moveEarlier = try #require(coverageClosureMenuItems(in: hosting).first { $0.title == "Move Earlier" })
  #expect(NSApp.sendAction(try #require(moveEarlier.action), to: moveEarlier.target, from: moveEarlier))
  #expect(environment.settings.modelOrder != original)

  environment.settings.setShortLabel("CUSTOM", for: second)
  list = WindowSelectionList(environment: environment)
  let overridden = try #require(list.row(second))
  let button = try #require(
    coverageClosureIconButtons(in: list.modelRow(overridden)).first {
      $0.accessibilityLabel.hasPrefix("Revert label")
    })
  button.action()
  #expect(environment.settings.shortLabels[second] == nil)
}

@MainActor
private func coverageClosureViews<Wanted: NSView>(in root: NSView) -> [Wanted] {
  coverageClosureAllViews(in: root).compactMap { $0 as? Wanted }
}

@MainActor
private func coverageClosureAllViews(in root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { coverageClosureAllViews(in: $0) }
}

@MainActor
private func coverageClosureMenuItems(in root: NSView) -> [NSMenuItem] {
  guard let window = root.window,
    let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: NSPoint(x: root.bounds.midX, y: root.bounds.midY), modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
  else { return [] }
  return coverageClosureAllViews(in: root).flatMap { $0.menu(for: event)?.items ?? [] }
}

private func coverageClosureIconButtons(in value: Any, depth: Int = 0) -> [NativeIconButton] {
  if let button = value as? NativeIconButton { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap {
    coverageClosureIconButtons(in: $0.value, depth: depth + 1)
  }
}
