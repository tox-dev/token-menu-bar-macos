import Foundation
import Testing
import TokenMenuBarCore

@Test(arguments: [
  (PowerState(lowPowerMode: false, thermalPressure: false), false),
  (PowerState(lowPowerMode: true, thermalPressure: false), true),
  (PowerState(lowPowerMode: false, thermalPressure: true), true),
])
func powerStateThrottlesScanningWhenEitherConditionHolds(state: PowerState, throttles: Bool) {
  #expect(state.throttlesScanning == throttles)
}

@Test func powerStateCurrentReadsTheRunningMachine() {
  let current = PowerState.current()

  #expect(current.throttlesScanning == (current.lowPowerMode || current.thermalPressure))
}
