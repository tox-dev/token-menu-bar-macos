import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test @MainActor func sixtyDayHistoryPreparationHasBoundedRetainedMemory() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await DemoData.seed(history, providers: ProviderID.allCases, now: fixedNow.addingTimeInterval(-30 * 86400))
  try await DemoData.seed(history, providers: ProviderID.allCases, now: fixedNow)
  let sampleCount = try await history.stats().sampleCount
  #expect(sampleCount > 30_000)
  let settings = Settings(defaults: testDefaults())
  settings.historyRange = .twoMonths
  let presenter = HistoryPresenter(history: history, settings: settings, clock: testClock)
  let before = try #require(ProcessPerformanceSnapshot.current())
  let started = ProcessInfo.processInfo.systemUptime
  for metric: HistoryMetric in [
    .windowUsagePercent, .analytics(.inputTokens), .analytics(.turns), .analytics(.costUSD),
  ] {
    presenter.setMetric(metric)
    presenter.ensureLoaded()
    await presenter.waitForLoad()
    #expect(presenter.state.data?.series.isEmpty == false)
  }
  let after = try #require(ProcessPerformanceSnapshot.current())
  let duration = ProcessInfo.processInfo.systemUptime - started
  let growth = Int64(after.physicalFootprintBytes) - Int64(before.physicalFootprintBytes)
  #expect(growth < 128 * 1024 * 1024)
  #expect(duration < 10)
  print(
    "HISTORY_PROFILE samples=\(sampleCount) preparation_s=\(duration) retained_growth_bytes=\(growth) cpu_ns=\(after.cpuNanoseconds - before.cpuNanoseconds)"
  )
}
