import Foundation

public struct VerificationProfile: Equatable, Sendable {
  public enum Fixture: String, Equatable, Sendable {
    case standard
    case longText = "long-text"
    case controlAudit = "control-audit"
  }

  public static let fixtureEnvironmentKey = "TOKEN_MENU_BAR_VERIFY_FIXTURE"
  public static let visibleFrameWidthEnvironmentKey = "TOKEN_MENU_BAR_VERIFY_VISIBLE_WIDTH"
  public static let nativePanelsEnvironmentKey = "TOKEN_MENU_BAR_VERIFY_NATIVE_PANELS"

  public let fixture: Fixture
  public let visibleFrameWidth: Double?
  public let nativePanels: Bool

  public init(fixture: Fixture = .standard, visibleFrameWidth: Double? = nil, nativePanels: Bool = false) {
    self.fixture = fixture
    self.visibleFrameWidth = visibleFrameWidth
    self.nativePanels = nativePanels
  }

  init(environment: [String: String]) {
    fixture = environment[Self.fixtureEnvironmentKey].flatMap(Fixture.init(rawValue:)) ?? .standard
    visibleFrameWidth = environment[Self.visibleFrameWidthEnvironmentKey].flatMap(Double.init).flatMap {
      $0.isFinite && $0 > 0 ? $0 : nil
    }
    nativePanels = environment[Self.nativePanelsEnvironmentKey] == "1"
  }
}

public struct LaunchPolicy: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case standard
    case verification
  }

  public static let verificationArgument = "--verify-ui"
  public static let relaunchedArgument = "--relaunched"
  public static let verificationEnvironmentKey = "TOKEN_MENU_BAR_VERIFY_UI"
  public static let verificationSessionKey = "TOKEN_MENU_BAR_VERIFY_SESSION"
  public static let verificationSupportDirectoryKey = "TOKEN_MENU_BAR_VERIFY_SUPPORT_DIRECTORY"
  public static let verificationSuitePrefix = "dev.tox.token-menu-bar.verify"
  public static let verificationOpenPopoverNotification = Notification.Name(
    "dev.tox.token-menu-bar.verification.open-popover")
  public static let verificationSnapshotNotification = Notification.Name(
    "dev.tox.token-menu-bar.verification.snapshot")

  public let mode: Mode
  public let environment: [String: String]
  public let defaultsSuiteName: String?
  public let supportDirectory: URL?
  public let verificationProfile: VerificationProfile?
  /// Verification runs sit beside an installed copy on purpose, and a relaunch starts its replacement while this
  /// instance is still winding down, so neither hands off to the instance already running.
  public let yieldsToRunningInstance: Bool
  private let isRelaunch: Bool
  private let makeSuite: @Sendable (String) -> UserDefaults

  public static func == (lhs: LaunchPolicy, rhs: LaunchPolicy) -> Bool {
    lhs.mode == rhs.mode && lhs.environment == rhs.environment && lhs.defaultsSuiteName == rhs.defaultsSuiteName
      && lhs.supportDirectory == rhs.supportDirectory && lhs.verificationProfile == rhs.verificationProfile
      && lhs.yieldsToRunningInstance == rhs.yieldsToRunningInstance
      && lhs.isRelaunch == rhs.isRelaunch
  }

  public init(
    arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    verificationIdentifier: String? = nil,
    suite makeSuite: @escaping @Sendable (String) -> UserDefaults = persistentDefaults(suiteName:)
  ) {
    self.makeSuite = makeSuite
    isRelaunch = arguments.contains(Self.relaunchedArgument)
    guard arguments.contains(Self.verificationArgument) || environment[Self.verificationEnvironmentKey] != nil else {
      mode = .standard
      self.environment = environment
      defaultsSuiteName = nil
      supportDirectory = nil
      verificationProfile = nil
      yieldsToRunningInstance = !isRelaunch
      return
    }

    mode = .verification
    let session = Self.safeSession(environment[Self.verificationSessionKey] ?? verificationIdentifier ?? "manual")
    defaultsSuiteName = "\(Self.verificationSuitePrefix).\(session)"
    supportDirectory =
      environment[Self.verificationSupportDirectoryKey].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? temporaryDirectory.appendingPathComponent("token-menu-bar-verify-\(session)", isDirectory: true)
    var resolvedEnvironment = environment
    resolvedEnvironment["TOKEN_MENU_BAR_DEMO"] = "1"
    resolvedEnvironment["TOKEN_MENU_BAR_OPEN_POPOVER"] = "1"
    resolvedEnvironment[Self.verificationEnvironmentKey] = "1"
    resolvedEnvironment[Self.verificationSessionKey] =
      environment[Self.verificationSessionKey] ?? verificationIdentifier ?? "manual"
    resolvedEnvironment[Self.verificationSupportDirectoryKey] = supportDirectory!.path
    self.environment = resolvedEnvironment
    verificationProfile = VerificationProfile(environment: environment)
    yieldsToRunningInstance = false
  }

  public func defaults(standard: UserDefaults = .standard) -> UserDefaults {
    guard let defaultsSuiteName else { return standard }
    let defaults = makeSuite(defaultsSuiteName)
    if !isRelaunch { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    return defaults
  }

  public var relaunchArguments: [String] {
    [Self.relaunchedArgument] + (mode == .verification ? [Self.verificationArgument] : [])
  }

  public var relaunchEnvironment: [String: String] {
    environment.filter { $0.key != "TOKEN_MENU_BAR_DEMO" }
  }

  public func cleanup(fileManager: FileManager = .default) throws {
    guard mode == .verification else { return }
    if let defaultsSuiteName {
      makeSuite(defaultsSuiteName).removePersistentDomain(forName: defaultsSuiteName)
    }
    if let supportDirectory, fileManager.fileExists(atPath: supportDirectory.path) {
      try fileManager.removeItem(at: supportDirectory)
    }
  }

  private static func safeSession(_ value: String) -> String {
    let safe = String(value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    return safe.isEmpty ? "session" : safe
  }
}
