import AppKit
import Sparkle
import TokenMenuBarUI

@MainActor
final class SparkleUpdater: UpdaterHook {
  private let controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
  private var canCheckObservation: NSKeyValueObservation?
  var onCanCheckChange: (@MainActor (Bool) -> Void)?

  var canCheck: Bool {
    controller.updater.canCheckForUpdates
  }

  var automaticallyChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  func start() {
    canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
      [weak self] updater, _ in
      Task { @MainActor [weak self] in self?.onCanCheckChange?(updater.canCheckForUpdates) }
    }
    controller.startUpdater()
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}
