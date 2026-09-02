import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func panelMaterialAdapterUsesFloorAvailability() {
  let expected: PlatformDesignGeneration =
    if #available(macOS 26, *) {
      .macOS26
    } else if #available(macOS 15, *) {
      .macOS15
    } else {
      .macOS14
    }
  #expect(PanelMaterialAdapter.generation == expected)
}

@Test(arguments: PanelSurfaceRole.allCases) @MainActor
func panelMaterialAdapterResolvesCorePolicy(surface: PanelSurfaceRole) {
  #expect(
    PanelMaterialAdapter.material(for: surface)
      == PanelMaterialPolicy.material(for: surface, generation: PanelMaterialAdapter.generation))
}

@Test(arguments: [PanelSurfaceRole.popoverChrome, .content]) @MainActor
func panelMaterialAdapterMapsPolicyToLowCostFill(surface: PanelSurfaceRole) {
  let expected: PanelSurfaceFill = surface == .popoverChrome ? .inherited : .windowBackground
  #expect(PanelMaterialAdapter.fill(for: surface) == expected)
}
