import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test(arguments: [340.0, 548, 852]) @MainActor
func resetCreditExpiryKeepsItsTitleAndDateOnSeparateSingleLines(width: CGFloat) throws {
  let credits = try #require(
    UsagePresenter.creditsPresentation(
      CreditBalance(balance: 125, hasCredits: true),
      resetCredits: ResetCredits(
        available: 2, applicable: 1, immediatePurchaseEligible: true,
        expiries: [ResetCreditExpiry(id: "fixture", expiresAt: fixedNow)])))
  let hosting = host(CreditsView(presentation: credits), width: width, height: 300)
  let metrics = creditTooltipAnchors(in: hosting)
  #expect(metrics.count == credits.primaryMetrics.count)
  let expiry = try #require(metrics.first { $0.tooltipContent.title == "Next reset-credit expiry" })
  #expect(expiry.bounds.height > 20 && expiry.bounds.height < 40)
  for metric in metrics {
    let frame = metric.convert(metric.bounds, to: hosting)
    #expect(frame.minX >= 0 && frame.maxX <= width)
    #expect(!frame.isEmpty)
  }
}

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
  let hosting = host(ProviderCardView(card: card, environment: environment, onRefreshProvider: { _ in }))
  #expect(creditAccessibleText(hosting).contains("Resets in 2 min"))
  #expect(environment.advanceUsageDeadlines(to: fixedNow.addingTimeInterval(6)))
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  #expect(creditAccessibleText(hosting).contains("Resets in 1 min"))
  #expect(environment.cards.first == card)
}

@MainActor private func creditTooltipAnchors(in root: NSView) -> [TooltipTrackingView] {
  root.subviews.flatMap { view in
    (view as? TooltipTrackingView).map { [$0] } ?? creditTooltipAnchors(in: view)
  }
}

@MainActor private func creditAccessibleText(_ value: Any, depth: Int = 0) -> String {
  guard depth < 30 else { return "" }
  if let view = value as? NSView {
    return
      ([view.accessibilityLabel() ?? "", String(describing: view.accessibilityValue() ?? "")]
      + (view.accessibilityChildren() ?? []).map { creditAccessibleText($0, depth: depth + 1) }
      + view.subviews.map { creditAccessibleText($0, depth: depth + 1) }).joined(separator: "\n")
  }
  guard let element = value as? any NSAccessibilityProtocol else { return "" }
  return
    ([element.accessibilityLabel() ?? "", String(describing: element.accessibilityValue() ?? "")]
    + (element.accessibilityChildren() ?? []).map { creditAccessibleText($0, depth: depth + 1) }).joined(
      separator: "\n")
}
