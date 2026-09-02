import Foundation
import Security

func systemKeychainLoad(service: String, account: String?) throws -> KeychainCredentialItem? {
  var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecReturnAttributes as String: true,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
  ]
  query[kSecAttrAccount as String] = account
  var item: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &item)
  guard status != errSecItemNotFound else { return nil }
  guard status == errSecSuccess, let values = item as? [String: Any],
    let data = values[kSecValueData as String] as? Data
  else { throw CredentialStoreError.keychain(status) }
  return KeychainCredentialItem(data: data, account: values[kSecAttrAccount as String] as? String)
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
