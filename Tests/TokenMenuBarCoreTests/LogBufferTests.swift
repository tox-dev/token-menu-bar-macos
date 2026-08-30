import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func logBufferKeepsEntriesAndLevels() {
  let log = makeLog()
  log.log("hello")
  log.logError("bad")
  log.logDebug("hidden")
  log.debugEnabled = true
  log.logDebug("shown")
  #expect(log.snapshot.map(\.message) == ["hello", "bad", "shown"])
  #expect(log.snapshot.map(\.level) == [.info, .error, .info])
  #expect(log.tail(1).map(\.message) == ["shown"])
  #expect(log.text.contains("[error] bad"))
  #expect(log.snapshot[0].line.hasPrefix("2026-08-29"))
  #expect(log.snapshot[0].id != log.snapshot[1].id)
  #expect(LogLevel.debug < .info && LogLevel.info < .error)
  log.clear()
  #expect(log.snapshot.isEmpty)
}

@Test func logBufferCapsCapacity() {
  let log = makeLog()
  for index in 0..<(LogBuffer.capacity + 10) { log.log("line \(index)") }
  #expect(log.snapshot.count == LogBuffer.capacity)
  #expect(log.snapshot.first?.message == "line 10")
}

@Test func logBufferPersistsAndPrunesOnLoad() throws {
  let url = temporaryDirectory().appendingPathComponent("logs/app.json")
  let old = LogEntry(
    timestamp: fixedNow.addingTimeInterval(-LogBuffer.retention - 10), level: .info, message: "ancient")
  let recent = LogEntry(timestamp: fixedNow.addingTimeInterval(-10), level: .info, message: "recent")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try JSONEncoder().encode([old, recent]).write(to: url)
  let log = LogBuffer(fileURL: url, clock: testClock)
  #expect(log.snapshot.map(\.message) == ["recent"])
  log.log("new")
  #expect(LogBuffer(fileURL: url, clock: testClock).snapshot.map(\.message) == ["recent", "new"])
  try Data("garbage".utf8).write(to: url)
  #expect(LogBuffer(fileURL: url, clock: testClock).snapshot.isEmpty)
}

@Test func logBufferPrunesHourlyWhileAppending() {
  let box = DateBox(fixedNow)
  let log = LogBuffer(fileURL: nil, clock: box.clock)
  log.log("first")
  box.date = fixedNow.addingTimeInterval(LogBuffer.retention + 7200)
  log.log("second")
  #expect(log.snapshot.map(\.message) == ["second"])
}
