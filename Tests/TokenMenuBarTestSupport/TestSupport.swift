import Darwin
import Foundation
import TokenMenuBarCore

public let fixedNow = Date(timeIntervalSince1970: 1_788_030_000)

public let testClock = Clock.fixed(fixedNow)

public func makeLog() -> LogBuffer {
  LogBuffer(fileURL: nil, clock: testClock)
}

public struct TestError: Error {
  public init() {}
}

public func testDefaults() -> UserDefaults {
  TestDefaults()
}

// Keeps every value in memory so a test run never writes to ~/Library/Preferences, which a named suite
// always does regardless of later cleanup.
public final class TestDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Any] = [:]

  public init() {
    super.init(suiteName: nil)!
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    nil
  }

  public override func object(forKey defaultName: String) -> Any? {
    lock.withLock { storage[defaultName] }
  }

  public override func set(_ value: Any?, forKey defaultName: String) {
    lock.withLock { storage[defaultName] = value }
  }

  public override func set(_ value: Bool, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }

  public override func set(_ value: Int, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }

  public override func set(_ value: Float, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }

  public override func set(_ value: Double, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }

  public override func set(_ url: URL?, forKey defaultName: String) {
    set(url as Any?, forKey: defaultName)
  }

  public override func removeObject(forKey defaultName: String) {
    lock.withLock { storage[defaultName] = nil }
  }

  public override func string(forKey defaultName: String) -> String? {
    switch object(forKey: defaultName) {
    case let text as String: text
    case let number as NSNumber: number.stringValue
    default: nil
    }
  }

  public override func data(forKey defaultName: String) -> Data? {
    object(forKey: defaultName) as? Data
  }

  public override func array(forKey defaultName: String) -> [Any]? {
    object(forKey: defaultName) as? [Any]
  }

  public override func stringArray(forKey defaultName: String) -> [String]? {
    object(forKey: defaultName) as? [String]
  }

  public override func dictionary(forKey defaultName: String) -> [String: Any]? {
    object(forKey: defaultName) as? [String: Any]
  }

  public override func url(forKey defaultName: String) -> URL? {
    object(forKey: defaultName) as? URL
  }

  public override func bool(forKey defaultName: String) -> Bool {
    switch object(forKey: defaultName) {
    case let flag as Bool: flag
    case let number as NSNumber: number.boolValue
    case let text as String: ["1", "yes", "true"].contains(text.lowercased())
    default: false
    }
  }

  public override func integer(forKey defaultName: String) -> Int {
    switch object(forKey: defaultName) {
    case let number as NSNumber: number.intValue
    case let text as String: Int(text) ?? 0
    default: 0
    }
  }

  public override func double(forKey defaultName: String) -> Double {
    switch object(forKey: defaultName) {
    case let number as NSNumber: number.doubleValue
    case let text as String: Double(text) ?? 0
    default: 0
    }
  }

  public override func float(forKey defaultName: String) -> Float {
    Float(double(forKey: defaultName))
  }

  public override func dictionaryRepresentation() -> [String: Any] {
    lock.withLock { storage }
  }

  public override func persistentDomain(forName domainName: String) -> [String: Any]? {
    let values = dictionaryRepresentation()
    return values.isEmpty ? nil : values
  }

  public override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
    lock.withLock { storage = domain }
  }

  public override func removePersistentDomain(forName domainName: String) {
    lock.withLock { storage.removeAll() }
  }

  public override func synchronize() -> Bool {
    true
  }
}
