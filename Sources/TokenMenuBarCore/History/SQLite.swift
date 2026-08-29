import Foundation
import SQLite3

public enum SQLiteError: Error, Equatable {
  case open(String)
  case prepare(String, String)
  case step(String, String)
}

public enum SQLiteValue: Sendable, Equatable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)

  init(_ double: Double?) {
    self = double.map(SQLiteValue.real) ?? .null
  }

  init(_ date: Date?) {
    self = date.map { .real($0.timeIntervalSince1970) } ?? .null
  }
}

public struct SQLiteRow {
  private let statement: OpaquePointer

  init(_ statement: OpaquePointer) {
    self.statement = statement
  }

  public func double(_ index: Int32) -> Double? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
  }

  public func int(_ index: Int32) -> Int {
    Int(sqlite3_column_int64(statement, index))
  }

  public func text(_ index: Int32) -> String {
    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
  }

  public func date(_ index: Int32) -> Date? {
    double(index).map { Date(timeIntervalSince1970: $0) }
  }
}

public final class SQLiteDatabase {
  private var handle: OpaquePointer?

  public init(path: String, readOnly: Bool = false) throws {
    var handle: OpaquePointer?
    let flags =
      readOnly
      ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
      : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
      sqlite3_close(handle)
      throw SQLiteError.open(message)
    }
    self.handle = handle
  }

  deinit {
    sqlite3_close(handle)
  }

  private var errorMessage: String {
    handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
  }

  public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
    _ = try query(sql, parameters) { _ in () }
  }

  public func query<T>(_ sql: String, _ parameters: [SQLiteValue] = [], _ row: (SQLiteRow) throws -> T) throws -> [T] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw SQLiteError.prepare(sql, errorMessage)
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, parameter) in parameters.enumerated() {
      let index = Int32(offset + 1)
      switch parameter {
      case .null: sqlite3_bind_null(statement, index)
      case .integer(let value): sqlite3_bind_int64(statement, index, value)
      case .real(let value): sqlite3_bind_double(statement, index, value)
      case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
      }
    }
    var rows: [T] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw SQLiteError.step(sql, errorMessage) }
      rows.append(try row(SQLiteRow(statement)))
    }
    return rows
  }

  public var changes: Int {
    Int(sqlite3_changes(handle))
  }
}
