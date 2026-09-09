import Foundation

struct StatusQuotaRestriction {
  let windows: [QuotaWindow]

  init?(window: QuotaWindow, snapshot: ProviderSnapshot, now: Date) {
    guard window.isActive else { return nil }
    windows = snapshot.windows.filter { candidate in
      candidate.isActive && candidate.usedPercent >= 100
        && (candidate.resetsAt.map { $0 > now } ?? true)
        && Self.applies(candidate, to: window, provider: snapshot.provider)
    }
    guard windows.contains(where: { $0.id != window.id }) else { return nil }
  }

  func projected(_ window: QuotaWindow) -> QuotaWindow {
    let resets = windows.compactMap(\.resetsAt)
    return QuotaWindow(
      id: window.id, label: window.label, group: window.group, usedPercent: 100,
      resetsAt: resets.count == windows.count ? resets.max() : nil, duration: window.duration,
      severity: .critical, isActive: window.isActive, scope: window.scope,
      resetPrecision: window.resetPrecision, detail: window.detail)
  }

  func explanation(now: Date) -> String {
    "Included quota limited by "
      + windows.map { "\($0.label) (100% used; resets \(Format.countdown(to: $0.resetsAt, now: now)))" }
      .joined(separator: "; ")
      + "."
  }

  private static func applies(_ limit: QuotaWindow, to window: QuotaWindow, provider: ProviderID) -> Bool {
    if limit.id == window.id { return true }
    switch provider {
    case .claude:
      return limit.id == "session" || limit.id == "weekly"
    case .codex:
      guard limit.group != .other, window.group != .other else { return false }
      return limit.id.split(separator: ":").dropLast() == window.id.split(separator: ":").dropLast()
    case .gemini, .antigravity, .cursor, .copilot:
      return false
    }
  }
}
