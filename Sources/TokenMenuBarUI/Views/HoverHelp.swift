import SwiftUI

@MainActor
private struct RichHelpModifier: ViewModifier {
  let help: TooltipContent
  let presenter: TooltipPresenter

  func body(content: Content) -> some View {
    content
      .richHelpAccessibility(help)
      .background(
        TooltipAnchor(content: help, focused: false, presenter: presenter, tracksHover: true)
          .allowsHitTesting(false)
      )
  }
}

@MainActor
private struct FocusValueRichHelpModifier: ViewModifier {
  let help: TooltipContent
  let isFocused: Bool
  let presenter: TooltipPresenter

  func body(content: Content) -> some View {
    content
      .richHelpAccessibility(help)
      .background(
        TooltipAnchor(content: help, focused: isFocused, presenter: presenter, tracksHover: true)
          .allowsHitTesting(false)
      )
  }
}

@MainActor
private struct FocusedRichHelpModifier<Value: Hashable>: ViewModifier {
  let help: TooltipContent
  let focus: FocusState<Value?>.Binding
  let value: Value
  let presenter: TooltipPresenter

  func body(content: Content) -> some View {
    content
      .focused(focus, equals: value)
      .modifier(
        FocusValueRichHelpModifier(
          help: help,
          isFocused: focus.wrappedValue == value,
          presenter: presenter
        ))
  }
}

@MainActor
private struct BooleanFocusedRichHelpModifier: ViewModifier {
  let help: TooltipContent
  let focus: FocusState<Bool>.Binding
  let presenter: TooltipPresenter

  func body(content: Content) -> some View {
    content
      .focused(focus)
      .modifier(
        FocusValueRichHelpModifier(
          help: help,
          isFocused: focus.wrappedValue,
          presenter: presenter
        ))
  }
}

extension View {
  @MainActor
  public func richHelpAccessibility(_ help: TooltipContent) -> some View {
    accessibilityHint(Text(help.accessibilityHint))
  }

  @MainActor
  public func richHelp(_ help: TooltipContent) -> some View {
    richHelp(help, presenter: .shared)
  }

  @MainActor
  public func richHelp(_ help: TooltipContent, presenter: TooltipPresenter) -> some View {
    modifier(RichHelpModifier(help: help, presenter: presenter))
  }

  @MainActor
  public func richHelp(_ help: TooltipContent, isFocused: Bool) -> some View {
    richHelp(help, isFocused: isFocused, presenter: .shared)
  }

  @MainActor
  public func richHelp(
    _ help: TooltipContent,
    isFocused: Bool,
    presenter: TooltipPresenter
  ) -> some View {
    modifier(FocusValueRichHelpModifier(help: help, isFocused: isFocused, presenter: presenter))
  }

  @MainActor
  public func richHelp<Value: Hashable>(
    _ help: TooltipContent,
    focus: FocusState<Value?>.Binding,
    equals value: Value
  ) -> some View {
    richHelp(help, focus: focus, equals: value, presenter: .shared)
  }

  @MainActor
  public func richHelp<Value: Hashable>(
    _ help: TooltipContent,
    focus: FocusState<Value?>.Binding,
    equals value: Value,
    presenter: TooltipPresenter
  ) -> some View {
    modifier(FocusedRichHelpModifier(help: help, focus: focus, value: value, presenter: presenter))
  }

  @MainActor
  public func richHelp(
    _ help: TooltipContent,
    focus: FocusState<Bool>.Binding
  ) -> some View {
    richHelp(help, focus: focus, presenter: .shared)
  }

  @MainActor
  public func richHelp(
    _ help: TooltipContent,
    focus: FocusState<Bool>.Binding,
    presenter: TooltipPresenter
  ) -> some View {
    modifier(BooleanFocusedRichHelpModifier(help: help, focus: focus, presenter: presenter))
  }
}
