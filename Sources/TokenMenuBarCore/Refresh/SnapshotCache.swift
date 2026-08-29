import Foundation

public struct SnapshotCache: Sendable {
  public let url: URL?

  public init(url: URL?) {
    self.url = url
  }

  public func load() -> [ProviderID: ProviderSnapshot] {
    guard let url, let data = try? Data(contentsOf: url) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let stored = (try? decoder.decode([ProviderID: ProviderSnapshot].self, from: data)) ?? [:]
    return stored.mapValues { snapshot in
      ProviderSnapshot(
        provider: snapshot.provider, identity: snapshot.identity, windows: snapshot.windows,
        credits: snapshot.credits, spend: snapshot.spend, resetCredits: snapshot.resetCredits,
        notices: snapshot.notices, localUsage: snapshot.localUsage, source: .cache, fetchedAt: snapshot.fetchedAt)
    }
  }

  public func store(_ snapshots: [ProviderID: ProviderSnapshot]) throws {
    guard let url else { return }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(snapshots).write(to: url, options: .atomic)
  }
}
