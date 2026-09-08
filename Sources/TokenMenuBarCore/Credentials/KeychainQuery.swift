import Foundation
import LocalAuthentication
import Security

// The raw value of kSecUseAuthenticationUIFail, whose symbol is deprecated in favour of the LAContext set alongside
// it; both are passed so a background read fails instead of prompting on every SDK that honours either.
let keychainAuthenticationUIFail = "u_AuthUIF"

func systemKeychainQuery(service: String, account: String?) -> [String: Any] {
  let context = LAContext()
  context.interactionNotAllowed = true
  var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecReturnAttributes as String: true,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
    kSecUseAuthenticationContext as String: context,
    kSecUseAuthenticationUI as String: keychainAuthenticationUIFail,
  ]
  query[kSecAttrAccount as String] = account
  return query
}

// Attributes alone never trip an item's access control list, so listing every generic password cannot prompt.
func systemKeychainListQuery() -> [String: Any] {
  var query = systemKeychainQuery(service: "", account: nil)
  query[kSecAttrService as String] = nil
  query[kSecReturnData as String] = nil
  query[kSecMatchLimit as String] = kSecMatchLimitAll
  return query
}

func keychainServices(_ attributes: [[String: Any]], prefix: String) -> [String] {
  attributes.compactMap { $0[kSecAttrService as String] as? String }
    .filter { $0.hasPrefix(prefix) }
    .uniqued()
    .sorted()
}
