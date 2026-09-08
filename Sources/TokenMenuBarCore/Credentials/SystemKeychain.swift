import Foundation
import Security

func systemKeychainLoad(service: String, account: String?) throws -> KeychainCredentialItem? {
  var item: CFTypeRef?
  let status = SecItemCopyMatching(systemKeychainQuery(service: service, account: account) as CFDictionary, &item)
  guard status != errSecItemNotFound else { return nil }
  guard status == errSecSuccess, let values = item as? [String: Any],
    let data = values[kSecValueData as String] as? Data
  else { throw CredentialStoreError.keychain(status) }
  return KeychainCredentialItem(data: data, account: values[kSecAttrAccount as String] as? String)
}

func systemKeychainServices(prefix: String) throws -> [String] {
  var items: CFTypeRef?
  let status = SecItemCopyMatching(systemKeychainListQuery() as CFDictionary, &items)
  guard status != errSecItemNotFound else { return [] }
  guard status == errSecSuccess, let values = items as? [[String: Any]] else {
    throw CredentialStoreError.keychain(status)
  }
  return keychainServices(values, prefix: prefix)
}

func systemKeychainSave(data: Data, service: String, account: String) throws {
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
  ]
  let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
  if status == errSecItemNotFound {
    var addQuery = query
    addQuery[kSecValueData as String] = data
    let added = SecItemAdd(addQuery as CFDictionary, nil)
    guard added == errSecSuccess else { throw CredentialStoreError.keychain(added) }
    return
  }
  guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
}
