import Foundation

public struct KeychainCredentialItem: Sendable, Equatable {
  public let data: Data
  public let account: String?

  public init(data: Data, account: String?) {
    self.data = data
    self.account = account
  }
}

public struct KeychainCredentialClient: Sendable {
  private let loadValue: @Sendable (String, String?) throws -> KeychainCredentialItem?
  private let saveValue: @Sendable (Data, String, String) throws -> Void

  public init(
    load: @escaping @Sendable (String, String?) throws -> KeychainCredentialItem?,
    save: @escaping @Sendable (Data, String, String) throws -> Void
  ) {
    loadValue = load
    saveValue = save
  }

  public func load(service: String, account: String? = nil) throws -> KeychainCredentialItem? {
    try loadValue(service, account)
  }

  public func save(_ data: Data, service: String, account: String) throws {
    try saveValue(data, service, account)
  }

  public static let empty = KeychainCredentialClient(load: { _, _ in nil }, save: { _, _, _ in })
  public static let system = KeychainCredentialClient(load: systemKeychainLoad, save: systemKeychainSave)
}
