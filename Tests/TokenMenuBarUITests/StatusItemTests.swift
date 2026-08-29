import AppKit
import Testing
import TokenMenuBarCore

@testable import TokenMenuBarUI

@Test @MainActor func appIconDrawsEveryTone() {
  for tone in [StatusIconTone.normal, .offline, .attention] {
    for dark in [false, true] {
      let image = AppIcon.image(height: 18, tone: tone, dark: dark)
      #expect(image.size == CGSize(width: 18, height: 18))
      #expect(image.tiffRepresentation != nil)
      #expect(!image.isTemplate)
    }
  }
  #expect(AppIcon.inkColor(tone: .offline, dark: false) == .systemGray)
  #expect(AppIcon.inkColor(tone: .attention, dark: true) == .white)
  #expect(AppIcon.inkColor(tone: .normal, dark: false) == .black)
  let hosting = host(AppIconView(size: 24, tone: .attention), width: 40, height: 40)
  #expect(hosting.fittingSize.width > 0)
  _ = host(AppIconView(size: 24).environment(\.colorScheme, .dark), width: 40, height: 40)
}

@Test @MainActor func providerGlyphs() {
  #expect(ProviderGlyph.image(.claude, pointSize: 12).size.width > 0)
  #expect(ProviderGlyph.image(.codex, pointSize: 12).size.width > 0)
  #expect(ProviderGlyph.symbolName(.claude) != ProviderGlyph.symbolName(.codex))
  #expect(ProviderGlyph.color(.claude) != ProviderGlyph.color(.codex))
}

@Test @MainActor func rendererFontSizeAndColors() {
  #expect(StatusItemRenderer.fontSizes(height: 18, lineCount: 1) == [13])
  #expect(StatusItemRenderer.fontSizes(height: 24, lineCount: 2) == [9, 11.5])
  #expect(StatusItemRenderer.fontSizes(height: 30, lineCount: 3) == [8, 8, 8])
  #expect(StatusItemRenderer.fontSizes(height: 60, lineCount: 4) == [9, 9, 9, 9])
  #expect(StatusItemRenderer.color(for: .label, dark: true) == .white)
  #expect(StatusItemRenderer.color(for: .label, dark: false) == .black)
  #expect(StatusItemRenderer.color(for: .number, dark: false).alphaComponent < 1)
  let light = StatusItemRenderer.color(for: .usage(50), dark: false)
  let dark = StatusItemRenderer.color(for: .usage(50), dark: true)
  #expect(dark.brightnessComponent > light.brightnessComponent)
}

@Test @MainActor func rendererBuildsTitlesForEachFormat() {
  for format in StatusFormat.allCases {
    let model = statusModel(format: format)
    let title = StatusItemRenderer.attributedTitle(for: model, height: 18, dark: false)
    #expect(title.length == max(model.cells.count * 2 - 1, 0))
    for cell in model.cells {
      let image = StatusItemRenderer.cellImage(cell, height: 18, dark: true)
      #expect(image.size.height == 18)
      #expect(image.size.width > 0)
      #expect(image.tiffRepresentation != nil)
    }
    let preview = StatusItemRenderer.previewImage(for: model, height: 18, dark: false)
    #expect(preview.size.width > 0)
    #expect(preview.tiffRepresentation != nil)
  }
  let empty = StatusItemRenderer.previewImage(for: .empty, height: 18, dark: true)
  #expect(empty.size.width == 18)
  #expect(StatusItemRenderer.attributedTitle(for: .empty, height: 18, dark: false).length == 0)
  let signature = StatusRenderSignature(model: .empty, dark: true, height: 22)
  #expect(signature == StatusRenderSignature(model: .empty, dark: true, height: 22))
}

@Test @MainActor func statusItemControllerRendersAndTracksTimers() async throws {
  let log = makeLog()
  log.debugEnabled = true
  var presented = 0
  let controller = StatusItemController(log: log, tickInterval: 0.05) { _ in presented += 1 }
  defer { controller.remove() }
  #expect(controller.item.button != nil)
  #expect(controller.barHeight >= 22)
  _ = controller.isDark
  controller.update(.empty)
  #expect(controller.item.button?.image != nil)
  #expect(controller.item.button?.imagePosition != .noImage)
  controller.update(statusModel(format: .custom))
  #expect(controller.countdownRunning)
  #expect(controller.item.button?.attributedTitle.length == 7)
  #expect(controller.item.button?.image == nil)
  #expect(controller.item.button?.toolTip?.contains("Claude") == true)
  controller.update(statusModel(format: .stacked))
  #expect(!controller.countdownRunning)
  controller.update(statusModel(format: .stacked))
  controller.render(force: true)
  var ticks = 0
  controller.onCountdownTick = { ticks += 1 }
  controller.update(statusModel(format: .custom))
  for _ in 0..<200 where ticks == 0 { try await Task.sleep(for: .milliseconds(25)) }
  #expect(ticks >= 1)
  var probes: [StatusItemProbe] = []
  controller.onProbeChange = { probes.append($0) }
  controller.probing = true
  let first = controller.probe()
  #expect(first.summary.contains("visible="))
  #expect(controller.probe() == first)
  #expect(probes.count <= 1)
  try await Task.sleep(for: .milliseconds(200))
  controller.probing = false
  _ = controller.buttonFrameOnScreen
  var clicks = 0
  controller.onClick = { clicks += 1 }
  controller.buttonClicked(nil)
  #expect(clicks == 1)
  controller.menuProvider = { NSMenu() }
  controller.buttonClicked(nil)
  #expect(clicks == 2)
  let rightClick = NSEvent.mouseEvent(
    with: .rightMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
    eventNumber: 0,
    clickCount: 1, pressure: 1)!
  controller.handleClick(rightClick)
  #expect(clicks == 2)
  #expect(presented == 1)
  #expect(controller.item.menu != nil)
  controller.item.menu?.delegate?.menuDidClose?(controller.item.menu!)
  #expect(controller.item.menu == nil)
  NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  controller.item.button?.appearance = NSAppearance(named: .darkAqua)
  controller.appearanceChanged()
  await Task.yield()
  try await Task.sleep(for: .milliseconds(50))
  #expect(controller.isDark)
}
