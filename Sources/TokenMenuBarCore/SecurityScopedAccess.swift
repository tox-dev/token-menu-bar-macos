import Foundation

public struct SecurityScopedBookmarkResolution: Sendable, Equatable {
  public let url: URL
  public let isStale: Bool

  public init(url: URL, isStale: Bool) {
    self.url = url
    self.isStale = isStale
  }
}

public struct SecurityScopedBookmarkClient: Sendable {
  public var resolve: @Sendable (Data) throws -> SecurityScopedBookmarkResolution
  public var create: @Sendable (URL) throws -> Data
  public var start: @Sendable (URL) -> Bool
  public var stop: @Sendable (URL) -> Void

  public init(
    resolve: @escaping @Sendable (Data) throws -> SecurityScopedBookmarkResolution,
    create: @escaping @Sendable (URL) throws -> Data,
    start: @escaping @Sendable (URL) -> Bool,
    stop: @escaping @Sendable (URL) -> Void
  ) {
    self.resolve = resolve
    self.create = create
    self.start = start
    self.stop = stop
  }

  public static let live = SecurityScopedBookmarkClient(
    resolve: { data in
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &stale)
      return SecurityScopedBookmarkResolution(url: url, isStale: stale)
    },
    create: { url in
      try (url as NSURL).bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    },
    start: { $0.startAccessingSecurityScopedResource() },
    stop: { $0.stopAccessingSecurityScopedResource() }
  )
}

public final class SecurityScopedResourceLease: @unchecked Sendable {
  public let url: URL
  private let lock = NSLock()
  private let stop: @Sendable (URL) -> Void
  private var active = true

  init(url: URL, stop: @escaping @Sendable (URL) -> Void) {
    self.url = url
    self.stop = stop
  }

  public func release() {
    let shouldStop = lock.withLock { () -> Bool in
      guard active else { return false }
      active = false
      return true
    }
    if shouldStop { stop(url) }
  }

  deinit {
    release()
  }
}

public struct SecurityScopedResourceResolution: Sendable {
  public let url: URL
  public let access: ResourceAccessState
  public let lease: SecurityScopedResourceLease?
  public let replacementBookmark: Data?

  public init(
    url: URL,
    access: ResourceAccessState,
    lease: SecurityScopedResourceLease?,
    replacementBookmark: Data?
  ) {
    self.url = url
    self.access = access
    self.lease = lease
    self.replacementBookmark = replacementBookmark
  }
}

public struct SecurityScopedResourceResolver: Sendable {
  public let client: SecurityScopedBookmarkClient

  public init(client: SecurityScopedBookmarkClient = .live) {
    self.client = client
  }

  public func resolve(resource: SandboxResource, bookmark: Data?, fallback: URL) -> SecurityScopedResourceResolution {
    guard let bookmark else {
      return SecurityScopedResourceResolution(
        url: fallback, access: ResourceAccessState(resource: resource, health: .needed), lease: nil,
        replacementBookmark: nil)
    }
    do {
      let resolved = try client.resolve(bookmark)
      guard client.start(resolved.url) else {
        return SecurityScopedResourceResolution(
          url: fallback,
          access: ResourceAccessState(
            resource: resource, health: .error("macOS denied access to the selected location.")),
          lease: nil, replacementBookmark: nil)
      }
      let lease = SecurityScopedResourceLease(url: resolved.url, stop: client.stop)
      guard resolved.isStale else {
        return SecurityScopedResourceResolution(
          url: resolved.url, access: ResourceAccessState(resource: resource, health: .granted), lease: lease,
          replacementBookmark: nil)
      }
      do {
        return SecurityScopedResourceResolution(
          url: resolved.url, access: ResourceAccessState(resource: resource, health: .granted), lease: lease,
          replacementBookmark: try client.create(resolved.url))
      } catch {
        return SecurityScopedResourceResolution(
          url: resolved.url, access: ResourceAccessState(resource: resource, health: .stale), lease: lease,
          replacementBookmark: nil)
      }
    } catch {
      return SecurityScopedResourceResolution(
        url: fallback,
        access: ResourceAccessState(resource: resource, health: .error("The saved access grant is no longer valid.")),
        lease: nil, replacementBookmark: nil)
    }
  }
}
