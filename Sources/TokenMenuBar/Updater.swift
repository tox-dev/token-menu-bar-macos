import TokenMenuBarCore
import TokenMenuBarUI

@MainActor
enum Updater {
  static func make(appInfo: AppInfo) -> (any UpdaterHook)? {
    guard appInfo.canSelfUpdate else { return nil }
    #if DIRECT
      return SparkleUpdater()
    #else
      return nil
    #endif
  }
}
