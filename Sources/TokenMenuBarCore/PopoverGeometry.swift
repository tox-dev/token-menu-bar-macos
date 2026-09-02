import CoreGraphics
import Foundation

public enum PopoverDismissalTrigger: Sendable, Equatable {
  case mouseDown
  case mouseMoved
  case keyEscape
}

public struct PopoverDismissalGate: Sendable, Equatable {
  public init() {}

  public func shouldClose(
    mouseLocation: CGPoint,
    popoverFrame: CGRect?,
    excludedFrame: CGRect? = nil,
    trigger: PopoverDismissalTrigger
  ) -> Bool {
    if trigger == .keyEscape { return true }
    if popoverFrame?.contains(mouseLocation) ?? false { return false }
    if excludedFrame?.contains(mouseLocation) == true { return false }
    switch trigger {
    case .mouseDown: return true
    case .mouseMoved: return false
    case .keyEscape: return true
    }
  }
}

public struct PopoverMeasurement: Sendable, Equatable {
  public let tab: PopoverTab
  public let size: CGSize

  public init(tab: PopoverTab, size: CGSize) {
    self.tab = tab
    self.size = size
  }
}

public struct SettingsHeightInput: Sendable, Equatable {
  public let mountedSections: Set<SettingsSection>
  public let showsModelFilter: Bool
  public let providerCount: Int
  public let modelCount: Int
  public let logLineCount: Int
  public let showsCustomTemplate: Bool
  public let showsUpdates: Bool

  public init(
    mountedSections: Set<SettingsSection>, showsModelFilter: Bool, providerCount: Int, modelCount: Int,
    logLineCount: Int, showsCustomTemplate: Bool, showsUpdates: Bool
  ) {
    self.mountedSections = mountedSections
    self.showsModelFilter = showsModelFilter
    self.providerCount = providerCount
    self.modelCount = modelCount
    self.logLineCount = logLineCount
    self.showsCustomTemplate = showsCustomTemplate
    self.showsUpdates = showsUpdates
  }
}

public enum PopoverGeometry {
  public static let minimumWidth: CGFloat = 728
  public static let contentPadding: CGFloat = 14
  public static let stableTabWidth: CGFloat = 880
  public static let stableContentWidth: CGFloat = stableTabWidth - 2 * contentPadding
  public static let minimumHeight: CGFloat = 200
  public static let tabBarHeight: CGFloat = 30
  public static let footerHeight: CGFloat = 39
  public static let settingsInitialHeight: CGFloat = 480
  public static let historyInitialHeight: CGFloat = 620
  public static let historyChartHeight: CGFloat = 500
  public static let usageInitialHeight: CGFloat = 760
  public static let margin: CGFloat = 12

  public static func contentWidth(for tab: PopoverTab) -> CGFloat {
    stableContentWidth
  }

  public static func tabWidth(for tab: PopoverTab) -> CGFloat {
    stableTabWidth
  }

  public static func stableWidth(maximum: CGFloat = stableTabWidth) -> CGFloat {
    min(stableTabWidth, max(maximum, 0))
  }

  public static func visibleFrame(_ visibleFrame: CGRect?, cappedTo width: CGFloat?) -> CGRect? {
    guard let visibleFrame else { return nil }
    guard let width else { return visibleFrame }
    let cappedWidth = min(width, visibleFrame.width)
    return CGRect(
      x: visibleFrame.maxX - cappedWidth, y: visibleFrame.minY,
      width: cappedWidth, height: visibleFrame.height)
  }

  public static func preferredHeight(for tab: PopoverTab, measured: CGFloat? = nil) -> CGFloat {
    switch tab {
    case .usage: measured ?? usageInitialHeight
    case .history: measured ?? historyInitialHeight
    case .settings: measured ?? settingsInitialHeight
    }
  }

  public static func settingsHeight(_ input: SettingsHeightInput) -> CGFloat {
    let sectionSpacing = CGFloat(max(input.mountedSections.count - 1, 0)) * 12
    var height = contentPadding * 2 + sectionSpacing + 34
    for section in input.mountedSections {
      height += 30
      switch section {
      case .about:
        height += 104 + (input.showsUpdates ? 30 : 0)
      case .menuBar:
        height += 112 + (input.showsCustomTemplate ? 42 : 0)
        if input.showsModelFilter {
          height += 52 + CGFloat(max(input.providerCount, 0)) * 36 + CGFloat(max(input.modelCount, 0)) * 48
        }
      case .providers:
        height += 62 + CGFloat(max(input.providerCount, 0)) * 68
      case .data:
        height += 82
      case .notifications:
        height += 58
      case .log:
        height += 96 + CGFloat(min(max(input.logLineCount, 0), 8)) * 14
      }
    }
    return max(ceil(height), minimumHeight)
  }

  public static func maxSize(
    anchor: CGRect, visibleFrame: CGRect, popoverChromeSize: CGSize = .zero
  ) -> CGSize {
    let chromeHeight = max(popoverChromeSize.height, 0)
    let drawableHeight = anchor.minY - visibleFrame.minY - margin - chromeHeight
    // A zero or off-screen anchor is transient while the status item gains a window. Keep that first frame visible,
    // but never make the fallback taller than the screen can draw.
    let fallbackHeight = min(minimumHeight, max(visibleFrame.height - margin - chromeHeight, 0))
    return CGSize(
      width: stableWidth(maximum: visibleFrame.width - margin * 2 - max(popoverChromeSize.width, 0)),
      height: drawableHeight > 0 ? drawableHeight : fallbackHeight)
  }

  public static func maximumBodyHeight(
    anchor: CGRect, visibleFrame: CGRect, chromeHeight: CGFloat
  ) -> CGFloat {
    max(maxSize(anchor: anchor, visibleFrame: visibleFrame).height - chromeHeight, 0)
  }

  public static func clamp(_ size: CGSize, maximum: CGSize) -> CGSize {
    CGSize(
      width: min(max(size.width, minimumWidth), max(maximum.width, 0)),
      height: min(max(size.height, minimumHeight), max(maximum.height, 0)))
  }

  public static func recoveredFrame(
    windowFrame: CGRect, visibleFrame: CGRect, margin: CGFloat = margin
  ) -> CGRect {
    CGRect(
      origin: CGPoint(
        x: max(visibleFrame.maxX - windowFrame.width - margin, visibleFrame.minX),
        y: max(visibleFrame.maxY - windowFrame.height, visibleFrame.minY)),
      size: windowFrame.size)
  }

  public static func pinnedOrigin(lastTopCenter: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
    return CGPoint(
      x: min(max(lastTopCenter.x - size.width / 2, visibleFrame.minX), visibleFrame.maxX - size.width),
      y: min(max(lastTopCenter.y - size.height, visibleFrame.minY), visibleFrame.maxY - size.height))
  }
}
