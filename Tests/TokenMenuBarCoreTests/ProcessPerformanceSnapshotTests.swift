import Darwin
import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test func currentProcessPerformanceSnapshotContainsLiveCounters() throws {
  let started = ProcessInfo.processInfo.systemUptime
  let snapshot = try #require(ProcessPerformanceSnapshot.current())

  #expect(snapshot.processIdentifier > 0)
  #expect(snapshot.residentMemoryBytes > 0)
  #expect(snapshot.physicalFootprintBytes > 0)
  #expect(snapshot.cpuNanoseconds > 0)
  #expect(snapshot.capturedUptime >= started && snapshot.capturedUptime <= ProcessInfo.processInfo.systemUptime)
}

@Test func targetedPerformanceSnapshotMatchesTheRequestedPID() throws {
  let snapshot = try #require(ProcessPerformanceSnapshot.capture(processIdentifier: getpid()))
  #expect(snapshot.processIdentifier == getpid() && snapshot.cpuNanoseconds > 0)
}

@Test func nonexistentProcessHasNoPerformanceSnapshot() {
  #expect(ProcessPerformanceSnapshot.capture(processIdentifier: -1) == nil)
}
