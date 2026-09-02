import AppKit
import TokenMenuBarCore

@MainActor
struct TooltipPresentationContext {
  let anchorRect: CGRect
  let visibleFrame: CGRect
  let parentWindow: NSWindow
}

@MainActor
protocol TooltipPresentationSource: AnyObject {
  var tooltipOwner: TooltipOwner { get }
  var tooltipContent: TooltipContent { get }
  var tooltipPresentationContext: TooltipPresentationContext? { get }
  var tooltipClipView: NSClipView? { get }
}

@MainActor
private final class CursorTooltipSource: TooltipPresentationSource {
  let tooltipOwner: TooltipOwner
  var tooltipContent = TooltipContent(title: "", body: "")
  let tooltipClipView: NSClipView? = nil
  var hovering = false
  private let context: @MainActor () -> TooltipPresentationContext?

  init(owner: TooltipOwner, context: @escaping @MainActor () -> TooltipPresentationContext?) {
    tooltipOwner = owner
    self.context = context
  }

  var tooltipPresentationContext: TooltipPresentationContext? {
    guard hovering else { return nil }
    return context()
  }
}

@MainActor
private final class ActiveTooltipSource {
  weak var source: (any TooltipPresentationSource)?
  var focused = false
  var focusSequence: UInt64 = 0
  var hovering = false
  var hoverSequence: UInt64 = 0

  init(source: any TooltipPresentationSource) {
    self.source = source
  }
}

@MainActor
public final class TooltipPresenter {
  public static let shared = TooltipPresenter()

  typealias Sleep = @Sendable (Duration) async throws -> Void
  typealias PanelFactory = @MainActor () -> any TooltipPanelPresenting
  typealias CursorContext = @MainActor () -> TooltipPresentationContext?

  private let sleep: Sleep
  private let panelFactory: PanelFactory
  private let cursorContext: CursorContext
  private var arbiter = TooltipArbiter()
  private var presentationTask: Task<Void, Never>?
  private var dismissalTask: Task<Void, Never>?
  private var dismissalOwner: TooltipOwner?
  private weak var source: (any TooltipPresentationSource)?
  private var panel: (any TooltipPanelPresenting)?
  private var activeSources: [TooltipOwner: ActiveTooltipSource] = [:]
  private var activitySequence: UInt64 = 0
  private var nextOwnerValue: UInt64 = 0
  private var cursorSource: CursorTooltipSource?
  private var eventMonitor: Any?
  private var windowObservers: [any NSObjectProtocol] = []
  private weak var observedWindow: NSWindow?
  private var accessibilityObserver: (any NSObjectProtocol)?
  private weak var clipView: NSClipView?
  private var clipViewObserver: (any NSObjectProtocol)?
  private var clipViewWasPostingBoundsChanges = false

  init(
    sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    panelFactory: @escaping PanelFactory = { TooltipPanel() },
    cursorContext: @escaping CursorContext = {
      TooltipPresenter.currentCursorContext(point: NSEvent.mouseLocation, windows: NSApp.orderedWindows)
    }
  ) {
    self.sleep = sleep
    self.panelFactory = panelFactory
    self.cursorContext = cursorContext
  }

  var hasPanel: Bool { panel != nil }
  var hasPendingTask: Bool { presentationTask != nil || dismissalTask != nil }
  var hasEventMonitor: Bool { eventMonitor != nil }
  var visibleOwner: TooltipOwner? { arbiter.visible?.owner }

  func makeOwner() -> TooltipOwner {
    nextOwnerValue &+= 1
    return TooltipOwner(rawValue: nextOwnerValue)
  }

  func settle() async {
    let presentationTask = presentationTask
    let dismissalTask = dismissalTask
    await presentationTask?.value
    await dismissalTask?.value
  }

  func arm(source: any TooltipPresentationSource) {
    let active = activeSources[source.tooltipOwner]
    update(source: source, hovering: true, focused: active?.focused ?? false)
  }

  func updateCursor(content: TooltipContent, hovering: Bool) {
    let cursorSource = cursorSource ?? CursorTooltipSource(owner: makeOwner(), context: cursorContext)
    self.cursorSource = cursorSource
    cursorSource.tooltipContent = content
    cursorSource.hovering = hovering
    update(source: cursorSource, hovering: hovering, focused: false)
  }

  static func currentCursorContext(point: CGPoint, windows: [NSWindow]) -> TooltipPresentationContext? {
    guard
      let window = windows.first(where: {
        $0.isVisible && $0.frame.contains(point) && !($0 is TooltipPanel)
      }),
      let screen = window.screen
    else { return nil }
    return TooltipPresentationContext(
      anchorRect: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
      visibleFrame: screen.visibleFrame,
      parentWindow: window)
  }

  func update(source: any TooltipPresentationSource, hovering: Bool, focused: Bool) {
    let entry = activeSources[source.tooltipOwner] ?? ActiveTooltipSource(source: source)
    let wasFocused = entry.focused
    let wasHovering = entry.hovering
    entry.source = source
    if hovering, !entry.hovering {
      activitySequence &+= 1
      entry.hoverSequence = activitySequence
    }
    if focused, !entry.focused {
      activitySequence &+= 1
      entry.focusSequence = activitySequence
    }
    entry.hovering = hovering
    entry.focused = focused
    if hovering || focused {
      cancelHoverDismissal()
      activeSources[source.tooltipOwner] = entry
      reconcile()
      return
    }
    activeSources.removeValue(forKey: source.tooltipOwner)
    if wasFocused {
      dismiss(owner: source.tooltipOwner)
    } else if wasHovering {
      cancelPresentation(owner: source.tooltipOwner)
      if selectedSource() == nil {
        scheduleHoverDismissal(owner: source.tooltipOwner)
      } else {
        reconcile()
      }
    }
  }

  private func beginPresentation(source: any TooltipPresentationSource) {
    guard let context = source.tooltipPresentationContext else {
      activeSources.removeValue(forKey: source.tooltipOwner)
      return
    }
    let request = arbiter.arm(owner: source.tooltipOwner)!
    presentationTask?.cancel()
    self.source = source
    observe(source: source, window: context.parentWindow)
    installEventMonitor()
    let sleep = sleep
    presentationTask = Task { @MainActor [weak self, weak source] in
      do {
        try await sleep(TooltipTiming.presentationDelay)
      } catch {
        guard let self, arbiter.pending == request else { return }
        dismiss(owner: request.owner)
        return
      }
      guard !Task.isCancelled, let self else { return }
      guard let source, source.tooltipOwner == request.owner else {
        dismiss(owner: request.owner)
        return
      }
      presentationTask = nil
      let replacesVisible = arbiter.visible != nil
      guard arbiter.present(request) else { return }
      show(source: source, animated: !replacesVisible)
    }
  }

  func dismiss(owner: TooltipOwner) {
    cancelHoverDismissal()
    activeSources.removeValue(forKey: owner)
    if arbiter.pending?.owner == owner {
      presentationTask?.cancel()
      presentationTask = nil
    }
    let hidesPanel = arbiter.visible?.owner == owner
    _ = arbiter.dismiss(owner: owner)
    if hidesPanel { panel?.hide() }
    reconcile()
  }

  public func dismissAll() {
    activeSources.removeAll(keepingCapacity: true)
    arbiter.dismissAll()
    clearPresentation()
  }

  public func tearDown() {
    dismissAll()
    activeSources.removeAll(keepingCapacity: false)
    removeAccessibilityObserver()
    panel?.tearDown()
    panel = nil
    cursorSource = nil
  }

  func refresh(source: any TooltipPresentationSource) {
    guard activeSources[source.tooltipOwner] != nil else { return }
    guard source.tooltipPresentationContext != nil else {
      dismiss(owner: source.tooltipOwner)
      return
    }
    guard arbiter.visible?.owner == source.tooltipOwner else { return }
    self.source = source
    show(source: source, animated: false)
  }

  private func reconcile() {
    guard let selected = selectedSource() else {
      arbiter.dismissAll()
      clearPresentation()
      return
    }
    self.source = selected
    if arbiter.pending?.owner == selected.tooltipOwner { return }
    if arbiter.visible?.owner == selected.tooltipOwner { return }
    beginPresentation(source: selected)
  }

  private func selectedSource() -> (any TooltipPresentationSource)? {
    var staleOwners: [TooltipOwner] = []
    var hovered: ActiveTooltipSource?
    var focused: ActiveTooltipSource?
    var newestHover: UInt64 = 0
    var newestFocus: UInt64 = 0
    for (owner, entry) in activeSources {
      guard let source = entry.source, source.tooltipPresentationContext != nil else {
        staleOwners.append(owner)
        continue
      }
      if entry.hovering {
        newestHover = max(newestHover, entry.hoverSequence)
        if hovered == nil || preferred(entry, over: hovered!, sequence: \.hoverSequence) { hovered = entry }
      }
      if entry.focused {
        newestFocus = max(newestFocus, entry.focusSequence)
        if focused == nil || preferred(entry, over: focused!, sequence: \.focusSequence) { focused = entry }
      }
    }
    for owner in staleOwners { activeSources.removeValue(forKey: owner) }
    return (newestFocus > newestHover ? focused : hovered)?.source
  }

  private func preferred(
    _ candidate: ActiveTooltipSource,
    over selected: ActiveTooltipSource,
    sequence: KeyPath<ActiveTooltipSource, UInt64>
  ) -> Bool {
    let candidateSource = candidate.source!
    let selectedSource = selected.source!
    if let candidateContext = candidateSource.tooltipPresentationContext,
      let selectedContext = selectedSource.tooltipPresentationContext,
      candidateContext.parentWindow === selectedContext.parentWindow
    {
      let candidateRect = candidateContext.anchorRect.standardized
      let selectedRect = selectedContext.anchorRect.standardized
      if selectedRect != candidateRect {
        if selectedRect.contains(candidateRect) || candidateRect.contains(selectedRect) {
          return candidateRect.width * candidateRect.height < selectedRect.width * selectedRect.height
        }
      }
    }
    return candidate[keyPath: sequence] > selected[keyPath: sequence]
  }

  private func show(source: any TooltipPresentationSource, animated: Bool) {
    guard
      let context = source.tooltipPresentationContext,
      context.parentWindow === observedWindow
    else {
      dismiss(owner: source.tooltipOwner)
      return
    }
    let panel = panel ?? makePanel()
    panel.show(
      content: source.tooltipContent,
      anchorRect: context.anchorRect,
      visibleFrame: context.visibleFrame,
      parentWindow: context.parentWindow,
      reduceMotion: !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    )
    self.panel = panel
  }

  private func makePanel() -> any TooltipPanelPresenting {
    let panel = panelFactory()
    let center = NSWorkspace.shared.notificationCenter
    accessibilityObserver = center.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let source = self.source else { return }
        self.refresh(source: source)
      }
    }
    return panel
  }

  private func clearPresentation() {
    presentationTask?.cancel()
    presentationTask = nil
    cancelHoverDismissal()
    panel?.hide()
    source = nil
    removeEventMonitor()
    stopObservingSource()
  }

  private func installEventMonitor() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .scrollWheel]) {
      [weak self] event in
      if event.type == .scrollWheel || (event.type == .keyDown && event.keyCode == 53) {
        self?.dismissAll()
      } else if event.type == .mouseMoved {
        self?.validateCurrentSource()
      }
      return event
    }
  }

  private func removeEventMonitor() {
    guard let eventMonitor else { return }
    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }

  private func observe(source: any TooltipPresentationSource, window: NSWindow) {
    stopObservingSource()
    if let clipView = source.tooltipClipView {
      self.clipView = clipView
      clipViewWasPostingBoundsChanges = clipView.postsBoundsChangedNotifications
      clipView.postsBoundsChangedNotifications = true
      clipViewObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.dismissAll() }
      }
    }
    observedWindow = window
    for name in [
      NSWindow.willCloseNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
    ] {
      windowObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in self?.dismissAll() }
        })
    }
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
      windowObservers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in self?.dismissAll() }
        })
    }
  }

  private func validateCurrentSource() {
    guard let source else { return }
    if source.tooltipPresentationContext == nil { dismiss(owner: source.tooltipOwner) }
  }

  private func cancelPresentation(owner: TooltipOwner) {
    guard arbiter.pending?.owner == owner else { return }
    presentationTask?.cancel()
    presentationTask = nil
    _ = arbiter.dismiss(owner: owner)
  }

  private func scheduleHoverDismissal(owner: TooltipOwner) {
    cancelHoverDismissal()
    dismissalOwner = owner
    let sleep = sleep
    dismissalTask = Task { @MainActor [weak self] in
      do {
        try await sleep(TooltipTiming.dismissalDelay)
      } catch {
        return
      }
      guard !Task.isCancelled, let self, dismissalOwner == owner else { return }
      dismissalTask = nil
      dismissalOwner = nil
      arbiter.dismissAll()
      clearPresentation()
    }
  }

  private func cancelHoverDismissal() {
    dismissalTask?.cancel()
    dismissalTask = nil
    dismissalOwner = nil
  }

  private func stopObservingSource() {
    if let clipViewObserver { NotificationCenter.default.removeObserver(clipViewObserver) }
    clipViewObserver = nil
    if let clipView, !clipViewWasPostingBoundsChanges { clipView.postsBoundsChangedNotifications = false }
    clipView = nil
    clipViewWasPostingBoundsChanges = false
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    windowObservers.removeAll()
    observedWindow = nil
  }

  private func removeAccessibilityObserver() {
    guard let accessibilityObserver else { return }
    NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
    self.accessibilityObserver = nil
  }
}
