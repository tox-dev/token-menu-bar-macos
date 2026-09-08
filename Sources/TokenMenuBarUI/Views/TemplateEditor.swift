import AppKit
import SwiftUI

public struct TemplateEditor: NSViewRepresentable {
  @Binding private var text: String

  public init(text: Binding<String>) {
    _text = text
  }

  public func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    let editor = scroll.documentView as! NSTextView
    editor.delegate = context.coordinator
    editor.isRichText = false
    editor.allowsUndo = true
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    editor.textColor = .labelColor
    editor.textContainerInset = CGSize(width: 4, height: 4)
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = true
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    // SwiftUI's TextEditor attaches these to the scroll container on macOS 14, leaving its editable child unnamed.
    editor.setAccessibilityLabel("Template")
    editor.setAccessibilityIdentifier("status-template")
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    return scroll
  }

  public func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.text = $text
    let editor = scroll.documentView as! NSTextView
    editor.isEditable = context.environment.isEnabled
    editor.setAccessibilityEnabled(context.environment.isEnabled)
    guard editor.string != text else { return }
    let selection = editor.selectedRange()
    editor.string = text
    let location = min(selection.location, text.utf16.count)
    editor.setSelectedRange(NSRange(location: location, length: min(selection.length, text.utf16.count - location)))
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  @MainActor
  public final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>

    init(text: Binding<String>) {
      self.text = text
    }

    public func textDidChange(_ notification: Notification) {
      text.wrappedValue = (notification.object as! NSTextView).string
    }
  }
}
