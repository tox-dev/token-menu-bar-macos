import SwiftUI
import TokenMenuBarCore

struct SupportingDetails<Content: View>: View {
  let id: String
  let title: String
  let summary: String?
  @Bindable var state: DisclosureState
  let content: () -> Content

  init(
    _ title: String, id: String, state: DisclosureState, summary: String? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.id = id
    self.state = state
    self.summary = summary
    self.content = content
  }

  var body: some View {
    DisclosureGroup(
      isExpanded: Binding(
        get: { state.expanded.contains(id) }, set: { state.setExpanded($0, for: id) })
    ) {
      if state.expanded.contains(id) {
        VStack(alignment: .leading, spacing: 7) { content() }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("disclosure-content-\(id)")
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        if let summary {
          Text(summary).font(.caption).semanticForeground(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .foregroundStyle(.primary)
      .contentShape(Rectangle())
      .onTapGesture(perform: state.toggleAction(for: id))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("disclosure-\(id)")
    .accessibilityLabel(title)
    .accessibilityValue(state.expanded.contains(id) ? "Expanded" : "Collapsed")
    .richHelp(
      TooltipContent(
        title: title, body: "Shows supporting details without changing any settings. Other groups stay open."))
  }
}
