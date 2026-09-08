import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test @MainActor func mountedLimitNoticeCountsDownWithoutRebuildingTheCard() async throws {
  let environment = try makeEnvironment(populate: false)
  let snapshot = ProviderSnapshot(
    provider: .claude, windows: [],
    notices: [
      Notice(kind: .limitReached, text: "Weekly limit reached.", resetsAt: fixedNow.addingTimeInterval(125))
    ], fetchedAt: fixedNow)
  environment.state.update(.claude) {
    $0.snapshot = snapshot
    $0.availability = .current
  }
  environment.refreshUsagePresentation(at: fixedNow)
  let card = try #require(environment.cards.first)
  let fixture = NativeHosting(ProviderCardView(card: card, environment: environment, onRefreshProvider: { _ in }))
  defer { fixture.close() }
  fixture.show()
  try await loadNativeAccessibility()
  #expect(creditAccessibleText(fixture.view).contains("Resets in 2 min"))
  #expect(environment.advanceUsageDeadlines(to: fixedNow.addingTimeInterval(6)))
  try await loadNativeAccessibility()
  #expect(
    await waitUntil(within: 5) {
      CFRunLoopRunInMode(.defaultMode, 0.005, true)
      fixture.view.layoutSubtreeIfNeeded()
      fixture.view.displayIfNeeded()
      return creditAccessibleText(fixture.view).contains("Resets in 1 min")
    }, "After advancing to \(environment.usageDeadlineNow): \(creditAccessibleText(fixture.view))")
  #expect(environment.cards.first == card)
}

@MainActor private func creditAccessibleText(_ root: AnyObject) -> String {
  var visited: Set<ObjectIdentifier> = []
  func text(_ element: AnyObject) -> String {
    guard visited.insert(ObjectIdentifier(element)).inserted else { return "" }
    let value: Any? = element.accessibilityValue?()
    return
      ([
        element.accessibilityLabel?(), element.accessibilityTitle?(), value as? String,
      ].compactMap { $0 }
      + (element.accessibilityChildren?() ?? []).map { text($0 as AnyObject) }).joined(separator: "\n")
  }
  return text(root)
}
