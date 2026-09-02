import Testing
import TokenMenuBarCore

@Test func interfaceTokensReserveAccentForSelectionAndData() {
  let tokens = InterfaceTokens.standard

  #expect(tokens.bodyForeground == .primary)
  #expect(tokens.detailForeground == .secondary)
  #expect(tokens.quietForeground == .tertiary)
  #expect(tokens.controls.appearance(for: .action) == ControlAppearance(foreground: .primary))
  #expect(tokens.controls.appearance(for: .selection) == ControlAppearance(foreground: .primary))
  #expect(
    tokens.controls.appearance(for: .selection, selected: true)
      == ControlAppearance(foreground: .primary, tint: .accent))
  #expect(
    tokens.controls.appearance(for: .data) == ControlAppearance(foreground: .primary, tint: .accent))
}

@Test func interfaceTokensKeepWarningAndDestructiveControlsSemantic() {
  let controls = InterfaceTokens.standard.controls

  #expect(controls.appearance(for: .warning) == ControlAppearance(foreground: .warning))
  #expect(controls.appearance(for: .destructive) == ControlAppearance(foreground: .destructive))
  #expect(controls.action.foreground != .accent)
  #expect(controls.destructive.foreground != .accent)
  #expect(controls.warning.foreground != .accent)
}

@Test func interfaceTokenPolicyCanBeReplacedWithoutUIFrameworkTypes() {
  let appearance = ControlAppearance(foreground: .secondary, tint: .warning)
  let controls = ControlPolicy(
    action: appearance, selected: appearance, destructive: appearance, warning: appearance, data: appearance)
  let tokens = InterfaceTokens(
    bodyForeground: .secondary, detailForeground: .tertiary, quietForeground: .primary, controls: controls)

  #expect(tokens.controls.appearance(for: .action) == appearance)
  #expect(SemanticColorRole.allCases.map(\.rawValue).count == 6)
  #expect(ControlIntent.allCases.map(\.rawValue).count == 5)
}
