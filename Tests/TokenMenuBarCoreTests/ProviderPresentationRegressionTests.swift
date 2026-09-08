import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test(arguments: ProviderID.allCases, [false, true])
func providerHeaderKeepsTheAccountVisible(provider: ProviderID, hidden: Bool) {
  let card = UsagePresenter.card(
    provider: provider,
    state: ProviderState(
      snapshot: ProviderSnapshot(
        provider: provider, identity: ProviderIdentity(planName: "Pro", email: "fixture@example.com"),
        windows: [], fetchedAt: fixedNow), availability: .current),
    samples: [:], options: UsageDisplayOptions(hidePersonalInformation: hidden), now: fixedNow)
  #expect(card.primaryChips.map(\.text) == ["Pro", hidden ? "account" : "fixture@example.com"])
}

@Test(arguments: [
  ("exhausted visible meter", Notice.Kind.limitReached, "weekly:model" as String?, 100.0, true, false),
  ("hidden meter", .limitReached, "weekly:model", 100.0, false, true),
  ("not exhausted", .limitReached, "weekly:model", 90.0, true, true),
  ("unrelated meter", .limitReached, "weekly", 100.0, true, true),
  ("unscoped warning", .limitReached, nil, 100.0, true, true),
  ("spend control", .spendControl, "weekly:model", 100.0, true, true),
])
func providerNoticesOnlyOmitLimitsAlreadyShown(
  reason: String, kind: Notice.Kind, windowID: String?, percent: Double, selected: Bool, retained: Bool
) throws {
  let notice = Notice(kind: kind, text: "Fixture limit warning", windowID: windowID)
  let window = QuotaWindow(id: "weekly:model", label: "Model", group: .weekly, usedPercent: percent, resetsAt: nil)
  let snapshot = ProviderSnapshot(provider: .claude, windows: [window], notices: [notice], fetchedAt: fixedNow)
  let card = try #require(
    UsagePresenter.presentation(
      state: [.claude: ProviderState(snapshot: snapshot, availability: .current)], enabled: [.claude],
      selected: selected ? [WindowKey(.claude, window)] : [], samples: [:], analytics: [:], lastRefresh: nil,
      iconTone: .normal, isRefreshing: false, now: fixedNow
    ).cards.first)
  #expect(card.notices == (retained ? [notice] : []), Comment(rawValue: reason))
}

@Test func providerDetailsOmitMissingValuesAndKeepZeroAndOff() {
  let details = [
    ProviderDetail(id: "oauth-availability", title: "Not reported by this source", value: "Balance", explanation: ""),
    ProviderDetail(id: "empty", title: "Empty", value: " \n", explanation: ""),
    ProviderDetail(id: "balance", title: "Balance", value: "0", explanation: ""),
    ProviderDetail(id: "reload", title: "Auto-reload", value: "Off", explanation: ""),
  ]
  let card = UsagePresenter.card(
    provider: .claude,
    state: ProviderState(
      snapshot: ProviderSnapshot(provider: .claude, windows: [], fetchedAt: fixedNow, details: details),
      availability: .current), samples: [:], now: fixedNow)
  #expect(card.details == Array(details.suffix(2)))
}

@Test func providerNoticeDecodesCachedEntriesWithoutAWindowID() throws {
  let notice = try JSONDecoder().decode(
    Notice.self, from: Data(#"{"kind":"limitReached","text":"Fixture limit"}"#.utf8))
  #expect(notice == Notice(kind: .limitReached, text: "Fixture limit"))
}

@Test func providerNoticePreservesItsWindowThroughTheCache() throws {
  let notice = Notice(kind: .limitReached, text: "Fixture limit", windowID: "weekly:model")
  #expect(try JSONDecoder().decode(Notice.self, from: JSONEncoder().encode(notice)) == notice)
}
