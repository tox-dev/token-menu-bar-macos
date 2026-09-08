public enum SemanticColorRole: String, CaseIterable, Sendable {
  case primary
  case secondary
  case tertiary
  case accent
  case warning
  case destructive
}

public enum ControlIntent: String, CaseIterable, Sendable {
  case action
  case selection
  case destructive
  case warning
  case data
}

public struct ControlAppearance: Equatable, Sendable {
  public let foreground: SemanticColorRole
  public let tint: SemanticColorRole?

  public init(foreground: SemanticColorRole, tint: SemanticColorRole? = nil) {
    self.foreground = foreground
    self.tint = tint
  }
}

public struct ControlPolicy: Equatable, Sendable {
  public let action: ControlAppearance
  public let selected: ControlAppearance
  public let destructive: ControlAppearance
  public let warning: ControlAppearance
  public let data: ControlAppearance

  public init(
    action: ControlAppearance,
    selected: ControlAppearance,
    destructive: ControlAppearance,
    warning: ControlAppearance,
    data: ControlAppearance
  ) {
    self.action = action
    self.selected = selected
    self.destructive = destructive
    self.warning = warning
    self.data = data
  }

  public func appearance(for intent: ControlIntent, selected isSelected: Bool = false) -> ControlAppearance {
    switch intent {
    case .action: action
    case .selection: isSelected ? selected : action
    case .destructive: destructive
    case .warning: warning
    case .data: data
    }
  }
}

public struct InterfaceTokens: Equatable, Sendable {
  public let bodyForeground: SemanticColorRole
  public let detailForeground: SemanticColorRole
  public let quietForeground: SemanticColorRole
  public let controls: ControlPolicy

  public init(
    bodyForeground: SemanticColorRole,
    detailForeground: SemanticColorRole,
    quietForeground: SemanticColorRole,
    controls: ControlPolicy
  ) {
    self.bodyForeground = bodyForeground
    self.detailForeground = detailForeground
    self.quietForeground = quietForeground
    self.controls = controls
  }

  public static let standard = InterfaceTokens(
    bodyForeground: .primary,
    detailForeground: .secondary,
    quietForeground: .tertiary,
    controls: ControlPolicy(
      action: ControlAppearance(foreground: .primary),
      selected: ControlAppearance(foreground: .primary, tint: .accent),
      destructive: ControlAppearance(foreground: .destructive),
      warning: ControlAppearance(foreground: .warning),
      data: ControlAppearance(foreground: .primary, tint: .accent)
    )
  )
}
