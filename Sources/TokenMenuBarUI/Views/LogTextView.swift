import AppKit
import SwiftUI
import TokenMenuBarCore

public struct LogTextView: NSViewRepresentable {
  public static var textColor: NSColor { SemanticColorPalette.color(for: .secondary) }

  public let entries: [LogEntry]
  public let height: CGFloat?
  public let bordered: Bool
  public let followsTail: Bool

  public init(entries: [LogEntry], height: CGFloat? = nil, bordered: Bool = true, followsTail: Bool = false) {
    self.entries = entries
    self.height = height
    self.bordered = bordered
    self.followsTail = followsTail
  }

  public func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = scrollView.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    textView.textColor = Self.textColor
    textView.drawsBackground = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.textContainerInset = CGSize(width: 8, height: 8)
    textView.setAccessibilityLabel("Log")
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.borderType = bordered ? .bezelBorder : .noBorder
    if let height { scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true }
    return scrollView
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  public func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    guard let change = context.coordinator.change(to: entries) else { return }
    let origin = scrollView.contentView.bounds.origin
    let previousHeight = change.prepended ? textView.frame.height : 0
    let wasAtEnd = textView.bounds.maxY - scrollView.documentVisibleRect.maxY <= 12
    let ranges = textView.selectedRanges
    switch change {
    case .append(let suffix):
      textView.textStorage?.append(NSAttributedString(string: suffix, attributes: textView.typingAttributes))
    case .prepend(let prefix):
      textView.textStorage?.insert(NSAttributedString(string: prefix, attributes: textView.typingAttributes), at: 0)
    case .replace:
      textView.string = Self.text(entries)
    }
    textView.selectedRanges = Self.adjusted(ranges, for: change, textLength: textView.string.utf16.count)
    if followsTail, wasAtEnd {
      textView.scrollToEndOfDocument(nil)
    } else {
      let verticalOffset = change.prepended ? max(textView.frame.height - previousHeight, 0) : 0
      scrollView.contentView.scroll(to: CGPoint(x: origin.x, y: origin.y + verticalOffset))
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
  }

  @MainActor
  public final class Coordinator {
    private var snapshot = EntrySnapshot.empty

    func change(to entries: [LogEntry]) -> Change? {
      guard !snapshot.matches(entries) else { return nil }
      guard snapshot.count > 0, !entries.isEmpty else {
        snapshot.replace(with: entries)
        return .replace
      }
      if entries.count > snapshot.count,
        snapshot.matchesPrefix(of: entries)
      {
        let appended = entries.dropFirst(snapshot.count)
        snapshot.append(contentsOf: appended)
        return .append(LogTextView.text(appended, leadingNewline: true))
      }
      let offset = entries.count - snapshot.count
      if offset > 0,
        snapshot.matchesSuffix(of: entries)
      {
        let prepended = entries.prefix(offset)
        snapshot.prepend(contentsOf: prepended)
        return .prepend(LogTextView.text(prepended, trailingNewline: true))
      }
      snapshot.replace(with: entries)
      return .replace
    }
  }

  private static func text<Entries: Collection>(_ entries: Entries) -> String where Entries.Element == LogEntry {
    text(entries, leadingNewline: false, trailingNewline: false)
  }

  private static func text<Entries: Collection>(
    _ entries: Entries, leadingNewline: Bool = false, trailingNewline: Bool = false
  ) -> String where Entries.Element == LogEntry {
    guard !entries.isEmpty else { return "" }
    var result = ""
    result.reserveCapacity(entries.reduce(0) { $0 + $1.line.utf8.count + 1 })
    if leadingNewline { result.append("\n") }
    for entry in entries {
      if result.last != nil, result.last != "\n" { result.append("\n") }
      result.append(entry.line)
    }
    if trailingNewline { result.append("\n") }
    return result
  }

  private static func adjusted(_ values: [NSValue], for change: Change, textLength: Int) -> [NSValue] {
    values.map {
      let range = $0.rangeValue
      let location = min(range.location + change.selectionOffset, textLength)
      return NSValue(range: NSRange(location: location, length: min(range.length, textLength - location)))
    }
  }

  enum Change {
    case append(String)
    case prepend(String)
    case replace

    var prepended: Bool {
      if case .prepend = self { return true }
      return false
    }

    var selectionOffset: Int {
      if case .prepend(let text) = self { return (text as NSString).length }
      return 0
    }
  }

  private struct EntrySnapshot {
    static let empty = EntrySnapshot(ids: [])

    private var ids: [UInt64]
    var count: Int { ids.count }

    mutating func append<Entries: Collection>(contentsOf entries: Entries) where Entries.Element == LogEntry {
      ids.append(contentsOf: entries.lazy.map(\.sequenceID))
    }

    mutating func prepend<Entries: Collection>(contentsOf entries: Entries) where Entries.Element == LogEntry {
      ids.insert(contentsOf: entries.lazy.map(\.sequenceID), at: 0)
    }

    mutating func replace(with entries: [LogEntry]) {
      ids = entries.map(\.sequenceID)
    }

    func matches(_ entries: [LogEntry]) -> Bool {
      ids.elementsEqual(entries.lazy.map(\.sequenceID))
    }

    func matchesPrefix(of entries: [LogEntry]) -> Bool {
      ids.elementsEqual(entries.prefix(count).lazy.map(\.sequenceID))
    }

    func matchesSuffix(of entries: [LogEntry]) -> Bool {
      ids.elementsEqual(entries.suffix(count).lazy.map(\.sequenceID))
    }
  }
}
