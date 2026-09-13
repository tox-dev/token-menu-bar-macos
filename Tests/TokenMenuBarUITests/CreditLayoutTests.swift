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

@MainActor private func creditTooltipAnchors(in root: NSView) -> [TooltipTrackingView] {
  root.subviews.flatMap { view in
    (view as? TooltipTrackingView).map { [$0] } ?? creditTooltipAnchors(in: view)
  }
}
