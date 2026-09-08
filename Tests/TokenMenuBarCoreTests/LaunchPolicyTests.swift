import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test func launchPolicyEqualityIgnoresOnlyTheDefaultsFactory() {
  let first = LaunchPolicy(arguments: [], environment: [:], suite: { _ in testDefaults() })
  let second = LaunchPolicy(arguments: [], environment: [:], suite: { _ in testDefaults() })
  #expect(first == second)
  #expect(first != LaunchPolicy(arguments: ["--relaunched"], environment: [:]))
  #expect(first != LaunchPolicy(arguments: ["--verify-ui"], environment: [:]))
}

@Test func standardLaunchKeepsTheProcessEnvironmentAndDefaults() {
  let standard = testDefaults()
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
  #expect(policy.environment[LaunchPolicy.verificationSessionKey] == "test/session 1")
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
  let suites = SuiteRecorder()
  let policy = LaunchPolicy(arguments: ["TokenMenuBar", "--verify-ui"], environment: [:], suite: suites.defaults)
  let suite = try #require(policy.defaultsSuiteName)
  #expect(suite == "\(LaunchPolicy.verificationSuitePrefix).manual")
  suites.defaults(suite).set(false, forKey: "demoMode")

  let defaults = policy.defaults()

  #expect(defaults === suites.defaults(suite))
  #expect(defaults.object(forKey: "demoMode") == nil)
}

@Test(arguments: [false, true])
func relaunchPreservesItsIsolationMode(verification: Bool) {
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", verification ? "--verify-ui" : "--demo"],
    environment: ["TOKEN_MENU_BAR_DEMO": "1", "EXISTING": "value"],
    verificationIdentifier: "relaunch")
  let replacement = LaunchPolicy(arguments: policy.relaunchArguments, environment: policy.relaunchEnvironment)

  #expect(replacement.mode == policy.mode)
  #expect(replacement.defaultsSuiteName == policy.defaultsSuiteName)
  #expect(replacement.supportDirectory == policy.supportDirectory)
  #expect(replacement.verificationProfile == policy.verificationProfile)
  #expect(policy.relaunchEnvironment["TOKEN_MENU_BAR_DEMO"] == nil)
  #expect(replacement.environment["EXISTING"] == "value")
  #expect(!replacement.yieldsToRunningInstance)
  #expect(replacement != policy)
}

@Test func verificationRelaunchPreservesTheDemoOffChoice() {
  let suites = SuiteRecorder()
  let policy = LaunchPolicy(arguments: ["--verify-ui"], environment: [:], suite: suites.defaults)
  policy.defaults().set(false, forKey: "demoMode")

  let replacement = LaunchPolicy(
    arguments: policy.relaunchArguments, environment: policy.relaunchEnvironment, suite: suites.defaults)

  #expect(replacement.defaults().object(forKey: "demoMode") as? Bool == false)
}

@Test func verificationCleanupRemovesDefaultsAndSupportFiles() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let suites = SuiteRecorder()
  let policy = LaunchPolicy(
    arguments: ["TokenMenuBar", "--verify-ui"], environment: [:], temporaryDirectory: root,
    verificationIdentifier: "cleanup", suite: suites.defaults)
  let suite = try #require(policy.defaultsSuiteName)
  let supportDirectory = try #require(policy.supportDirectory)
  suites.defaults(suite).set("stale", forKey: "value")
  try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
  try Data("stale".utf8).write(to: supportDirectory.appendingPathComponent("state"))

  try policy.cleanup()

  #expect(suites.defaults(suite).object(forKey: "value") == nil)
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

private final class SuiteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stores: [String: UserDefaults] = [:]

  @Sendable func defaults(_ name: String) -> UserDefaults {
    lock.withLock {
      if let store = stores[name] { return store }
      let store = testDefaults()
      stores[name] = store
      return store
    }
  }
}
