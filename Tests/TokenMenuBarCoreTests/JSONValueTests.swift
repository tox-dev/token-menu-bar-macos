import Foundation
import Testing
import TokenMenuBarCore

@Test func jsonValueRoundTripsAllKinds() throws {
  let text = #"{"a":null,"b":true,"c":1.5,"d":"x","e":[1,"y"],"f":{"g":2}}"#
  let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  #expect(value["a"] == .null)
  #expect(value["b"]?.boolValue == true)
  #expect(value["c"]?.doubleValue == 1.5)
  #expect(value["d"]?.stringValue == "x")
  #expect(value["e"]?.arrayValue == [.number(1), .string("y")])
  #expect(value["f"]?.objectValue == ["g": .number(2)])
  #expect(try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value)) == value)
  #expect(String(decoding: try JSONEncoder().encode(JSONValue.number(2)), as: UTF8.self) == "2")
  #expect(String(decoding: try JSONEncoder().encode(JSONValue.number(2.5)), as: UTF8.self) == "2.5")
  #expect(String(decoding: try JSONEncoder().encode(JSONValue.number(1e16)), as: UTF8.self).hasPrefix("1e+16"))
}

@Test func jsonValueAccessorsReturnNilForOtherKinds() {
  let value = JSONValue.string("7")
  #expect(value["missing"] == nil)
  #expect(value.boolValue == nil)
  #expect(value.arrayValue == nil)
  #expect(value.objectValue == nil)
  #expect(value.doubleValue == 7)
  #expect(JSONValue.bool(true).doubleValue == nil)
  #expect(JSONValue.bool(true).stringValue == nil)
  #expect(JSONValue.null.isNull)
  #expect(!JSONValue.bool(false).isNull)
}

@Test func jsonValueMergingAddsKeys() {
  #expect(
    JSONValue.object(["a": .number(1)]).merging("b", .string("x")) == .object(["a": .number(1), "b": .string("x")]))
  #expect(JSONValue.null.merging("b", .string("x")) == .object(["b": .string("x")]))
}

@Test func jsonValueSummaryFlattens() {
  let value = JSONValue.object(["z": .array([.number(1.25), .bool(true)]), "a": .null, "m": .string("s")])
  #expect(value.summary == "a: null, m: s, z: 1.25, true")
}
