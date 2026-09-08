import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarUI

@Test @MainActor func templateEditorNamesItsEditableChild() throws {
  let hosting = host(TemplateEditor(text: .constant("{label}\n{pct}")), width: 400, height: 54)
  let editor: NSTextView = try #require(findView(hosting))

  #expect(editor.accessibilityLabel() == "Template")
  #expect(editor.accessibilityIdentifier() == "status-template")
  #expect(editor.isEditable)
  #expect(editor.string == "{label}\n{pct}")
}

@Test @MainActor func templateEditorKeepsTokensLiteral() throws {
  let hosting = host(TemplateEditor(text: .constant("{label}")), width: 400, height: 54)
  let editor: NSTextView = try #require(findView(hosting))

  #expect(!editor.isRichText)
  #expect(editor.allowsUndo)
  #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
  #expect(!editor.isAutomaticDashSubstitutionEnabled)
  #expect(!editor.isAutomaticTextReplacementEnabled)
  #expect(!editor.isAutomaticSpellingCorrectionEnabled)
  #expect(!editor.isContinuousSpellCheckingEnabled)
}

@Test @MainActor func templateEditorWrapsInsideAnOverlayScrollView() throws {
  let hosting = host(TemplateEditor(text: .constant("{label}")), width: 400, height: 54)
  let scroll: NSScrollView = try #require(findView(hosting))
  let editor = try #require(scroll.documentView as? NSTextView)

  #expect(scroll.hasVerticalScroller)
  #expect(!scroll.hasHorizontalScroller)
  #expect(scroll.autohidesScrollers)
  #expect(scroll.scrollerStyle == .overlay)
  #expect(editor.textContainer?.widthTracksTextView == true)
  #expect(!editor.isHorizontallyResizable)
}

@Test(arguments: [["{label}\n{pct}"], ["{label}", "\n", "{pct}"]]) @MainActor
func templateEditorWritesMultilineEditsToItsBinding(edits: [String]) throws {
  var text = "old"
  let hosting = host(TemplateEditor(text: Binding(get: { text }, set: { text = $0 })), width: 400, height: 54)
  let editor: NSTextView = try #require(findView(hosting))

  editor.selectAll(nil)
  for edit in edits { editor.insertText(edit, replacementRange: editor.selectedRange()) }

  #expect(text == "{label}\n{pct}")
}

@Test(arguments: [
  ("{provider}\n{label}:{pct}", NSRange(location: 8, length: 3)),
  ("", NSRange(location: 0, length: 0)),
  ("𐐷", NSRange(location: 2, length: 0)),
]) @MainActor
func templateEditorClampsSelectionAfterExternalChanges(replacement: String, selection: NSRange) throws {
  let hosting = host(TemplateEditor(text: .constant("{label}\n{pct}")), width: 400, height: 54)
  let editor: NSTextView = try #require(findView(hosting))
  editor.setSelectedRange(NSRange(location: 8, length: 3))

  hosting.rootView = TemplateEditor(text: .constant(replacement))
  hosting.layoutSubtreeIfNeeded()

  #expect(editor.string == replacement)
  #expect(editor.selectedRange() == selection)
}

@Test @MainActor func templateEditorPreservesSelectionWhenTextIsUnchanged() throws {
  let hosting = host(TemplateEditor(text: .constant("{label}")), width: 400, height: 54)
  let editor: NSTextView = try #require(findView(hosting))
  editor.setSelectedRange(NSRange(location: 1, length: 5))

  hosting.rootView = TemplateEditor(text: .constant("{label}"))
  hosting.layoutSubtreeIfNeeded()

  #expect(editor.selectedRange() == NSRange(location: 1, length: 5))
}

@Test(arguments: [true, false]) @MainActor func templateEditorRespectsDisabledState(disabled: Bool) throws {
  let hosting = host(TemplateEditor(text: .constant("{label}")).disabled(disabled), width: 400, height: 54)
  let editor: NSTextView = try #require(findView(hosting))

  #expect(editor.isEditable == !disabled)
  #expect(editor.isAccessibilityEnabled() == !disabled)

  hosting.rootView = TemplateEditor(text: .constant("{label}")).disabled(!disabled)
  hosting.layoutSubtreeIfNeeded()

  #expect(editor.isEditable == disabled)
  #expect(editor.isAccessibilityEnabled() == disabled)
}

@Test @MainActor func templateEditorUpdatesItsBindingAfterRemount() throws {
  var original = "first"
  var replacement = "second"
  let hosting = host(TemplateEditor(text: Binding(get: { original }, set: { original = $0 })), width: 400, height: 54)
  let editor: NSTextView = try #require(findView(hosting))

  hosting.rootView = TemplateEditor(text: Binding(get: { replacement }, set: { replacement = $0 }))
  hosting.layoutSubtreeIfNeeded()
  editor.selectAll(nil)
  editor.insertText("{label}", replacementRange: editor.selectedRange())

  #expect(replacement == "{label}")
  #expect(original == "first")
}
