import AppKit
import Foundation
import TokenMenuBarCore
import XCTest

@MainActor
struct VerificationApplication {
  enum Appearance: String {
    case light = "Light"
    case dark = "Dark"
  }

  let application: XCUIApplication
  private let launchPolicy: LaunchPolicy
  private let session: String

  init(
    testName: String, profile: VerificationProfile = VerificationProfile(),
    appearance: Appearance? = nil, doubleLocalizedStrings: Bool = false, detailedLogging: Bool = false
  ) {
    let session = "\(testName)-\(UUID().uuidString)"
    self.session = session
    let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "token-menu-bar-verify-\(session)", isDirectory: true)
    application = XCUIApplication()
    application.launchArguments = [LaunchPolicy.verificationArgument]
    if let appearance {
      application.launchArguments += ["-AppleInterfaceStyle", appearance.rawValue]
    }
    if doubleLocalizedStrings {
      application.launchArguments += ["-NSDoubleLocalizedStrings", "YES"]
    }
    if detailedLogging {
      application.launchArguments += ["-detailedLogging", "YES"]
    }
    application.launchEnvironment = [
      LaunchPolicy.verificationSessionKey: session,
      LaunchPolicy.verificationSupportDirectoryKey: supportDirectory.path,
      VerificationProfile.fixtureEnvironmentKey: profile.fixture.rawValue,
    ]
    if let visibleFrameWidth = profile.visibleFrameWidth {
      application.launchEnvironment[VerificationProfile.visibleFrameWidthEnvironmentKey] = String(visibleFrameWidth)
    }
    if profile.nativePanels {
      application.launchEnvironment[VerificationProfile.nativePanelsEnvironmentKey] = "1"
    }
    launchPolicy = LaunchPolicy(
      arguments: ["TokenMenuBar", LaunchPolicy.verificationArgument],
      environment: [
        LaunchPolicy.verificationSessionKey: session,
        LaunchPolicy.verificationSupportDirectoryKey: supportDirectory.path,
      ])
  }

  var statusItem: XCUIElement { application.statusItems.firstMatch }
  var tabs: XCUIElement {
    application.descendants(matching: .radioGroup)
      .matching(NSPredicate(format: "label == %@", "Popover tabs")).firstMatch
  }

  func tab(_ title: String) -> XCUIElement {
    tabs.radioButtons[title]
  }

  func selectTab(_ title: String) {
    tab(title).click()
  }

  var supportDirectory: URL { launchPolicy.supportDirectory! }

  func openPopover() {
    if NSScreen.screens.contains(where: { $0.frame.intersects(statusItem.frame) }) {
      statusItem.click()
      return
    }
    for _ in 0..<5 {
      DistributedNotificationCenter.default().post(
        name: LaunchPolicy.verificationOpenPopoverNotification,
        object: session,
        userInfo: nil)
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  @discardableResult func launch() -> TimeInterval {
    let started = Date()
    application.launch()
    return Date().timeIntervalSince(started)
  }

  func terminate() {
    application.terminate()
    _ = application.wait(for: .notRunning, timeout: 2)
    do {
      try launchPolicy.cleanup()
    } catch {
      XCTFail("Could not remove verification state: \(error)")
    }
  }

  func residentMemoryBytes() throws -> Int {
    Int(try performanceSnapshot().residentMemoryBytes)
  }

  func physicalFootprintBytes() throws -> Int {
    Int(try performanceSnapshot().physicalFootprintBytes)
  }

  func cpuTime() throws -> TimeInterval {
    TimeInterval(try performanceSnapshot().cpuNanoseconds) / 1_000_000_000
  }

  func processSnapshot() throws -> String {
    let identifier = try processIdentifier()
    let snapshot = try performanceSnapshot()
    return "pid=\(identifier) rss=\(snapshot.residentMemoryBytes) footprint=\(snapshot.physicalFootprintBytes) "
      + "cpu_ns=\(snapshot.cpuNanoseconds)"
  }

  func processIdentifier() throws -> pid_t {
    let processIdentifier = try performanceSnapshot().processIdentifier
    guard processIdentifier > 0 else { throw ProcessMeasurementError.processNotFound }
    return processIdentifier
  }

  func tabPresentationDurations() throws -> [TimeInterval] {
    _ = try performanceSnapshot()
    let text = try String(contentsOf: supportDirectory.appendingPathComponent("log.txt"), encoding: .utf8)
    let expression = try NSRegularExpression(pattern: #"tab\.presented[^\n]*durationMs=([0-9.]+)"#)
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let range = Range(match.range(at: 1), in: text), let milliseconds = Double(text[range]) else {
        return nil
      }
      return milliseconds / 1_000
    }
  }

  private func performanceSnapshot() throws -> ProcessPerformanceSnapshot {
    let url = supportDirectory.appendingPathComponent("process-snapshot.json")
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    DistributedNotificationCenter.default().post(
      name: LaunchPolicy.verificationSnapshotNotification,
      object: session,
      userInfo: nil)
    let deadline = Date().addingTimeInterval(2)
    repeat {
      if FileManager.default.fileExists(atPath: url.path) {
        return try JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: Data(contentsOf: url))
      }
      Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    throw ProcessMeasurementError.measurementFailed
  }

  private enum ProcessMeasurementError: Error {
    case measurementFailed
    case processNotFound
  }
}
