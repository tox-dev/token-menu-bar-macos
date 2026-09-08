import SwiftUI
import TokenMenuBarCore

public struct WindowRowView: View {
  @Environment(\.usageValueAppearance) private var valueAppearance
  public let row: WindowRow
  /// False when neighbouring windows share this reset and the group prints it once underneath them all.
  public let showsReset: Bool
  private let fixedNow: Date?
  private let fixedIncreaseContrast: Bool
  private let environment: UIEnvironment?

  public init(row: WindowRow, now: Date, showsReset: Bool = true, increaseContrast: Bool = false) {
    self.row = row
    self.showsReset = showsReset
    fixedNow = now
    fixedIncreaseContrast = increaseContrast
    environment = nil
  }

  public init(row: WindowRow, environment: UIEnvironment, showsReset: Bool = true) {
    self.row = row
    self.showsReset = showsReset
    fixedNow = nil
    fixedIncreaseContrast = false
    self.environment = environment
  }

  public var body: some View {
    ResponsivePanelLayout {
      wideRow.frame(minWidth: 680)
    } narrow: {
      narrowRow
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .richHelp(TooltipContent(title: row.window.label, body: row.helpText))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityValue(accessibilityValue)
  }

  private var wideRow: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(row.window.label).font(.callout.weight(.medium))
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(row.detail).font(.caption.monospaced()).semanticForeground(.secondary)
          if !row.window.isActive {
            Text("inactive").font(.caption2).semanticForeground(.secondary)
          }
          if !row.isSelected {
            Text("Not in menu bar").font(.caption2).semanticForeground(.secondary)
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 240, alignment: .leading)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          UsageBar(
            percent: row.window.usedPercent, expectedPercent: row.pace.expectedPercent,
            color: usageBarColor, label: row.window.label, outlined: increaseContrast)
          Text(row.percentText)
            .font(.callout.monospacedDigit().weight(.semibold))
            .semanticForeground(valueAppearance.foreground)
            .frame(width: 52, alignment: .trailing)
        }
        Text(row.pace.comparison(now: currentNow))
          .font(.caption)
          .semanticForeground(valueAppearance.foreground)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(minWidth: 100, idealWidth: 250, maxWidth: .infinity, alignment: .leading)
      if showsReset {
        ResetDeadlineText(deadline: row.resetDeadline, now: currentNow, alignment: .trailing)
          .frame(width: 150, alignment: .trailing)
      } else {
        Color.clear.frame(width: 150, height: 1)
      }
    }
    .frame(minHeight: 34)
  }

  private var narrowRow: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(row.window.label).font(.callout.weight(.medium))
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.detail).font(.caption.monospaced()).semanticForeground(.secondary)
            if !row.window.isActive { Text("inactive").font(.caption2).semanticForeground(.secondary) }
            if !row.isSelected { Text("Not in menu bar").font(.caption2).semanticForeground(.secondary) }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Text(row.percentText)
          .font(.callout.monospacedDigit().weight(.semibold))
          .semanticForeground(valueAppearance.foreground)
      }
      UsageBar(
        percent: row.window.usedPercent, expectedPercent: row.pace.expectedPercent,
        color: usageBarColor, label: row.window.label, outlined: increaseContrast)
      Text(row.pace.comparison(now: currentNow))
        .font(.caption)
        .semanticForeground(valueAppearance.foreground)
        .fixedSize(horizontal: false, vertical: true)
      if showsReset {
        ResetDeadlineText(deadline: row.resetDeadline, now: currentNow, alignment: .leading)
      }
    }
  }

  var usageBarColor: Color {
    if valueAppearance == .stale { return Color(.tertiary) }
    return Color(
      UsageColor.color(
        pace: row.pace.status, percent: row.window.usedPercent, contrast: UsageContrast(increased: increaseContrast)))
  }

  var increaseContrast: Bool {
    environment.map(\.increaseContrast) ?? fixedIncreaseContrast
  }

  var accessibilityValue: String {
    valueAppearance.accessibilityValue(row.accessibilityValue(at: currentNow))
  }

  var accessibilityLabelText: String {
    "\(row.key.provider.displayName) \(row.window.label), \(row.detail)"
  }

  /// Pace state belongs to the bar; text stays readable on both panel appearances.
  var paceColor: Color {
    .primary
  }

  private var currentNow: Date {
    environment?.usageDeadlineNow ?? fixedNow!
  }
}

struct ResetDeadlineText: View {
  let deadline: UsageDeadline
  let now: Date
  let alignment: HorizontalAlignment

  var body: some View {
    let lines = deadline.lines(at: now)
    VStack(alignment: alignment, spacing: 1) {
      ForEach(lines.indices, id: \.self) { index in
        Text(lines[index]).fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.caption.monospacedDigit())
    .semanticForeground(.secondary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(deadline.text(at: now))
  }
}
