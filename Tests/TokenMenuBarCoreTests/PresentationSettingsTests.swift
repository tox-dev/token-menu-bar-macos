import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test @MainActor func presentationSettingsDefaultToUsedEveryDayAndVisible() {
  let settings = Settings(defaults: testDefaults())
  #expect(settings.usageDisplay == .used)
  #expect(settings.paceWorkdays == 7)
  #expect(!settings.hidePersonalInformation)
  #expect(settings.notifications.notifyOnPace)
  #expect(settings.presentationOptions == .standard)
}

@Test(arguments: [(3, 4), (5, 5), (9, 7)])
@MainActor func paceWorkdaysClampToTheSupportedWeek(requested: Int, stored: Int) {
  let defaults = testDefaults()
  let settings = Settings(defaults: defaults)
  settings.paceWorkdays = requested
  #expect(settings.paceWorkdays == stored)
  #expect(Settings(defaults: defaults).paceWorkdays == stored)
}

@Test @MainActor func presentationSettingsSurviveAReloadAndReset() {
  let defaults = testDefaults()
  let settings = Settings(defaults: defaults)
  settings.usageDisplay = .remaining
  settings.hidePersonalInformation = true
  settings.paceWorkdays = 5
  settings.notifications.notifyOnPace = false
  let reloaded = Settings(defaults: defaults)
  #expect(reloaded.usageDisplay == .remaining)
  #expect(reloaded.hidePersonalInformation)
  #expect(reloaded.paceWorkdays == 5)
  #expect(!reloaded.notifications.notifyOnPace)
  #expect(
    reloaded.presentationOptions
      == UsageDisplayOptions(display: .remaining, paceWorkdays: 5, hidePersonalInformation: true))
  reloaded.resetToDefaults()
  #expect(reloaded.presentationOptions == .standard)
  #expect(reloaded.notifications.notifyOnPace)
  #expect(Settings(defaults: defaults).presentationOptions == .standard)
}

@Test @MainActor func presentationSettingsIgnoreAnUnknownStoredDisplay() {
  let defaults = testDefaults()
  defaults.set("Sideways", forKey: "usageDisplay")
  #expect(Settings(defaults: defaults).usageDisplay == .used)
}
