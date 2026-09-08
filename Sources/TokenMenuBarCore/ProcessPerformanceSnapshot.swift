import Darwin
import Foundation

public struct ProcessPerformanceSnapshot: Codable, Equatable, Sendable {
  public let processIdentifier: pid_t
  public let residentMemoryBytes: UInt64
  public let physicalFootprintBytes: UInt64
  public let cpuNanoseconds: UInt64
  public let capturedUptime: TimeInterval

  public init(
    processIdentifier: pid_t = getpid(), residentMemoryBytes: UInt64, physicalFootprintBytes: UInt64,
    cpuNanoseconds: UInt64, capturedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    self.processIdentifier = processIdentifier
    self.residentMemoryBytes = residentMemoryBytes
    self.physicalFootprintBytes = physicalFootprintBytes
    self.cpuNanoseconds = cpuNanoseconds
    self.capturedUptime = capturedUptime
  }

  public static func current() -> ProcessPerformanceSnapshot? {
    capture(processIdentifier: getpid())
  }

  public static func capture(processIdentifier: pid_t) -> ProcessPerformanceSnapshot? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return nil }
    // proc_pid_rusage reports Mach ticks, whose scale differs between Intel and Apple silicon.
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let cpuTime = (usage.ri_user_time + usage.ri_system_time).multipliedFullWidth(by: UInt64(timebase.numer))
    return ProcessPerformanceSnapshot(
      processIdentifier: processIdentifier,
      residentMemoryBytes: usage.ri_resident_size,
      physicalFootprintBytes: usage.ri_phys_footprint,
      cpuNanoseconds: UInt64(timebase.denom).dividingFullWidth(cpuTime).quotient)
  }
}
