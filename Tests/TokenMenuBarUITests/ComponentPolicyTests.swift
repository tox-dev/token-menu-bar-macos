import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func semanticColorsUseSystemRoles() {
  #expect(Color(.primary) == Color(nsColor: .labelColor))
  #expect(Color(.accent) == Color(nsColor: .controlAccentColor))
  #expect(Color(.secondary) != Color(.primary))
  #expect(Color(.tertiary) != Color(.secondary))
}

@Test @MainActor func readableSemanticColorsMeetPanelContrastInLightAndDarkAppearances() throws {
  for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
    let appearance = try #require(NSAppearance(named: appearanceName))
    var colors: (NSColor?, [NSColor?])?
    appearance.performAsCurrentDrawingAppearance {
      colors = (
        NSColor.windowBackgroundColor.usingColorSpace(.sRGB),
        [SemanticColorRole.primary, .secondary, .tertiary, .warning, .destructive].map {
          SemanticColorPalette.color(for: $0).usingColorSpace(.sRGB)
        } + [LogTextView.textColor.usingColorSpace(.sRGB)]
      )
    }
    let resolvedColors = try #require(colors)
    let background = try #require(resolvedColors.0)
    for foreground in resolvedColors.1 {
      #expect(contrastRatio(try #require(foreground), background: background) >= 4.5)
    }
  }
}

@Test @MainActor func nativeComponentsRenderWithIntrinsicControlHeights() {
  #expect(inkFraction(NativeActionButton("Refresh") {}, width: 160, height: 40) > 0)
  #expect(
    inkFraction(
      NativeActionButton(intent: .destructive, action: {}) { Label("Clear", systemImage: "trash") }, width: 160,
      height: 40) > 0)
  #expect(NativeActionButton("Refresh") {}.role == nil)
  #expect(NativeActionButton("Clear", intent: .destructive) {}.role == .destructive)
  #expect(
    inkFraction(
      NativeIconButton(symbol: "arrow.clockwise", accessibilityLabel: "Refresh", action: {}), width: 48, height: 40)
      > 0)
  #expect(
    inkFraction(IconButton(symbol: "arrow.clockwise", help: "Refresh", action: {}), width: 48, height: 40) > 0)
  #expect(inkFraction(Button("Action") {}.buttonStyle(.bordered), width: 120, height: 40) > 0)
}

@Test @MainActor func sectionComponentsKeepLabelsSeparateFromContent() {
  #expect(inkFraction(SectionLabel("Menu bar"), width: 200, height: 28) > 0)
  #expect(
    inkFraction(
      PanelSection("Menu bar") { PanelRow("Format") { Text("Percent") } }, width: 420, height: 80) > 0)
  #expect(PanelRow("Format") { Text("Percent") }.labelWidth == 116)
  #expect(PanelRow("Format", labelWidth: 140) { Text("Percent") }.labelWidth == 140)
}

@Test @MainActor func semanticControlModifiersRenderEachIntent() {
  #expect(inkFraction(Text("Detail").semanticForeground(.secondary), width: 100, height: 30) > 0)
  for intent in ControlIntent.allCases {
    #expect(
      inkFraction(Button(intent.rawValue) {}.buttonStyle(.bordered).semanticControl(intent, selected: true), width: 140)
        > 0)
  }
}

@Test @MainActor func scrollerStylerUsesAutoHidingVerticalOverlay() {
  let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
  let probe = ScrollerStyler.ProbeView(frame: .zero)
  let document = NSView(frame: .zero)
  let nested = NSScrollView(frame: .zero)
  nested.hasHorizontalScroller = true
  nested.horizontalScrollElasticity = .automatic
  document.addSubview(probe)
  document.addSubview(nested)
  scrollView.documentView = document

  ScrollerStyler.apply(from: probe)
  probe.viewDidMoveToSuperview()
  probe.viewDidMoveToWindow()

  #expect(scrollView.scrollerStyle == .overlay)
  #expect(scrollView.hasVerticalScroller)
  #expect(!scrollView.hasHorizontalScroller)
  #expect(scrollView.autohidesScrollers)
  #expect(scrollView.horizontalScrollElasticity == .none)
  #expect(!nested.hasVerticalScroller)
  #expect(nested.hasHorizontalScroller)
  #expect(nested.horizontalScrollElasticity == .automatic)
}

private func contrastRatio(_ foreground: NSColor, background: NSColor) -> Double {
  let foreground = composite(foreground, over: background)
  let lighter = max(luminance(foreground), luminance(background))
  let darker = min(luminance(foreground), luminance(background))
  return (lighter + 0.05) / (darker + 0.05)
}

private func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
  let alpha = foreground.alphaComponent
  return NSColor(
    red: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
    green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
    blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha),
    alpha: 1)
}

private func luminance(_ color: NSColor) -> Double {
  func linear(_ component: CGFloat) -> Double {
    let value = Double(component)
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
    + 0.0722 * linear(color.blueComponent)
}
