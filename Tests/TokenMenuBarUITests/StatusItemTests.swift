import AppKit
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test(arguments: [StatusIconTone.normal, .offline, .attention], [false, true])
@MainActor func appIconDrawsEveryTone(tone: StatusIconTone, dark: Bool) {
  let image = AppIcon.image(height: 18, tone: tone, dark: dark)
  #expect(image.size == CGSize(width: 18, height: 18))
  #expect(image.tiffRepresentation != nil)
  #expect(!image.isTemplate)
}

@Test(
  arguments: [
    (StatusIconTone.offline, false, NSColor.systemGray), (.attention, true, .white), (.normal, false, .black),
  ])
func appIconInkFollowsTone(tone: StatusIconTone, dark: Bool, ink: NSColor) {
  #expect(AppIcon.inkColor(tone: tone, dark: dark) == ink)
}

@Test @MainActor func appIconViewDraws() {
  #expect(host(AppIconView(size: 24, tone: .attention), width: 40, height: 40).fittingSize.width > 0)
  #expect(inkFraction(AppIconView(size: 24).environment(\.colorScheme, .dark), width: 40, height: 40) > 0)
}

@Test @MainActor func statusItemPlacementIsNamespacedByBundle() {
  #expect(StatusItemController.autosaveName(bundleIdentifier: nil) == "dev.tox.token-menu-bar.status")
  #expect(
    StatusItemController.autosaveName(bundleIdentifier: "dev.tox.token-menu-bar.verification")
      == "dev.tox.token-menu-bar.verification.status")
}

@Test @MainActor func statusItemPlacementCanBeEphemeral() {
  let controller = StatusItemController(log: makeLog(), autosaveName: nil) { _ in }
  defer { controller.remove() }

  #expect(controller.item.autosaveName != StatusItemController.autosaveName(bundleIdentifier: nil))
}

@Test @MainActor func statusItemCanReattachAfterItsWindowLeavesTheScreen() {
  let controller = statusController()
  defer { controller.remove() }

  controller.reattach()

  #expect(controller.item.isVisible)
  #expect(controller.item.button?.image != nil)
}

@Test @MainActor func providerGlyphs() {
  #expect(ProviderGlyph.image(.claude, pointSize: 12).size.width > 0)
  #expect(ProviderGlyph.image(.codex, pointSize: 12).size.width > 0)
  #expect(ProviderGlyph.symbolName(.claude) != ProviderGlyph.symbolName(.codex))
  #expect(ProviderGlyph.color(.claude) != ProviderGlyph.color(.codex))
}

@Test @MainActor func rendererFontSizeAndColors() {
  #expect(StatusItemRenderer.fontSizes(height: 18, lineCount: 1) == [13])
  #expect(StatusItemRenderer.fontSizes(height: 24, lineCount: 2) == [9, 11.5])
  #expect(StatusItemRenderer.fontSizes(height: 30, lineCount: 3) == [8, 8, 8])
  #expect(StatusItemRenderer.fontSizes(height: 60, lineCount: 4) == [9, 9, 9, 9])
  #expect(StatusItemRenderer.color(for: .label, dark: true) == .white)
  #expect(StatusItemRenderer.color(for: .label, dark: false) == .black)
  #expect(StatusItemRenderer.color(for: .number, dark: false).alphaComponent < 1)
  let dark = StatusItemRenderer.color(for: .usage(50), dark: true)
  #expect(dark.brightnessComponent > StatusItemRenderer.color(for: .usage(50), dark: false).brightnessComponent)
}

@Test @MainActor func rendererBuildsTitlesForEachFormat() {
  for format in StatusFormat.allCases {
    let model = statusModel(format: format)
    let title = StatusItemRenderer.attributedTitle(for: model, height: 18, dark: false)
    #expect(title.length == max(model.cells.count * 2 - 1, 0))
    for cell in model.cells {
      let image = StatusItemRenderer.cellImage(cell, height: 18, dark: true)
      #expect(image.size.height == 18)
      #expect(image.size.width > 0)
      #expect(image.tiffRepresentation != nil)
    }
    let preview = StatusItemRenderer.previewImage(for: model, height: 18, dark: false)
    #expect(preview.size.width > 0)
    #expect(preview.tiffRepresentation != nil)
  }
  #expect(StatusItemRenderer.accessibilityDescription(for: .empty) == "Token Menu Bar, no usage yet")
  #expect(
    StatusItemRenderer.accessibilityDescription(for: statusModel()).contains("Claude Current session: 36%, resets"))
  #expect(StatusItemRenderer.accessibilityDescription(for: statusModel()).contains("Displayed CC 5h / 36%"))
  #expect(
    StatusItemRenderer.accessibilityDescription(for: statusModel(format: .miniBars))
      .contains("Displayed CC 5h bar at 36%"))
  let empty = StatusItemRenderer.previewImage(for: .empty, height: 18, dark: true)
  #expect(empty.size.width == 18)
  #expect(StatusItemRenderer.attributedTitle(for: .empty, height: 18, dark: false).length == 0)
  let signature = StatusRenderSignature(model: .empty, dark: true, height: 22)
  #expect(signature == StatusRenderSignature(model: .empty, dark: true, height: 22))
}

@Test @MainActor func rendererSizesEmptyTextAndBarCells() {
  let cell = StatusCell(id: "empty", provider: .claude, lines: [], percent: 0, tooltip: "")

  #expect(StatusItemRenderer.textImage(cell, height: 18, dark: false).size.width == StatusItemRenderer.cellPadding * 2)
  #expect(StatusItemRenderer.miniBarImage(cell, height: 18, dark: false).size.width > 0)
}

@MainActor
private func statusController(
  clock: Clock = .system,
  diagnosticProbeInterval: Double = 0.05,
  onPresent: @escaping (NSStatusBarButton) -> Void = { _ in }
)
  -> StatusItemController
{
  let log = makeLog()
  log.debugEnabled = true
  return StatusItemController(
    log: log, clock: clock, diagnosticProbeInterval: diagnosticProbeInterval
  ) { onPresent($0) }
}

private final class CadenceClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date
  private var immediateSleeps: Int
  private var intervals: [TimeInterval] = []

  init(date: Date, immediateSleeps: Int) {
    self.date = date
    self.immediateSleeps = immediateSleeps
  }

  var recordedIntervals: [TimeInterval] {
    lock.withLock { intervals }
  }

  var clock: Clock {
    Clock(
      now: { self.lock.withLock { self.date } },
      sleep: { interval in
        let returnsImmediately = self.lock.withLock {
          self.intervals.append(interval)
          guard self.immediateSleeps > 0 else { return false }
          self.immediateSleeps -= 1
          self.date = self.date.addingTimeInterval(interval)
          return true
        }
        if !returnsImmediately { try await CancellationSuspension.wait() }
      })
  }
}

private final class ResumableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var returnCount = 0

  var isSleeping: Bool {
    lock.withLock { continuation != nil }
  }

  var returnedSleeps: Int {
    lock.withLock { returnCount }
  }

  var clock: Clock {
    Clock(
      now: { fixedNow },
      sleep: { _ in
        try await withCheckedThrowingContinuation { continuation in
          self.lock.withLock { self.continuation = continuation }
        }
        self.lock.withLock { self.returnCount += 1 }
      })
  }

  func resume() {
    let continuation = lock.withLock {
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume()
  }
}

@Test @MainActor func statusItemDrawsTheIconWhenThereIsNothingToShow() {
  let controller = statusController()
  defer { controller.remove() }
  #expect(controller.item.button != nil)
  #expect(controller.barHeight >= 22)
  controller.update(.empty)
  #expect(controller.item.button?.image != nil)
  #expect(controller.item.button?.imagePosition != .noImage)
}

@Test @MainActor func statusItemRendersAnIconBesideNonemptyCells() {
  let controller = statusController()
  defer { controller.remove() }
  let source = statusModel(format: .stacked)
  let model = StatusItemModel(
    cells: source.cells, iconTone: source.iconTone, showsIcon: true, countdownActive: source.countdownActive)

  controller.update(model)

  #expect(controller.item.button?.imagePosition == .imageLeading)
}

@Test @MainActor func statusItemUsesSafeValuesWithoutAStatusBarButton() {
  let controller = StatusItemController(item: NSStatusItem(), log: makeLog(), presentMenu: { _ in })
  defer { controller.remove() }

  _ = controller.isDark
  controller.update(.empty)
  let probe = controller.probe()

  #expect(probe.buttonHidden)
  #expect(probe.buttonWidth == 0)
}

@Test func statusItemProbeSummaryMarksUnavailableValues() {
  let probe = StatusItemProbe(
    isVisible: false, buttonHidden: true, windowVisible: nil, occlusionVisible: nil, length: 0, buttonWidth: 0,
    frontmostApp: nil)

  #expect(probe.summary.contains("window=- occlusion=-"))
  #expect(probe.summary.hasSuffix("front=-"))
}

@Test func statusItemNormalizesAnUnavailableFrontmostContext() {
  #expect(StatusItemController.normalizedContext(nil).isEmpty)
  #expect(StatusItemController.normalizedContext("com.example.editor") == "com.example.editor")
}

@Test @MainActor func statusItemTreatsAnEmptyLadderAsTheEmptyModel() {
  let controller = statusController()
  defer { controller.remove() }

  controller.update(ladder: [])

  #expect(controller.ladder == [.empty])
  #expect(controller.model == .empty)
  #expect(controller.collapseToNarrowest())
}

@Test @MainActor func statusItemDrawsCellsAsAttributedTitle() {
  let controller = statusController()
  defer { controller.remove() }
  controller.update(statusModel(format: .custom))
  #expect(controller.item.button?.attributedTitle.length == 7)
  #expect(controller.item.button?.image == nil)
  #expect(controller.item.button?.toolTip?.contains("Claude") == true)
}

@Test @MainActor func statusItemButtonReadsTheValuesItDraws() {
  let controller = statusController()
  defer { controller.remove() }
  controller.update(.empty)
  #expect(controller.item.button?.accessibilityLabel() == "Token Menu Bar, no usage yet")
  controller.update(statusModel(format: .miniBars))
  let label = controller.item.button?.accessibilityLabel()
  #expect(label?.contains("Current session: 36%") == true)
  #expect(label?.contains("\n") == false)
}

@Test @MainActor func statusItemAccessibilityTracksVisibleSettingsWithoutMovingTheOpenAnchor() throws {
  let controller = statusController()
  defer { controller.remove() }
  controller.adaptive = false
  controller.update(configuredStatusModel(format: .stacked, decimals: 0))
  controller.popoverVisible = true
  let frozenFrame = try #require(controller.item.button?.frame)
  let frozenLength = controller.item.length
  let stackedDescription = try #require(controller.item.button?.accessibilityLabel())
  #expect(stackedDescription.contains("Displayed CC 5h / 36%"))

  controller.update(configuredStatusModel(format: .inline, decimals: 1))
  let inlineDescription = try #require(controller.item.button?.accessibilityLabel())
  #expect(inlineDescription.contains("Displayed CC 5h:36.0%"))
  #expect(inlineDescription != stackedDescription)
  #expect(controller.item.length == frozenLength)
  #expect(controller.item.button?.frame == frozenFrame)

  controller.update(configuredStatusModel(format: .custom, decimals: 2, label: "SOL"))
  let labelDescription = try #require(controller.item.button?.accessibilityLabel())
  #expect(labelDescription.contains("Displayed SOL 36.00%"))
  #expect(labelDescription != inlineDescription)
  #expect(controller.item.length == frozenLength)
  #expect(controller.item.button?.frame == frozenFrame)
}

@Test @MainActor func statusItemRunsTheCountdownOnlyForTemplatesThatNeedIt() async throws {
  let cadence = CadenceClock(date: Date(timeIntervalSince1970: 125), immediateSleeps: 1)
  let controller = statusController(clock: cadence.clock)
  defer { controller.remove() }
  var ticks = 0
  controller.onCountdownTick = { ticks += 1 }
  controller.update(statusModel(format: .custom))
  await waitUntil { ticks == 1 && cadence.recordedIntervals.count == 2 }
  #expect(controller.countdownRunning)
  #expect(cadence.recordedIntervals == [55, 60])
  #expect(ticks == 1)
  controller.update(statusModel(format: .custom))
  #expect(cadence.recordedIntervals == [55, 60])
  controller.update(statusModel(format: .stacked))
  #expect(!controller.countdownRunning)
}

@Test @MainActor func statusItemClearsAStoppedCountdownTask() async {
  let clock = Clock(now: { Date(timeIntervalSince1970: 125) }, sleep: { _ in throw CancellationError() })
  let controller = statusController(clock: clock)
  defer { controller.remove() }
  controller.update(statusModel(format: .custom))
  await waitUntil { !controller.countdownRunning }
  #expect(!controller.countdownRunning)
}

@Test @MainActor func statusItemDoesNotTickAfterCountdownCancellation() async throws {
  let sleeper = ResumableClock()
  let controller = statusController(clock: sleeper.clock)
  defer { controller.remove() }
  var ticks = 0
  controller.onCountdownTick = { ticks += 1 }
  controller.update(statusModel(format: .custom))
  await waitUntil { sleeper.isSleeping }

  controller.update(statusModel(format: .stacked))
  sleeper.resume()

  await waitUntil { sleeper.returnedSleeps == 1 }
  await mainActorTurn()
  #expect(ticks == 0)
}

@Test @MainActor func statusItemTickerDoesNotTickAfterCancellation() async {
  let sleeper = ResumableClock()
  var ticks = 0
  let task = StatusItemController.ticker(every: 30, clock: sleeper.clock) { ticks += 1 }
  await waitUntil { sleeper.isSleeping }

  task.cancel()
  sleeper.resume()
  await task.value

  #expect(ticks == 0)
}

@Test func statusItemCountdownDeadlineIsTheNextMinuteBoundary() {
  #expect(
    StatusItemController.nextCountdownUpdate(after: Date(timeIntervalSince1970: 125))
      == Date(timeIntervalSince1970: 180))
  #expect(
    StatusItemController.nextCountdownUpdate(after: Date(timeIntervalSince1970: 180))
      == Date(timeIntervalSince1970: 240))
}

@Test @MainActor func statusItemProbesPeriodicallyOnlyForDetailedLogging() async throws {
  let cadence = CadenceClock(date: fixedNow, immediateSleeps: 1)
  let controller = statusController(clock: cadence.clock, diagnosticProbeInterval: 30)
  defer { controller.remove() }
  controller.update(statusModel(format: .stacked))
  var probes: [StatusItemProbe] = []
  controller.onProbeChange = { probes.append($0) }
  controller.popoverVisible = true
  controller.layoutChanged(forgetting: false)
  #expect(!controller.diagnosticProbeRunning)
  #expect(probes.isEmpty)
  controller.detailedLoggingEnabled = true
  await waitUntil { probes.count == 1 && cadence.recordedIntervals.count == 2 }
  #expect(controller.diagnosticProbeRunning)
  #expect(cadence.recordedIntervals == [30, 30])
  let first = controller.probe()
  #expect(first.summary.contains("visible="))
  #expect(controller.probe() == first)
  controller.layoutChanged(forgetting: false)
  controller.detailedLoggingEnabled = false
  #expect(!controller.diagnosticProbeRunning)
  _ = controller.buttonFrameOnScreen
}

@Test @MainActor func statusItemLeftClickTogglesAndRightClickOpensTheMenu() {
  var presented = 0
  let controller = statusController { _ in presented += 1 }
  defer { controller.remove() }
  var clicks = 0
  controller.onClick = { clicks += 1 }
  controller.buttonClicked(nil)
  #expect(clicks == 1)
  controller.menuProvider = { NSMenu() }
  controller.buttonClicked(nil)
  #expect(clicks == 2)
  let rightClick = NSEvent.mouseEvent(
    with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    eventNumber: 0,
    clickCount: 1, pressure: 1)!
  controller.handleClick(rightClick)
  #expect(clicks == 2)
  #expect(presented == 1)
  #expect(controller.item.menu != nil)
  controller.item.menu?.delegate?.menuDidClose?(controller.item.menu!)
  #expect(controller.item.menu == nil)
}

@Test @MainActor func statusItemFollowsTheMenuBarAppearance() async throws {
  let controller = statusController()
  defer { controller.remove() }
  controller.update(statusModel(format: .stacked))
  NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  controller.item.button?.appearance = NSAppearance(named: .darkAqua)
  controller.appearanceChanged()
  await mainActorTurn()
  #expect(controller.isDark)
}

@Test @MainActor func statusItemKeepsTheContextOfTheAppBehindIt() {
  let controller = StatusItemController(log: makeLog(), presentMenu: { _ in })
  defer { controller.remove() }
  controller.frontmostContext = { "com.example.editor" }
  #expect(controller.layoutContext() == "com.example.editor")
  // Opening the popover activates this app; the width the item has to fit into is still the editor's menu bar.
  controller.frontmostContext = { Bundle.main.bundleIdentifier ?? "" }
  #expect(controller.layoutContext() == "com.example.editor")
  controller.frontmostContext = { "" }
  #expect(controller.layoutContext() == "com.example.editor")
}

@Test @MainActor func statusItemHoldsItsTierWhileThePopoverIsVisible() {
  let controller = statusController()
  defer { controller.remove() }
  controller.fitCheckDelay = .seconds(10)
  var fitChecks = 0
  controller.visibleItemFrame = { _ in
    fitChecks += 1
    return nil
  }
  controller.update(ladder: [statusModel(format: .stacked), .empty])
  #expect(!controller.checkFit())
  #expect(fitChecks == 1)
  #expect(controller.model == .empty)
  controller.popoverVisible = true
  controller.layoutChanged(forgetting: true)
  controller.restart()
  #expect(controller.checkFit())
  #expect(fitChecks == 1)
  #expect(controller.model == .empty)
  controller.popoverVisible = false
  #expect(controller.model == statusModel(format: .stacked))
}

@Test @MainActor func statusItemUpdatesTheCurrentTierWithoutMovingTheOpenPopoverAnchor() throws {
  let controller = statusController()
  defer { controller.remove() }
  controller.fitCheckDelay = .seconds(10)
  controller.visibleItemFrame = { _ in nil }
  controller.update(ladder: [statusModel(format: .stacked), .empty])
  #expect(!controller.checkFit())
  #expect(controller.model == .empty)
  let frozenWidth = try #require(controller.item.button?.frame.width)
  #expect(frozenWidth > 0)
  controller.popoverVisible = true
  let wide = statusModel(format: .custom)
  let currentTier = statusModel(format: .miniBars)

  controller.update(ladder: [wide, currentTier])

  #expect(controller.ladder == [wide, currentTier])
  #expect(controller.model == currentTier)
  #expect(controller.item.length == frozenWidth)
  #expect(controller.item.button?.accessibilityLabel() == StatusItemRenderer.accessibilityDescription(for: currentTier))

  controller.popoverVisible = false
  #expect(controller.model == wide)
  #expect(controller.item.length == NSStatusItem.variableLength)
}

@Test @MainActor func statusItemIgnoresRepeatedPopoverVisibilityNotifications() throws {
  let controller = statusController()
  defer { controller.remove() }
  controller.update(statusModel(format: .stacked))
  controller.popoverVisible = true
  let frozenLength = controller.item.length
  let button = try #require(controller.item.button)
  button.setFrameSize(CGSize(width: button.frame.width + 40, height: button.frame.height))

  controller.popoverVisible = true

  #expect(controller.item.length == frozenLength)
  controller.popoverVisible = false
}

@Test @MainActor func statusItemBuildsGeometryDiagnosticsOnlyWhenDetailedLoggingIsEnabled() {
  let log = makeLog()
  log.debugEnabled = true
  let controller = StatusItemController(log: log, presentMenu: { _ in })
  defer { controller.remove() }
  controller.popoverVisible = true

  controller.layoutChanged(forgetting: false, trigger: "quiet")
  #expect(!log.text.contains("status.deferred"))

  controller.detailedLoggingEnabled = true
  controller.layoutChanged(forgetting: false, trigger: "detailed")
  #expect(log.text.contains("status.deferred trigger=detailed"))
}

private func configuredStatusModel(format: StatusFormat, decimals: Int, label: String? = nil) -> StatusItemModel {
  let snapshot = sampleSnapshot(.claude)
  let window = snapshot.windows[0]
  let key = WindowKey(.claude, window)
  return StatusItemBuilder.build(
    StatusItemInput(
      snapshots: [.claude: snapshot], availability: [.claude: .current], selectedKeys: [key], format: format,
      customTemplate: "{label} {pct}", decimals: decimals, hideZeroCells: false, order: .provider,
      labels: label.map { [key: $0] } ?? [:], now: fixedNow))
}
