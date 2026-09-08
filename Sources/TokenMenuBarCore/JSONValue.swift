import Foundation

public enum JSONValue: Codable, Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      if value == value.rounded(), abs(value) < 1e15 {
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public subscript(key: String) -> JSONValue? {
    guard case .object(let dict) = self else { return nil }
    return dict[key]
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    switch self {
    case .number(let value): value
    case .string(let value): Double(value)
    default: nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public func merging(_ key: String, _ value: JSONValue) -> JSONValue {
    var dict = objectValue ?? [:]
    dict[key] = value
    return .object(dict)
  }

  public var summary: String {
    switch self {
    case .null: "null"
    case .bool(let value): String(value)
    case .number(let value): value.formatted(.number.precision(.fractionLength(0...2)))
    case .string(let value): value
    case .array(let values): values.map(\.summary).joined(separator: ", ")
    case .object(let dict): dict.keys.sorted().map { "\($0): \(dict[$0]!.summary)" }.joined(separator: ", ")
    }
  }
}
