import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

@Test(
  arguments: [
    QuotaAvailability.current, .stale, .loading, .authenticationRequired, .networkUnavailable, .rateLimited,
    .unavailable,
    .disabled,
  ], ProviderID.allCases)
func staleUsageAppearanceFollowsProviderAvailability(availability: QuotaAvailability, provider: ProviderID) {
  let card = UsagePresenter.card(
    provider: provider,
    state: ProviderState(snapshot: DemoData.snapshot(provider, now: fixedNow), availability: availability),
    samples: [:], now: fixedNow)

  #expect(card.valueAppearance == (availability == .current ? .current : .stale))
}

@Test func staleUsageIncludesCreditOnlySnapshots() {
  let card = UsagePresenter.card(
    provider: .codex,
    state: ProviderState(
      snapshot: ProviderSnapshot(
        provider: .codex, windows: [], credits: CreditBalance(balance: 0), fetchedAt: fixedNow),
      availability: .authenticationRequired), samples: [:], now: fixedNow)

  #expect(card.isStale)
}

@Test func staleUsageDoesNotInventCachedDataBeforeTheFirstFetch() {
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(availability: .authenticationRequired), samples: [:], now: fixedNow)

  #expect(!card.isStale)
}

@Test(arguments: [UsageValueAppearance.current, .stale])
func staleUsageTextRetainsItsValueAndDescribesFreshness(appearance: UsageValueAppearance) {
  #expect(
    appearance.accessibilityValue("52% used") == (appearance == .stale ? "Stale, last known: 52% used" : "52% used"))
  #expect(appearance.foreground == (appearance == .stale ? .tertiary : .primary))
}

@Test(arguments: StatusFormat.allCases)
func staleUsageDefaultsToCurrentWhenAvailabilityIsMissing(format: StatusFormat) {
  let snapshot = DemoData.snapshot(.claude, now: fixedNow)
  let models = [[ProviderID: QuotaAvailability](), [.claude: .current]].map { availability in
    StatusItemBuilder.build(
      StatusItemInput(
        snapshots: [.claude: snapshot], availability: availability,
        selectedKeys: snapshot.windows.map { WindowKey(.claude, $0) }, format: format, customTemplate: "{label}:{pct}",
        decimals: 0, hideZeroCells: false, order: .provider, labels: [:], now: fixedNow))
  }

  #expect(!models[0].cells.isEmpty)
  #expect(models[0] == models[1])
}

@Test(arguments: StatusFormat.allCases)
func staleUsageStatusCellsRetainNumbersAndIdentifyOldData(format: StatusFormat) {
  let snapshot = DemoData.snapshot(.claude, now: fixedNow)
  let models = [QuotaAvailability.current, .authenticationRequired].map { availability in
    StatusItemBuilder.build(
      StatusItemInput(
        snapshots: [.claude: snapshot], availability: [.claude: availability],
        selectedKeys: snapshot.windows.map { WindowKey(.claude, $0) }, format: format, customTemplate: "{label}:{pct}",
        decimals: 0, hideZeroCells: false, order: .provider, labels: [:], now: fixedNow))
  }
  let model = models[1]

  #expect(!model.cells.isEmpty)
  #expect(model.cells.map(\.lines) == models[0].cells.map(\.lines))
  #expect(model.cells.map(\.bars) == models[0].cells.map(\.bars))
  #expect(model.cells.map(\.percent) == models[0].cells.map(\.percent))
  #expect(model.cells.allSatisfy { $0.isStale })
  #expect(model.cells.allSatisfy { $0.tooltip.hasPrefix("Stale, last known values.") })
}
