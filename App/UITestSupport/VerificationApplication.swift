import AppKit
import Foundation
import TokenMenuBarCore
import XCTest

@MainActor
struct VerificationApplication {
  typealias Appearance = VerificationProfile.Appearance

  let application: XCUIApplication
  private let launchPolicy: LaunchPolicy
  private let session: String

  init(
    testName: String, profile: VerificationProfile = VerificationProfile(),
    appearance: Appearance? = nil, doubleLocalizedStrings: Bool = false, detailedLogging: Bool = false
  ) {
    let session = "\(testName)-\(UUID().uuidString)"
    self.session = session
    let temporaryDirectory =
      ProcessInfo.processInfo.environment["TMB_VERIFICATION_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? FileManager.default.temporaryDirectory
    let supportDirectory = temporaryDirectory.appendingPathComponent(
      "token-menu-bar-verify-\(session)", isDirectory: true)
    application = XCUIApplication()
    application.launchArguments = [LaunchPolicy.verificationArgument]
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
    if let appearance = appearance ?? profile.appearance {
      application.launchEnvironment[VerificationProfile.appearanceEnvironmentKey] = appearance.rawValue
    }
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
    application.windows["Token Menu Bar"].radioGroups["popover-tabs"]
  }

  func tab(_ title: String) -> XCUIElement {
    tabs.radioButtons[title]
  }

  func selectTab(_ title: String) {
    tab(title).click()
  }

  func waitForPopover(timeout: TimeInterval) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    application.activate()
    let ready = tab("Usage").wait(
      for: \.isHittable, toEqual: true,
      timeout: max(deadline - ProcessInfo.processInfo.systemUptime, 0))
    if !ready { attachReadinessScreenshot() }
    return ready
  }

  private func attachReadinessScreenshot() {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "Failed popover readiness"
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Popover readiness diagnostics") { $0.add(attachment) }
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

  @discardableResult func launch() throws -> TimeInterval {
    let started = ProcessInfo.processInfo.systemUptime
    let frames = WindowFrameSampler(snapshotURL: supportDirectory.appendingPathComponent("process-snapshot.json"))
    frames.start()
    defer { _ = frames.stop() }
    application.launch()
    // Wait for presentation before asking XCTest to traverse the accessibility tree.
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while !frames.isStable(), ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    if !frames.isStable() {
      attachReadinessScreenshot()
      let attachment = XCTAttachment(
        data: try JSONEncoder().encode(frames.stop()), uniformTypeIdentifier: "public.json")
      attachment.name = "Failed launch frames"
      attachment.lifetime = .keepAlways
      XCTContext.runActivity(named: "Launch diagnostics") { $0.add(attachment) }
    }
    _ = try XCTUnwrap(frames.isStable() ? true : nil, "Verification did not present a stable on-screen window")
    return ProcessInfo.processInfo.systemUptime - started
  }

  func terminate() async {
    if application.state != .notRunning {
      do {
        try await requestSnapshot()
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
        if (try? await Task.sleep(for: .milliseconds(50))) == nil { break }
      }
      if !relaunched.isTerminated { relaunched.forceTerminate() }
    }
    do {
      let log = supportDirectory.appendingPathComponent("log.txt")
      if FileManager.default.fileExists(atPath: log.path) {
        let data = try Data(contentsOf: log)
        try preserveDiagnostic(data, name: "log.txt")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
        attachment.name = "Verification log"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Verification diagnostics") { $0.add(attachment) }
      }
      let snapshotURL = supportDirectory.appendingPathComponent("process-snapshot.json")
      if FileManager.default.fileExists(atPath: snapshotURL.path) {
        let data = try Data(contentsOf: snapshotURL)
        try preserveDiagnostic(data, name: "process-snapshot.json")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Verification process snapshot"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Process diagnostics") { $0.add(attachment) }
      }
      try launchPolicy.cleanup()
    } catch {
      XCTFail("Could not remove verification state: \(error)")
    }
  }

  private func preserveDiagnostic(_ data: Data, name: String) throws {
    guard let output = ProcessInfo.processInfo.environment["TMB_BENCHMARK_OUTPUT_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
      .appendingPathComponent("diagnostics", isDirectory: true).appendingPathComponent(session, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
  }

  func residentMemoryBytes() async throws -> Int {
    Int(try await performanceSnapshot().residentMemoryBytes)
  }

  func physicalFootprintBytes() async throws -> Int {
    Int(try await performanceSnapshot().physicalFootprintBytes)
  }

  func cpuTime() async throws -> TimeInterval {
    TimeInterval(try await performanceSnapshot().cpuNanoseconds) / 1_000_000_000
  }

  func processSnapshot() async throws -> String {
    let snapshot = try await performanceSnapshot()
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
    let deadline = Date().addingTimeInterval(30)
    repeat {
      do {
        let current = try processIdentifier()
        if current != previous,
          NSRunningApplication(processIdentifier: previous)?.isTerminated != false,
          let replacement = NSRunningApplication(processIdentifier: current)
        {
          let profile =
            ProcessInfo.processInfo.environment["TMB_PROFILE_RELAUNCH"] == "1" ? try await requestCPUProfile() : nil
          // XCTest can relaunch its original configuration after a process replacement, clearing verification defaults.
          replacement.activate(options: [])
          let frames = WindowFrameSampler(processIdentifier: current)
          frames.start()
          defer { _ = frames.stop() }
          while !frames.isStable(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
          }
          if !frames.isStable() {
            attachReadinessScreenshot()
            let attachment = XCTAttachment(
              data: try JSONEncoder().encode(frames.stop()), uniformTypeIdentifier: "public.json")
            attachment.name = "Failed relaunch frames"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Relaunch diagnostics") { $0.add(attachment) }
          }
          let stable = frames.isStable()
          if let profile { try await attachCPUProfile(profile, name: "Replacement startup CPU sample") }
          return stable
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

  func tabPresentationDurations() async throws -> [TimeInterval] {
    try await requestSnapshot()
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

  private func performanceSnapshot() async throws -> ProcessPerformanceSnapshot {
    // Xcode sandboxes its runner; the owned verification app measures itself without cross-process privileges.
    try await requestSnapshot()
    return try JSONDecoder().decode(
      ProcessPerformanceSnapshot.self,
      from: Data(contentsOf: supportDirectory.appendingPathComponent("process-snapshot.json")))
  }

  private func requestSnapshot() async throws {
    let url = supportDirectory.appendingPathComponent("process-snapshot.json")
    let started = ProcessInfo.processInfo.systemUptime
    let deadline = started + 2
    var lastCaptured: TimeInterval?
    try VerificationSnapshotRequests.send(to: url)
    repeat {
      if FileManager.default.fileExists(atPath: url.path) {
        let snapshot = try JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: Data(contentsOf: url))
        lastCaptured = snapshot.capturedUptime
        if snapshot.capturedUptime >= started {
          guard snapshot.capturedUptime <= deadline else { break }
          return
        }
      }
      guard ProcessInfo.processInfo.systemUptime < deadline else { break }
      try await Task.sleep(for: .milliseconds(50))
    } while true
    print(
      "Snapshot request timed out: requested=\(started) deadline=\(deadline) "
        + "captured=\(String(describing: lastCaptured)) observed=\(ProcessInfo.processInfo.systemUptime)")
    await captureSnapshotTimeout()
    throw ProcessMeasurementError.snapshotTimedOut(url.path)
  }

  private func captureSnapshotTimeout() async {
    do {
      guard let report = try await requestCPUProfile() else { return }
      try await attachCPUProfile(report, name: "Process snapshot timeout CPU sample")
    } catch {
      print("Could not sample the verification process after its snapshot timed out: \(error)")
    }
  }

  func requestCPUProfile() async throws -> URL? {
    guard let path = ProcessInfo.processInfo.environment["TMB_PROFILE_DIRECTORY"] else { return nil }
    let directory = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let request = directory.appendingPathComponent("request")
    let snapshot = supportDirectory.appendingPathComponent("process-snapshot.json")
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: snapshot.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try Data("\(try processIdentifier())\n".utf8).write(to: request, options: .atomic)
    return directory.appendingPathComponent("sample.txt")
  }

  func attachCPUProfile(_ report: URL, name: String) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let attachment = XCTAttachment(data: try Data(contentsOf: report), uniformTypeIdentifier: "public.plain-text")
    attachment.name = name
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: name) { $0.add(attachment) }
  }

  private enum ProcessMeasurementError: Error {
    case snapshotMissing(String)
    case snapshotTimedOut(String)
    case processNotFound
  }
}
