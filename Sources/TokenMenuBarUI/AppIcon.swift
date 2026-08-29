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

public enum ProviderGlyph {
  public static func image(_ provider: ProviderID, pointSize: CGFloat) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    return NSImage(systemSymbolName: symbolName(provider), accessibilityDescription: provider.displayName)!
      .withSymbolConfiguration(configuration)!
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
