import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func productIconDrawsAndExports() throws {
  let image = AppIcon.productImage(size: 128)
  #expect(image.size == CGSize(width: 128, height: 128))
  #expect(AppIcon.pngData(size: 64)?.isEmpty == false)
  #expect(AppIcon.squircleRatio > 0 && AppIcon.productInset > 0)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-icon-\(UUID().uuidString)")
  try AppIcon.exportIconSet(to: directory)
  let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(files.contains("icon_16x16.png"))
  #expect(files.contains("icon_512x512@2x.png"))
  #expect(files.count > AppIcon.appIconSizes.count)
  try FileManager.default.removeItem(at: directory)
}

@Test(arguments: [true, false])
@MainActor func menuBarStripRendersForBothAppearances(dark: Bool) {
  let image = StatusItemRenderer.stripImage(for: statusModel(), dark: dark)
  #expect(image.size == CGSize(width: 520, height: 28))
  #expect(StatusItemRenderer.stripData(for: statusModel(), dark: dark)?.isEmpty == false)
}

@Test @MainActor func menuBarStripTakesTheRequestedWidth() {
  #expect(StatusItemRenderer.stripImage(for: .empty, dark: false, width: 200).size.width == 200)
}

@Test @MainActor func popoverExporterRendersAViewToPNG() {
  let view = Text("Token Menu Bar").frame(width: 200, height: 60)
  #expect(PopoverExporter.image(view, dark: true)?.size == CGSize(width: 200, height: 60))
  #expect(PopoverExporter.png(view, dark: false)?.isEmpty == false)
  // a view with no intrinsic size has nothing to render
  #expect(PopoverExporter.image(Color.clear.frame(width: 0, height: 0), dark: false) == nil)
  #expect(PopoverExporter.png(Color.clear.frame(width: 0, height: 0), dark: false) == nil)
}
