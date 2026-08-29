import Foundation
import Testing

@testable import TokenMenuBarCore

enum Fixtures {
  static func url(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
  }

  static func data(_ name: String) -> Data {
    try! Data(contentsOf: url(name))
  }

  static func json(_ name: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: data(name))
  }

  static func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T {
    try! JSONDecoder().decode(type, from: data(name))
  }
}

let fixedNow = Date(timeIntervalSince1970: 1_788_030_000)

let testClock = Clock.fixed(fixedNow)

func makeLog() -> LogBuffer {
  LogBuffer(fileURL: nil, clock: testClock)
}

func temporaryDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-tests-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

final class DateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  var date: Date {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }

  var clock: Clock {
    Clock(now: { self.date }, sleep: { _ in })
  }
}
