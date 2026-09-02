import Foundation

public enum ProviderRediscoveryTrigger: Sendable, Equatable {
  case applicationActivated
  case userInitiated
}

public struct ProviderRediscoveryPolicy: Sendable {
  public static let activationInterval: TimeInterval = 60

  private let activationInterval: TimeInterval
  private var lastDiscoveryAt: Date?

  public init(
    activationInterval: TimeInterval = activationInterval,
    lastDiscoveryAt: Date? = nil
  ) {
    self.activationInterval = activationInterval
    self.lastDiscoveryAt = lastDiscoveryAt
  }

  public mutating func begin(_ trigger: ProviderRediscoveryTrigger, at now: Date) -> Bool {
    if trigger == .applicationActivated, let lastDiscoveryAt,
      now >= lastDiscoveryAt, now.timeIntervalSince(lastDiscoveryAt) < activationInterval
    {
      return false
    }
    lastDiscoveryAt = now
    return true
  }

  public mutating func recordDiscovery(at now: Date) {
    lastDiscoveryAt = now
  }
}

public struct ProviderDiscoverySnapshot: Sendable, Equatable {
  public let providerIDs: [ProviderID]
  public let credentials: [ProviderID: ProviderCredentialHealth]
  public let resources: [ProviderID: [ResourceAccessState]]

  public init(
    providerIDs: [ProviderID],
    credentials: [ProviderID: ProviderCredentialHealth],
    resources: [ProviderID: [ResourceAccessState]]
  ) {
    self.providerIDs = providerIDs
    self.credentials = credentials
    self.resources = resources
  }

  public static func inspect(_ registry: ProviderRegistry, now: Date) async -> ProviderDiscoverySnapshot {
    let credentials = await withTaskGroup(
      of: (ProviderID, ProviderCredentialHealth).self,
      returning: [ProviderID: ProviderCredentialHealth].self
    ) { group in
      for provider in registry.providers {
        group.addTask { (provider.id, await provider.credentialHealth(now: now)) }
      }
      var values: [ProviderID: ProviderCredentialHealth] = [:]
      for await (provider, health) in group { values[provider] = health }
      return values
    }
    return ProviderDiscoverySnapshot(
      providerIDs: registry.ids,
      credentials: credentials,
      resources: registry.setupStates.mapValues(\.resources))
  }

  public func differs(
    from states: [ProviderID: ProviderState],
    providerIDs currentProviderIDs: [ProviderID]
  ) -> Bool {
    guard providerIDs == currentProviderIDs else { return true }
    return providerIDs.contains { provider in
      credentials[provider] != states[provider]?.credentialHealth
        || (resources[provider] ?? []) != (states[provider]?.resourceAccess ?? [])
    }
  }
}
