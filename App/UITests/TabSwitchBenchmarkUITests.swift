import CoreGraphics
import Foundation
import TokenMenuBarCore
import XCTest

final class TabSwitchBenchmarkUITests: XCTestCase {
  private let latencyP95Target = 0.02
  private let latencyMaximumBudget = 0.2
  private let settleTimeout = 2.0
  private let iterations = 5
  private let instrumentedPhysicalFootprintBudget = 256 * 1024 * 1024
  private let instrumentedPhysicalFootprintGrowthBudget = 20 * 1024 * 1024

  @MainActor
  func testProfileMockedTabSwitches() throws {
    guard let path = ProcessInfo.processInfo.environment["TMB_PROFILE_DIRECTORY"] else {
      throw XCTSkip("Run through Scripts/profile-ui-tests.sh to collect a CPU sample")
    }
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in verification.terminate() }
    verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 3))
    for tab in ["History", "Settings", "Usage"] {
      verification.tab(tab).click()
      XCTAssertTrue(readyContent(tab, application: verification.application).waitForExistence(timeout: settleTimeout))
    }
    let directory = URL(fileURLWithPath: path)
    let report = directory.appendingPathComponent("sample.txt")
    try Data("\(try verification.processIdentifier())\n".utf8).write(
      to: directory.appendingPathComponent("request"), options: .atomic)
    for _ in 0..<3 {
      for tab in ["History", "Settings", "Usage"] {
        verification.tab(tab).click()
        XCTAssertTrue(readyContent(tab, application: verification.application).waitForExistence(timeout: settleTimeout))
      }
    }
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    let samplerLog = directory.appendingPathComponent("sampler.log")
    if FileManager.default.fileExists(atPath: samplerLog.path) {
      let attachment = XCTAttachment(data: try Data(contentsOf: samplerLog), uniformTypeIdentifier: "public.plain-text")
      attachment.name = "CPU sampler diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    let attachment = XCTAttachment(data: try Data(contentsOf: report), uniformTypeIdentifier: "public.plain-text")
    attachment.name = "Mocked tab-switch CPU sample"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testFirstSettingsClickFromFreshLaunch() throws {
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in verification.terminate() }
    let frameSampler = WindowFrameSampler(
      snapshotURL: verification.supportDirectory.appendingPathComponent("process-snapshot.json"))
    addTeardownBlock { _ = frameSampler.stop() }
    frameSampler.start()
    verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 3))
    let openingFrames = frameSampler.stop()
    let frames = XCTAttachment(data: try JSONEncoder().encode(openingFrames), uniformTypeIdentifier: "public.json")
    frames.name = "Cold opening frames"
    frames.lifetime = .keepAlways
    add(frames)
    assertOpeningFrames(openingFrames)
    let started = ProcessInfo.processInfo.systemUptime
    verification.tab("Settings").click()
    XCTAssertTrue(
      readyContent("Settings", application: verification.application).waitForExistence(timeout: settleTimeout))
    let ready = ProcessInfo.processInfo.systemUptime - started
    let screenshot = verification.application.screenshot()
    let captured = ProcessInfo.processInfo.systemUptime - started
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "First Settings click"
    attachment.lifetime = .keepAlways
    add(attachment)
    let draw = try XCTUnwrap(verification.tabPresentationDurations().first)
    XCTAssertLessThan(draw, latencyMaximumBudget)
    print(
      "FIRST_SETTINGS input_to_draw_s=\(draw) xctest_click_to_ready_s=\(ready) xctest_click_to_capture_s=\(captured)")
  }

  @MainActor
  func testTabSwitchLatencyAndFrameStability() throws {
    executionTimeAllowance = 120
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in verification.terminate() }
    let launchStarted = ProcessInfo.processInfo.systemUptime
    verification.launch()

    XCTAssertTrue(verification.statusItem.waitForExistence(timeout: 3))
    let launchToStatusItem = ProcessInfo.processInfo.systemUptime - launchStarted
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 3))
    let launchToPanel = ProcessInfo.processInfo.systemUptime - launchStarted
    verification.application.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(verification.tabs.waitForNonExistence(timeout: 2))
    let processIdentifier = try verification.processIdentifier()
    let frameSampler = WindowFrameSampler(processIdentifier: processIdentifier)
    frameSampler.start()
    verification.openPopover()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 2))

    let output = try outputDirectory()
    let surface = verification.application.descendants(matching: .any)["popover-surface"]
    let initialFrame = surface.frame
    let openFrame = try settledFrame(
      of: surface, after: verification.application.descendants(matching: .any)["tab-content-Usage"],
      processIdentifier: processIdentifier, timeout: settleTimeout)
    let openFrameTimeline = frameSampler.stop()
    retain(try JSONEncoder().encode(openFrameTimeline), named: "open-frame-timeline.json", writingTo: output)
    assertOpeningFrames(openFrameTimeline)
    XCTAssertLessThan(abs(initialFrame.minX - openFrame.minX), 2, "Popover moved horizontally after opening")
    XCTAssertLessThan(abs(initialFrame.minY - openFrame.minY), 2, "Popover top edge moved after opening")

    verification.tab("Settings").click()
    let coldSettingsFrame = try settledFrame(
      of: surface, after: readyContent("Settings", application: verification.application),
      processIdentifier: processIdentifier, timeout: settleTimeout)
    XCTAssertLessThan(abs(coldSettingsFrame.minX - openFrame.minX), 2, "Cold Settings moved horizontally")
    XCTAssertLessThan(abs(coldSettingsFrame.minY - openFrame.minY), 2, "Cold Settings moved the panel top edge")

    for tab in ["History", "Usage"] {
      verification.tab(tab).click()
      _ = try settledFrame(
        of: surface, after: readyContent(tab, application: verification.application),
        processIdentifier: processIdentifier, timeout: settleTimeout)
    }

    let settledProcessSnapshot = try verification.processSnapshot()
    let idleCPUStart = try verification.cpuTime()
    Thread.sleep(forTimeInterval: 10)
    let idleCPUTime = try verification.cpuTime() - idleCPUStart
    let idleProcessSnapshot = try verification.processSnapshot()
    let physicalFootprintBefore = try verification.physicalFootprintBytes()
    XCTAssertLessThan(
      physicalFootprintBefore,
      instrumentedPhysicalFootprintBudget,
      "Instrumented physical footprint exceeded 256 MB")
    XCTAssertLessThan(idleCPUTime, 0.1, "Idle CPU exceeded 1% of one core over ten seconds")
    let interactionCPUStart = try verification.cpuTime()
    let tabs = ["History", "Settings", "Usage"]
    var samples: [TabSwitchSample] = []
    for iteration in 1...iterations {
      for tab in tabs {
        verification.tab(tab).click()
        let firstFrame = surface.frame
        let frame = try settledFrame(
          of: surface, after: readyContent(tab, application: verification.application),
          processIdentifier: processIdentifier, timeout: settleTimeout)
        samples.append(
          TabSwitchSample(iteration: iteration, tab: tab, latency: 0, firstFrame: firstFrame, frame: frame))
        XCTAssertLessThan(abs(firstFrame.minX - frame.minX), 2, "\(tab) moved horizontally while settling")
        XCTAssertLessThan(abs(firstFrame.minY - frame.minY), 2, "\(tab) moved the panel's top edge while settling")
      }
    }

    let presentationDurations = try verification.tabPresentationDurations()
    XCTAssertGreaterThanOrEqual(presentationDurations.count, samples.count + 3)
    let coldSettingsPresentation = presentationDurations[presentationDurations.count - samples.count - 3]
    samples = zip(samples, presentationDurations.suffix(samples.count)).map { sample, latency in
      TabSwitchSample(
        iteration: sample.iteration,
        tab: sample.tab,
        latency: latency,
        firstFrame: sample.firstFrame.cgRect,
        frame: sample.frame.cgRect)
    }
    for sample in samples {
      XCTAssertLessThan(
        sample.latency, latencyMaximumBudget,
        "\(sample.tab) took \(Self.milliseconds(sample.latency)) ms to present; maximum is \(Self.milliseconds(latencyMaximumBudget)) ms"
      )
    }
    XCTAssertLessThan(
      coldSettingsPresentation, latencyMaximumBudget,
      "First Settings presentation took \(Self.milliseconds(coldSettingsPresentation)) ms")
    let p95 = Self.percentile(samples.map(\.latency), percentile: 0.95)
    let interactionCPUTime = try verification.cpuTime() - interactionCPUStart
    Thread.sleep(forTimeInterval: 2)
    let physicalFootprintAfter = try verification.physicalFootprintBytes()
    let interactionProcessSnapshot = try verification.processSnapshot()
    XCTAssertLessThan(
      physicalFootprintAfter,
      instrumentedPhysicalFootprintBudget,
      "Instrumented physical footprint exceeded 256 MB")
    XCTAssertLessThan(
      physicalFootprintAfter - physicalFootprintBefore,
      instrumentedPhysicalFootprintGrowthBudget,
      "(iterations) tab cycles grew instrumented physical footprint by more than 20 MB")

    for tab in tabs {
      verification.tab(tab).click()
      _ = try settledFrame(
        of: surface, after: readyContent(tab, application: verification.application),
        processIdentifier: processIdentifier, timeout: settleTimeout)
      retain(
        verification.application.screenshot().pngRepresentation,
        named: "\(tab.lowercased()).png", writingTo: output)
    }

    let widths = samples.map(\.width)
    let horizontalOrigins = samples.map(\.minX)
    let topEdges = samples.map(\.minY)
    XCTAssertLessThan((widths.max() ?? 0) - (widths.min() ?? 0), 2, "Popover width moved")
    XCTAssertLessThan((horizontalOrigins.max() ?? 0) - (horizontalOrigins.min() ?? 0), 2, "Popover moved horizontally")
    XCTAssertLessThan((topEdges.max() ?? 0) - (topEdges.min() ?? 0), 2, "Popover top edge moved")
    let report = TabSwitchReport(
      p95TargetMilliseconds: Self.milliseconds(latencyP95Target),
      maximumBudgetMilliseconds: Self.milliseconds(latencyMaximumBudget),
      coldSettingsPresentation: coldSettingsPresentation,
      launchToStatusItem: launchToStatusItem, launchToPanel: launchToPanel,
      displayBounds: CGDisplayBounds(CGMainDisplayID()),
      physicalFootprintBefore: physicalFootprintBefore, physicalFootprintAfter: physicalFootprintAfter,
      idleCPUTime: idleCPUTime, interactionCPUTime: interactionCPUTime,
      openFirstFrame: initialFrame, openSettledFrame: openFrame,
      openFrameTimeline: openFrameTimeline,
      processSnapshots: [settledProcessSnapshot, idleProcessSnapshot, interactionProcessSnapshot], samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    retain(try encoder.encode(report), named: "timings.json", writingTo: output)
    print("TAB_SWITCH_BENCHMARK=\(output.path)")
    print(
      "TAB_SWITCH_TARGET p95_target_ms=\(Self.milliseconds(latencyP95Target)) met=\(p95 < latencyP95Target) "
        + "maximum_limit_ms=\(Self.milliseconds(latencyMaximumBudget))")
    print(
      "TAB_SWITCH_SUMMARY median_ms=\(Self.milliseconds(Self.percentile(samples.map(\.latency), percentile: 0.5))) "
        + "p95_ms=\(Self.milliseconds(p95)) max_ms=\(Self.milliseconds(samples.map(\.latency).max() ?? 0)) "
        + "cold_settings_ms=\(Self.milliseconds(coldSettingsPresentation)) "
        + "launch_status_ms=\(Self.milliseconds(launchToStatusItem)) launch_panel_ms=\(Self.milliseconds(launchToPanel)) "
        + "footprint_before=\(physicalFootprintBefore) footprint_after=\(physicalFootprintAfter) "
        + "idle_cpu_s=\(idleCPUTime) "
        + "interaction_cpu_s=\(interactionCPUTime)")
    for tab in tabs {
      let latencies = samples.filter { $0.tab == tab }.map(\.latency)
      print(
        "TAB_SWITCH_SUMMARY tab=\(tab) median_ms=\(Self.milliseconds(Self.percentile(latencies, percentile: 0.5))) "
          + "p95_ms=\(Self.milliseconds(Self.percentile(latencies, percentile: 0.95))) "
          + "max_ms=\(Self.milliseconds(latencies.max() ?? 0))")
    }
    for sample in samples {
      print(
        "TAB_SWITCH tab=\(sample.tab) iteration=\(sample.iteration) latency_ms=\(Self.milliseconds(sample.latency)) "
          + "frame=\(sample.frameDescription)")
    }
  }

  @MainActor
  private func settledFrame(
    of surface: XCUIElement, after content: XCUIElement, processIdentifier: pid_t, timeout: TimeInterval
  ) throws -> CGRect {
    let sampler = WindowFrameSampler(processIdentifier: processIdentifier)
    sampler.start()
    defer {
      let timeline = sampler.stop()
      do {
        let attachment = XCTAttachment(
          data: try JSONEncoder().encode(timeline), uniformTypeIdentifier: "public.json")
        attachment.name = "Tab settling frames"
        attachment.lifetime = .keepAlways
        add(attachment)
      } catch {
        XCTFail("Could not retain settling frames: \(error)")
      }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    guard content.waitForExistence(timeout: timeout) else { throw BenchmarkError.contentNotReady }
    repeat {
      if sampler.isStable(within: timeout) { return surface.frame }
      Thread.sleep(forTimeInterval: 0.006)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw BenchmarkError.didNotSettle
  }

  @MainActor
  private func readyContent(_ tab: String, application: XCUIApplication) -> XCUIElement {
    if tab == "Settings" { return application.textFields["model-filter"] }
    return application.descendants(matching: .any)["tab-content-\(tab)"]
  }

  private func outputDirectory() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let root =
      environment["TMB_BENCHMARK_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("token-menu-bar-benchmark", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func retain(_ data: Data, named name: String, writingTo directory: URL) {
    let attachment = XCTAttachment(
      data: data, uniformTypeIdentifier: name.hasSuffix(".json") ? "public.json" : "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    try? data.write(to: directory.appendingPathComponent(name))
  }

  private func assertOpeningFrames(_ timeline: [WindowFrameTimelineSample]) {
    XCTAssertFalse(timeline.isEmpty, "CGWindow did not expose the opening panel frame")
    guard let final = timeline.last?.frame else { return }
    XCTAssertLessThan(
      timeline.map { abs($0.frame.minX - final.minX) }.max()!, 2, "Opening panel moved horizontally")
    XCTAssertLessThan(
      timeline.map { abs($0.frame.minY - final.minY) }.max()!, 2, "Opening panel top edge moved")
  }

  private static func milliseconds(_ duration: TimeInterval) -> Int {
    Int((duration * 1_000).rounded())
  }

  private static func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let index = min(Int(ceil(Double(sorted.count) * percentile)) - 1, sorted.count - 1)
    return sorted[max(index, 0)]
  }

  private enum BenchmarkError: Error {
    case didNotSettle
    case contentNotReady
  }
}

private struct TabSwitchReport: Codable {
  let p95TargetMilliseconds: Int
  let maximumBudgetMilliseconds: Int
  let coldSettingsPresentation: TimeInterval
  let launchToStatusItem: TimeInterval
  let launchToPanel: TimeInterval
  let displayWidth: CGFloat
  let displayHeight: CGFloat
  let physicalFootprintBefore: Int
  let physicalFootprintAfter: Int
  let idleCPUTime: TimeInterval
  let interactionCPUTime: TimeInterval
  let openFirstFrame: FrameSample
  let openSettledFrame: FrameSample
  let openFrameTimeline: [WindowFrameTimelineSample]
  let processSnapshots: [String]
  let samples: [TabSwitchSample]

  init(
    p95TargetMilliseconds: Int, maximumBudgetMilliseconds: Int,
    coldSettingsPresentation: TimeInterval,
    launchToStatusItem: TimeInterval, launchToPanel: TimeInterval,
    displayBounds: CGRect, physicalFootprintBefore: Int, physicalFootprintAfter: Int,
    idleCPUTime: TimeInterval, interactionCPUTime: TimeInterval, openFirstFrame: CGRect, openSettledFrame: CGRect,
    openFrameTimeline: [WindowFrameTimelineSample], processSnapshots: [String], samples: [TabSwitchSample]
  ) {
    self.p95TargetMilliseconds = p95TargetMilliseconds
    self.maximumBudgetMilliseconds = maximumBudgetMilliseconds
    self.coldSettingsPresentation = coldSettingsPresentation
    self.launchToStatusItem = launchToStatusItem
    self.launchToPanel = launchToPanel
    displayWidth = displayBounds.width
    displayHeight = displayBounds.height
    self.physicalFootprintBefore = physicalFootprintBefore
    self.physicalFootprintAfter = physicalFootprintAfter
    self.idleCPUTime = idleCPUTime
    self.interactionCPUTime = interactionCPUTime
    self.openFirstFrame = FrameSample(openFirstFrame)
    self.openSettledFrame = FrameSample(openSettledFrame)
    self.openFrameTimeline = openFrameTimeline
    self.processSnapshots = processSnapshots
    self.samples = samples
  }
}

private struct TabSwitchSample: Codable {
  let iteration: Int
  let tab: String
  let latency: TimeInterval
  let firstFrame: FrameSample
  let frame: FrameSample

  init(iteration: Int, tab: String, latency: TimeInterval, firstFrame: CGRect, frame: CGRect) {
    self.iteration = iteration
    self.tab = tab
    self.latency = latency
    self.firstFrame = FrameSample(firstFrame)
    self.frame = FrameSample(frame)
  }

  var minX: CGFloat { frame.minX }
  var minY: CGFloat { frame.minY }
  var width: CGFloat { frame.width }
  var frameDescription: String {
    "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
  }
}

struct FrameSample: Codable {
  let minX: CGFloat
  let minY: CGFloat
  let width: CGFloat
  let height: CGFloat

  var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

  init(_ frame: CGRect) {
    minX = frame.minX
    minY = frame.minY
    width = frame.width
    height = frame.height
  }
}

struct WindowFrameTimelineSample: Codable {
  let elapsed: TimeInterval
  let frame: FrameSample
}

final class WindowFrameSampler: @unchecked Sendable {
  private let identifyProcess: @Sendable () -> pid_t?
  private var processIdentifier: pid_t?
  private let started = ProcessInfo.processInfo.systemUptime
  private let queue = DispatchQueue(label: "dev.tox.token-menu-bar.frame-sampler")
  private let lock = NSLock()
  private var samples: [WindowFrameTimelineSample] = []
  private var timer: (any DispatchSourceTimer)?

  init(processIdentifier: pid_t) {
    identifyProcess = { processIdentifier }
  }

  init(snapshotURL: URL) {
    identifyProcess = {
      guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
      return try? JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: data).processIdentifier
    }
  }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(6), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.capture() }
    lock.withLock { self.timer = timer }
    timer.resume()
  }

  func stop() -> [WindowFrameTimelineSample] {
    let timer = lock.withLock { () -> (any DispatchSourceTimer)? in
      let timer = self.timer
      self.timer = nil
      return timer
    }
    timer?.cancel()
    queue.sync {}
    return lock.withLock { samples }
  }

  func isStable(within deadline: TimeInterval) -> Bool {
    lock.withLock {
      guard let last = samples.last else { return false }
      let recent = samples.reversed().prefix {
        abs($0.frame.minX - last.frame.minX) < 0.5 && abs($0.frame.minY - last.frame.minY) < 0.5
          && abs($0.frame.width - last.frame.width) < 0.5 && abs($0.frame.height - last.frame.height) < 0.5
      }
      let inBudget = recent.filter { $0.elapsed <= deadline }
      return inBudget.count >= 3 && inBudget.first!.elapsed - inBudget.last!.elapsed >= 0.032
    }
  }

  private func capture() {
    guard let processIdentifier = processIdentifier ?? identifyProcess() else { return }
    self.processIdentifier = processIdentifier
    guard
      let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[CFString: Any]],
      let frame = values.compactMap({ value -> CGRect? in
        guard
          (value[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier,
          let bounds = value[kCGWindowBounds] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
          frame.width >= 500, frame.height >= 100
        else { return nil }
        return frame
      }).max(by: { $0.width * $0.height < $1.width * $1.height })
    else { return }
    let sample = WindowFrameTimelineSample(
      elapsed: ProcessInfo.processInfo.systemUptime - started, frame: FrameSample(frame))
    lock.withLock { samples.append(sample) }
  }
}
