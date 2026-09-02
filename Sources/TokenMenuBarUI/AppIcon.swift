import AppKit
import SwiftUI
import TokenMenuBarCore

public enum AppIcon {
  public static let designSize: CGFloat = 24

  public static func draw(in context: CGContext, rect: CGRect, tone: StatusIconTone, dark: Bool) {
    let scale = min(rect.width, rect.height) / designSize
    context.saveGState()
    context.translateBy(
      x: rect.minX + (rect.width - designSize * scale) / 2, y: rect.minY + (rect.height - designSize * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    let ink = inkColor(tone: tone, dark: dark)
    let frame = CGPath(
      roundedRect: CGRect(x: 2, y: 2, width: 20, height: 20), cornerWidth: 5, cornerHeight: 5, transform: nil)
    context.setStrokeColor(ink.cgColor)
    context.setLineWidth(1.6)
    context.addPath(frame)
    context.strokePath()
    let bars: [(y: CGFloat, width: CGFloat)] = [(15, 12), (10.5, 8), (6, 5)]
    for bar in bars {
      let track = CGPath(
        roundedRect: CGRect(x: 6, y: bar.y, width: 12, height: 2.4), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil
      )
      context.setFillColor(ink.withAlphaComponent(0.25).cgColor)
      context.addPath(track)
      context.fillPath()
      let fill = CGPath(
        roundedRect: CGRect(x: 6, y: bar.y, width: bar.width, height: 2.4), cornerWidth: 1.2, cornerHeight: 1.2,
        transform: nil)
      context.setFillColor(ink.cgColor)
      context.addPath(fill)
      context.fillPath()
    }
    if tone == .attention {
      context.setFillColor(NSColor.systemOrange.cgColor)
      context.fillEllipse(in: CGRect(x: 16, y: 16, width: 7, height: 7))
    }
    context.restoreGState()
  }

  public static func inkColor(tone: StatusIconTone, dark: Bool) -> NSColor {
    switch tone {
    case .offline: NSColor.systemGray
    case .attention: dark ? NSColor.white : NSColor.black
    case .normal: dark ? NSColor.white : NSColor.black
    }
  }

  public static func image(height: CGFloat, tone: StatusIconTone, dark: Bool) -> NSImage {
    let size = CGSize(width: height, height: height)
    let image = NSImage(size: size, flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      draw(in: context, rect: rect, tone: tone, dark: dark)
      return true
    }
    image.isTemplate = false
    return image
  }
}

extension AppIcon {
  public static let squircleRatio: CGFloat = 0.2237
  public static let productInset: CGFloat = 0.092
  public static let appIconSizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]

  public static func drawProduct(in context: CGContext, size: CGFloat) {
    let inset = size * productInset
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * squircleRatio
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let stops = [Brand.gradientStart, Brand.gradientEnd].map(\.cgColor)
    if let gradient = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: [0, 1]) {
      context.drawLinearGradient(
        gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    let unit = rect.width / 100
    let bars: [(y: CGFloat, fill: CGFloat)] = [(62, 56), (43, 38), (24, 22)]
    for bar in bars {
      let height = 14 * unit
      let bottom = rect.minY + bar.y * unit
      for (width, alpha) in [(CGFloat(56), 0.32), (bar.fill, 1.0)] {
        let barRect = CGRect(x: rect.minX + 22 * unit, y: bottom, width: width * unit, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: alpha))
        context.addPath(
          CGPath(roundedRect: barRect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.fillPath()
      }
    }
    context.restoreGState()
  }

  /// Draws into a bitmap of exactly `size` pixels. Going through `NSImage.cgImage` hands back the backing store,
  /// which on a Retina context is twice the requested size, and actool rejects every slot whose image is the wrong
  /// size — silently, so the app ships with no icon at all.
  public static func pngData(size: Int) -> Data? {
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    rep.size = CGSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawProduct(in: context.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
  }

  /// `iconutil` turns the directory this writes into the `.icns` the bundle ships.
  public static func exportIconSet(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in appIconSizes {
      guard let data = pngData(size: size) else { continue }
      try data.write(to: directory.appendingPathComponent("icon_\(size).png"))
      if size >= 32 {
        try data.write(to: directory.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
      }
      if size <= 512 {
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
      }
    }
  }
}

public struct AppIconView: View {
  public let size: CGFloat
  public let tone: StatusIconTone

  public init(size: CGFloat, tone: StatusIconTone = .normal) {
    self.size = size
    self.tone = tone
  }

  @Environment(\.colorScheme) private var colorScheme

  public var body: some View {
    Canvas { context, canvasSize in
      context.withCGContext { cg in
        AppIcon.draw(in: cg, rect: CGRect(origin: .zero, size: canvasSize), tone: tone, dark: colorScheme == .dark)
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Token Menu Bar")
  }
}

extension Color {
  /// The brand iris, resolved per appearance so it holds contrast on both popover materials.
  public static var brandAccent: Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let brand = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Brand.irisDark : Brand.iris
        return NSColor(cgColor: brand.cgColor)!
      })
  }

}

public enum ProviderGlyph {
  public static func image(_ provider: ProviderID, pointSize: CGFloat) -> NSImage {
    return NSImage(systemSymbolName: symbolName(provider), accessibilityDescription: provider.displayName)!
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))!
  }

  public static func symbolName(_ provider: ProviderID) -> String {
    switch provider {
    case .claude: "sparkle"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .gemini: "sparkles"
    case .cursor: "cursorarrow.rays"
    case .copilot: "circle.hexagongrid"
    }
  }

  public static func color(_ provider: ProviderID) -> Color {
    switch provider {
    case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
    case .codex: Color(red: 0.06, green: 0.64, blue: 0.55)
    case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
    case .cursor: Color(red: 0.45, green: 0.45, blue: 0.5)
    case .copilot: Color(red: 0.42, green: 0.35, blue: 0.8)
    }
  }
}

extension BrandColor {
  var cgColor: CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
  }
}
