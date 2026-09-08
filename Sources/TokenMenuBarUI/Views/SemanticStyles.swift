import AppKit
import SwiftUI
import TokenMenuBarCore

extension Color {
  public init(_ role: SemanticColorRole) {
    self.init(nsColor: SemanticColorPalette.color(for: role))
  }
}

public enum SemanticColorPalette {
  public static func color(for role: SemanticColorRole) -> NSColor {
    switch role {
    case .primary: .labelColor
    case .secondary:
      NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 0.78, green: 0.78, blue: 0.8, alpha: 1)
          : NSColor(srgbRed: 0.3, green: 0.3, blue: 0.32, alpha: 1)
      }
    case .tertiary:
      NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 0.68, green: 0.68, blue: 0.71, alpha: 1)
          : NSColor(srgbRed: 0.36, green: 0.36, blue: 0.38, alpha: 1)
      }
    case .accent: .controlAccentColor
    case .warning:
      NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 1, green: 0.71, blue: 0.35, alpha: 1)
          : NSColor(srgbRed: 0.45, green: 0.22, blue: 0, alpha: 1)
      }
    case .destructive:
      NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 1, green: 0.61, blue: 0.59, alpha: 1)
          : NSColor(srgbRed: 0.58, green: 0.04, blue: 0.1, alpha: 1)
      }
    }
  }
}

extension View {
  public func semanticForeground(_ role: SemanticColorRole) -> some View {
    foregroundStyle(Color(role))
  }

  public func semanticControl(_ intent: ControlIntent, selected: Bool = false) -> some View {
    modifier(SemanticControlModifier(intent: intent, selected: selected))
  }
}

private struct SemanticControlModifier: ViewModifier {
  let intent: ControlIntent
  let selected: Bool

  func body(content: Content) -> some View {
    let appearance = InterfaceTokens.standard.controls.appearance(for: intent, selected: selected)
    content
      .foregroundStyle(Color(appearance.foreground))
      .tint(appearance.tint.map(Color.init))
  }
}
