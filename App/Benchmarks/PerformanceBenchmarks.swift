import CoreGraphics
import Foundation
import TokenMenuBarCore
import XCTest

final class PerformanceBenchmarks: XCTestCase {
  @MainActor func testSixtyDayHistoryPreparation() async throws {
    let history = try UsageHistoryStore(url: nil)
    try await DemoData.seed(history, providers: ProviderID.allCases, now: fixedNow.addingTimeInterval(-30 * 86400))
    try await DemoData.seed(history, providers: ProviderID.allCases, now: fixedNow)
    let sampleCount = try await history.stats().sampleCount
    XCTAssertGreaterThan(sampleCount, 30_000)
    let settings = Settings(defaults: testDefaults())
    settings.historyRange = .twoMonths
    let presenter = HistoryPresenter(history: history, settings: settings, clock: testClock)
    let before = try XCTUnwrap(ProcessPerformanceSnapshot.current())
    let started = ProcessInfo.processInfo.systemUptime
    for metric: HistoryMetric in [
      .windowUsagePercent, .analytics(.inputTokens), .analytics(.turns), .analytics(.costUSD),
    ] {
      presenter.setMetric(metric)
      presenter.ensureLoaded()
      await presenter.waitForLoad()
      XCTAssertFalse(try XCTUnwrap(presenter.state.data).series.isEmpty)
    }
    let after = try XCTUnwrap(ProcessPerformanceSnapshot.current())
    let duration = ProcessInfo.processInfo.systemUptime - started
    let growth = Int64(after.physicalFootprintBytes) - Int64(before.physicalFootprintBytes)
    print(
      "HISTORY_PROFILE samples=\(sampleCount) preparation_s=\(duration) retained_growth_bytes=\(growth) cpu_ns=\(after.cpuNanoseconds - before.cpuNanoseconds)"
    )
  }

  private let settleTimeout = 10.0
  private let iterations = 5

  override func setUpWithError() throws {
    let expected = Int(ProcessInfo.processInfo.environment["TMB_BENCHMARK_MACOS_MAJOR"] ?? "")
    guard expected == ProcessInfo.processInfo.operatingSystemVersion.majorVersion else {
      throw BenchmarkError.wrongRuntime
    }
    try super.setUpWithError()
  }

  @MainActor
  func testProfileMockedTabSwitches() async throws {
    guard ProcessInfo.processInfo.environment["TMB_PROFILE_DIRECTORY"] != nil else {
      throw BenchmarkError.profileUnavailable
    }
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 3))
    let requestedReport = try await verification.requestCPUProfile()
    let report = try XCTUnwrap(requestedReport)
    let samplerLog = report.deletingLastPathComponent().appendingPathComponent("sampler.log")
    let samplingDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: samplerLog.path), Date() < samplingDeadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: samplerLog.path), "CPU sampler did not start")
    verification.tab("Settings").click()
    XCTAssertTrue(
      readyContent("Settings", application: verification.application).waitForExistence(timeout: settleTimeout))
    verification.application.typeKey("r", modifierFlags: .command)
    for _ in 0..<3 {
      for tab in ["History", "Settings", "Usage"] {
        verification.tab(tab).click()
        XCTAssertTrue(readyContent(tab, application: verification.application).waitForExistence(timeout: settleTimeout))
      }
    }
    let deadline = Date().addingTimeInterval(60)
    while !FileManager.default.fileExists(atPath: report.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
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
  func testFirstSettingsClickFromFreshLaunch() async throws {
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in await verification.terminate() }
    let frameSampler = WindowFrameSampler(
      snapshotURL: verification.supportDirectory.appendingPathComponent("process-snapshot.json"))
    addTeardownBlock { _ = frameSampler.stop() }
    frameSampler.start()
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 3))
    let openingFrames = frameSampler.stop()
    let frames = XCTAttachment(data: try JSONEncoder().encode(openingFrames), uniformTypeIdentifier: "public.json")
    frames.name = "Cold opening frames"
    frames.lifetime = .keepAlways
    add(frames)
    try assertOpeningFrames(openingFrames)
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
    let durations = try await verification.tabPresentationDurations()
    let draw = try XCTUnwrap(durations.first)
    print(
      "FIRST_SETTINGS input_to_draw_s=\(draw) xctest_click_to_ready_s=\(ready) xctest_click_to_capture_s=\(captured)")
  }

  @MainActor
  func testTabSwitchLatencyAndFrameStability() async throws {
    executionTimeAllowance = 120
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in await verification.terminate() }
    let launchStarted = ProcessInfo.processInfo.systemUptime
    try verification.launch()

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
    try assertOpeningFrames(openFrameTimeline)
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

    let settledProcessSnapshot = try await verification.processSnapshot()
    let idleCPUStart = try await verification.cpuTime()
    try await Task.sleep(for: .seconds(10))
    let idleCPUTime = try await verification.cpuTime() - idleCPUStart
    let idleProcessSnapshot = try await verification.processSnapshot()
    let physicalFootprintBefore = try await verification.physicalFootprintBytes()
    let interactionCPUStart = try await verification.cpuTime()
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

    let presentationDurations = try await verification.tabPresentationDurations()
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
    let p95 = Self.percentile(samples.map(\.latency), percentile: 0.95)
    let interactionCPUTime = try await verification.cpuTime() - interactionCPUStart
    try await Task.sleep(for: .seconds(2))
    let physicalFootprintAfter = try await verification.physicalFootprintBytes()
    let interactionProcessSnapshot = try await verification.processSnapshot()
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

  private func assertOpeningFrames(_ timeline: [WindowFrameTimelineSample]) throws {
    let final = try XCTUnwrap(timeline.last?.frame, "CGWindow did not expose the opening panel frame")
    let delta = CGSize(
      width: timeline.map { abs($0.frame.minX - final.minX) }.max()!,
      height: timeline.map { abs($0.frame.minY - final.minY) }.max()!)
    guard delta.width < 2, delta.height < 2 else { throw BenchmarkError.openingPanelMoved(delta) }
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
    case profileUnavailable
    case wrongRuntime
    case didNotSettle
    case contentNotReady
    case openingPanelMoved(CGSize)
  }
}

private struct TabSwitchReport: Codable {
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
    coldSettingsPresentation: TimeInterval,
    launchToStatusItem: TimeInterval, launchToPanel: TimeInterval,
    displayBounds: CGRect, physicalFootprintBefore: Int, physicalFootprintAfter: Int,
    idleCPUTime: TimeInterval, interactionCPUTime: TimeInterval, openFirstFrame: CGRect, openSettledFrame: CGRect,
    openFrameTimeline: [WindowFrameTimelineSample], processSnapshots: [String], samples: [TabSwitchSample]
  ) {
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
