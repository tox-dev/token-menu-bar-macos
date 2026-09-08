import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

@Test func codexReadsResetCreditExpiriesAndDropsIncompleteEntries() async throws {
  let transport = StubTransport()
  transport.on(path: "/wham/usage", .text(#"{"plan_type":"pro"}"#))
  transport.on(
    path: "rate-limit-reset-credits",
    .text(
      #"{"available_count":2,"credits":[{"id":"a","expires_at":1756512000},"#
        + #"{"id":"b","expires_at":"2026-09-03T10:00:00Z"},{"id":"c"},{"expires_at":1},{"id":"d","expires_at":"soon"}]}"#
    ))
  let result = await codexProvider(MemoryCodexStore(validCodex), transport: transport).fetch(
    now: fixedNow, options: FetchOptions())
  let expiry = try #require(ISODate.parse("2026-09-03T10:00:00Z"))
  #expect(
    result.outcome.snapshot?.resetCredits?.expiries == [
      ResetCreditExpiry(id: "a", expiresAt: Date(timeIntervalSince1970: 1_756_512_000)),
      ResetCreditExpiry(id: "b", expiresAt: expiry),
    ])
}

private let timestampCases: [(JSONValue, Date?)] = [
  (.number(5), Date(timeIntervalSince1970: 5)),
  (.string("2026-09-03T10:00:00Z"), ISODate.parse("2026-09-03T10:00:00Z")),
  (.string("soon"), nil),
  (.bool(true), nil),
]

@Test(arguments: timestampCases)
func codexMapperReadsEpochAndISOTimestamps(value: JSONValue, expected: Date?) {
  #expect(CodexMapper.timestamp(value) == expected)
}

@Test func resetCreditsDecodeWithoutExpiries() throws {
  let legacy = #"{"available":1,"applicable":1,"immediatePurchaseEligible":false}"#
  #expect(
    try JSONDecoder().decode(ResetCredits.self, from: Data(legacy.utf8)) == ResetCredits(available: 1, applicable: 1))
  let full = ResetCredits(
    available: 1, applicable: 0, totalEarned: 2, expiries: [ResetCreditExpiry(id: "a", expiresAt: fixedNow)])
  #expect(try JSONDecoder().decode(ResetCredits.self, from: JSONEncoder().encode(full)) == full)
}
