import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func concurrentUsageLoadsPublishSamplesBeforeReturning() async throws {
  let environment = try makeEnvironment()
  let snapshot = sampleSnapshot(.claude)
  try await environment.history.record(snapshot, now: fixedNow)
  let expected = Dictionary(
    uniqueKeysWithValues: environment.state.snapshots.values.flatMap { provider in
      provider.windows.map { window in
        (
          WindowKey(provider.provider, window),
          provider.provider == .claude
            ? [
              UsageSample(
                timestamp: fixedNow, key: WindowKey(.claude, window), usedPercent: window.usedPercent,
                resetsAt: window.resetsAt)
            ] : []
        )
      }
    })
  let loads = (0..<2).map { _ in
    Task { @MainActor in
      await environment.loadRecentSamples(force: true)
      return environment.samples
    }
  }

  for load in loads {
    let loaded = await load.value
    #expect(loaded == expected)
  }
}
