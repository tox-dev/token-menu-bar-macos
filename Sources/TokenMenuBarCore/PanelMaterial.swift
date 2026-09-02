public enum PanelSurfaceRole: CaseIterable, Sendable {
  case popoverChrome
  case content
}

public enum PanelMaterial: CaseIterable, Sendable {
  case system
  case standardContent
}

public enum PanelMaterialPolicy {
  public static func material(
    for surface: PanelSurfaceRole,
    generation: PlatformDesignGeneration
  ) -> PanelMaterial {
    switch (generation, surface) {
    case (.macOS14, .popoverChrome), (.macOS15, .popoverChrome), (.macOS26, .popoverChrome): .system
    case (.macOS14, .content), (.macOS15, .content), (.macOS26, .content): .standardContent
    }
  }
}
