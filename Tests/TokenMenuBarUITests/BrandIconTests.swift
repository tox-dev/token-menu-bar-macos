import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test @MainActor func productIconDrawsAndExports() throws {
  #expect(AppIcon.squircleRatio > 0 && AppIcon.productInset > 0)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-icon-\(UUID().uuidString)")
  try AppIcon.exportIconSet(to: directory)
  let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(files.contains("icon_16x16.png"))
  #expect(files.contains("icon_512x512@2x.png"))
  #expect(files.count > AppIcon.appIconSizes.count)

  // actool drops a slot whose image is not exactly the size its name claims, and says so as a warning, so an icon
  // rendered at the wrong scale leaves the app with no icon at all rather than a broken build.
  for file in files {
    let name = file.replacingOccurrences(of: "icon_", with: "").replacingOccurrences(of: ".png", with: "")
    let scale = name.hasSuffix("@2x") ? 2 : 1
    guard let nominal = Int(name.replacingOccurrences(of: "@2x", with: "").split(separator: "x").first ?? "") else {
      continue
    }
    let image = try #require(NSImage(contentsOf: directory.appendingPathComponent(file)))
    let rep = try #require(image.representations.first)
    #expect(rep.pixelsWide == nominal * scale, "\(file) is \(rep.pixelsWide)px, expected \(nominal * scale)")
    #expect(rep.pixelsHigh == nominal * scale)
  }
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

@Test(arguments: PopoverTab.allCases, [CGSize(width: 880, height: 640), CGSize(width: 600, height: 320)]) @MainActor
func popoverPreparationLaysOutTheViewportWithoutPresenting(tab: PopoverTab, maximum: CGSize) throws {
  let controller = PopoverController(content: AnyView(Color.clear), beginActivation: { nil })
  controller.select(tab: tab)
  controller.maximum = maximum

  controller.prepareToShow()

  let view = try #require(controller.popover.contentViewController).view
  #expect(
    view.frame.size
      == CGSize(width: maximum.width, height: min(maximum.height, PopoverGeometry.preferredHeight(for: tab))))
  #expect(view.window == nil)
  #expect(!controller.isShown)
  controller.close()
}

@Test(arguments: [false, true]) @MainActor
func popoverExporterResizesAnExistingHostWithoutPresenting(dark: Bool) throws {
  let hosting = host(Text("ALPHA BRAVO"), width: 200, height: 60)
  let initial = try #require(PopoverExporter.image(hosting, dark: dark, size: CGSize(width: 200, height: 60)))
  #expect(initial.size == CGSize(width: 200, height: 60))

  let size = CGSize(width: 240, height: 80)
  let data = try #require(PopoverExporter.png(hosting, dark: dark, size: size))
  let bitmap = try #require(NSBitmapImageRep(data: data))

  #expect(hosting.frame.size == size)
  #expect(bitmap.pixelsWide == 480)
  #expect(bitmap.pixelsHigh == 160)
  #expect(hosting.window == nil)
}

@Test @MainActor func popoverPreparationLocksGeometryBeforeActivationAndReleasesItOnCancellation() {
  var visibility: [Bool] = []
  let controller = PopoverController(
    content: AnyView(Color.clear),
    beginActivation: {
      #expect(visibility == [true])
      return nil
    })
  controller.onVisibilityChange = { visibility.append($0) }

  controller.prepareToShow()
  controller.prepareToShow()
  #expect(visibility == [true])
  controller.close()
  controller.close()

  #expect(visibility == [true, false])
}

@Test(arguments: [false, true]) @MainActor
func popoverExportsUseRetinaResolutionWithoutChangingLayout(dark: Bool) throws {
  let size = CGSize(width: 200, height: 60)
  let image = try #require(PopoverExporter.image(Text("ALPHA BRAVO"), dark: dark, size: size))
  let bitmap = try #require(image.representations.first as? NSBitmapImageRep)

  #expect(image.size == size)
  #expect(bitmap.pixelsWide == 400)
  #expect(bitmap.pixelsHigh == 120)
}

@Test(arguments: [
  (CGSize(width: 880, height: 640), 640.0),
  (CGSize(width: 400, height: 1200), 760.0),
  (CGSize.zero, 760.0),
]) @MainActor func popoverExportKeepsWidthAndCapsTheMeasuredHeight(measured: CGSize, expectedHeight: Double) {
  let fallback = CGSize(width: 880, height: 760)

  #expect(
    ExportRunner.exportSize(measured: measured, fallback: fallback)
      == CGSize(width: 880, height: expectedHeight))
}

@Test @MainActor func popoverExportFilesMeasurementsUnderTheirOwnTab() throws {
  let environment = try makeEnvironment()
  environment.settings.lastTab = .history
  var measured = CGSize.zero
  let view = RootView(
    environment: environment,
    onMeasure: { measurement in
      if measurement.tab == .history { measured = measurement.size }
    })

  _ = PopoverExporter.image(view, dark: false, size: ExportRunner.shotSize)
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))

  #expect(measured.height > 0)
  #expect(measured.height <= 760)
}
