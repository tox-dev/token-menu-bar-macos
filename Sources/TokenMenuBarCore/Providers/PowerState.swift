import Foundation

/// The conditions under which the local log readers skip their periodic tree walks and keep serving what they have.
public struct PowerState: Sendable, Equatable {
  public let lowPowerMode: Bool
  public let thermalPressure: Bool

  public init(lowPowerMode: Bool, thermalPressure: Bool) {
    self.lowPowerMode = lowPowerMode
    self.thermalPressure = thermalPressure
  }

  public var throttlesScanning: Bool {
    lowPowerMode || thermalPressure
  }

  public static func current() -> PowerState {
    let processInfo = ProcessInfo.processInfo
    return PowerState(
      lowPowerMode: processInfo.isLowPowerModeEnabled,
      thermalPressure: [.serious, .critical].contains(processInfo.thermalState))
  }
}
