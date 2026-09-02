import Darwin
import Foundation

public struct ProcessPerformanceSnapshot: Codable, Equatable, Sendable {
  public let processIdentifier: pid_t
  public let residentMemoryBytes: UInt64
  public let physicalFootprintBytes: UInt64
  public let cpuNanoseconds: UInt64

  public init(
    processIdentifier: pid_t = getpid(), residentMemoryBytes: UInt64, physicalFootprintBytes: UInt64,
    cpuNanoseconds: UInt64
  ) {
    self.processIdentifier = processIdentifier
    self.residentMemoryBytes = residentMemoryBytes
    self.physicalFootprintBytes = physicalFootprintBytes
    self.cpuNanoseconds = cpuNanoseconds
  }

  public static func current() -> ProcessPerformanceSnapshot? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    guard result == 0 else { return nil }
    return ProcessPerformanceSnapshot(
      processIdentifier: getpid(),
      residentMemoryBytes: usage.ri_resident_size,
      physicalFootprintBytes: usage.ri_phys_footprint,
      cpuNanoseconds: usage.ri_user_time + usage.ri_system_time)
  }
}
