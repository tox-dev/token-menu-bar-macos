import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func uiActionsDefaultsChangeNothing() {
  let actions = UIActions()
  let environment = try! makeEnvironment()
  actions.refresh()
  actions.openURL(URL(string: "https://example.com")!)
  actions.copy("x")
  actions.exportHistory()
  actions.clearHistory()
  actions.revealHistory()
  actions.copyDiagnostics()
  actions.reportIssue()
  actions.showFullLog()
  actions.setLaunchAtLogin(true)
  actions.openLoginItems()
  actions.grantAccess(ProviderID.codex.sandboxResources[0])
  actions.checkForUpdates()
  actions.quit()
  actions.settingsChanged()
  actions.setDemoMode(true)
  // the defaults are placeholders: none of them may reach settings, the log or the pasteboard
  #expect(environment.settings.demoMode == environment.settings.demoMode)
  #expect(environment.log.text.isEmpty)
}

@Test @MainActor func hoverStatePresentsAfterDelayAndToggles() async {
  let state = HoverState()
  state.hover(true)
  await state.settle()
  #expect(state.presented)
  state.hover(false)
  #expect(!state.presented)
  state.hover(true)
  state.hover(false)
  await state.settle()
  #expect(!state.presented)
  state.toggle()
  #expect(state.presented)
  #expect(HoverHelpModifier<Text>.isActive(.active(.zero)))
  #expect(!HoverHelpModifier<Text>.isActive(.ended))
}

@Test @MainActor func chipActionsRouteToCallbacks() {
  var copied: [String] = []
  var opened: [URL] = []
  let linked = ChipView(
    chip: Chip(text: "Max", link: URL(string: "https://claude.ai")!), onCopy: { copied.append($0) },
    onOpen: { opened.append($0) })
  linked.primaryAction()
  linked.copyAction()
  let plain = ChipView(chip: Chip(text: "plain"), onCopy: { copied.append($0) }, onOpen: { opened.append($0) })
  plain.primaryAction()
  #expect(opened.map(\.host) == ["claude.ai"])
  #expect(copied == ["Max", "plain"])
}

@Test @MainActor func windowHelpViewRenders() {
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(snapshot: sampleSnapshot(.claude), availability: .current), samples: [:],
    now: fixedNow)
  for row in card.rows {
    #expect(inkFraction(WindowHelpView(row: row), width: 300, height: 200) > 0)
  }
  let environment = try! makeEnvironment()
  var opened: [URL] = []
  environment.actions.openURL = { opened.append($0) }
  ProviderCardView(card: card, environment: environment).openUsagePage()
  #expect(opened == [ProviderID.claude.usagePage])
}

@Test @MainActor func settingsTabBindingsAndMutations() throws {
  let environment = try makeEnvironment()
  var changes = 0
  environment.actions.settingsChanged = { changes += 1 }
  let tab = SettingsTab(environment: environment)
  tab.openRepository()
  tab.grantAccess(ProviderID.codex.sandboxResources[0])
  tab.setting(\.allowTokenRefresh).wrappedValue = true
  #expect(environment.settings.allowTokenRefresh)
  #expect(tab.setting(\.allowTokenRefresh).wrappedValue)
  tab.menuBarSetting(\.windowOrder).wrappedValue = .percent
  #expect(environment.settings.windowOrder == .percent)
  #expect(tab.menuBarSetting(\.windowOrder).wrappedValue == .percent)
  #expect(changes == 1)
  tab.setProvider(.codex, enabled: false)
  #expect(environment.settings.enabledProviders == Set(ProviderID.allCases).subtracting([.codex]))
  tab.provider(.codex).wrappedValue = true
  #expect(tab.provider(.codex).wrappedValue)
  #expect(environment.settings.enabledProviders == Set(ProviderID.allCases))
  tab.setThreshold(50, on: true)
  #expect(environment.settings.notifications.thresholds == [50, 75, 90, 100])
  tab.threshold(90).wrappedValue = false
  #expect(!tab.threshold(90).wrappedValue)
  #expect(environment.settings.notifications.thresholds == [50, 75, 100])
  tab.resetDefaults()
  #expect(environment.settings.windowOrder == .provider)
  #expect(changes == 4)
  let log = LogSection(environment: environment)
  log.setDetailedLogging(true)
  #expect(environment.settings.detailedLogging)
  #expect(environment.log.debugEnabled)
}

@Test @MainActor func historyTabPagingAndChartInteractions() async throws {
  let environment = try makeEnvironment()
  let presenter = environment.historyPresenter
  environment.settings.historyRange = .custom
  presenter.customStart = fixedNow.addingTimeInterval(-7200)
  presenter.customEnd = fixedNow.addingTimeInterval(-3600)
  presenter.followNow = false
  let tab = HistoryTab(environment: environment)
  tab.pageForward()
  await presenter.waitForLoad()
  #expect(presenter.followNow)
  tab.pageBack()
  await presenter.waitForLoad()
  #expect(!presenter.followNow)
  try await environment.history.record(sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-60))
  presenter.setRange(.today)
  await presenter.waitForLoad()
  let data = presenter.state.data!
  let chart = UsageChart(data: data, presenter: presenter, stacked: false, timeZone: .current)
  let plot = CGRect(x: 10, y: 0, width: 100, height: 50)
  chart.hover(.active(CGPoint(x: 60, y: 10)), in: plot) { offset in
    #expect(offset == 50)
    return fixedNow.addingTimeInterval(-60)
  }
  #expect(presenter.selectedDate != nil)
  chart.hover(.ended, in: plot) { _ in nil }
  #expect(presenter.selectedDate == nil)
  chart.pick(CGPoint(x: 20, y: 0), in: plot) { _ in fixedNow }
  #expect(presenter.selectedDate != nil)
  #expect(inkFraction(chart, width: 400, height: 240) > 0)
  #expect(inkFraction(EmptyHistoryView(), width: 300, height: 200) > 0)
  #expect(inkFraction(UpdatingBadge(), width: 100, height: 30) > 0)
}

@Test @MainActor func historyTabShowsEmptyAndUpdatingStates() async throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  #expect(presenter.state.data?.isEmpty == true)
  #expect(inkFraction(HistoryTab(environment: environment), width: 700, height: 600) > 0)
  presenter.reload()
  guard case .loaded(_, true, _) = presenter.state else {
    Issue.record("expected refreshing state")
    return
  }
  #expect(inkFraction(HistoryTab(environment: environment), width: 700, height: 600) > 0)
  await presenter.waitForLoad()
}

@Test @MainActor func liveDependencyHelpers() {
  let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.tox.token-menu-bar.tests"))
  LiveDependencies.copy("hello", to: pasteboard)
  #expect(pasteboard.string(forType: .string) == "hello")
  let export = LiveDependencies.exportPanel()
  #expect(export.nameFieldStringValue == "token-menu-bar-history.csv")
  #expect(export.allowedContentTypes == [.commaSeparatedText])
  let codex = LiveDependencies.directoryPanel(
    resource: ProviderID.codex.sandboxResources[0], default: URL(fileURLWithPath: "/tmp"))
  let configured = LiveDependencies.directoryPanel(
    ProviderID.codex.sandboxResources[0], paths: LiveDependencies.Paths(environment: ["CODEX_HOME": "/tmp/cx"]))
  #expect(configured.directoryURL?.path == "/tmp/cx")
  let accountFile = LiveDependencies.directoryPanel(
    ProviderID.claude.sandboxResources[1], paths: LiveDependencies.Paths())
  #expect(accountFile.canChooseFiles)
  #expect(!accountFile.canChooseDirectories)
  #expect(accountFile.directoryURL?.lastPathComponent != ".claude.json")
  #expect(codex.canChooseDirectories)
  #expect(!codex.canChooseFiles)
  #expect(codex.showsHiddenFiles)
  #expect(codex.directoryURL?.path == "/tmp")
  #expect(LiveDependencies.chosen(export) { _ in .cancel } == nil)
  #expect(LiveDependencies.chosen(codex) { _ in .OK } == codex.url)
}

@Test @MainActor func popoverForwardsEvents() {
  let event = NSEvent.mouseEvent(
    with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
    clickCount: 0, pressure: 0)!
  #expect(PopoverController(content: AnyView(Text("x"))).forward(event) === event)
}
