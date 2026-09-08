import Foundation
import Security

extension KeychainCredentialClient {
  public static let deniedStatuses: Set<OSStatus> = [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed]
  public static let denialCacheInterval: TimeInterval = 30 * 60

  // Claude Code recreates its item periodically, which drops an earlier "Always Allow"; without this cache a user who
  // clicked Deny would be asked again on every poll.
  public func cachingDenials(clock: Clock) -> KeychainCredentialClient {
    let cache = KeychainDenialCache(clock: clock)
    return KeychainCredentialClient(
      load: { service, account in
        if let status = cache.status(service: service, account: account) { throw CredentialStoreError.keychain(status) }
        do {
          return try load(service: service, account: account)
        } catch CredentialStoreError.keychain(let status) where Self.deniedStatuses.contains(status) {
          cache.record(status, service: service, account: account)
          throw CredentialStoreError.keychain(status)
        }
      },
      save: save,
      list: services(prefix:),
      invalidate: { service, includingVariants in
        cache.invalidate(service: service, includingVariants: includingVariants)
        retryDeniedReads(service: service, includingVariants: includingVariants)
      })
  }
}

private final class KeychainDenialCache: @unchecked Sendable {
  private struct Key: Hashable {
    let service: String
    let account: String?
  }

  private let clock: Clock
  private let lock = NSLock()
  private var denials: [Key: (status: OSStatus, until: Date)] = [:]

  init(clock: Clock) {
    self.clock = clock
  }

  func status(service: String, account: String?) -> OSStatus? {
    lock.withLock {
      guard let denial = denials[Key(service: service, account: account)], denial.until > clock.now() else {
        return nil
      }
      return denial.status
    }
  }

  func record(_ status: OSStatus, service: String, account: String?) {
    lock.withLock {
      denials[Key(service: service, account: account)] = (
        status, clock.now().addingTimeInterval(KeychainCredentialClient.denialCacheInterval)
      )
    }
  }

  func invalidate(service: String, includingVariants: Bool) {
    lock.withLock {
      denials = denials.filter {
        $0.key.service != service && !(includingVariants && $0.key.service.hasPrefix(service + "-"))
      }
    }
  }
}
