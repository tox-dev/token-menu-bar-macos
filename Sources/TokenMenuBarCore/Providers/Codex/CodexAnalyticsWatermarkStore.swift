import Foundation

public struct CodexAnalyticsWatermarkPersistence: @unchecked Sendable {
  public static let standard = CodexAnalyticsWatermarkPersistence(defaults: .standard)

  let defaults: UserDefaults

  public init(defaults: UserDefaults) {
    self.defaults = defaults
  }
}

struct CodexAnalyticsCoverage: Codable, Equatable {
  var start: String
  var through: String
}

struct CodexAnalyticsWatermarkStore {
  static let storageKey = "codexAnalyticsWatermarks"
  static let maximumAccounts = 4

  let persistence: CodexAnalyticsWatermarkPersistence

  func load(account: String, now: Date, retentionDays: Int) -> [CodexAPI.Analytics: CodexAnalyticsCoverage] {
    var (state, needsWrite) = decoded(now: now)
    needsWrite = prune(&state, now: now, retentionDays: retentionDays) || needsWrite
    if needsWrite { write(state) }
    return Dictionary(
      uniqueKeysWithValues: (state.accounts[account]?.coverage ?? [:]).compactMap { key, value in
        CodexAPI.Analytics(rawValue: key).map { ($0, value) }
      })
  }

  func update(
    account: String,
    coverage: [CodexAPI.Analytics: CodexAnalyticsCoverage],
    now: Date,
    retentionDays: Int
  ) {
    var (state, _) = decoded(now: now)
    state.accounts[account] = StoredAccount(
      lastAccess: now,
      coverage: Dictionary(uniqueKeysWithValues: coverage.map { ($0.key.rawValue, $0.value) }))
    _ = prune(&state, now: now, retentionDays: retentionDays)
    write(state)
  }

  private func decoded(now: Date) -> (StoredState, Bool) {
    guard let data = persistence.defaults.data(forKey: Self.storageKey) else { return (StoredState(), false) }
    let decoder = JSONDecoder()
    if let state = try? decoder.decode(StoredState.self, from: data), state.version == StoredState.version {
      return (state, false)
    }
    if let legacy = try? decoder.decode(LegacyState.self, from: data) {
      return (
        StoredState(
          accounts: legacy.accounts.mapValues { watermarks in
            StoredAccount(
              lastAccess: now,
              coverage: watermarks.mapValues { CodexAnalyticsCoverage(start: $0, through: $0) })
          }),
        true
      )
    }
    return (StoredState(), true)
  }

  private func prune(_ state: inout StoredState, now: Date, retentionDays: Int) -> Bool {
    let cutoff = DayStamp.string(now.addingTimeInterval(-Double(max(retentionDays - 1, 0)) * 86400))
    let end = DayStamp.string(now)
    let previous = state
    state.accounts = state.accounts.compactMapValues { account in
      var account = account
      account.coverage = account.coverage.filter { key, value in
        CodexAPI.Analytics(rawValue: key) != nil
          && DayStamp.date(value.start) != nil
          && DayStamp.date(value.through) != nil
          && value.start <= value.through
          && value.through >= cutoff
          && value.through <= end
      }.mapValues { value in
        CodexAnalyticsCoverage(start: max(value.start, cutoff), through: value.through)
      }
      return account.coverage.isEmpty ? nil : account
    }
    if state.accounts.count > Self.maximumAccounts {
      let retained = state.accounts.sorted {
        $0.value.lastAccess == $1.value.lastAccess
          ? $0.key > $1.key
          : $0.value.lastAccess > $1.value.lastAccess
      }.prefix(Self.maximumAccounts)
      state.accounts = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }
    return state != previous
  }

  private func write(_ state: StoredState) {
    persistence.defaults.set(try! JSONEncoder().encode(state), forKey: Self.storageKey)
  }
}

private struct StoredState: Codable, Equatable {
  static let version = 1

  var version = Self.version
  var accounts: [String: StoredAccount] = [:]
}

private struct StoredAccount: Codable, Equatable {
  var lastAccess: Date
  var coverage: [String: CodexAnalyticsCoverage]
}

private struct LegacyState: Codable {
  let accounts: [String: [String: String]]
}
