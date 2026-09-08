import SwiftUI
import TokenMenuBarCore

public struct WindowHelpView: View {
  public let row: WindowRow

  public init(row: WindowRow) {
    self.row = row
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(row.window.label).font(.headline)
      Text(
        "Used \(Format.percent(row.window.usedPercent, decimals: 1)), "
          + "\(Format.percent(row.window.remainingPercent, decimals: 1)) left"
      )
      if let duration = row.window.duration { Text("Window: \(Format.duration(duration))") }
      if let expected = row.pace.expectedPercent { Text("Even pace would be \(Format.percent(expected)) by now") }
      if let ratio = row.pace.ratio { Text("Pace ratio: \(ratio.formatted(.number.precision(.fractionLength(2))))×") }
      Text("Severity: \(row.window.severity.rawValue)")
    }
    .font(.callout)
  }
}
