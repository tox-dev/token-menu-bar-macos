import CoreGraphics
import Foundation
import OSLog

public enum LogCategory: String, CaseIterable, Codable, Sendable {
  case app
  case geometry
  case network
  case persistence
  case refresh
  case status
  case tabs

  public var title: String {
    switch self {
    case .app: "App"
    case .geometry: "Geometry"
    case .network: "Network"
    case .persistence: "Persistence"
    case .refresh: "Refresh"
    case .status: "Status item"
    case .tabs: "Tabs"
    }
  }
}

public struct DiagnosticRect: Sendable, Equatable, CustomStringConvertible {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public init(_ rect: CGRect) {
    self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
  }

  public var description: String {
    "(\(DiagnosticNumber.text(x)),\(DiagnosticNumber.text(y)) "
      + "\(DiagnosticNumber.text(width))x\(DiagnosticNumber.text(height)))"
  }
}

public struct DiagnosticSize: Sendable, Equatable, CustomStringConvertible {
  public let width: Double
  public let height: Double

  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }

  public init(_ size: CGSize) {
    self.init(width: size.width, height: size.height)
  }

  public var description: String {
    "\(DiagnosticNumber.text(width))x\(DiagnosticNumber.text(height))"
  }
}

public struct PanelDiagnostic: Sendable, Equatable {
  public enum Action: String, Sendable {
    case open
    case resize
    case screenChanged = "screen-changed"
  }

  public let action: Action
  public let trigger: String
  public let tab: String
  public let anchor: DiagnosticRect?
  public let screenID: String?
  public let screenFrame: DiagnosticRect?
  public let maximum: DiagnosticSize
  public let proposed: DiagnosticSize
  public let clamped: DiagnosticSize
  public let resultFrame: DiagnosticRect?
  public let appActive: Bool
  public let windowKey: Bool?
  public let windowMain: Bool?
  public let frontmostBundleID: String?

  public init(
    action: Action,
    trigger: String,
    tab: String,
    anchor: DiagnosticRect?,
    screenID: String?,
    screenFrame: DiagnosticRect?,
    maximum: DiagnosticSize,
    proposed: DiagnosticSize,
    clamped: DiagnosticSize,
    resultFrame: DiagnosticRect?,
    appActive: Bool,
    windowKey: Bool?,
    windowMain: Bool?,
    frontmostBundleID: String?
  ) {
    self.action = action
    self.trigger = trigger
    self.tab = tab
    self.anchor = anchor
    self.screenID = screenID
    self.screenFrame = screenFrame
    self.maximum = maximum
    self.proposed = proposed
    self.clamped = clamped
    self.resultFrame = resultFrame
    self.appActive = appActive
    self.windowKey = windowKey
    self.windowMain = windowMain
    self.frontmostBundleID = frontmostBundleID
  }

  public static func postResize(
    trigger: String,
    tab: String,
    anchor: DiagnosticRect?,
    screenID: String?,
    screenFrame: DiagnosticRect?,
    maximum: DiagnosticSize,
    proposed: DiagnosticSize,
    clamped: DiagnosticSize,
    resultFrame: DiagnosticRect?,
    appActive: Bool,
    windowKey: Bool?,
    windowMain: Bool?,
    frontmostBundleID: String?
  ) -> PanelDiagnostic {
    PanelDiagnostic(
      action: .resize,
      trigger: trigger,
      tab: tab,
      anchor: anchor,
      screenID: screenID,
      screenFrame: screenFrame,
      maximum: maximum,
      proposed: proposed,
      clamped: clamped,
      resultFrame: resultFrame,
      appActive: appActive,
      windowKey: windowKey,
      windowMain: windowMain,
      frontmostBundleID: frontmostBundleID)
  }
}

public struct TabDiagnostic: Sendable, Equatable {
  public enum Action: String, Sendable {
    case measurement
    case presented
    case transition
  }

  public let action: Action
  public let from: String?
  public let to: String?
  public let sourceTab: String?
  public let activeTab: String
  public let filedUnderTab: String?
  public let size: DiagnosticSize?
  public let chromeHeight: Double?
  public let durationMilliseconds: Double?

  public init(
    action: Action,
    from: String? = nil,
    to: String? = nil,
    sourceTab: String? = nil,
    activeTab: String,
    filedUnderTab: String? = nil,
    size: DiagnosticSize? = nil,
    chromeHeight: Double? = nil,
    durationMilliseconds: Double? = nil
  ) {
    self.action = action
    self.from = from
    self.to = to
    self.sourceTab = sourceTab
    self.activeTab = activeTab
    self.filedUnderTab = filedUnderTab
    self.size = size
    self.chromeHeight = chromeHeight
    self.durationMilliseconds = durationMilliseconds
  }
}

public struct StatusDiagnostic: Sendable, Equatable {
  public enum Action: String, Sendable {
    case deferred
    case probe
    case retier
  }

  public let action: Action
  public let trigger: String
  public let buttonFrame: DiagnosticRect?
  public let oldTier: Int?
  public let newTier: Int?
  public let visible: Bool
  public let popoverVisible: Bool
  public let fits: Bool?
  public let layoutContext: String?

  public init(
    action: Action,
    trigger: String,
    buttonFrame: DiagnosticRect?,
    oldTier: Int?,
    newTier: Int?,
    visible: Bool,
    popoverVisible: Bool,
    fits: Bool?,
    layoutContext: String?
  ) {
    self.action = action
    self.trigger = trigger
    self.buttonFrame = buttonFrame
    self.oldTier = oldTier
    self.newTier = newTier
    self.visible = visible
    self.popoverVisible = popoverVisible
    self.fits = fits
    self.layoutContext = layoutContext
  }

  public static func retierIfChanged(
    trigger: String,
    buttonFrame: DiagnosticRect?,
    oldTier: Int,
    newTier: Int,
    visible: Bool,
    popoverVisible: Bool,
    fits: Bool?,
    layoutContext: String?
  ) -> StatusDiagnostic? {
    guard oldTier != newTier else { return nil }
    return StatusDiagnostic(
      action: .retier,
      trigger: trigger,
      buttonFrame: buttonFrame,
      oldTier: oldTier,
      newTier: newTier,
      visible: visible,
      popoverVisible: popoverVisible,
      fits: fits,
      layoutContext: layoutContext)
  }
}

public enum DiagnosticRefreshOutcome: String, Sendable {
  case authenticationRequired = "authentication-required"
  case failed
  case networkUnavailable = "network-unavailable"
  case partial
  case rateLimited = "rate-limited"
  case skipped
  case success
}

public enum DiagnosticRefreshSkipReason: String, Sendable {
  case analyticsNotDue = "analytics-not-due"
  case cancelled
  case disabled
  case notDiscovered = "not-discovered"
  case noWork = "no-work"
  case retryBackoff = "retry-backoff"
}

public struct RefreshDiagnostic: Sendable, Equatable {
  public let cycleID: String
  public let trigger: String
  public let provider: ProviderID
  public let usagePolicy: String
  public let analyticsPolicy: String
  public let outcome: DiagnosticRefreshOutcome
  public let durationMilliseconds: Int
  public let includeAnalytics: Bool
  public let analyticsReturned: Bool
  public let analyticsPointCount: Int
  public let warnings: [String]
  public let skipReason: DiagnosticRefreshSkipReason?

  public init(
    cycleID: String,
    trigger: String,
    provider: ProviderID,
    usagePolicy: String,
    analyticsPolicy: String,
    outcome: DiagnosticRefreshOutcome,
    durationMilliseconds: Int,
    includeAnalytics: Bool,
    analyticsReturned: Bool,
    analyticsPointCount: Int,
    warnings: [String],
    skipReason: DiagnosticRefreshSkipReason? = nil
  ) {
    self.cycleID = cycleID
    self.trigger = trigger
    self.provider = provider
    self.usagePolicy = usagePolicy
    self.analyticsPolicy = analyticsPolicy
    self.outcome = outcome
    self.durationMilliseconds = durationMilliseconds
    self.includeAnalytics = includeAnalytics
    self.analyticsReturned = analyticsReturned
    self.analyticsPointCount = analyticsPointCount
    self.warnings = warnings
    self.skipReason = skipReason
  }

  public static func skipped(
    cycleID: String,
    trigger: String,
    provider: ProviderID,
    usagePolicy: String,
    analyticsPolicy: String,
    reason: DiagnosticRefreshSkipReason
  ) -> RefreshDiagnostic {
    RefreshDiagnostic(
      cycleID: cycleID,
      trigger: trigger,
      provider: provider,
      usagePolicy: usagePolicy,
      analyticsPolicy: analyticsPolicy,
      outcome: .skipped,
      durationMilliseconds: 0,
      includeAnalytics: false,
      analyticsReturned: false,
      analyticsPointCount: 0,
      warnings: [],
      skipReason: reason)
  }
}

public struct RequestDiagnostic: Sendable, Equatable {
  public let requestID: String
  public let operation: String
  public let method: String
  public let status: Int?
  public let byteCount: Int
  public let durationMilliseconds: Int
  public let errorDomain: String?
  public let errorCode: Int?

  public init(
    requestID: String,
    operation: String,
    method: String,
    status: Int?,
    byteCount: Int,
    durationMilliseconds: Int,
    errorDomain: String? = nil,
    errorCode: Int? = nil
  ) {
    self.requestID = requestID
    self.operation = operation
    self.method = method
    self.status = status
    self.byteCount = byteCount
    self.durationMilliseconds = durationMilliseconds
    self.errorDomain = errorDomain
    self.errorCode = errorCode
  }

  public init(
    requestID: String,
    operation: String,
    method: String,
    byteCount: Int,
    durationMilliseconds: Int,
    error: any Error
  ) {
    let value = error as NSError
    self.init(
      requestID: requestID,
      operation: operation,
      method: method,
      status: nil,
      byteCount: byteCount,
      durationMilliseconds: durationMilliseconds,
      errorDomain: value.domain,
      errorCode: value.code)
  }
}

public enum DiagnosticEvent: Sendable, Equatable {
  case panel(PanelDiagnostic)
  case refresh(RefreshDiagnostic)
  case request(RequestDiagnostic)
  case status(StatusDiagnostic)
  case tab(TabDiagnostic)

  public var category: LogCategory {
    switch self {
    case .panel: .geometry
    case .refresh: .refresh
    case .request: .network
    case .status: .status
    case .tab: .tabs
    }
  }

  public var message: String {
    switch self {
    case .panel(let event):
      fields(
        "panel.\(event.action.rawValue)",
        [
          ("trigger", event.trigger), ("tab", event.tab), ("anchor", event.anchor?.description),
          ("screen", event.screenID), ("screenFrame", event.screenFrame?.description),
          ("max", event.maximum.description), ("proposed", event.proposed.description),
          ("clamped", event.clamped.description), ("result", event.resultFrame?.description),
          ("appActive", event.appActive.description), ("windowKey", event.windowKey?.description),
          ("windowMain", event.windowMain?.description), ("frontmost", event.frontmostBundleID),
        ])
    case .tab(let event):
      fields(
        "tab.\(event.action.rawValue)",
        [
          ("from", event.from), ("to", event.to), ("source", event.sourceTab), ("active", event.activeTab),
          ("filedUnder", event.filedUnderTab), ("size", event.size?.description),
          ("chromeHeight", event.chromeHeight.map(DiagnosticNumber.text)),
          ("durationMs", event.durationMilliseconds.map(DiagnosticNumber.text)),
        ])
    case .status(let event):
      fields(
        "status.\(event.action.rawValue)",
        [
          ("trigger", event.trigger), ("buttonFrame", event.buttonFrame?.description),
          ("oldTier", event.oldTier.map(String.init)), ("newTier", event.newTier.map(String.init)),
          ("visible", event.visible.description), ("popoverVisible", event.popoverVisible.description),
          ("fits", event.fits?.description), ("context", event.layoutContext),
        ])
    case .refresh(let event):
      fields(
        "refresh.provider",
        [
          ("cycle", event.cycleID), ("trigger", event.trigger), ("provider", event.provider.rawValue),
          ("usagePolicy", event.usagePolicy), ("analyticsPolicy", event.analyticsPolicy),
          ("outcome", event.outcome.rawValue), ("durationMs", String(event.durationMilliseconds)),
          ("includeAnalytics", event.includeAnalytics.description),
          ("analyticsReturned", event.analyticsReturned.description),
          ("analyticsPoints", String(event.analyticsPointCount)), ("warnings", String(event.warnings.count)),
          ("skipReason", event.skipReason?.rawValue),
        ] + event.warnings.enumerated().map { ("warning\($0.offset + 1)", $0.element) }
      )
    case .request(let event):
      fields(
        "request.finished",
        [
          ("id", event.requestID), ("operation", event.operation), ("method", event.method),
          ("status", event.status.map(String.init)), ("bytes", String(event.byteCount)),
          ("durationMs", String(event.durationMilliseconds)), ("errorDomain", event.errorDomain),
          ("errorCode", event.errorCode.map(String.init)),
        ])
    }
  }

  private func fields(_ name: String, _ values: [(String, String?)]) -> String {
    ([name] + values.compactMap { key, value in value.map { "\(key)=\(DiagnosticValue.text($0))" } })
      .joined(separator: " ")
  }
}

public struct DiagnosticSignposter: Sendable {
  private let base: OSSignposter

  public init(category: LogCategory) {
    base = OSSignposter(subsystem: SystemLog.subsystem, category: category.rawValue)
  }

  public func withInterval<Result>(
    _ name: StaticString, operation: () throws -> Result
  ) rethrows -> Result {
    guard base.isEnabled else { return try operation() }
    let state = base.beginInterval(name)
    defer { base.endInterval(name, state) }
    return try operation()
  }

  public func withInterval<Result: Sendable>(
    _ name: StaticString, operation: () async throws -> Result
  ) async rethrows -> Result {
    guard base.isEnabled else { return try await operation() }
    let state = base.beginInterval(name)
    defer { base.endInterval(name, state) }
    return try await operation()
  }
}

public enum DiagnosticSignposts {
  public static let geometry = DiagnosticSignposter(category: .geometry)
  public static let refresh = DiagnosticSignposter(category: .refresh)
  public static let tabs = DiagnosticSignposter(category: .tabs)
}

enum DiagnosticNumber {
  static func text(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
  }
}

enum DiagnosticValue {
  static func text(_ value: String) -> String {
    let safe = LogSanitizer.redact(value)
    guard safe.contains(where: { $0.isWhitespace || $0 == #"""# || $0 == "=" }) else { return safe }
    return #""\#(safe.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))""#
  }
}

enum SystemLog {
  static let subsystem = "dev.tox.token-menu-bar"
}
