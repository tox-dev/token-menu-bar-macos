import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test(arguments: [false, true], [StatusRun.Kind.number, .usage(52)]) @MainActor
func staleStatusNumbersUseOpaqueGray(dark: Bool, kind: StatusRun.Kind) throws {
  let color = try #require(StatusItemRenderer.color(for: kind, dark: dark, isStale: true).usingColorSpace(.sRGB))

  #expect(abs(color.redComponent - color.greenComponent) < 0.001)
  #expect(abs(color.greenComponent - color.blueComponent) < 0.001)
  #expect(color.alphaComponent == 1)
}

@Test(arguments: [false, true]) @MainActor func staleStatusLabelsKeepTheirNormalContrast(dark: Bool) {
  #expect(
    StatusItemRenderer.color(for: .label, dark: dark, isStale: true)
      == StatusItemRenderer.color(for: .label, dark: dark))
}

@Test(arguments: [560.0, 880.0]) @MainActor func staleUsageRowsRenderWithoutFreshUsageColors(width: Double) throws {
  let environment = try makeEnvironment()
  let row = try #require(environment.cards.first?.rows.first)
  let fresh = host(WindowRowView(row: row, now: fixedNow), width: width, height: 110)
  let stale = host(
    WindowRowView(row: row, now: fixedNow).environment(\.usageValueAppearance, .stale), width: width, height: 110)

  #expect(try coloredPixels(fresh) > 30)
  #expect(try coloredPixels(stale) == 0)
}

@MainActor private func coloredPixels(_ view: NSView) throws -> Int {
  let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
  view.cacheDisplay(in: view.bounds, to: rep)
  let bitmap = try #require(rep.cgImage)
  return try coloredPixels(bitmap)
}

private func coloredPixels(_ bitmap: CGImage) throws -> Int {
  var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
  return try pixels.withUnsafeMutableBytes { buffer in
    let context = try #require(
      CGContext(
        data: buffer.baseAddress, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
        bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
    var count = 0
    for offset in stride(from: 0, to: buffer.count, by: 4) {
      let red = buffer[offset], green = buffer[offset + 1], blue = buffer[offset + 2]
      if buffer[offset + 3] > 25, max(red, green, blue) - min(red, green, blue) > 20 { count += 1 }
    }
    return count
  }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func staleStatusRenderingChangesTheActualNumbersAndBars(dark: Bool, miniBars: Bool) throws {
  let rendered = try [false, true].map { stale in
    let cell = StatusCell(
      id: "fixture", provider: .claude, lines: [[StatusRun(text: "52%", kind: .usage(52))]],
      bars: miniBars ? [StatusBar(label: "CC", percent: 52)] : [], percent: 52, tooltip: "Fixture", isStale: stale)
    let image = StatusItemRenderer.cellImage(cell, height: 24, dark: dark)
    let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    if miniBars {
      let scale = CGFloat(bitmap.width) / image.size.width
      return try coloredPixels(
        #require(
          bitmap.cropping(
            to: CGRect(
              x: (image.size.width - 36) * scale, y: 0, width: 30 * scale, height: CGFloat(bitmap.height)))))
    }
    return try coloredPixels(bitmap)
  }
  #expect(rendered[0] > 10)
  #expect(rendered[1] == 0)
}
