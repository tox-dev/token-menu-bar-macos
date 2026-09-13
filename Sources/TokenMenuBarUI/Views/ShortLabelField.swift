import SwiftUI
import TokenMenuBarCore

struct ShortLabelField: View {
  @Binding var label: String
  @State private var text: String

  init(label: Binding<String>) {
    _label = label
    _text = State(initialValue: label.wrappedValue)
  }

  var body: some View {
    TextField("Label", text: $text)
      .onChange(of: text) { _, value in
        // Keep the raw edit in State so rejecting a seventh character updates the native field editor.
        text = ShortLabelPolicy.draft(value)
        label = text
      }
      .onChange(of: label) { _, value in text = value }
  }
}
