import Foundation
import Testing
import TokenMenuBarCore

@Test func standardLaunchKeepsTheProcessEnvironmentAndDefaults() {
  let suite = "launch-policy-standard-\(UUID().uuidString)"
  let standard = UserDefaults(suiteName: suite)!
  defer { standard.removePersistentDomain(forName: suite) }
  let policy = LaunchPolicy(arguments: ["TokenMenuBar"], environment: ["EXISTING": "value"])

  #expect(policy.mode == .standard)
  #expect(policy.environment == ["EXISTING": "value"])
  #expect(policy.defaultsSuiteName == nil)
  #expect(policy.supportDirectory == nil)
  #expect(policy.verificationProfile == nil)
  #expect(policy.defaults(standard: standard) === standard)
}

@Test func verificationArgumentForcesIsolatedDemoState() {
  let temporaryDirectory = URL(fileURLWithPath: "/tmp/launch-policy-tests", isDirectory: true)
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", "--verify-ui"],
    environment: [LaunchPolicy.verificationSessionKey: "test/session 1", "EXISTING": "value"],
    temporaryDirectory: temporaryDirectory,
    verificationIdentifier: "unused"
  )

  #expect(policy.mode == .verification)
  #expect(policy.environment["EXISTING"] == "value")
  #expect(policy.environment["TOKEN_MENU_BAR_DEMO"] == "1")
  #expect(policy.environment["TOKEN_MENU_BAR_OPEN_POPOVER"] == "1")
  #expect(policy.defaultsSuiteName == "\(LaunchPolicy.verificationSuitePrefix).test-session-1")
  #expect(
    policy.supportDirectory
      == temporaryDirectory.appendingPathComponent("token-menu-bar-verify-test-session-1", isDirectory: true))
  #expect(policy.verificationProfile == VerificationProfile())
}

@Test func verificationProfileParsesLongTextAndVisibleWidth() {
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", "--verify-ui"],
    environment: [
      VerificationProfile.fixtureEnvironmentKey: VerificationProfile.Fixture.longText.rawValue,
      VerificationProfile.visibleFrameWidthEnvironmentKey: "752",
    ])

  #expect(policy.verificationProfile == VerificationProfile(fixture: .longText, visibleFrameWidth: 752))
}

@Test func verificationProfileParsesControlAuditFixture() {
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", "--verify-ui"],
    environment: [
      VerificationProfile.fixtureEnvironmentKey: VerificationProfile.Fixture.controlAudit.rawValue,
      VerificationProfile.nativePanelsEnvironmentKey: "1",
    ])

  #expect(policy.verificationProfile?.fixture == .controlAudit)
  #expect(policy.verificationProfile?.nativePanels == true)
}

@Test func standardLaunchIgnoresVerificationProfileEnvironment() {
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar"],
    environment: [
      VerificationProfile.fixtureEnvironmentKey: VerificationProfile.Fixture.longText.rawValue,
      VerificationProfile.visibleFrameWidthEnvironmentKey: "752",
    ])

  #expect(policy.mode == .standard)
  #expect(policy.verificationProfile == nil)
}

@Test(arguments: ["nan", "infinity", "-1", "0", "narrow"])
func verificationProfileRejectsInvalidVisibleWidth(_ value: String) {
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", "--verify-ui"],
    environment: [VerificationProfile.visibleFrameWidthEnvironmentKey: value])

  #expect(policy.verificationProfile?.visibleFrameWidth == nil)
}

@Test func verificationEnvironmentUsesTheGeneratedIdentifierWithoutASession() {
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar"], environment: [LaunchPolicy.verificationEnvironmentKey: "1"],
    verificationIdentifier: "generated-42")

  #expect(policy.mode == .verification)
  #expect(policy.defaultsSuiteName == "\(LaunchPolicy.verificationSuitePrefix).generated-42")
}

@Test func verificationUsesTheSharedSupportDirectory() {
  let directory = URL(fileURLWithPath: "/tmp/token-menu-bar-shared-verification", isDirectory: true)
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", "--verify-ui"],
    environment: [LaunchPolicy.verificationSupportDirectoryKey: directory.path])

  #expect(policy.supportDirectory == directory)
}

@Test func verificationEnvironmentReplacesAnEmptySession() {
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar"],
    environment: [LaunchPolicy.verificationEnvironmentKey: "1", LaunchPolicy.verificationSessionKey: ""],
    verificationIdentifier: "unused"
  )

  #expect(policy.mode == .verification)
  #expect(policy.defaultsSuiteName == "\(LaunchPolicy.verificationSuitePrefix).session")
}

@Test func verificationDefaultsDiscardPersistedChoices() throws {
  let policy = LaunchPolicy(arguments: ["TokenMenuBar", "--verify-ui"], environment: [:])
  let suite = try #require(policy.defaultsSuiteName)
  #expect(suite == "\(LaunchPolicy.verificationSuitePrefix).manual")
  let stale = UserDefaults(suiteName: suite)!
  stale.set(false, forKey: "demoMode")

  let defaults = policy.defaults()

  #expect(defaults.object(forKey: "demoMode") == nil)
  defaults.removePersistentDomain(forName: suite)
}

@Test func verificationCleanupRemovesDefaultsAndSupportFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", "--verify-ui"], environment: [:], temporaryDirectory: root,
    verificationIdentifier: "cleanup")
  let suite = try #require(policy.defaultsSuiteName)
  let supportDirectory = try #require(policy.supportDirectory)
  UserDefaults(suiteName: suite)!.set("stale", forKey: "value")
  try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
  try Data("stale".utf8).write(to: supportDirectory.appendingPathComponent("state"))

  try policy.cleanup()

  #expect(UserDefaults(suiteName: suite)!.object(forKey: "value") == nil)
  #expect(!FileManager.default.fileExists(atPath: supportDirectory.path))
}

@Test func standardCleanupLeavesItsFilesAlone() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let state = root.appendingPathComponent("state")
  try Data("keep".utf8).write(to: state)

  try LaunchPolicy(arguments: ["TokenMenuBar"], environment: [:], temporaryDirectory: root).cleanup()

  #expect(FileManager.default.fileExists(atPath: state.path))
}
