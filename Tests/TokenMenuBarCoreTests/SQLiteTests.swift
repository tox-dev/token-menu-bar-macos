import Testing

@testable import TokenMenuBarCore

@Test func sqliteTransactionCommitsAllRows() throws {
  let database = try SQLiteDatabase(path: ":memory:")
  try database.execute("CREATE TABLE values_table (value INTEGER NOT NULL)")
  try database.withTransaction {
    try database.executeMany("INSERT INTO values_table (value) VALUES (?)", [[.integer(1)], [.integer(2)]])
  }
  #expect(try database.query("SELECT value FROM values_table ORDER BY value") { $0.int(0) } == [1, 2])
}

@Test func sqliteTransactionRollsBackEveryRowAfterFailure() throws {
  let database = try SQLiteDatabase(path: ":memory:")
  try database.execute("CREATE TABLE values_table (value INTEGER NOT NULL UNIQUE)")
  #expect(throws: SQLiteError.self) {
    try database.withTransaction {
      try database.executeMany("INSERT INTO values_table (value) VALUES (?)", [[.integer(1)], [.integer(1)]])
    }
  }
  #expect(try database.query("SELECT value FROM values_table") { $0.int(0) }.isEmpty)
}

@Test func sqliteInterruptDoesNotPoisonTheNextStatement() throws {
  let database = try SQLiteDatabase(path: ":memory:")

  database.interrupt()

  #expect(try database.query("SELECT 42") { $0.int(0) } == [42])
}

@Test func sqliteTransactionRollsBackAfterCancellation() async throws {
  let database = try SQLiteDatabase(path: ":memory:")
  try database.execute("CREATE TABLE values_table (value INTEGER NOT NULL)")
  let transaction = Task {
    try database.withTransaction {
      try database.execute("INSERT INTO values_table (value) VALUES (1)")
      withUnsafeCurrentTask { $0?.cancel() }
      try database.execute("INSERT INTO values_table (value) VALUES (2)")
    }
  }

  do {
    try await transaction.value
    Issue.record("expected cancellation")
  } catch is CancellationError {
  } catch {
    Issue.record("expected CancellationError, got \(error)")
  }

  #expect(try database.query("SELECT value FROM values_table") { $0.int(0) }.isEmpty)
  try database.withTransaction {
    try database.execute("INSERT INTO values_table (value) VALUES (3)")
  }
  #expect(try database.query("SELECT value FROM values_table") { $0.int(0) } == [3])
}

@Test func sqliteTransactionPreservesBodyErrorWhenRollbackFails() throws {
  let database = try SQLiteDatabase(path: ":memory:")

  do {
    try database.withTransaction {
      try database.execute("ROLLBACK")
      throw TransactionFixtureError.body
    }
    Issue.record("expected body error")
  } catch let error as TransactionFixtureError {
    #expect(error == .body)
  } catch {
    Issue.record("expected TransactionFixtureError, got \(error)")
  }

  #expect(try database.query("SELECT 42") { $0.int(0) } == [42])
}

private enum TransactionFixtureError: Error {
  case body
}
