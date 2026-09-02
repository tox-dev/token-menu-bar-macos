import Testing
import TokenMenuBarCore

@Test func currentProcessPerformanceSnapshotContainsLiveCounters() throws {
  let snapshot = try #require(ProcessPerformanceSnapshot.current())

  #expect(snapshot.processIdentifier > 0)
  #expect(snapshot.residentMemoryBytes > 0)
  #expect(snapshot.physicalFootprintBytes > 0)
  #expect(snapshot.cpuNanoseconds > 0)
}
