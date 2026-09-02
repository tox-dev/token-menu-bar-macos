import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func missingBookmarkNeedsAccessWithoutStartingALease() {
  let probe = SecurityScopeProbe()
  let resource = ProviderID.codex.sandboxResources[0]
  let fallback = URL(fileURLWithPath: "/fallback")
  let result = SecurityScopedResourceResolver(client: probe.client()).resolve(
    resource: resource, bookmark: nil, fallback: fallback)
  #expect(result.url == fallback)
  #expect(result.access == ResourceAccessState(resource: resource, health: .needed))
  #expect(result.lease == nil)
  #expect(probe.starts == 0)
}

@Test func resolvedBookmarkStopsExactlyOnceWhenReleased() {
  let probe = SecurityScopeProbe()
  let resource = ProviderID.codex.sandboxResources[0]
  let result = SecurityScopedResourceResolver(client: probe.client()).resolve(
    resource: resource, bookmark: Data([1]), fallback: URL(fileURLWithPath: "/fallback"))
  #expect(result.url == probe.url)
  #expect(result.access.health == .granted)
  #expect(probe.starts == 1)
  result.lease?.release()
  result.lease?.release()
  #expect(probe.stops == 1)
}

@Test func staleBookmarkIsReplacedWhileTheLeaseRemainsValid() {
  let probe = SecurityScopeProbe(stale: true)
  let resource = ProviderID.codex.sandboxResources[0]
  let result = SecurityScopedResourceResolver(client: probe.client()).resolve(
    resource: resource, bookmark: Data([1]), fallback: URL(fileURLWithPath: "/fallback"))
  #expect(result.access.health == .granted)
  #expect(result.replacementBookmark == Data([2]))
  #expect(probe.creates == 1)
  #expect(probe.stops == 0)
  result.lease?.release()
  #expect(probe.stops == 1)
}

@Test func failedStaleReplacementKeepsTheLeaseAndReportsStale() {
  let probe = SecurityScopeProbe(stale: true, createFails: true)
  let resource = ProviderID.codex.sandboxResources[0]
  let result = SecurityScopedResourceResolver(client: probe.client()).resolve(
    resource: resource, bookmark: Data([1]), fallback: URL(fileURLWithPath: "/fallback"))
  #expect(result.url == probe.url)
  #expect(result.access.health == .stale)
  #expect(result.replacementBookmark == nil)
  result.lease?.release()
  #expect(probe.stops == 1)
}

@Test func deniedSecurityScopeFallsBackWithoutALease() {
  let probe = SecurityScopeProbe(startDenied: true)
  let resource = ProviderID.codex.sandboxResources[0]
  let fallback = URL(fileURLWithPath: "/fallback")
  let result = SecurityScopedResourceResolver(client: probe.client()).resolve(
    resource: resource, bookmark: Data([1]), fallback: fallback)
  #expect(result.url == fallback)
  #expect(result.access.health == .error("macOS denied access to the selected location."))
  #expect(result.lease == nil)
  #expect(probe.stops == 0)
}

@Test func invalidSecurityScopeBookmarkReportsAnAccessError() {
  let probe = SecurityScopeProbe(resolveFails: true)
  let resource = ProviderID.codex.sandboxResources[0]
  let fallback = URL(fileURLWithPath: "/fallback")
  let result = SecurityScopedResourceResolver(client: probe.client()).resolve(
    resource: resource, bookmark: Data([1]), fallback: fallback)
  #expect(result.url == fallback)
  #expect(result.access.health == .error("The saved access grant is no longer valid."))
  #expect(result.lease == nil)
  #expect(probe.starts == 0)
}

@Test func liveSecurityScopeClientCreatesBookmarkData() throws {
  let directory = temporaryDirectory()
  let bookmark = try SecurityScopedBookmarkClient.live.create(directory)
  #expect(!bookmark.isEmpty)
}

@Test func providerRegistryRetainsAndThenReleasesResourceLeases() throws {
  let probe = SecurityScopeProbe()
  var registry: ProviderRegistry?
  do {
    let result = SecurityScopedResourceResolver(client: probe.client()).resolve(
      resource: ProviderID.codex.sandboxResources[0], bookmark: Data([1]),
      fallback: URL(fileURLWithPath: "/fallback"))
    registry = ProviderRegistry([], resourceLeases: [try #require(result.lease)])
  }
  #expect(probe.stops == 0)
  registry = nil
  #expect(registry == nil)
  #expect(probe.stops == 1)
}

private final class SecurityScopeProbe: @unchecked Sendable {
  let url = URL(fileURLWithPath: "/granted")
  private let lock = NSLock()
  private let stale: Bool
  private let createFails: Bool
  private let startDenied: Bool
  private let resolveFails: Bool
  private var counts = (starts: 0, stops: 0, creates: 0)

  init(stale: Bool = false, createFails: Bool = false, startDenied: Bool = false, resolveFails: Bool = false) {
    self.stale = stale
    self.createFails = createFails
    self.startDenied = startDenied
    self.resolveFails = resolveFails
  }

  var starts: Int { lock.withLock { counts.starts } }
  var stops: Int { lock.withLock { counts.stops } }
  var creates: Int { lock.withLock { counts.creates } }

  func client() -> SecurityScopedBookmarkClient {
    SecurityScopedBookmarkClient(
      resolve: { [url, stale, resolveFails] _ in
        if resolveFails { throw CocoaError(.fileReadCorruptFile) }
        return SecurityScopedBookmarkResolution(url: url, isStale: stale)
      },
      create: { [self] _ in
        lock.withLock { counts.creates += 1 }
        if createFails { throw CocoaError(.fileWriteUnknown) }
        return Data([2])
      },
      start: { [self] _ in
        lock.withLock { counts.starts += 1 }
        return !startDenied
      },
      stop: { [self] _ in lock.withLock { counts.stops += 1 } })
  }
}
