import Foundation

/// The right-click menu as data, so what it contains is decided and tested without AppKit.
public enum MenuCommand: Sendable, Equatable, Identifiable {
  case refresh
  case separator
  case openUsagePage(ProviderID)
  case checkForUpdates
  case quit(appName: String)

  public var id: String {
    switch self {
    case .refresh: "refresh"
    case .separator: "separator"
    case .openUsagePage(let provider): "usage:\(provider.rawValue)"
    case .checkForUpdates: "updates"
    case .quit: "quit"
    }
  }

  public var title: String {
    switch self {
    case .refresh: "Refresh Now"
    case .separator: ""
    case .openUsagePage(let provider): "Open \(provider.displayName) usage page"
    case .checkForUpdates: "Check for Updates…"
    case .quit(let appName): "Quit \(appName)"
    }
  }

  public var keyEquivalent: String {
    switch self {
    case .refresh: "r"
    case .quit: "q"
    default: ""
    }
  }

  public static func menu(providers: [ProviderID], canCheckForUpdates: Bool, appName: String) -> [MenuCommand] {
    var commands: [MenuCommand] = [.refresh, .separator]
    commands += providers.map(MenuCommand.openUsagePage)
    if canCheckForUpdates { commands += [.separator, .checkForUpdates] }
    return commands + [.separator, .quit(appName: appName)]
  }
}
