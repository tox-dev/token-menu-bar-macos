import Foundation
import Observation

@MainActor
@Observable
public final class SpendSummaryModel {
  public private(set) var summary: SpendSummary?
  public private(set) var error: String?
  public private(set) var isLoading = false
  private var generation = 0
  private var providers: Set<ProviderID>?

  public init() {}

  public func load(history: UsageHistoryStore, providers: Set<ProviderID>, now: Date, timeZone: TimeZone) async {
    if self.providers != providers {
      self.providers = providers
      summary = nil
      error = nil
    }
    generation += 1
    let request = generation
    isLoading = true
    defer { if request == generation { isLoading = false } }
    do {
      let loaded = try await SpendSummaryPresenter.load(
        history: history, providers: providers.sorted(), now: now, timeZone: timeZone)
      guard request == generation, !Task.isCancelled else { return }
      summary = loaded
      error = nil
    } catch {
      guard request == generation, !Task.isCancelled else { return }
      self.error =
        summary == nil
        ? "Cost history could not be loaded." : "Cost history could not be updated. Showing last-known totals."
    }
  }
}
