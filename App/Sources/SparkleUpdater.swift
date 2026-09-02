import AppKit
import Sparkle
import TokenMenuBarUI

@MainActor
final class SparkleUpdater: UpdaterHook {
  private let controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  var canCheck: Bool {
    controller.updater.canCheckForUpdates
  }

  var automaticallyChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}
