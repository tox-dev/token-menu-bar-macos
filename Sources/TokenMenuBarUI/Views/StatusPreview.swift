import AppKit
import SwiftUI
import TokenMenuBarCore

public struct StatusPreview: View {
  public let model: StatusItemModel
  @Binding private var highlightedKey: WindowKey?
  private let select: (WindowKey) -> Void
  @Environment(\.colorScheme) private var colorScheme

  public init(
    model: StatusItemModel, highlightedKey: Binding<WindowKey?> = .constant(nil),
    select: @escaping (WindowKey) -> Void = { _ in }
  ) {
    self.model = model
    _highlightedKey = highlightedKey
    self.select = select
  }

  public var body: some View {
    Group {
      if !model.showsIcon {
        WrappingHStack(horizontalSpacing: 6, verticalSpacing: 4) {
          ForEach(model.cells) { cell in preview(cell) }
        }
      } else {
        HStack(spacing: 0) {
          Image(nsImage: StatusItemRenderer.previewImage(for: model, height: 24, dark: colorScheme == .dark))
            .accessibilityLabel("Menu bar preview")
            .accessibilityValue(StatusItemRenderer.accessibilityDescription(for: model))
          Spacer(minLength: 0)
        }
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
      in: RoundedRectangle(cornerRadius: 6)
    )
  }

  @ViewBuilder
  func preview(_ cell: StatusCell) -> some View {
    if let key = WindowKey(storageKey: cell.id) {
      let help =
        "Shows the status cell from the same model used by the menu bar. "
        + "Select it to scroll to and focus its model row."
      StatusPreviewCellButton(
        image: StatusItemRenderer.cellImage(cell, height: 24, dark: colorScheme == .dark),
        accessibilityLabel: cell.tooltip,
        accessibilityHelp: help,
        selected: highlightedKey == key
      ) {
        highlightedKey = key
        select(key)
      }
      .richHelp(
        TooltipContent(
          title: "Preview \(cell.tooltip)",
          body: help)
      )
      .onHover { inside in
        if inside { highlightedKey = key } else if highlightedKey == key { highlightedKey = nil }
      }
    } else {
      Image(nsImage: StatusItemRenderer.cellImage(cell, height: 24, dark: colorScheme == .dark))
        .accessibilityLabel(cell.tooltip)
    }
  }
}

private struct StatusPreviewCellButton: NSViewRepresentable {
  let image: NSImage
  let accessibilityLabel: String
  let accessibilityHelp: String
  let selected: Bool
  let action: () -> Void

  func makeNSView(context: Context) -> NSButton {
    let button = StatusPreviewButton()
    button.target = context.coordinator
    button.action = #selector(Coordinator.press(_:))
    button.setButtonType(.toggle)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleNone
    button.refusesFirstResponder = false
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    update(button, coordinator: context.coordinator)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    update(button, coordinator: context.coordinator)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  private func update(_ button: NSButton, coordinator: Coordinator) {
    coordinator.action = action
    button.image = image
    button.state = selected ? .on : .off
    button.setAccessibilityLabel(accessibilityLabel)
    button.setAccessibilityHelp(accessibilityHelp)
  }

  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void

    init(action: @escaping () -> Void) {
      self.action = action
    }

    @objc func press(_: NSButton) {
      action()
    }
  }
}

private final class StatusPreviewButton: NSButton {
  override func accessibilityPerformPress() -> Bool {
    performClick(nil)
    return true
  }
}
