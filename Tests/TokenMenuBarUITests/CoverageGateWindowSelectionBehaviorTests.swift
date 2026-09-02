import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func coverageGateWindowSelectionBindingsPersistSelectionAndLabels() throws {
  let environment = try makeEnvironment()
  var drafts: [WindowKey: String] = [:]
  let list = WindowSelectionList(
    environment: environment,
    labelDrafts: Binding(get: { drafts }, set: { drafts = $0 }))
  let row = try #require(list.groups.first?.rows.first)

  #expect(list.availableKeys.contains(row.key))
  list.selectionBinding(row.key).wrappedValue = false
  #expect(!environment.settings.selectedWindows.contains(row.key))
  list.selectionBinding(row.key).wrappedValue = true
  #expect(environment.settings.selectedWindows.contains(row.key))

  list.label(row.key, window: row.window).wrappedValue = "CUSTOM"
  #expect(environment.settings.shortLabels[row.key] == "CUSTOM")

  drafts[row.key] = nil
  list.commitLabel(row.key, default: row.defaultLabel)
  #expect(environment.settings.shortLabels[row.key] == nil)

  let missingWindow = QuotaWindow(
    id: "missing", label: "Missing model", group: .other, usedPercent: 0, resetsAt: nil)
  let missingKey = WindowKey(.gemini, missingWindow)
  #expect(
    list.label(missingKey, window: missingWindow).wrappedValue
      == StatusItemBuilder.defaultShortLabel(provider: .gemini, window: missingWindow))
  #expect(list.labelConflictDescription(row, conflictingKey: missingKey).contains("Gemini missing"))
}

@Test @MainActor func coverageGateWindowReorderControlsRunButtonAndAccessibilityActions() throws {
  let environment = try makeEnvironment()
  environment.settings.windowOrder = .provider
  var list = WindowSelectionList(environment: environment)
  let firstGroup = try #require(list.groups.first)
  let originalProviders = list.orderDraft.providers
  let providerHeader = list.providerHeader(firstGroup)

  for button in selectionGateNativeIconButtons(in: providerHeader) { button.action() }
  #expect(environment.settings.providerOrder != originalProviders)

  list = WindowSelectionList(environment: environment)
  let row = try #require(list.groups.first?.rows.first)
  let originalModels = list.orderDraft.models
  for button in selectionGateNativeIconButtons(in: list.modelRow(row)) { button.action() }
  #expect(environment.settings.modelOrder != originalModels)

  for action in selectionGateVoidActions(in: providerHeader) { action() }
  for action in selectionGateVoidActions(in: list.modelRow(row)) { action() }
}

@Test @MainActor func coverageGateWindowContextAndHoverActionsRemainOperable() throws {
  let environment = try makeEnvironment()
  environment.settings.windowOrder = .provider
  var drafts: [WindowKey: String] = [:]
  var highlighted: WindowKey?
  let list = WindowSelectionList(
    environment: environment,
    highlightedKey: Binding(get: { highlighted }, set: { highlighted = $0 }),
    labelDrafts: Binding(get: { drafts }, set: { drafts = $0 }))
  let group = try #require(list.groups.first)
  let row = try #require(list.groups.first?.rows.first)
  drafts[row.key] = "CUSTOM"
  #expect(inkFraction(list.modelRow(row), width: 880, height: 100) > 0)

  list.queryChangeAction("before", "after")
  list.modelMoveAction(row.key, by: 1)()
  list.revertAction(row)()
  let provider = list.reorderDragAction("model:\(row.key.storageKey)")()
  #expect(provider.canLoadObject(ofClass: NSString.self))

  let hover = try #require(selectionGateHoverActions(in: list.providerHeader(group)).first)
  hover(true)
  hover(false)
  list.hover(true, row: row, target: .model(row.key))
  #expect(highlighted == row.key)
  list.hover(false, row: row, target: .model(row.key))
  #expect(highlighted == nil)
}

@MainActor
private func selectionGateNativeIconButtons(in value: Any, depth: Int = 0) -> [NativeIconButton] {
  if let button = value as? NativeIconButton { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap {
    selectionGateNativeIconButtons(in: $0.value, depth: depth + 1)
  }
}

@MainActor
private func selectionGateHoverActions(in value: Any, depth: Int = 0) -> [(Bool) -> Void] {
  guard depth < 48 else { return [] }
  if let action = value as? (Bool) -> Void { return [action] }
  return Mirror(reflecting: value).children.flatMap {
    selectionGateHoverActions(in: $0.value, depth: depth + 1)
  }
}

@MainActor
private func selectionGateVoidActions(in value: Any, depth: Int = 0) -> [() -> Void] {
  if let action = value as? () -> Void { return [action] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap {
    selectionGateVoidActions(in: $0.value, depth: depth + 1)
  }
}
