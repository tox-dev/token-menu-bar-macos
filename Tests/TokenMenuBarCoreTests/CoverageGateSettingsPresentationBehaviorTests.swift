import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func coverageGateLastUsageAdvancesWhenThePercentageRisesBeforeReset() {
  let key = WindowKey(provider: .codex, windowID: "weekly")
  let reset = Date(timeIntervalSince1970: 1_800_000_000)
  let first = UsageSample(
    timestamp: reset.addingTimeInterval(-300), key: key, usedPercent: 10, resetsAt: reset)
  let second = UsageSample(
    timestamp: reset.addingTimeInterval(-200), key: key, usedPercent: 20, resetsAt: reset)

  #expect(SettingsModelPresentation.lastUsageDates([first, second])[key] == second.timestamp)
}

@Test func coverageGateProviderServiceReportsEveryFailureDetail() {
  let retry = Date(timeIntervalSince1970: 1_800_000_000)

  #expect(SettingsProviderPresentation.service(.checking) == "Checking service")
  #expect(SettingsProviderPresentation.service(.offline(detail: "No route")) == "Offline · No route")
  #expect(SettingsProviderPresentation.service(.unavailable(detail: "Maintenance")) == "Unavailable · Maintenance")
  #expect(
    SettingsProviderPresentation.service(.rateLimited(retryAt: retry, detail: "Slow down"))
      == "Rate limited · retry \(retry.formatted(date: .abbreviated, time: .shortened)) · Slow down")
  #expect(
    SettingsProviderPresentation.service(.rateLimited(retryAt: nil, detail: "Slow down"))
      == "Rate limited · Slow down")
}
