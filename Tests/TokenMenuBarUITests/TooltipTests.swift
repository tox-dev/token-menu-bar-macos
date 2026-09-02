import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

private actor TooltipSleepGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private(set) var durations: [Duration] = []

  func sleep(_ duration: Duration) async {
    durations.append(duration)
    await withCheckedContinuation { continuations.append($0) }
  }

  func releaseAll() {
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting { continuation.resume() }
  }
}

private actor TooltipTestClock {
  private struct Sleeper {
    let deadline: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var now: Duration = .zero
  private var sleepers: [UUID: Sleeper] = [:]

  var pendingCount: Int { sleepers.count }

  func sleep(_ duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          sleepers[id] = Sleeper(deadline: now + duration, continuation: continuation)
        }
      }
    } onCancel: {
      Task { await self.cancel(id: id) }
    }
  }

  func advance(by duration: Duration) {
    now += duration
    let ready = sleepers.filter { $0.value.deadline <= now }
    for (id, sleeper) in ready {
      sleepers.removeValue(forKey: id)
      sleeper.continuation.resume()
    }
  }

  private func cancel(id: UUID) {
    sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
}

@MainActor
private final class TooltipPanelSpy: TooltipPanelPresenting {
  private(set) var anchorRects: [CGRect] = []
  private(set) var contents: [TooltipContent] = []
  private(set) var hideCount = 0
  private(set) var parentWindows: [NSWindow] = []
  private(set) var tearDownCount = 0
  private(set) var reduceMotionValues: [Bool] = []
  var isVisible = false

  func show(
    content: TooltipContent,
    anchorRect: CGRect,
    visibleFrame: CGRect,
    parentWindow: NSWindow,
    reduceMotion: Bool,
    reduceTransparency: Bool
  ) {
    anchorRects.append(anchorRect)
    contents.append(content)
    parentWindows.append(parentWindow)
    reduceMotionValues.append(reduceMotion)
    isVisible = true
  }

  func hide() {
    hideCount += 1
    isVisible = false
  }

  func tearDown() {
    tearDownCount += 1
    isVisible = false
  }
}

@MainActor
private final class TooltipMouseWindow: NSWindow {
  var mouseLocation = CGPoint.zero

  override var mouseLocationOutsideOfEventStream: NSPoint { mouseLocation }
}

@MainActor
private final class FlippedTooltipContainer: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
private final class TooltipSourceStub: TooltipPresentationSource {
  let tooltipOwner: TooltipOwner
  var tooltipContent: TooltipContent
  var tooltipPresentationContext: TooltipPresentationContext?
  var tooltipClipView: NSClipView?

  init(
    presenter: TooltipPresenter,
    title: String,
    window: NSWindow,
    clipView: NSClipView? = nil,
    anchorRect: CGRect = CGRect(x: 100, y: 200, width: 40, height: 20),
    visibleFrame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
  ) {
    tooltipOwner = presenter.makeOwner()
    tooltipContent = TooltipContent(title: title, body: "Explanation")
    tooltipPresentationContext = TooltipPresentationContext(
      anchorRect: anchorRect,
      visibleFrame: visibleFrame,
      parentWindow: window
    )
    tooltipClipView = clipView
  }
}

@MainActor
private final class VolatileTooltipSource: TooltipPresentationSource {
  let tooltipOwner: TooltipOwner
  let tooltipContent = TooltipContent(title: "Transient", body: "Explains the current control.")
  let tooltipClipView: NSClipView? = nil
  private var contexts: [TooltipPresentationContext]

  init(presenter: TooltipPresenter, contexts: [TooltipPresentationContext]) {
    tooltipOwner = presenter.makeOwner()
    self.contexts = contexts
  }

  var tooltipPresentationContext: TooltipPresentationContext? {
    contexts.isEmpty ? nil : contexts.removeFirst()
  }
}

private enum TooltipTestError: Error {
  case failedSleep
}

@MainActor
private struct TooltipModifierProbe: View {
  @FocusState private var focused: Bool

  let help: TooltipContent
  let presenter: TooltipPresenter

  var body: some View {
    VStack {
      Button("Bound") {}
        .richHelp(help, focus: $focused, presenter: presenter)
      Button("Shared bound") {}
        .richHelp(help, focus: $focused)
      Text("Explicit")
        .richHelp(help, isFocused: false, presenter: presenter)
      Text("Shared explicit")
        .richHelp(help, isFocused: false)
      Text("Accessibility")
        .richHelpAccessibility(help)
    }
  }
}

@MainActor
@Observable
private final class TooltipFocusProbeModel {
  var content: TooltipContent
  var focused = false

  init(content: TooltipContent) {
    self.content = content
  }
}

@MainActor
private struct TooltipFocusProbe: View {
  @Bindable var model: TooltipFocusProbeModel
  let presenter: TooltipPresenter

  var body: some View {
    Text("Focused control")
      .richHelp(model.content, isFocused: model.focused, presenter: presenter)
  }
}

@Suite(.serialized)
struct TooltipTests {
  @Test func tooltipContentIncludesTitleAndFlattensRichSpansForAccessibility() {
    let content = TooltipContent(
      title: "Format",
      body: [.code("{cell}:{pct}"), .text(" inline, or Custom to write your own")]
    )
    #expect(content.accessibilityHint == "Format. {cell}:{pct} inline, or Custom to write your own")
  }

  @Test func tooltipContentDoesNotRepeatTitleFromBody() {
    let content = TooltipContent(
      title: "Code reviews",
      body: "Code reviews counted today across all repositories."
    )
    #expect(content.accessibilityHint == "Code reviews counted today across all repositories.")
  }

  @Test func tooltipContentKeepsDistinctWordsWithTheSamePrefix() {
    let content = TooltipContent(title: "Log", body: "Logging records provider refresh details.")
    #expect(content.accessibilityHint == "Log. Logging records provider refresh details.")
  }

  @Test func tooltipContentUsesTheOnlyNonemptyPartForAccessibility() {
    let titleOnly = TooltipContent(title: "  Current period  ", body: " \n")
    let bodyOnly = TooltipContent(title: "\n", body: "  Returns to live usage.  ")
    #expect(titleOnly.accessibilityHint == "Current period")
    #expect(bodyOnly.accessibilityHint == "Returns to live usage.")
  }

  @Test @MainActor func tooltipPanelIsNonactivatingAndMouseTransparent() {
    let panel = TooltipPanel()
    #expect(panel.styleMask.contains(.borderless))
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(panel.contentView is NSVisualEffectView)
    #expect((panel.contentView as? NSVisualEffectView)?.material == .toolTip)
    panel.tearDown()
  }

  @Test @MainActor func tooltipPanelRendersRichContentAndMovesBetweenWindows() throws {
    let panel = TooltipPanel()
    let firstWindow = NSWindow(
      contentRect: CGRect(x: -9_980, y: -9_980, width: 200, height: 200),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let secondWindow = NSWindow(
      contentRect: CGRect(x: -9_960, y: -9_960, width: 200, height: 200),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let visibleFrame = CGRect(x: -10_000, y: -10_000, width: 400, height: 300)
    let content = TooltipContent(title: "Template", body: [.code("{pct}"), .text(" shows percent used")])

    panel.show(
      content: content,
      anchorRect: CGRect(x: -9_900, y: -9_800, width: 40, height: 20),
      visibleFrame: visibleFrame,
      parentWindow: firstWindow,
      reduceMotion: true,
      reduceTransparency: true
    )

    let effectView = try #require(panel.contentView as? NSVisualEffectView)
    let label = try #require(effectView.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(panel.isVisible)
    #expect(panel.parent === firstWindow)
    #expect(effectView.state == .inactive)
    #expect(label.stringValue == "Template\n{pct} shows percent used")
    var foregrounds: [NSColor] = []
    label.attributedStringValue.enumerateAttribute(
      .foregroundColor,
      in: NSRange(location: 0, length: label.attributedStringValue.length)
    ) { value, _, _ in
      if let color = value as? NSColor { foregrounds.append(color) }
    }
    #expect(foregrounds.count >= 2)
    #expect(foregrounds.allSatisfy { $0.isEqual(NSColor.labelColor) })
    #expect(visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame))
    let expectedOrigin = TooltipGeometry.placement(
      anchor: CGRect(x: -9_900, y: -9_800, width: 40, height: 20),
      tooltipSize: panel.frame.size,
      visibleFrame: visibleFrame
    ).origin
    #expect(abs(panel.frame.origin.x - expectedOrigin.x) <= 0.5)
    #expect(abs(panel.frame.origin.y - expectedOrigin.y) <= 0.5)

    panel.show(
      content: TooltipContent(title: "Updated", body: "Current value"),
      anchorRect: CGRect(x: -9_850, y: -9_900, width: 40, height: 20),
      visibleFrame: visibleFrame,
      parentWindow: secondWindow,
      reduceMotion: false,
      reduceTransparency: false
    )

    #expect(panel.parent === secondWindow)
    #expect(firstWindow.childWindows?.contains(panel) != true)
    #expect(secondWindow.childWindows?.contains(panel) == true)
    #expect(effectView.state == .active)
    #expect(label.stringValue == "Updated\nCurrent value")
    panel.hide()
    #expect(!panel.isVisible)
    #expect(panel.parent == nil)
    panel.tearDown()
    #expect(panel.contentView == nil)
  }

  @Test @MainActor func richHelpBuildsEveryFocusBridge() {
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { TooltipPanelSpy() })
    let hosting = NSHostingView(
      rootView: TooltipModifierProbe(
        help: TooltipContent(title: "Format", body: "Controls the status text."),
        presenter: presenter
      ))
    hosting.frame = CGRect(x: 0, y: 0, width: 220, height: 180)
    hosting.layoutSubtreeIfNeeded()

    #expect(hosting.fittingSize.width > 0)
    presenter.tearDown()
    TooltipPresenter.shared.dismissAll()
  }

  @Test @MainActor func focusedRichHelpSupportsHoverAndFocus() async throws {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let initial = TooltipContent(title: "Focus", body: "Initial help")
    let model = TooltipFocusProbeModel(content: initial)
    let hosting = host(TooltipFocusProbe(model: model, presenter: presenter), width: 220, height: 80)
    defer { presenter.tearDown() }

    let anchor = try #require(tooltipTrackingViews(in: hosting).first)
    #expect(!anchor.trackingAreas.isEmpty)

    let source = TooltipSourceStub(presenter: presenter, title: "Focus", window: NSWindow())
    source.tooltipContent = initial
    presenter.update(source: source, hovering: false, focused: true)
    await presenter.settle()
    #expect(panel.contents == [initial])

    presenter.update(source: source, hovering: false, focused: false)
    await presenter.settle()
    #expect(presenter.visibleOwner == nil)
    #expect(!panel.isVisible)
  }

  @Test @MainActor func tooltipPresenterPrefersTheNewestFocusedSource() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let first = TooltipSourceStub(
      presenter: presenter, title: "First", window: window,
      anchorRect: CGRect(x: 100, y: 100, width: 40, height: 20))
    let second = TooltipSourceStub(
      presenter: presenter, title: "Second", window: window,
      anchorRect: CGRect(x: 200, y: 100, width: 40, height: 20))
    defer { presenter.tearDown() }

    presenter.update(source: first, hovering: false, focused: true)
    await presenter.settle()
    presenter.update(source: second, hovering: false, focused: true)
    await presenter.settle()

    #expect(panel.contents.last?.title == "Second")
  }

  @Test @MainActor func tooltipPresenterUsesItsDefaultDependencies() async {
    let presenter = TooltipPresenter()
    let visibleFrame = CGRect(x: -10_000, y: -10_000, width: 400, height: 300)
    let source = TooltipSourceStub(
      presenter: presenter,
      title: "Defaults",
      window: NSWindow(),
      anchorRect: CGRect(x: -9_900, y: -9_800, width: 40, height: 20),
      visibleFrame: visibleFrame
    )

    presenter.arm(source: source)
    await presenter.settle()

    #expect(presenter.hasPanel)
    #expect(presenter.visibleOwner == source.tooltipOwner)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterTracksCursorHelpWithoutPerControlViews() async {
    let panel = TooltipPanelSpy()
    let window = NSWindow()
    let anchor = CGRect(x: 120, y: 240, width: 1, height: 1)
    let context = TooltipPresentationContext(
      anchorRect: anchor,
      visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
      parentWindow: window)
    let presenter = TooltipPresenter(
      sleep: { _ in }, panelFactory: { panel }, cursorContext: { context })
    let content = TooltipContent(title: "Refresh", body: "Fetches current usage.")

    presenter.updateCursor(content: content, hovering: true)
    await presenter.settle()

    #expect(panel.contents == [content])
    #expect(panel.anchorRects == [anchor])
    presenter.updateCursor(content: content, hovering: false)
    await presenter.settle()
    #expect(!panel.isVisible)
    presenter.tearDown()
  }

  @Test @MainActor func cursorContextUsesTheFrontEligibleWindow() throws {
    quietTestApp()
    let screen = try #require(NSScreen.screens.first)
    let point = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
    let window = NSWindow(
      contentRect: CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.orderFrontRegardless()

    let context = try #require(TooltipPresenter.currentCursorContext(point: point, windows: [window]))

    #expect(context.parentWindow === window)
    #expect(context.anchorRect == CGRect(origin: point, size: CGSize(width: 1, height: 1)))
    #expect(TooltipPresenter.currentCursorContext(point: point, windows: []) == nil)
    window.orderOut(nil)
  }

  @Test @MainActor func tooltipPresenterClearsAFailedDelay() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(
      sleep: { _ in throw TooltipTestError.failedSleep },
      panelFactory: { panel }
    )
    let source = TooltipSourceStub(presenter: presenter, title: "Failure", window: NSWindow())

    presenter.arm(source: source)
    await presenter.settle()

    #expect(panel.contents.isEmpty)
    #expect(!presenter.hasPendingTask)
    #expect(!presenter.hasEventMonitor)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterWaitsForTheInjectedDelay() async {
    let gate = TooltipSleepGate()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { await gate.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Period", window: NSWindow())

    presenter.arm(source: source)
    while await gate.durations.isEmpty { await Task.yield() }
    #expect(!presenter.hasPanel)
    #expect(await gate.durations == [TooltipTiming.presentationDelay])

    await gate.releaseAll()
    await presenter.settle()
    #expect(panel.contents == [source.tooltipContent])
    #expect(presenter.visibleOwner == source.tooltipOwner)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterShowsAfterTheFullHoverThreshold() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Threshold", window: NSWindow())

    presenter.arm(source: source)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: .milliseconds(149))
    await Task.yield()
    #expect(panel.contents.isEmpty)

    await clock.advance(by: .milliseconds(1))
    await presenter.settle()
    #expect(panel.contents == [source.tooltipContent])
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterDoesNotShowWhenHoverEndsBeforeTheEntryThreshold() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Brief hover", window: NSWindow())

    presenter.arm(source: source)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: .milliseconds(149))
    presenter.update(source: source, hovering: false, focused: false)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: TooltipTiming.dismissalDelay)
    await presenter.settle()

    #expect(panel.contents.isEmpty)
    #expect(presenter.visibleOwner == nil)
    #expect(!presenter.hasPendingTask)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterRejectsAnAnchorInvalidatedWhileArming() {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let context = TooltipPresentationContext(
      anchorRect: CGRect(x: 100, y: 200, width: 40, height: 20),
      visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
      parentWindow: window
    )
    let source = VolatileTooltipSource(presenter: presenter, contexts: [context])

    presenter.arm(source: source)

    #expect(panel.contents.isEmpty)
    #expect(!presenter.hasPendingTask)
    #expect(presenter.visibleOwner == nil)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterHidesAfterTheFullMouseExitThreshold() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Threshold", window: NSWindow())

    presenter.arm(source: source)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: TooltipTiming.presentationDelay)
    await presenter.settle()
    presenter.update(source: source, hovering: false, focused: false)
    await waitForSleeps(clock, count: 1)

    await clock.advance(by: .milliseconds(149))
    await Task.yield()
    #expect(panel.isVisible)
    #expect(presenter.visibleOwner == source.tooltipOwner)

    await clock.advance(by: .milliseconds(1))
    await presenter.settle()
    #expect(!panel.isVisible)
    #expect(presenter.visibleOwner == nil)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterCancelsMouseExitDismissalOnReentry() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Reentry", window: NSWindow())

    presenter.arm(source: source)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: TooltipTiming.presentationDelay)
    await presenter.settle()
    presenter.update(source: source, hovering: false, focused: false)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: .milliseconds(149))

    presenter.update(source: source, hovering: true, focused: false)
    await waitForSleeps(clock, count: 0)
    await clock.advance(by: .milliseconds(1))
    await Task.yield()

    #expect(panel.isVisible)
    #expect(panel.hideCount == 0)
    #expect(panel.contents == [source.tooltipContent])
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterKeepsThePanelVisibleAcrossAdjacentSources() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let window = NSWindow()
    let first = TooltipSourceStub(presenter: presenter, title: "First", window: window)
    let second = TooltipSourceStub(presenter: presenter, title: "Second", window: window)

    presenter.arm(source: first)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: TooltipTiming.presentationDelay)
    await presenter.settle()
    presenter.update(source: first, hovering: false, focused: false)
    presenter.update(source: second, hovering: true, focused: false)
    await waitForSleeps(clock, count: 1)

    await clock.advance(by: .milliseconds(149))
    await Task.yield()
    #expect(panel.contents == [first.tooltipContent])
    #expect(panel.isVisible)

    await clock.advance(by: .milliseconds(1))
    await presenter.settle()
    #expect(panel.contents == [first.tooltipContent, second.tooltipContent])
    #expect(panel.hideCount == 0)
    #expect(presenter.visibleOwner == second.tooltipOwner)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterDismissesImmediatelyWhenKeyboardFocusLeaves() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Focused", window: NSWindow())

    presenter.update(source: source, hovering: false, focused: true)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: TooltipTiming.presentationDelay)
    await presenter.settle()
    presenter.update(source: source, hovering: false, focused: false)

    #expect(!panel.isVisible)
    #expect(!presenter.hasPendingTask)
    #expect(presenter.visibleOwner == nil)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterKeepsHelpWhenFocusLeavesUnderThePointer() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Focused", window: NSWindow())

    presenter.update(source: source, hovering: true, focused: true)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: TooltipTiming.presentationDelay)
    await presenter.settle()
    presenter.update(source: source, hovering: true, focused: false)

    #expect(panel.isVisible)
    #expect(!presenter.hasPendingTask)
    #expect(presenter.visibleOwner == source.tooltipOwner)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterSafetyDismissalCancelsMouseExitGrace() async {
    let clock = TooltipTestClock()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { try await clock.sleep($0) }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Safety", window: NSWindow())

    presenter.arm(source: source)
    await waitForSleeps(clock, count: 1)
    await clock.advance(by: TooltipTiming.presentationDelay)
    await presenter.settle()
    presenter.update(source: source, hovering: false, focused: false)
    await waitForSleeps(clock, count: 1)
    presenter.dismissAll()

    #expect(!panel.isVisible)
    #expect(!presenter.hasPendingTask)
    #expect(presenter.visibleOwner == nil)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterRejectsCancelledRequestThatStillResumes() async {
    let gate = TooltipSleepGate()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { await gate.sleep($0) }, panelFactory: { panel })
    let window = NSWindow()
    let first = TooltipSourceStub(presenter: presenter, title: "First", window: window)
    let second = TooltipSourceStub(presenter: presenter, title: "Second", window: window)

    presenter.arm(source: first)
    while await gate.durations.count < 1 { await Task.yield() }
    presenter.arm(source: second)
    while await gate.durations.count < 2 { await Task.yield() }
    await gate.releaseAll()
    await presenter.settle()
    await Task.yield()

    #expect(panel.contents == [second.tooltipContent])
    #expect(presenter.visibleOwner == second.tooltipOwner)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterCleansUpWhenItsSourceDisappears() async {
    let gate = TooltipSleepGate()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { await gate.sleep($0) }, panelFactory: { panel })
    weak var weakSource: TooltipSourceStub?
    do {
      let source = TooltipSourceStub(presenter: presenter, title: "Removed", window: NSWindow())
      weakSource = source
      presenter.arm(source: source)
      while await gate.durations.isEmpty { await Task.yield() }
    }
    #expect(weakSource == nil)
    await gate.releaseAll()
    await presenter.settle()

    #expect(panel.contents.isEmpty)
    #expect(!presenter.hasPendingTask)
    #expect(!presenter.hasEventMonitor)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterIgnoresStaleExit() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let first = TooltipSourceStub(presenter: presenter, title: "First", window: window)
    let second = TooltipSourceStub(presenter: presenter, title: "Second", window: window)

    presenter.arm(source: first)
    await presenter.settle()
    presenter.arm(source: second)
    presenter.dismiss(owner: first.tooltipOwner)
    await presenter.settle()

    #expect(presenter.visibleOwner == second.tooltipOwner)
    #expect(panel.contents.last == second.tooltipContent)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterRestoresActiveParentAfterNestedChildExits() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let parent = TooltipSourceStub(
      presenter: presenter,
      title: "Status",
      window: window,
      anchorRect: CGRect(x: 80, y: 180, width: 120, height: 60)
    )
    let child = TooltipSourceStub(
      presenter: presenter,
      title: "Copy",
      window: window,
      anchorRect: CGRect(x: 100, y: 200, width: 24, height: 20)
    )

    presenter.update(source: parent, hovering: true, focused: false)
    await presenter.settle()
    presenter.update(source: child, hovering: true, focused: false)
    await presenter.settle()
    presenter.update(source: parent, hovering: true, focused: false)
    await presenter.settle()
    #expect(presenter.visibleOwner == child.tooltipOwner)

    presenter.update(source: child, hovering: false, focused: false)
    await presenter.settle()
    #expect(presenter.visibleOwner == parent.tooltipOwner)
    #expect(panel.contents.map(\.title) == ["Status", "Copy", "Status"])
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterRestoresParentAfterNestedChildDisappears() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let parent = TooltipSourceStub(
      presenter: presenter,
      title: "Parent",
      window: window,
      anchorRect: CGRect(x: 80, y: 180, width: 120, height: 60)
    )
    presenter.update(source: parent, hovering: true, focused: false)
    await presenter.settle()
    weak var releasedChild: TooltipSourceStub?
    do {
      let child = TooltipSourceStub(
        presenter: presenter,
        title: "Child",
        window: window,
        anchorRect: CGRect(x: 100, y: 200, width: 24, height: 20)
      )
      releasedChild = child
      presenter.update(source: child, hovering: true, focused: false)
      await presenter.settle()
    }
    presenter.update(source: parent, hovering: true, focused: false)
    await presenter.settle()

    #expect(releasedChild == nil)
    #expect(presenter.visibleOwner == parent.tooltipOwner)
    #expect(panel.contents.map(\.title) == ["Parent", "Child", "Parent"])
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterLetsNewKeyboardFocusSupersedeParkedPointer() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let hovered = TooltipSourceStub(presenter: presenter, title: "Hovered", window: window)
    let focused = TooltipSourceStub(presenter: presenter, title: "Focused", window: window)

    presenter.update(source: hovered, hovering: true, focused: false)
    await presenter.settle()
    presenter.update(source: focused, hovering: false, focused: true)
    await presenter.settle()

    #expect(presenter.visibleOwner == focused.tooltipOwner)
    #expect(panel.contents.map(\.title) == ["Hovered", "Focused"])
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterDoesNotRestoreOwnersAfterGlobalDismissal() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let parent = TooltipSourceStub(presenter: presenter, title: "Parent", window: window)
    let child = TooltipSourceStub(presenter: presenter, title: "Child", window: window)

    presenter.update(source: parent, hovering: true, focused: false)
    presenter.update(source: child, hovering: true, focused: false)
    await presenter.settle()
    presenter.dismissAll()
    presenter.dismiss(owner: child.tooltipOwner)
    await presenter.settle()

    #expect(presenter.visibleOwner == nil)
    #expect(!panel.isVisible)
    #expect(!presenter.hasPendingTask)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterReusesOnePanelUntilTeardown() async {
    var factoryCount = 0
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(
      sleep: { _ in },
      panelFactory: {
        factoryCount += 1
        return panel
      }
    )
    let window = NSWindow()
    let first = TooltipSourceStub(presenter: presenter, title: "First", window: window)
    let second = TooltipSourceStub(presenter: presenter, title: "Second", window: window)

    presenter.arm(source: first)
    await presenter.settle()
    presenter.dismiss(owner: first.tooltipOwner)
    presenter.arm(source: second)
    await presenter.settle()

    #expect(factoryCount == 1)
    #expect(panel.contents.count == 2)
    presenter.tearDown()
    #expect(!presenter.hasPanel)
    #expect(!presenter.hasPendingTask)
    #expect(!presenter.hasEventMonitor)
    #expect(panel.tearDownCount == 1)
  }

  @Test @MainActor func tooltipPresenterCancelsWhenItsScrollViewMoves() async {
    let gate = TooltipSleepGate()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { await gate.sleep($0) }, panelFactory: { panel })
    let clipView = NSClipView()
    let source = TooltipSourceStub(presenter: presenter, title: "Scrolled", window: NSWindow(), clipView: clipView)

    presenter.arm(source: source)
    while await gate.durations.isEmpty { await Task.yield() }
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
    await gate.releaseAll()
    await presenter.settle()

    #expect(panel.contents.isEmpty)
    #expect(!presenter.hasPendingTask)
    #expect(!presenter.hasEventMonitor)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterRefreshesForAccessibilityChangesAndDismissesWithItsWindow() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let source = TooltipSourceStub(presenter: presenter, title: "Accessible", window: window)

    presenter.arm(source: source)
    await presenter.settle()
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
    await Task.yield()
    await Task.yield()

    #expect(panel.contents.count == 2)
    #expect(panel.reduceMotionValues.last == true)

    NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
    await Task.yield()
    await Task.yield()
    #expect(presenter.visibleOwner == nil)
    #expect(!presenter.hasEventMonitor)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterDismissesOnEscape() async throws {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let source = TooltipSourceStub(presenter: presenter, title: "Dismiss", window: window)

    presenter.arm(source: source)
    await presenter.settle()
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53
      ))
    NSApplication.shared.sendEvent(event)

    #expect(presenter.visibleOwner == nil)
    #expect(!panel.isVisible)
    #expect(!presenter.hasEventMonitor)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterRejectsAnInvalidAnchorOnMouseMovement() async throws {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let source = TooltipSourceStub(presenter: presenter, title: "Invalid", window: NSWindow())

    presenter.arm(source: source)
    await presenter.settle()
    source.tooltipPresentationContext = nil
    NSApplication.shared.sendEvent(try mouseEvent())

    #expect(!panel.isVisible)
    #expect(!presenter.hasPendingTask)
    #expect(presenter.visibleOwner == nil)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipTrackingViewDoesNotAddAKeyboardStop() {
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { TooltipPanelSpy() })
    let view = TooltipTrackingView(
      content: TooltipContent(title: "Refresh", body: "Fetches current limits"),
      presenter: presenter
    )
    #expect(!view.acceptsFirstResponder)
    #expect(view.trackingAreas.count == 1)
    view.dismantle()
    presenter.tearDown()
  }

  @Test @MainActor func tooltipTrackingViewConvertsAFlippedFocusedAnchorToScreenCoordinates() throws {
    let screen = try #require(NSScreen.screens.first)
    let origin = CGPoint(x: screen.visibleFrame.minX + 100, y: screen.visibleFrame.minY + 120)
    let window = TooltipMouseWindow(
      contentRect: CGRect(origin: origin, size: CGSize(width: 300, height: 240)),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.alphaValue = 0
    let container = FlippedTooltipContainer(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
    window.contentView = container
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { TooltipPanelSpy() })
    let content = TooltipContent(title: "Focused", body: "Explains the focused control.")
    let view = TooltipTrackingView(content: content, presenter: presenter)
    view.frame = CGRect(x: 30, y: 40, width: 120, height: 24)
    container.addSubview(view)
    window.orderFrontRegardless()

    view.update(content: content, focused: true)
    let context = try #require(view.tooltipPresentationContext)

    #expect(context.parentWindow === window)
    #expect(context.anchorRect == CGRect(x: origin.x + 30, y: origin.y + 176, width: 120, height: 24))
    presenter.tearDown()
    window.orderOut(nil)
  }

  @Test @MainActor func tooltipTrackingViewAccountsForAScrolledAnchor() throws {
    let screen = try #require(NSScreen.screens.first)
    let origin = CGPoint(x: screen.visibleFrame.minX + 140, y: screen.visibleFrame.minY + 160)
    let window = TooltipMouseWindow(
      contentRect: CGRect(origin: origin, size: CGSize(width: 320, height: 240)),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.alphaValue = 0
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    window.contentView = container
    let clipView = NSClipView(frame: CGRect(x: 50, y: 40, width: 200, height: 100))
    let documentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
    clipView.documentView = documentView
    clipView.bounds.origin = CGPoint(x: 0, y: 100)
    container.addSubview(clipView)
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { TooltipPanelSpy() })
    let content = TooltipContent(title: "Scrolled", body: "Explains the visible row.")
    let view = TooltipTrackingView(content: content, presenter: presenter)
    view.frame = CGRect(x: 20, y: 120, width: 100, height: 30)
    documentView.addSubview(view)
    window.orderFrontRegardless()

    view.update(content: content, focused: true)
    let context = try #require(view.tooltipPresentationContext)

    #expect(context.anchorRect == CGRect(x: origin.x + 70, y: origin.y + 60, width: 100, height: 30))
    presenter.tearDown()
    window.orderOut(nil)
  }

  @Test @MainActor func tooltipTrackingViewAnchorsHoverToTheCurrentPointerAndRejectsAStaleHover() async throws {
    let screen = try #require(NSScreen.screens.first)
    let origin = CGPoint(x: screen.visibleFrame.minX + 180, y: screen.visibleFrame.minY + 180)
    let window = TooltipMouseWindow(
      contentRect: CGRect(origin: origin, size: CGSize(width: 260, height: 180)),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.alphaValue = 0
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 180))
    window.contentView = container
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let content = TooltipContent(title: "Pointer", body: "Explains the hovered control.")
    let view = TooltipTrackingView(content: content, presenter: presenter)
    view.frame = CGRect(x: 30, y: 40, width: 120, height: 30)
    container.addSubview(view)
    window.orderFrontRegardless()
    window.mouseLocation = CGPoint(x: 50, y: 55)

    view.mouseEntered(with: try mouseEvent())
    await presenter.settle()

    #expect(panel.anchorRects == [CGRect(x: origin.x + 50, y: origin.y + 55, width: 1, height: 1)])
    window.mouseLocation = CGPoint(x: 230, y: 160)
    presenter.refresh(source: view)
    #expect(presenter.visibleOwner == nil)
    #expect(!panel.isVisible)
    presenter.tearDown()
    window.orderOut(nil)
  }

  @Test @MainActor func tooltipPresenterRejectsAWindowChangedDuringTheDelay() async {
    let gate = TooltipSleepGate()
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { await gate.sleep($0) }, panelFactory: { panel })
    let firstWindow = NSWindow()
    let secondWindow = NSWindow()
    let source = TooltipSourceStub(presenter: presenter, title: "Moved", window: firstWindow)

    presenter.arm(source: source)
    while await gate.durations.isEmpty { await Task.yield() }
    source.tooltipPresentationContext = TooltipPresentationContext(
      anchorRect: CGRect(x: 120, y: 220, width: 40, height: 20),
      visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
      parentWindow: secondWindow
    )
    await gate.releaseAll()
    await presenter.settle()

    #expect(panel.contents.isEmpty)
    #expect(presenter.visibleOwner == nil)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterDismissesOnOwnerWindowGeometryChanges() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let source = TooltipSourceStub(presenter: presenter, title: "Moved", window: window)

    presenter.arm(source: source)
    await presenter.settle()
    NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
    await Task.yield()
    await Task.yield()

    #expect(panel.anchorRects == [CGRect(x: 100, y: 200, width: 40, height: 20)])
    #expect(!panel.isVisible)
    #expect(presenter.visibleOwner == nil)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipPresenterDismissesWhenTheAnchorBecomesInvalidDuringResize() async {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let window = NSWindow()
    let source = TooltipSourceStub(presenter: presenter, title: "Removed", window: window)

    presenter.arm(source: source)
    await presenter.settle()
    source.tooltipPresentationContext = nil
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    await Task.yield()
    await Task.yield()

    #expect(presenter.visibleOwner == nil)
    #expect(!panel.isVisible)
    presenter.tearDown()
  }

  @Test @MainActor func tooltipTrackingViewRefreshesVisibleContentInItsWindow() async throws {
    let screen = try #require(NSScreen.screens.first)
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let initial = TooltipContent(title: "Initial", body: "First explanation")
    let view = TooltipTrackingView(content: initial, presenter: presenter)
    let frame = CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 160, height: 40)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.contentView = view
    view.frame = CGRect(origin: .zero, size: frame.size)
    window.orderFrontRegardless()

    view.update(content: initial, focused: true)
    let context = try #require(view.tooltipPresentationContext)
    #expect(context.parentWindow === window)
    #expect(!context.anchorRect.isEmpty)

    await presenter.settle()
    let updated = TooltipContent(title: "Updated", body: "Second explanation")
    view.update(content: updated, focused: true)

    #expect(panel.contents == [initial, updated])
    #expect(panel.reduceMotionValues.last == true)
    window.contentView = nil
    #expect(presenter.visibleOwner == nil)
    view.dismantle()
    presenter.tearDown()
  }

  @Test @MainActor func tooltipTrackingViewKeepsFocusedHelpAfterPointerExit() async throws {
    let gate = TooltipSleepGate()
    let presenter = TooltipPresenter(
      sleep: { await gate.sleep($0) },
      panelFactory: { TooltipPanelSpy() }
    )
    let view = TooltipTrackingView(
      content: TooltipContent(title: "Refresh", body: "Fetches current limits"),
      presenter: presenter
    )
    let window = try showInvisibleWindow(containing: view)
    view.update(content: view.tooltipContent, focused: true)
    while await gate.durations.isEmpty { await Task.yield() }

    let exit = try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
    view.mouseExited(with: exit)
    #expect(presenter.hasPendingTask)

    view.update(content: view.tooltipContent, focused: false)
    await gate.releaseAll()
    await presenter.settle()
    #expect(!presenter.hasPendingTask)
    view.dismantle()
    presenter.tearDown()
    window.orderOut(nil)
  }

  @Test @MainActor func tooltipTrackingViewDismissesHelpWhenHidden() async throws {
    let panel = TooltipPanelSpy()
    let presenter = TooltipPresenter(sleep: { _ in }, panelFactory: { panel })
    let view = TooltipTrackingView(
      content: TooltipContent(title: "Refresh", body: "Fetches current limits"),
      presenter: presenter
    )
    let window = try showInvisibleWindow(containing: view)
    view.update(content: view.tooltipContent, focused: true)
    await presenter.settle()
    #expect(panel.isVisible)

    view.viewDidHide()

    #expect(!panel.isVisible)
    #expect(presenter.visibleOwner == nil)
    view.dismantle()
    presenter.tearDown()
    window.orderOut(nil)
  }

  @Test @MainActor func tooltipTrackingViewTransitionsBetweenPointerAndFocusWithoutRearming() async throws {
    let gate = TooltipSleepGate()
    let presenter = TooltipPresenter(
      sleep: { await gate.sleep($0) },
      panelFactory: { TooltipPanelSpy() }
    )
    let view = TooltipTrackingView(
      content: TooltipContent(title: "Refresh", body: "Fetches current limits"),
      presenter: presenter
    )
    let window = try showInvisibleWindow(containing: view)
    view.update(content: view.tooltipContent, focused: true)
    while await gate.durations.isEmpty { await Task.yield() }
    view.mouseEntered(with: try mouseEvent())
    view.mouseExited(with: try mouseEvent())

    #expect(await gate.durations == [TooltipTiming.presentationDelay])
    #expect(presenter.hasPendingTask)
    await gate.releaseAll()
    await presenter.settle()
    #expect(!presenter.hasPendingTask)
    view.dismantle()
    presenter.tearDown()
    window.orderOut(nil)
  }

  @MainActor
  private func showInvisibleWindow(containing view: NSView) throws -> TooltipMouseWindow {
    let screen = try #require(NSScreen.screens.first)
    let window = TooltipMouseWindow(
      contentRect: CGRect(
        x: screen.visibleFrame.midX,
        y: screen.visibleFrame.midY,
        width: 180,
        height: 60
      ),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.alphaValue = 0
    window.contentView = view
    view.frame = CGRect(x: 0, y: 0, width: 180, height: 60)
    window.mouseLocation = CGPoint(x: 90, y: 30)
    window.orderFrontRegardless()
    return window
  }

  private func waitForSleeps(_ clock: TooltipTestClock, count: Int) async {
    while await clock.pendingCount != count { await Task.yield() }
  }

  @MainActor
  private func tooltipTrackingViews(in view: NSView) -> [TooltipTrackingView] {
    (view as? TooltipTrackingView).map { [$0] } ?? view.subviews.flatMap { tooltipTrackingViews(in: $0) }
  }

  private func mouseEvent() throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
  }
}
