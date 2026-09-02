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
