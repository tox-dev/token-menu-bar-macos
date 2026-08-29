import TokenMenuBarUI

@MainActor
enum Updater {
  static func make() -> (any UpdaterHook)? {
    #if DIRECT
      SparkleUpdater()
    #else
      nil
    #endif
  }
}
