import Foundation

public enum SnapshotPersistenceFailure: Sendable, Equatable {
  case cacheLoad(String)
  case cacheWrite(String)
  case widgetWrite(String)

  public var message: String {
    switch self {
    case .cacheLoad(let detail): "snapshot cache load failed: \(detail)"
    case .cacheWrite(let detail): "snapshot cache write failed: \(detail)"
    case .widgetWrite(let detail): "widget snapshot write failed: \(detail)"
    }
  }
}

public struct SnapshotPersistenceWorkload: Sendable, Equatable {
  public fileprivate(set) var cacheLoads = 0
  public fileprivate(set) var cacheSubmissions = 0
  public fileprivate(set) var cacheWrites = 0
  public fileprivate(set) var coalescedCacheSubmissions = 0
  public fileprivate(set) var widgetSubmissions = 0
  public fileprivate(set) var widgetWrites = 0
  public fileprivate(set) var coalescedWidgetSubmissions = 0
  public fileprivate(set) var widgetReloads = 0

  public init() {}
}

private enum SnapshotCacheLoadResult: Sendable {
  case success([ProviderID: ProviderSnapshot])
  case failure(String)
}

public actor SnapshotPersistence {
  public typealias FailureHandler = @Sendable (SnapshotPersistenceFailure) async -> Void
  public typealias WidgetReload = @MainActor @Sendable () -> Void

  private let cache: SnapshotCache
  private let widgetStore: WidgetSnapshotStore?
  private let failureHandler: FailureHandler
  private let reloadWidgets: WidgetReload
  private var cachedLoad: [ProviderID: ProviderSnapshot]?
  private var cacheLoadTask: Task<SnapshotCacheLoadResult, Never>?
  private var pendingSnapshots: [ProviderID: ProviderSnapshot]?
  private var pendingWidget: WidgetSnapshot?
  private var lastWrittenSnapshots: [ProviderID: ProviderSnapshot]?
  private var lastWrittenWidget: WidgetSnapshot?
  private var cacheDrainTask: Task<Void, Never>?
  private var widgetDrainTask: Task<Void, Never>?
  public private(set) var workload = SnapshotPersistenceWorkload()

  public init(
    cache: SnapshotCache,
    widgetStore: WidgetSnapshotStore? = nil,
    failureHandler: @escaping FailureHandler = { _ in },
    reloadWidgets: @escaping WidgetReload = {}
  ) {
    self.cache = cache
    self.widgetStore = widgetStore
    self.failureHandler = failureHandler
    self.reloadWidgets = reloadWidgets
  }

  public func loadSnapshots() async -> [ProviderID: ProviderSnapshot] {
    if let cachedLoad { return cachedLoad }
    let task: Task<SnapshotCacheLoadResult, Never>
    if let cacheLoadTask {
      task = cacheLoadTask
    } else {
      let cache = cache
      let created: Task<SnapshotCacheLoadResult, Never> = Task.detached(priority: .utility) {
        do {
          return .success(try cache.read())
        } catch {
          return .failure(String(describing: error))
        }
      }
      cacheLoadTask = created
      task = created
    }
    let result = await task.value
    if let cachedLoad { return cachedLoad }
    workload.cacheLoads += 1
    cacheLoadTask = nil
    let snapshots: [ProviderID: ProviderSnapshot]
    switch result {
    case .success(let loaded): snapshots = loaded
    case .failure(let detail):
      snapshots = [:]
      await failureHandler(.cacheLoad(detail))
    }
    cachedLoad = snapshots
    return snapshots
  }

  public func submitSnapshots(_ snapshots: [ProviderID: ProviderSnapshot]) {
    workload.cacheSubmissions += 1
    if pendingSnapshots != nil { workload.coalescedCacheSubmissions += 1 }
    pendingSnapshots = snapshots
    guard cacheDrainTask == nil else { return }
    cacheDrainTask = Task { [weak self] in await self?.drainSnapshots() }
  }

  public func submitWidget(_ snapshot: WidgetSnapshot) {
    guard let widgetStore else { return }
    workload.widgetSubmissions += 1
    if pendingWidget != nil { workload.coalescedWidgetSubmissions += 1 }
    pendingWidget = snapshot
    guard widgetDrainTask == nil else { return }
    widgetDrainTask = Task { [weak self] in await self?.drainWidgets(widgetStore) }
  }

  public func flush() async {
    while cacheDrainTask != nil || widgetDrainTask != nil {
      let cacheTask = cacheDrainTask
      let widgetTask = widgetDrainTask
      await cacheTask?.value
      await widgetTask?.value
    }
  }

  private func drainSnapshots() async {
    while let snapshots = pendingSnapshots {
      pendingSnapshots = nil
      guard snapshots != lastWrittenSnapshots else { continue }
      let cache = cache
      let failure = await Task.detached(priority: .utility) { () -> String? in
        do {
          try cache.store(snapshots)
          return nil
        } catch {
          return String(describing: error)
        }
      }.value
      if let failure {
        await failureHandler(.cacheWrite(failure))
      } else {
        lastWrittenSnapshots = snapshots
        workload.cacheWrites += 1
      }
    }
    cacheDrainTask = nil
  }

  private func drainWidgets(_ widgetStore: WidgetSnapshotStore) async {
    while let snapshot = pendingWidget {
      pendingWidget = nil
      guard snapshot != lastWrittenWidget else { continue }
      let failure = await Task.detached(priority: .utility) { () -> String? in
        do {
          try widgetStore.write(snapshot)
          return nil
        } catch {
          return String(describing: error)
        }
      }.value
      if let failure {
        await failureHandler(.widgetWrite(failure))
      } else {
        lastWrittenWidget = snapshot
        workload.widgetWrites += 1
        await reloadWidgets()
        workload.widgetReloads += 1
      }
    }
    widgetDrainTask = nil
  }
}
