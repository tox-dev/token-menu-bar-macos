import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func tooltipTrackingContextRequiresHoverOrFocus() throws {
  let screen = try #require(NSScreen.screens.first)
  let presenter = TooltipPresenter(sleep: { _ in })
  let view = TooltipTrackingView(
    content: TooltipContent(title: "Idle", body: "No trigger is active."),
    presenter: presenter
  )
  let window = NSWindow(
    contentRect: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 180, height: 60),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
  )
  window.alphaValue = 0
  window.contentView = view
  window.orderFrontRegardless()
  defer {
    view.dismantle()
    presenter.tearDown()
    window.orderOut(nil)
  }

  #expect(view.tooltipPresentationContext == nil)
}

@Test @MainActor func logSectionCopyExportsCurrentEntriesNewestFirst() throws {
  let environment = try makeEnvironment(populate: false)
  environment.log.log("first")
  environment.log.logWarning("second")
  var copied: [String] = []
  environment.actions.copy = { copied.append($0) }
  let section = LogSection(environment: environment)
  let copy = try #require(findCoverageButtons(in: section.body).first)

  copy.action()

  #expect(copied == [LogExport.text(entries: environment.log.snapshot.reversed())])
}

@Test @MainActor func fullLogViewRespondsToLiveAppendReloadAndClear() async throws {
  let directory = try makeCoverageDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = LogBuffer(fileURL: directory.appendingPathComponent("app.log"))
  log.log("retained")
  log.flush()
  let hosting = host(FullLogView(log: log), width: 600, height: 300)
  let window = try #require(hosting.window)
  defer {
    window.contentView = nil
    window.close()
  }
  let textView: NSTextView = try #require(findCoverageView(in: hosting))
  await waitUntil { textView.string.contains("retained") }

  log.log("appended")
  await waitUntil { textView.string.contains("appended") }
  #expect(textView.string.contains("retained"))

  log.clear()
  log.log("reloaded")
  await waitUntil { textView.string.contains("reloaded") }
  #expect(!textView.string.contains("retained"))
  #expect(!textView.string.contains("appended"))

  log.clear()
  await waitUntil { textView.string.isEmpty }
  #expect(textView.string.isEmpty)
}

@Test @MainActor func fullLogViewTrimsRetainedHistoryAfterLiveAppends() async throws {
  let directory = try makeCoverageDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let fileURL = directory.appendingPathComponent("app.log")
  var retained = ""
  retained.reserveCapacity(LogBuffer.retainedEntryLimit * 48)
  let prefix = "[\(LogBuffer.timestampFormat.string(from: fixedNow))] [info] retained-"
  for index in 0..<LogBuffer.retainedEntryLimit {
    retained.append(contentsOf: "\(prefix)\(index)\n")
  }
  try retained.write(to: fileURL, atomically: true, encoding: .utf8)
  let log = LogBuffer(
    fileURL: fileURL,
    maximumFileBytes: retained.utf8.count + 1_000_000,
    maximumFileCount: 1
  )
  let hosting = host(FullLogView(log: log), width: 600, height: 300)
  let window = try #require(hosting.window)
  defer {
    window.contentView = nil
    window.close()
  }
  let textView: NSTextView = try #require(findCoverageView(in: hosting))
  #expect(await waitUntil(within: 90) { textView.string.hasPrefix("\(prefix)0\n") })

  for index in LogBuffer.retainedEntryLimit..<(LogBuffer.retainedEntryLimit + LogBuffer.capacity - 1) {
    log.log("retained-\(index)")
  }
  log.flush()
  #expect(await waitUntil(within: 30) { textView.string.hasSuffix("retained-100498") })

  log.log("retained-100499")
  log.log("retained-100500")
  log.flush()
  #expect(await waitUntil(within: 30) { textView.string.hasPrefix("\(prefix)501\n") })

  #expect(textView.string.hasSuffix("retained-100500"))
  #expect(!textView.string.contains("\(prefix)500\n"))
}

private func findCoverageButtons(in value: Any, depth: Int = 0) -> [NativeActionButton<Text>] {
  if let button = value as? NativeActionButton<Text> { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap { findCoverageButtons(in: $0.value, depth: depth + 1) }
}

@MainActor
private func findCoverageView<Wanted: NSView>(in root: NSView) -> Wanted? {
  if let match = root as? Wanted { return match }
  for subview in root.subviews {
    if let match: Wanted = findCoverageView(in: subview) { return match }
  }
  return nil
}

private func makeCoverageDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "token-menu-bar-log-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
