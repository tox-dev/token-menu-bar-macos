import SwiftUI
import TokenMenuBarCore

enum PanelSurfaceFill: Equatable {
  case inherited
  case windowBackground
}

@MainActor
enum PanelMaterialAdapter {
  static let generation: PlatformDesignGeneration = {
    if #available(macOS 26, *) { return .macOS26 }
    if #available(macOS 15, *) { return .macOS15 }
    return .macOS14
  }()

  static func material(for surface: PanelSurfaceRole) -> PanelMaterial {
    PanelMaterialPolicy.material(for: surface, generation: generation)
  }

  static func fill(for surface: PanelSurfaceRole) -> PanelSurfaceFill {
    switch material(for: surface) {
    case .system: .inherited
    case .standardContent: .windowBackground
    }
  }
}

extension View {
  func panelSurface(_ surface: PanelSurfaceRole) -> some View {
    modifier(PanelSurfaceModifier(fill: PanelMaterialAdapter.fill(for: surface)))
  }
}

private struct PanelSurfaceModifier: ViewModifier {
  let fill: PanelSurfaceFill

  @ViewBuilder func body(content: Content) -> some View {
    switch fill {
    case .inherited:
      content
    case .windowBackground:
      content.background(Color(nsColor: .windowBackgroundColor))
    }
  }
}
