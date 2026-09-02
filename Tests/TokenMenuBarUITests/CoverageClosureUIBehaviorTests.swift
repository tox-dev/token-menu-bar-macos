import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func coverageClosureRootTabControlChangesTheSelectedTab() throws {
  let environment = try makeEnvironment()
  var selected: [PopoverTab] = []
  let hosting = host(
    RootView(environment: environment, onMeasure: { _ in }, onTabChange: { selected.append($0) }),
    width: 880, height: 900)
  let control: NSSegmentedControl = try #require(
    coverageClosureViews(in: hosting).first { $0.accessibilityLabel() == "Popover tabs" })

  control.selectedSegment = 2
  NSApp.sendAction(try #require(control.action), to: control.target, from: control)

  #expect(environment.settings.lastTab == .settings)
  #expect(selected == [.settings])
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

@Test @MainActor func coverageClosureWindowFilterShortcutAndSettingRemainOperable() async throws {
  let environment = try makeEnvironment()
  let hosting = host(WindowSelectionList(environment: environment), width: 880, height: 900)
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
  let hosting = host(list.providerHeader(group), width: 880, height: 90)
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
  let hosting = host(list.modelRow(row), width: 880, height: 100)
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
  [root] + root.subviews.flatMap(coverageClosureAllViews)
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
