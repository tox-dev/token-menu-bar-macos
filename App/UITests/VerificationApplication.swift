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
      DistributedNotificationCenter.default().postNotificationName(
        LaunchPolicy.verificationOpenPopoverNotification,
        object: session,
        userInfo: nil, deliverImmediately: true)
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
  }

  @discardableResult func launch() -> TimeInterval {
    let started = Date()
    application.launch()
    return Date().timeIntervalSince(started)
  }

  func terminate() {
    if application.state != .notRunning {
      do {
        try requestSnapshot()
      } catch {
        print("Could not flush verification diagnostics before termination: \(error)")
      }
    }
    let relaunched = (try? processIdentifier()).flatMap(NSRunningApplication.init(processIdentifier:))
    application.terminate()
    _ = application.wait(for: .notRunning, timeout: 2)
    if let relaunched, !relaunched.isTerminated {
      relaunched.terminate()
      let deadline = Date().addingTimeInterval(2)
      while !relaunched.isTerminated, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      }
      if !relaunched.isTerminated { relaunched.forceTerminate() }
    }
    do {
      let log = supportDirectory.appendingPathComponent("log.txt")
      if FileManager.default.fileExists(atPath: log.path) {
        let attachment = XCTAttachment(data: try Data(contentsOf: log), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "Verification log"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Verification diagnostics") { $0.add(attachment) }
      }
      let snapshotURL = supportDirectory.appendingPathComponent("process-snapshot.json")
      if FileManager.default.fileExists(atPath: snapshotURL.path) {
        let attachment = XCTAttachment(data: try Data(contentsOf: snapshotURL), uniformTypeIdentifier: "public.json")
        attachment.name = "Verification process snapshot"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Process diagnostics") { $0.add(attachment) }
      }
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
    let snapshot = try performanceSnapshot()
    return
      "pid=\(snapshot.processIdentifier) rss=\(snapshot.residentMemoryBytes) footprint=\(snapshot.physicalFootprintBytes) "
      + "cpu_ns=\(snapshot.cpuNanoseconds)"
  }

  func processIdentifier() throws -> pid_t {
    let url = supportDirectory.appendingPathComponent("process-snapshot.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ProcessMeasurementError.snapshotMissing(url.path)
    }
    let processIdentifier = try JSONDecoder().decode(
      ProcessPerformanceSnapshot.self, from: Data(contentsOf: url)
    ).processIdentifier
    guard processIdentifier > 0 else { throw ProcessMeasurementError.processNotFound }
    return processIdentifier
  }

  func waitForRelaunch(from previous: pid_t) async throws -> Bool {
    let deadline = Date().addingTimeInterval(10)
    repeat {
      do {
        let current = try processIdentifier()
        if current != previous,
          NSRunningApplication(processIdentifier: previous)?.isTerminated != false,
          let replacement = NSRunningApplication(processIdentifier: current)
        {
          // XCTest can relaunch its original configuration after a process replacement, clearing verification defaults.
          replacement.activate(options: [])
          return true
        }
      } catch ProcessMeasurementError.snapshotMissing {
        if Date() >= deadline { throw ProcessMeasurementError.snapshotTimedOut(supportDirectory.path) }
      }
      try await Task.sleep(for: .milliseconds(50))
    } while Date() < deadline
    print(
      "Relaunch timed out: previous=\(previous), current=\(try processIdentifier()), previousTerminated=\(String(describing: NSRunningApplication(processIdentifier: previous)?.isTerminated))"
    )
    return false
  }

  func tabPresentationDurations() throws -> [TimeInterval] {
    try requestSnapshot()
    let text = try String(contentsOf: supportDirectory.appendingPathComponent("log.txt"), encoding: .utf8)
    print(text.split(separator: "\n").filter { $0.contains("tab.") }.joined(separator: "\n"))
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
    // Xcode sandboxes its runner; the owned verification app measures itself without cross-process privileges.
    try requestSnapshot()
    return try JSONDecoder().decode(
      ProcessPerformanceSnapshot.self,
      from: Data(contentsOf: supportDirectory.appendingPathComponent("process-snapshot.json")))
  }

  private func requestSnapshot() throws {
    let url = supportDirectory.appendingPathComponent("process-snapshot.json")
    let started = ProcessInfo.processInfo.systemUptime
    let deadline = Date().addingTimeInterval(2)
    repeat {
      DistributedNotificationCenter.default().postNotificationName(
        LaunchPolicy.verificationSnapshotNotification,
        object: session, userInfo: nil, deliverImmediately: true)
      if FileManager.default.fileExists(atPath: url.path) {
        let snapshot = try JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: Data(contentsOf: url))
        if snapshot.capturedUptime >= started { return }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    throw ProcessMeasurementError.snapshotTimedOut(url.path)
  }

  private enum ProcessMeasurementError: Error {
    case snapshotMissing(String)
    case snapshotTimedOut(String)
    case processNotFound
  }
}
