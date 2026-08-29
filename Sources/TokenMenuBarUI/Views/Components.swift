import SwiftUI
import TokenMenuBarCore

extension Color {
  public init(_ hsb: HSBColor) {
    self.init(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
  }
}

public struct UsageBar: View {
  public let percent: Double
  public let color: Color
  public let height: CGFloat

  public init(percent: Double, color: Color, height: CGFloat = 6) {
    self.percent = percent
    self.color = color
    self.height = height
  }

  public var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.1))
        Capsule().fill(color).frame(width: max(proxy.size.width * min(max(percent, 0), 100) / 100, 4))
      }
    }
    .frame(height: height)
    .accessibilityLabel(Format.percent(percent))
  }
}

public struct Banner: View {
  public enum Tone {
    case warning
    case info
  }

  public let text: String
  public let tone: Tone

  public init(_ text: String, tone: Tone = .warning) {
    self.text = text
    self.tone = tone
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
        .foregroundStyle(tone == .warning ? Color.orange : Color.accentColor)
      LinkifiedText(text)
        .font(.body)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(8)
    .background(
      (tone == .warning ? Color.orange : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 8)
    )
    .accessibilityLabel(text)
  }
}

public struct LinkifiedText: View {
  public let text: String

  public init(_ text: String) {
    self.text = text
  }

  public var body: some View {
    Text(Self.attributed(text))
  }

  public static func attributed(_ text: String) -> AttributedString {
    var result = AttributedString(text)
    let pattern = try! Regex("https?://[^\\s)]+")
    for match in text.matches(of: pattern) {
      if let range = Range(match.range, in: result), let url = URL(string: String(text[match.range])) {
        result[range].link = url
        result[range].underlineStyle = .single
      }
    }
    return result
  }
}

public struct ChipView: View {
  public let chip: Chip
  public let onCopy: (String) -> Void
  public let onOpen: (URL) -> Void

  public init(chip: Chip, onCopy: @escaping (String) -> Void, onOpen: @escaping (URL) -> Void) {
    self.chip = chip
    self.onCopy = onCopy
    self.onOpen = onOpen
  }

  public var body: some View {
    HStack(spacing: 0) {
      Button(chip.text, action: primaryAction)
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.vertical, 3)
      Button(action: copyAction) { Image(systemName: "doc.on.doc").font(.caption2) }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityLabel("Copy \(chip.text)")
    }
    .font(.callout)
    .background(Color.primary.opacity(0.08), in: Capsule())
    .contextMenu {
      if let link = chip.link { Button("Open") { onOpen(link) } }
      Button("Copy") { copyAction() }
    }
  }

  public func primaryAction() {
    if let link = chip.link {
      onOpen(link)
    } else {
      onCopy(chip.text)
    }
  }

  public func copyAction() {
    onCopy(chip.text)
  }
}

public struct WrappingHStack: Layout {
  public let horizontalSpacing: CGFloat
  public let verticalSpacing: CGFloat

  public init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 6) {
    self.horizontalSpacing = horizontalSpacing
    self.verticalSpacing = verticalSpacing
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = layoutRows(width: proposal.width ?? .infinity, subviews: subviews)
    let height = rows.map { $0.height }.reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
    let width = rows.map { $0.width }.max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in layoutRows(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
        x += size.width + horizontalSpacing
      }
      y += row.height + verticalSpacing
    }
  }

  struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  func layoutRows(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let spacing = current.indices.isEmpty ? 0 : horizontalSpacing
      if !current.indices.isEmpty, current.width + spacing + size.width > width {
        rows.append(current)
        current = Row()
      }
      current.indices.append(index)
      current.width += (current.indices.count == 1 ? 0 : horizontalSpacing) + size.width
      current.height = max(current.height, size.height)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}

public struct SizeKey: PreferenceKey {
  public static let defaultValue: CGSize = .zero
  public static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

extension View {
  public func measureSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
    background(GeometryReader { proxy in Color.clear.preference(key: SizeKey.self, value: proxy.size) })
      .onPreferenceChange(SizeKey.self) { size in Task { @MainActor in onChange(size) } }
  }
}

public struct MetricCell: View {
  public let title: String
  public let value: String
  public let help: String

  public init(title: String, value: String, help: String) {
    self.title = title
    self.value = value
    self.help = help
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.callout).foregroundStyle(.secondary)
      Text(value).font(.body.monospacedDigit()).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .hoverHelp { Text(help).font(.callout).frame(maxWidth: 260) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(value)")
  }
}
