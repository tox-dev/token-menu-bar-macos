import CoreGraphics
import Foundation
import TokenMenuBarCore

struct FrameSample: Codable {
  let minX: CGFloat
  let minY: CGFloat
  let width: CGFloat
  let height: CGFloat

  var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

  init(_ frame: CGRect) {
    minX = frame.minX
    minY = frame.minY
    width = frame.width
    height = frame.height
  }
}

struct WindowFrameTimelineSample: Codable {
  let elapsed: TimeInterval
  let frame: FrameSample
}

final class WindowFrameSampler: @unchecked Sendable {
  private let identifyProcess: @Sendable () -> pid_t?
  private var processIdentifier: pid_t?
  private let started = ProcessInfo.processInfo.systemUptime
  private let queue = DispatchQueue(label: "dev.tox.token-menu-bar.frame-sampler")
  private let lock = NSLock()
  private var samples: [WindowFrameTimelineSample] = []
  private var timer: (any DispatchSourceTimer)?

  init(processIdentifier: pid_t) {
    identifyProcess = { processIdentifier }
  }

  init(snapshotURL: URL) {
    identifyProcess = {
      guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
      return try? JSONDecoder().decode(ProcessPerformanceSnapshot.self, from: data).processIdentifier
    }
  }

  func start() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(6), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.capture() }
    lock.withLock { self.timer = timer }
    timer.resume()
  }

  func stop() -> [WindowFrameTimelineSample] {
    let timer = lock.withLock { () -> (any DispatchSourceTimer)? in
      let timer = self.timer
      self.timer = nil
      return timer
    }
    timer?.cancel()
    queue.sync {}
    return lock.withLock { samples }
  }

  func isStable(within deadline: TimeInterval = .infinity) -> Bool {
    lock.withLock {
      guard let last = samples.last else { return false }
      let recent = samples.reversed().prefix {
        abs($0.frame.minX - last.frame.minX) < 0.5 && abs($0.frame.minY - last.frame.minY) < 0.5
          && abs($0.frame.width - last.frame.width) < 0.5 && abs($0.frame.height - last.frame.height) < 0.5
      }
      let inBudget = recent.filter { $0.elapsed <= deadline }
      return inBudget.count >= 3 && inBudget.first!.elapsed - inBudget.last!.elapsed >= 0.032
    }
  }

  private func capture() {
    guard let processIdentifier = processIdentifier ?? identifyProcess() else { return }
    self.processIdentifier = processIdentifier
    guard
      let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[CFString: Any]],
      let frame = values.compactMap({ value -> CGRect? in
        guard
          (value[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier,
          let bounds = value[kCGWindowBounds] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
          frame.width >= 500, frame.height >= 100
        else { return nil }
        return frame
      }).max(by: { $0.width * $0.height < $1.width * $1.height })
    else { return }
    let sample = WindowFrameTimelineSample(
      elapsed: ProcessInfo.processInfo.systemUptime - started, frame: FrameSample(frame))
    lock.withLock { samples.append(sample) }
  }
}
