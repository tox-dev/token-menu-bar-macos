import Foundation

public enum ExportCommand: String, CaseIterable, Sendable {
  case icons = "--export-icon"
  case menuBar = "--export-menubar"
  case popover = "--export-popover"

  public static func parse(_ arguments: [String]) -> (command: ExportCommand, directory: URL)? {
    for command in allCases {
      guard let index = arguments.firstIndex(of: command.rawValue), index + 1 < arguments.count else { continue }
      return (command, URL(fileURLWithPath: arguments[index + 1]))
    }
    return nil
  }

  public var failureMessage: String {
    switch self {
    case .icons: "icon export failed"
    case .menuBar: "menu bar export failed"
    case .popover: "popover export failed"
    }
  }
}

/// Everything the executable does instead of starting the app: the image exports and the usage dump for scripts.
public enum ExportInvocation: Sendable, Equatable {
  case files(ExportCommand, directory: URL)
  case usageJSON

  public static let usageJSONFlag = "--usage-json"

  public static func parse(_ arguments: [String]) -> ExportInvocation? {
    if arguments.contains(usageJSONFlag) { return .usageJSON }
    return ExportCommand.parse(arguments).map { .files($0.command, directory: $0.directory) }
  }

  public var failureMessage: String {
    switch self {
    case .files(let command, _): command.failureMessage
    case .usageJSON: "usage export failed"
    }
  }
}

public enum UsageExportCommand {
  public struct NoCachedUsage: Error, CustomStringConvertible, Equatable {
    public init() {}

    public var description: String {
      "no cached usage yet; launch the app and let it finish one refresh"
    }
  }

  public static func output(cache: SnapshotCache) throws -> String {
    let snapshots = try cache.read()
    guard !snapshots.isEmpty else { throw NoCachedUsage() }
    return String(decoding: try UsageExport(snapshots: snapshots).json(), as: UTF8.self)
  }
}
