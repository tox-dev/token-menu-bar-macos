import Foundation
import Testing
import TokenMenuBarTestSupport

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
  let limited = SettingsProviderPresentation.service(.rateLimited(retryAt: retry, detail: "Slow down"))
  let limitedLater = SettingsProviderPresentation.service(
    .rateLimited(retryAt: retry.addingTimeInterval(86_400), detail: "Slow down"))
  #expect(limited.hasPrefix("Rate limited · retry "))
  #expect(limited.hasSuffix(" · Slow down"))
  #expect(limited.count > "Rate limited · retry  · Slow down".count)
  #expect(limited != limitedLater)
  #expect(
    SettingsProviderPresentation.service(.rateLimited(retryAt: nil, detail: "Slow down"))
      == "Rate limited · Slow down")
}
