import Foundation

@testable import TokenMenuBarCore

final class MemoryKeychain: @unchecked Sendable {
  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private var values: [Key: Data] = [:]

  var client: KeychainCredentialClient {
    KeychainCredentialClient(
      load: { [self] service, account in
        lock.withLock {
          if let account {
            return values[Key(service: service, account: account)].map {
              KeychainCredentialItem(data: $0, account: account)
            }
          }
          return
            values
            .filter { $0.key.service == service }
            .sorted { $0.key.account < $1.key.account }
            .first
            .map { KeychainCredentialItem(data: $0.value, account: $0.key.account) }
        }
      },
      save: { [self] data, service, account in
        lock.withLock { values[Key(service: service, account: account)] = data }
      })
  }
}
