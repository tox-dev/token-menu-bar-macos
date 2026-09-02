import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func defaultViewActionsAreInert() throws {
  let environment = try makeEnvironment()
  let root = RootView(environment: environment, onMeasure: { _ in }, onTabChange: { _ in })
  #expect(root.chooseHistoryExportURL() == nil)

  let cell = try #require(statusModel().cells.first)
  let model = StatusItemModel(cells: [cell], iconTone: .normal, showsIcon: false, countdownActive: false)
  let hosting = host(StatusPreview(model: model), width: 180, height: 48)
  #expect(pressElement(label: cell.tooltip, in: hosting))
}

@Test @MainActor func settingsReportsUndiscoveredProvidersAsNotConfigured() throws {
  let environment = try makeEnvironment(populate: false)
  #expect(SettingsTab(environment: environment).providerAvailabilityText(.codex) == "Not configured")
}

@Test @MainActor func authenticationRecoveryPrefersRequiredResourceAccess() {
  for (health, title) in [
    (ResourceAccessHealth.needed, "File access needed"),
    (ResourceAccessHealth.stale, "Access grant needs renewal"),
  ] {
    let state = AppState()
    let resource = ProviderID.codex.sandboxResources[0]
    let source = ProviderID.codex.credentialSource("codex.file")
    state.applySetupStates([
      .codex: ProviderSetupState(
        enabled: true, credential: .valid(source: source, expiresAt: nil),
        resources: [ResourceAccessState(resource: resource, health: health)])
    ])

    state.update(.codex) { $0.availability = .authenticationRequired }

    let issue = state.state(for: .codex).recoveryIssue
    #expect(issue?.kind == .resourceAccess)
    #expect(issue?.title == title)
    #expect(issue?.detail == "Grant access to ~/.codex so Codex data can be read.")
    #expect(issue?.action == .grantAccess(resource))
  }
}

@Test @MainActor func settingsPreviewFocusesItsModelAndCommitsPreviousLabel() async throws {
  let environment = try makeEnvironment()
  let cells = SettingsTab(environment: environment).previewModel.cells
  let first = try #require(cells.first)
  let second = try #require(cells.dropFirst().first)
  let firstKey = try #require(WindowKey(storageKey: first.id))
  let hosting = host(
    SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 3_000)

  #expect(pressElement(label: first.tooltip, in: hosting))
  await waitUntil { hosting.window?.firstResponder is NSTextView }
  let editor = try #require(hosting.window?.firstResponder as? NSTextView)
  editor.selectAll(nil)
  editor.insertText("FOCUS", replacementRange: editor.selectedRange())
  #expect(pressElement(label: second.tooltip, in: hosting))
  await waitUntil { environment.settings.shortLabels[firstKey] == "FOCUS" }
  #expect(environment.settings.shortLabels[firstKey] == "FOCUS")
}

@Test @MainActor func settingsRecoveryButtonRunsItsAction() throws {
  let environment = try makeEnvironment()
  let issue = ProviderRecoveryIssue(
    kind: .credentialPersistence, title: "Token not saved", detail: "The credential file changed.",
    action: .checkAgain)
  environment.state.update(.claude) { $0.recoveryIssue = issue }
  var refreshed: [ProviderID] = []
  environment.actions.refreshProvider = { refreshed.append($0) }
  let row = SettingsTab(environment: environment).providerRow(.claude)

  let button = try #require(nativeButtons(in: row).first)
  button.action()
  #expect(refreshed == [.claude])
}

@Test @MainActor func settingsRemountIsReadyWithoutADeferredFill() async throws {
  let environment = try makeEnvironment()
  let firstReady = ReadyState()
  let first = host(
    AnyView(
      SettingsTab(environment: environment)
        .onPreferenceChange(SettingsContentReadyKey.self) { firstReady.set($0) }),
    width: 880, height: 1_600)
  await waitUntil { firstReady.value }
  #expect(firstReady.value)
  first.rootView = AnyView(EmptyView())

  let lastReady = ReadyState()
  let last = host(
    AnyView(
      SettingsTab(environment: environment)
        .onPreferenceChange(SettingsContentReadyKey.self) { lastReady.set($0) }),
    width: 880, height: 3_000)
  await waitUntil { lastReady.value }
  #expect(lastReady.value)
  #expect(last.frame.width == 880)
}

@Test @MainActor func statusPreviewHoverTracksTheCellUnderThePointer() throws {
  let cell = try #require(statusModel().cells.first)
  let key = try #require(WindowKey(storageKey: cell.id))
  let model = StatusItemModel(cells: [cell], iconTone: .normal, showsIcon: false, countdownActive: false)
  var highlighted: WindowKey?
  let preview = StatusPreview(
    model: model,
    highlightedKey: Binding(get: { highlighted }, set: { highlighted = $0 }))
  let hover = try #require(hoverActions(in: preview.preview(cell)).first)

  hover(true)
  #expect(highlighted == key)
}

@Test @MainActor func modelRowHoverTracksTheModelUnderThePointer() throws {
  let environment = try makeEnvironment()
  let list = WindowSelectionList(environment: environment)
  let row = try #require(list.groups.first?.rows.first)
  var highlighted: WindowKey?
  let bound = WindowSelectionList(
    environment: environment,
    highlightedKey: Binding(get: { highlighted }, set: { highlighted = $0 }))
  let hover = try #require(hoverActions(in: bound.modelRow(row)).first)

  hover(true)
  #expect(highlighted == row.key)

  bound.hover(false, row: row, target: .model(row.key))
  #expect(highlighted == nil)
}

@Test @MainActor func modelRowsRenderConflictOverrideAndPlainLabelStates() throws {
  let environment = try makeEnvironment()
  environment.settings.windowOrder = .percent
  var drafts: [WindowKey: String] = [:]
  var list = WindowSelectionList(
    environment: environment,
    labelDrafts: Binding(get: { drafts }, set: { drafts = $0 }))
  let rows = list.groups.flatMap(\.rows)
  let first = try #require(rows.first)
  let second = try #require(rows.dropFirst().first)

  list.label(first).wrappedValue = "PAIR"
  list.label(second).wrappedValue = "pair"
  #expect(inkFraction(list.modelRow(second), width: 760, height: 100) > 0)

  drafts = [:]
  environment.settings.shortLabels[first.key] = "CUSTOM"
  list = WindowSelectionList(environment: environment)
  #expect(inkFraction(list.modelRow(try #require(list.row(first.key))), width: 760, height: 100) > 0)

  environment.settings.shortLabels[first.key] = nil
  list = WindowSelectionList(environment: environment)
  #expect(inkFraction(list.modelRow(try #require(list.row(first.key))), width: 760, height: 100) > 0)
}

@Test @MainActor func stableOrderDropTargetsMoveProvidersAndModels() async throws {
  let environment = try makeEnvironment()
  environment.settings.windowOrder = .provider
  var list = WindowSelectionList(environment: environment)
  let firstGroup = try #require(list.groups.first)
  let secondProvider = try #require(list.groups.dropFirst().first?.provider)
  let providerHeader = host(list.providerHeader(firstGroup), width: 760, height: 80)
  let unchangedProviders = environment.settings.providerOrder

  performDrop("wrong:\(secondProvider.rawValue)", on: providerHeader)
  await mainActorTurn()
  #expect(environment.settings.providerOrder == unchangedProviders)
  performDrop("provider:\(secondProvider.rawValue)", on: providerHeader)
  await waitUntil { environment.settings.providerOrder.first == secondProvider }
  #expect(environment.settings.providerOrder.first == secondProvider)

  list = WindowSelectionList(environment: environment)
  let models = list.orderDraft.models.filter { $0.provider == firstGroup.provider }
  let firstModel = try #require(models.first)
  let secondModel = try #require(models.dropFirst().first)
  let row = try #require(list.row(firstModel))
  let modelRow = host(list.modelRow(row), width: 760, height: 100)
  let unchangedModels = environment.settings.modelOrder

  performDrop("model:invalid", on: modelRow)
  await mainActorTurn()
  #expect(environment.settings.modelOrder == unchangedModels)
  performDrop("model:\(secondModel.storageKey)", on: modelRow)
  await waitUntil { environment.settings.modelOrder.first { $0.provider == firstGroup.provider } == secondModel }
  #expect(environment.settings.modelOrder.first { $0.provider == firstGroup.provider } == secondModel)
}

@MainActor
private func pressElement(label: String, in root: NSView) -> Bool {
  pressElement(label: label, in: root as Any, depth: 0)
}

@MainActor
private func pressElement(label: String, in value: Any, depth: Int) -> Bool {
  guard depth < 30 else { return false }
  if let view = value as? NSView {
    if view.accessibilityLabel() == label, view.accessibilityPerformPress() { return true }
    if view.subviews.contains(where: { pressElement(label: label, in: $0, depth: depth + 1) }) { return true }
    if (view.accessibilityChildren() ?? []).contains(where: {
      pressElement(label: label, in: $0, depth: depth + 1)
    }) {
      return true
    }
    return false
  }
  if let element = value as? NSAccessibilityElement {
    if element.accessibilityLabel() == label, element.accessibilityPerformPress() { return true }
    return (element.accessibilityChildren() ?? []).contains {
      pressElement(label: label, in: $0, depth: depth + 1)
    }
  }
  return false
}

@MainActor
private func allViews(in root: NSView) -> [NSView] {
  root.subviews.reduce(into: [root]) { views, subview in
    views.append(contentsOf: allViews(in: subview))
  }
}

private func nativeButtons(in value: Any, depth: Int = 0) -> [NativeActionButton<Text>] {
  if let button = value as? NativeActionButton<Text> { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap { nativeButtons(in: $0.value, depth: depth + 1) }
}

private func hoverActions(in value: Any, depth: Int = 0) -> [(Bool) -> Void] {
  guard depth < 48 else { return [] }
  let typeName = String(reflecting: type(of: value))
  if typeName.split(separator: "<", maxSplits: 1).first?.hasSuffix("HoverRegionModifier") == true {
    return booleanActions(in: value)
  }
  return Mirror(reflecting: value).children.flatMap { hoverActions(in: $0.value, depth: depth + 1) }
}

private func booleanActions(in value: Any, depth: Int = 0) -> [(Bool) -> Void] {
  if let action = value as? (Bool) -> Void { return [action] }
  guard depth < 16 else { return [] }
  return Mirror(reflecting: value).children.flatMap { booleanActions(in: $0.value, depth: depth + 1) }
}

@MainActor
private func performDrop(_ payload: String, on root: NSView) {
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("ui-drop-\(UUID().uuidString)"))
  pasteboard.clearContents()
  pasteboard.setString(payload, forType: .string)
  for view in allViews(in: root) where !view.registeredDraggedTypes.isEmpty {
    let info = TestDraggingInfo(
      window: root.window, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
      pasteboard: pasteboard)
    guard view.draggingEntered(info) != [] else { continue }
    guard view.prepareForDragOperation(info) else { continue }
    if view.performDragOperation(info) { return }
  }
}

@MainActor
private final class TestDraggingInfo: NSObject, NSDraggingInfo {
  let draggingDestinationWindow: NSWindow?
  let draggingSourceOperationMask: NSDragOperation = .move
  let draggingLocation: NSPoint
  let draggedImageLocation: NSPoint = .zero
  nonisolated var draggedImage: NSImage? { nil }
  let draggingPasteboard: NSPasteboard
  let draggingSource: Any? = nil
  let draggingSequenceNumber = 1
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  let springLoadingHighlight: NSSpringLoadingHighlight = .none

  init(window: NSWindow?, location: NSPoint, pasteboard: NSPasteboard) {
    draggingDestinationWindow = window
    draggingLocation = location
    draggingPasteboard = pasteboard
  }

  func slideDraggedImage(to _: NSPoint) {}

  override func namesOfPromisedFilesDropped(atDestination _: URL) -> [String]? { nil }

  func enumerateDraggingItems(
    options _: NSDraggingItemEnumerationOptions, for _: NSView?, classes _: [AnyClass],
    searchOptions _: [NSPasteboard.ReadingOptionKey: Any],
    using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}

  func resetSpringLoading() {}
}

private final class ReadyState: @unchecked Sendable {
  private let lock = NSLock()
  private var ready = false

  var value: Bool { lock.withLock { ready } }

  func set(_ value: Bool) {
    lock.withLock { ready = value }
  }
}
