import AppKit
import SwiftUI
import TokenMenuBarCore

extension Color {
  public init(_ hsb: HSBColor) {
    self.init(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
  }
}

public struct UsageBar: View {
  public let percent: Double
  public let expectedPercent: Double?
  public let color: Color
  public let height: CGFloat
  public let label: String

  public init(
    percent: Double, expectedPercent: Double? = nil, color: Color, height: CGFloat = 5, label: String
  ) {
    self.percent = percent
    self.expectedPercent = expectedPercent
    self.color = color
    self.height = height
    self.label = label
  }

  public var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.06))
        let fraction = min(max(percent, 0), 100) / 100
        if fraction > 0 {
          Capsule()
            .fill(color.gradient)
            .frame(width: max(proxy.size.width * fraction, height))
        }
        if let expectedPercent {
          let expected = min(max(expectedPercent, 0), 100) / 100
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.primary)
            .frame(width: 2, height: height + 4)
            .offset(x: max(min(proxy.size.width * expected - 1, proxy.size.width - 2), 0))
        }
      }
    }
    .frame(height: height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(
      expectedPercent.map { "\(Format.percent(percent)) used, expected \(Format.percent($0))" }
        ?? "\(Format.percent(percent)) used")
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
        .semanticForeground(tone == .warning ? .warning : .secondary)
        .accessibilityHidden(true)
      LinkifiedText(text)
        .font(.body)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
    .padding(8)
    .background(
      Color(tone == .warning ? .warning : .secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8)
    )
    .accessibilityElement(children: .combine)
    // The tint is the only thing that separates a warning from a note, so the label says which one this is.
    .accessibilityLabel("\(tone == .warning ? "Warning" : "Note"): \(text)")
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
    // Compiling a Regex costs more than scanning the string, and every banner does this on every body evaluation.
    for span in links(in: text) {
      if let range = Range(span, in: result), let url = URL(string: String(text[span])) {
        result[range].link = url
        result[range].underlineStyle = .single
      }
    }
    return result
  }

  /// The `http://` and `https://` runs in `text`, each ending at the first space or closing bracket.
  static func links(in text: String) -> [Range<String.Index>] {
    var spans: [Range<String.Index>] = []
    var cursor = text.startIndex
    while let scheme = text.range(of: "http", range: cursor..<text.endIndex) {
      cursor = scheme.upperBound
      let rest = text[scheme.upperBound...]
      guard rest.hasPrefix("://") || rest.hasPrefix("s://") else { continue }
      let end = text[scheme.lowerBound...].firstIndex { $0.isWhitespace || $0 == ")" } ?? text.endIndex
      spans.append(scheme.lowerBound..<end)
      cursor = end
    }
    return spans
  }
}

public struct NativeActionButton<Label: View>: View {
  public let intent: ControlIntent
  public let action: () -> Void
  public let label: Label

  public init(
    intent: ControlIntent = .action, action: @escaping () -> Void, @ViewBuilder label: () -> Label
  ) {
    self.intent = intent
    self.action = action
    self.label = label()
  }

  public var body: some View {
    Button(role: role, action: action) { label }
      .buttonStyle(.bordered)
      .semanticControl(intent)
  }

  var role: ButtonRole? {
    switch intent {
    case .destructive: .destructive
    default: nil
    }
  }
}

public struct NativeSegmentedControl<Value: Hashable>: NSViewRepresentable {
  @Binding private var selection: Value
  private let values: [Value]
  private let labels: [String]
  private let accessibilityLabel: String
  private let accessibilityIdentifier: String?

  public init(
    _ items: [(value: Value, label: String)],
    selection: Binding<Value>,
    accessibilityLabel: String,
    accessibilityIdentifier: String? = nil
  ) {
    values = items.map(\.value)
    labels = items.map(\.label)
    _selection = selection
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityIdentifier = accessibilityIdentifier
  }

  public func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: labels,
      trackingMode: .selectOne,
      target: context.coordinator,
      action: #selector(Coordinator.changed(_:)))
    control.controlSize = .small
    control.segmentStyle = .automatic
    control.setAccessibilityLabel(accessibilityLabel)
    if let accessibilityIdentifier { control.setAccessibilityIdentifier(accessibilityIdentifier) }
    return control
  }

  public func updateNSView(_ control: NSSegmentedControl, context: Context) {
    let selectedSegment = values.firstIndex(of: selection) ?? -1
    if control.selectedSegment != selectedSegment { control.selectedSegment = selectedSegment }
    if control.isEnabled != context.environment.isEnabled { control.isEnabled = context.environment.isEnabled }
    context.coordinator.selection = $selection
    context.coordinator.values = values
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection, values: values)
  }

  @MainActor
  public final class Coordinator: NSObject {
    var selection: Binding<Value>
    var values: [Value]

    init(selection: Binding<Value>, values: [Value]) {
      self.selection = selection
      self.values = values
    }

    @objc func changed(_ sender: NSSegmentedControl) {
      guard values.indices.contains(sender.selectedSegment) else { return }
      selection.wrappedValue = values[sender.selectedSegment]
    }
  }
}

extension NativeActionButton where Label == Text {
  public init(_ title: String, intent: ControlIntent = .action, action: @escaping () -> Void) {
    self.init(intent: intent, action: action) { Text(title) }
  }
}

public struct NativeIconButton: View {
  public let symbol: String
  public let accessibilityLabel: String
  public let explanation: String
  public let intent: ControlIntent
  public let action: () -> Void

  public init(
    symbol: String,
    accessibilityLabel: String,
    explanation: String? = nil,
    intent: ControlIntent = .action,
    action: @escaping () -> Void
  ) {
    self.symbol = symbol
    self.accessibilityLabel = accessibilityLabel
    self.explanation = explanation ?? accessibilityLabel
    self.intent = intent
    self.action = action
  }

  public init(symbol: String, help: String, intent: ControlIntent = .action, action: @escaping () -> Void) {
    self.init(symbol: symbol, accessibilityLabel: help, explanation: help, intent: intent, action: action)
  }

  public var body: some View {
    NativeActionButton(intent: intent, action: action) {
      Label(accessibilityLabel, systemImage: symbol).labelStyle(.iconOnly)
    }
    .buttonBorderShape(.circle)
    .richHelp(TooltipContent(title: accessibilityLabel, body: explanation))
    .accessibilityLabel(accessibilityLabel)
  }
}

public typealias IconButton = NativeIconButton

public struct SectionLabel: View {
  public let title: String

  public init(_ title: String) {
    self.title = title
  }

  public var body: some View {
    Text(title)
      .textCase(.uppercase)
      .font(.caption2.weight(.semibold))
      .tracking(0.6)
      .semanticForeground(.secondary)
      .accessibilityAddTraits(.isHeader)
  }
}

public struct PanelSection<Content: View>: View {
  public let title: String
  public let content: Content

  public init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel(title)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

public struct ResponsivePanelLayout<Wide: View, Narrow: View>: View {
  public let wide: Wide
  public let narrow: Narrow
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(@ViewBuilder wide: () -> Wide, @ViewBuilder narrow: () -> Narrow) {
    self.wide = wide()
    self.narrow = narrow()
  }

  public var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      narrow
    } else {
      ViewThatFits(in: .horizontal) {
        wide
        narrow
      }
    }
  }
}

public struct PanelRow<Content: View>: View {
  public let title: String
  public let labelWidth: CGFloat
  public let content: Content

  public init(_ title: String, labelWidth: CGFloat = 116, @ViewBuilder content: () -> Content) {
    self.title = title
    self.labelWidth = labelWidth
    self.content = content()
  }

  public var body: some View {
    ResponsivePanelLayout {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        label.frame(width: labelWidth, alignment: .leading)
        content.frame(maxWidth: .infinity, alignment: .leading)
      }
    } narrow: {
      VStack(alignment: .leading, spacing: 5) {
        if !title.isEmpty { label }
        content.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var label: some View {
    Text(title).semanticForeground(.secondary)
  }
}

public struct ChipView: View {
  public let chip: Chip
  public let onCopy: (String) -> Void

  public init(chip: Chip, onCopy: @escaping (String) -> Void) {
    self.chip = chip
    self.onCopy = onCopy
  }

  public var body: some View {
    ControlGroup {
      Button(chip.text, action: primaryAction)
        .accessibilityHint("Copies this value")
      Button(action: copyAction) { Label("Copy \(chip.text)", systemImage: "doc.on.doc").labelStyle(.iconOnly) }
        .richHelp(TooltipContent(title: "Copy", body: "Copies this value to the clipboard."))
        .accessibilityLabel("Copy \(chip.text)")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .semanticControl(.action)
    .contextMenu {
      Button("Copy", systemImage: "doc.on.doc", action: copyAction)
    }
  }

  public func primaryAction() {
    onCopy(chip.text)
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

  public func makeCache(subviews: Subviews) -> Cache {
    Cache()
  }

  public func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache = Cache()
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let rows = layoutRows(width: proposal.width ?? .infinity, subviews: subviews, cache: &cache)
    let height = rows.map { $0.height }.reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
    let width = rows.map { $0.width }.max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    var rowTop = bounds.minY
    for row in layoutRows(width: bounds.width, subviews: subviews, cache: &cache) {
      var itemLeft = bounds.minX
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: itemLeft, y: rowTop + (row.height - item.size.height) / 2), proposal: .unspecified)
        itemLeft += item.size.width + horizontalSpacing
      }
      rowTop += row.height + verticalSpacing
    }
  }

  public struct Cache {
    var width: CGFloat?
    var rows: [Row] = []
  }

  struct Row {
    var items: [(index: Int, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  func layoutRows(width: CGFloat, subviews: Subviews, cache: inout Cache) -> [Row] {
    if cache.width == width { return cache.rows }
    var rows: [Row] = []
    var current = Row()
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let spacing = current.items.isEmpty ? 0 : horizontalSpacing
      if !current.items.isEmpty, current.width + spacing + size.width > width {
        rows.append(current)
        current = Row()
      }
      current.items.append((index, size))
      current.width += (current.items.count == 1 ? 0 : horizontalSpacing) + size.width
      current.height = max(current.height, size.height)
    }
    if !current.items.isEmpty { rows.append(current) }
    cache.width = width
    cache.rows = rows
    return rows
  }
}

public struct SizeKey: PreferenceKey {
  public static let defaultValue: CGSize = .zero

  /// Keeping the last non-zero value would make a second publisher anywhere in the subtree win by reduction order,
  /// silently sizing the popover to some inner view.
  public static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    let next = nextValue()
    value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
  }
}

extension View {
  /// Reports this view's size to the enclosing `onPreferenceChange(SizeKey.self)` without observing it here.
  public func publishSize() -> some View {
    background(GeometryReader { proxy in Color.clear.preference(key: SizeKey.self, value: proxy.size) })
  }

  public func measureSize(_ onChange: @escaping @MainActor @Sendable (CGSize) -> Void) -> some View {
    publishSize().onPreferenceChange(SizeKey.self) { size in Task { @MainActor in onChange(size) } }
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
      Text(title).font(.callout).semanticForeground(.secondary)
      Text(value).font(.body.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .richHelp(TooltipContent(title: title, body: help))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title): \(value)")
  }
}

public struct HelpText: View {
  public let text: String

  public init(_ text: String) {
    self.text = text
  }

  public var body: some View {
    Text(text).font(.callout).frame(idealWidth: 260, maxWidth: 260, alignment: .leading)
  }
}

public struct EmptyStateView: View {
  public let title: String
  public let systemImage: String
  public let description: String

  public init(title: String, systemImage: String, description: String) {
    self.title = title
    self.systemImage = systemImage
    self.description = description
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage).font(.system(size: 26)).semanticForeground(.secondary).frame(width: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(description).font(.callout).semanticForeground(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
