import Foundation
import Observation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport
import os

@Test(arguments: ProviderID.allCases) @MainActor
func appStatePublishesSnapshotChanges(provider: ProviderID) {
  let state = AppState()
  let snapshot = DemoData.snapshot(provider, now: fixedNow)
  let invalidated = OSAllocatedUnfairLock(initialState: false)
  withObservationTracking {
    _ = state.snapshots
  } onChange: {
    invalidated.withLock { $0 = true }
  }

  state.update(provider) { $0.snapshot = snapshot }

  #expect(state.snapshots == [provider: snapshot])
  #expect(invalidated.withLock { $0 })
}

@Test(arguments: ProviderID.allCases) @MainActor
func appStateRemovesSnapshotsWithProviders(provider: ProviderID) {
  let state = AppState()
  state.update(provider) { $0.snapshot = DemoData.snapshot(provider, now: fixedNow) }

  state.remove(provider)

  #expect(state.snapshots.isEmpty)
}

@Test(arguments: ProviderID.allCases) @MainActor
func appStateKeepsSnapshotObserversIdleDuringRefresh(provider: ProviderID) {
  let state = AppState()
  let snapshot = DemoData.snapshot(provider, now: fixedNow)
  state.update(provider) { $0.snapshot = snapshot }
  let invalidated = OSAllocatedUnfairLock(initialState: false)
  withObservationTracking {
    _ = state.snapshots
  } onChange: {
    invalidated.withLock { $0 = true }
  }

  state.update(provider) {
    $0.isRefreshing = true
    $0.lastAttempt = fixedNow
    $0.availability = .stale
    $0.snapshot = snapshot
  }

  #expect(!invalidated.withLock { $0 })
}
