import Foundation
import TokenMenuBarCore

final class PowerSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var state = PowerState(lowPowerMode: false, thermalPressure: false)

  var current: PowerState {
    get { lock.withLock { state } }
    set { lock.withLock { state = newValue } }
  }

  func read() -> PowerState {
    current
  }
}

let throttledPowerStates = [
  PowerState(lowPowerMode: true, thermalPressure: false), PowerState(lowPowerMode: false, thermalPressure: true),
]
