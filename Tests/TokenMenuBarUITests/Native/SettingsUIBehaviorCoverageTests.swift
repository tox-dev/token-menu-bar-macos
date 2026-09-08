import AppKit
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func rootViewWithoutAChooserOffersNoHistoryExportDestination() async throws {
  let root = RootView(environment: try makeEnvironment(), onMeasure: { _ in }, onTabChange: { _ in })
  #expect(await root.chooseHistoryExportURL() == nil)
}

@Test @MainActor func settingsReportsUndiscoveredProvidersAsNotConfigured() throws {
  let environment = try makeEnvironment(populate: false)
  #expect(SettingsTab(environment: environment).providerAvailabilityText(.codex) == "Not configured")
}

@Test(arguments: [ProviderID.codex, nil]) @MainActor
func settingsFocusesARequestedProvider(provider: ProviderID?) async throws {
  let environment = try makeEnvironment()
  let request = ProviderSettingsFocusRequest(provider: provider)
  environment.providerFocusRequest = request
  let fixture = NativeHosting(
    SettingsTab(environment: environment, providerFocusRequest: request, mountsIncrementally: false),
    width: 720, height: 480)
  defer { fixture.close() }
  fixture.show()

  await waitUntil { environment.providerFocusRequest == nil }

  #expect(environment.providerFocusRequest == nil)
  let scroll = try #require(allViews(in: fixture.view).compactMap { $0 as? NSScrollView }.first)
  #expect(scroll.documentVisibleRect.minY > 0)
}

@Test @MainActor func settingsListsOnlyRefreshProvidersSupportedByItsSandboxPolicy() throws {
  let environment = try makeEnvironment(populate: false)
  #expect(SettingsTab(environment: environment).tokenRefreshProviderNames == "Claude and Codex")

  environment.isSandboxed = false
  #expect(SettingsTab(environment: environment).tokenRefreshProviderNames == "Claude, Codex, Gemini, and Antigravity")
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
  let hostingFixture = NativeHosting(
    SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 3_000)
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view

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

@Test(arguments: ["Reset All Settings", "Clear…"], [false, true]) @MainActor
func settingsDestructiveButtonsRequireConfirmation(action: String, confirm: Bool) async throws {
  let environment = try makeEnvironment()
  environment.settings.historyRetentionDays = 7
  var resets = 0
  var cleared = 0
  environment.actions.settingsReset = { resets += 1 }
  environment.actions.clearHistory = { cleared += 1 }
  let fixture = NativeHosting(
    SettingsTab(environment: environment, mountsIncrementally: false),
    width: 880, height: 1_200, styleMask: [.titled])
  defer { fixture.close() }
  fixture.show()
  let window = try #require(fixture.view.window)
  try await loadNativeAccessibility()
  var prompt: NSWindow?
  defer {
    if let prompt, prompt.sheetParent === window {
      window.endSheet(prompt, returnCode: .cancel)
      prompt.orderOut(nil)
    }
  }

  try #require(pressElement(label: action, in: fixture.view))
  #expect(
    await waitUntil {
      CFRunLoopRunInMode(.defaultMode, 0.005, true)
      prompt = window.sheets.first
      return prompt != nil
    })
  let dialog = try #require(prompt?.contentView)
  #expect(resets == 0 && cleared == 0)
  #expect(environment.settings.historyRetentionDays == 7)
  let confirmation = action == "Clear…" ? "Clear History" : "Reset All Settings"
  _ = pressElement(label: confirm ? confirmation : "Cancel", in: dialog)
  #expect(
    await waitUntil {
      CFRunLoopRunInMode(.defaultMode, 0.005, true)
      return window.sheets.isEmpty
    })
  #expect(resets == (confirm && action == "Reset All Settings" ? 1 : 0))
  #expect(cleared == (confirm && action == "Clear…" ? 1 : 0))
  #expect(environment.settings.historyRetentionDays == (resets == 1 ? 60 : 7))
}

@Test(arguments: [["DRAFT"], ["TOOLONG"], ["T", "O", "O", "L", "O", "N", "G"]]) @MainActor
func modelLabelEditsApplyImmediatelyAndSurviveFocusChanges(edits: [String]) async throws {
  let environment = try makeEnvironment()
  let row = try #require(WindowSelectionList(environment: environment).groups.first?.rows.first)
  var drafts: [WindowKey: String] = [:]
  let fixture = NativeHosting(
    WindowSelectionList(
      environment: environment, labelDrafts: Binding(get: { drafts }, set: { drafts = $0 })),
    width: 880, height: 700, styleMask: [.titled])
  defer { fixture.close() }
  fixture.show()
  let window = try #require(fixture.view.window)
  window.makeKey()
  await mainActorTurn()
  let fields = allViews(in: fixture.view).compactMap { $0 as? NSTextField }
  let label = try #require(fields.first { $0.stringValue == row.label })
  let filter = try #require(fields.first { $0.placeholderString == "Filter models…" })
  label.selectText(nil)
  await mainActorTurn()
  let editor = try #require(label.currentEditor() as? NSTextView)
  editor.selectAll(nil)
  for edit in edits {
    editor.insertText(edit, replacementRange: editor.selectedRange())
    await mainActorTurn()
  }
  let expected = String(edits.joined().prefix(6))
  await waitUntil { environment.settings.shortLabels[row.key] == expected }
  #expect(environment.settings.shortLabels[row.key] == expected)
  #expect(editor.string == expected)

  filter.selectText(nil)
  await mainActorTurn()

  #expect(filter.currentEditor() != nil)
  #expect(environment.settings.shortLabels[row.key] == expected)
  #expect(label.stringValue == expected)

  environment.settings.shortLabels[row.key] = nil
  await mainActorTurn()
  #expect(label.stringValue == row.defaultLabel)
  #expect(environment.settings.shortLabels[row.key] == nil)
}

@Test(arguments: [["{label}\n{pct}"], ["{label}", "\n", "{pct}"]]) @MainActor
func customTemplateKeepsNewlinesDuringNativeEditing(edits: [String]) async throws {
  let environment = try makeEnvironment()
  environment.settings.statusFormat = .custom
  environment.disclosures.setExpanded(true, for: "settings.display")
  let fixture = NativeHosting(
    SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 1_600)
  defer { fixture.close() }
  fixture.show()
  let window = try #require(fixture.view.window)
  window.makeKey()
  let editor = try #require(
    allViews(in: fixture.view).compactMap { $0 as? NSTextView }.first {
      $0.isEditable && $0.string == environment.settings.customTemplate
    })
  #expect(window.makeFirstResponder(editor))
  editor.selectAll(nil)
  for edit in edits {
    editor.insertText(edit, replacementRange: editor.selectedRange())
    await mainActorTurn()
  }
  await waitUntil { environment.settings.customTemplate == edits.joined() }
  #expect(environment.settings.customTemplate == "{label}\n{pct}")
  #expect(editor.string == "{label}\n{pct}")
  #expect(try #require(SettingsTab(environment: environment).previewModel.cells.first).lines.count == 2)

  environment.settings.customTemplate = "{provider}\n{label}:{pct}"
  await waitUntil { editor.string == environment.settings.customTemplate }
  #expect(editor.string == "{provider}\n{label}:{pct}")
}

@Test @MainActor func settingsRemountRestoresModelSelectionControls() async throws {
  let environment = try makeEnvironment()
  let firstFixture = NativeHosting(
    AnyView(SettingsTab(environment: environment)),
    width: 880, height: 1_600)
  defer { firstFixture.close() }
  firstFixture.show()
  let first = firstFixture.view
  #expect(await waitUntil { modelFilterField(in: first) != nil })
  first.rootView = AnyView(EmptyView())

  let lastFixture = NativeHosting(
    AnyView(SettingsTab(environment: environment)),
    width: 880, height: 3_000)
  defer { lastFixture.close() }
  lastFixture.show()
  let last = lastFixture.view
  #expect(await waitUntil { modelFilterField(in: last) != nil })
  #expect(last.frame.width == 880)
}

@Test @MainActor func statusPreviewHoverTracksTheCellUnderThePointer() throws {
  let cell = try #require(statusModel().cells.first)
  let key = try #require(WindowKey(storageKey: cell.id))
  let model = StatusItemModel(cells: [cell], iconTone: .normal, showsIcon: false, countdownActive: false)
  var highlighted: WindowKey?
  let preview = StatusPreview(
    model: model,
    highlightedKey: Binding(get: { highlighted }, set: { highlighted = $0 }), select: { _ in })
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
  let providerHeaderFixture = NativeHosting(list.providerHeader(firstGroup), width: 760, height: 80)
  defer { providerHeaderFixture.close() }
  let providerHeader = providerHeaderFixture.view
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
  let modelRowFixture = NativeHosting(list.modelRow(row), width: 760, height: 100)
  defer { modelRowFixture.close() }
  let modelRow = modelRowFixture.view
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
  pressNativeElement(in: root) { $0.accessibilityLabel?() == label || $0.accessibilityTitle?() == label }
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
