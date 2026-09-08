import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func logSectionRoutesActionsAndOptionBindings() throws {
  let environment = try makeEnvironment(populate: false)
  environment.log.log("copy me")
  var copied = ""
  var fullLogRequests = 0
  var settingsChanges = 0
  environment.actions.copy = { copied = $0 }
  environment.actions.showFullLog = { fullLogRequests += 1 }
  environment.actions.settingsChanged = { settingsChanges += 1 }

  let section = LogSection(environment: environment)
  section.copyDisplayedEntries()
  section.clear()
  section.showFullLog()

  #expect(copied.contains("copy me"))
  #expect(environment.log.snapshot.isEmpty)
  #expect(fullLogRequests == 1)

  section.detailedLoggingBinding.wrappedValue = true

  #expect(environment.settings.detailedLogging)
  #expect(environment.log.debugEnabled)
  #expect(settingsChanges >= 1)
}

@Test @MainActor func logSectionSelectsAllLevelsOrOnlyTheRequestedLevel() {
  #expect(LogSection.selectedLevels(nil) == Set(LogLevel.allCases))
  #expect(LogSection.selectedLevels(.warning) == [.warning])
}

@Test @MainActor func fullLogMergeHandlesEmptyRetainedAndMismatchedOverlap() {
  let first = LogEntry(timestamp: fixedNow, level: .info, message: "first")
  let second = LogEntry(timestamp: fixedNow, level: .info, message: "second")
  let replacement = LogEntry(timestamp: fixedNow, level: .warning, message: "replacement")

  #expect(FullLogView.merge(retained: [], live: [first]) == [first])
  #expect(FullLogView.overlap([first, second], [first, replacement]) == 0)
}
