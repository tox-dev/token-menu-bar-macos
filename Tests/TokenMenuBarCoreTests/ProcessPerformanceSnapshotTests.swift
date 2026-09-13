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

@Test func processCPUTimeUsesNanoseconds() throws {
  let before = try processCPUNanoseconds()
  let snapshot = try #require(ProcessPerformanceSnapshot.current())
  let after = try processCPUNanoseconds()

  #expect((before...after).contains(snapshot.cpuNanoseconds))
}

private func processCPUNanoseconds() throws -> UInt64 {
  // macOS 14 getrusage sums rounded per-thread times; Mach totals retain full precision.
  var times = task_absolutetime_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: times) / MemoryLayout<integer_t>.size)
  let result = withUnsafeMutablePointer(to: &times) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(task_self_trap(), task_flavor_t(TASK_ABSOLUTETIME_INFO), $0, &count)
    }
  }
  try #require(result == KERN_SUCCESS)
  var timebase = mach_timebase_info_data_t()
  try #require(mach_timebase_info(&timebase) == KERN_SUCCESS)
  return UInt64(Double(times.total_user + times.total_system) * Double(timebase.numer) / Double(timebase.denom))
}
