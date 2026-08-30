import Foundation
import Testing
import TokenMenuBarCore

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

  // the fixture stores readable claims; CodexAuth wants them as a token, so sign them on the way out
  static func codexAuth() -> JSONValue {
    let document = json("codex_auth")
    var tokens = document["tokens"]!.objectValue!
    tokens["id_token"] = .string(makeJWT(tokens.removeValue(forKey: "id_token_claims")!))
    return document.merging("tokens", .object(tokens))
  }

  static func decode<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value {
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

struct TestError: Error {}

func makeJWT(_ payload: JSONValue) -> String {
  let body = try! JSONEncoder().encode(payload).base64EncodedString().replacingOccurrences(of: "=", with: "")
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
  return "\(Data(#"{"alg":"none"}"#.utf8).base64EncodedString()).\(body).sig"
}
