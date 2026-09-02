import AppKit
import TokenMenuBarCore

@MainActor
protocol TooltipPanelPresenting: AnyObject {
  var isVisible: Bool { get }

  func show(
    content: TooltipContent,
    anchorRect: CGRect,
    visibleFrame: CGRect,
    parentWindow: NSWindow,
    reduceMotion: Bool,
    reduceTransparency: Bool
  )
  func hide()
  func tearDown()
}

@MainActor
final class TooltipPanel: NSPanel, TooltipPanelPresenting {
  private static let horizontalPadding: CGFloat = 10
  private static let verticalPadding: CGFloat = 8

  private weak var ownerWindow: NSWindow?
  private let effectView = NSVisualEffectView()
  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    animationBehavior = .none
    backgroundColor = .clear
    collectionBehavior = [.transient, .ignoresCycle]
    hasShadow = true
    hidesOnDeactivate = false
    ignoresMouseEvents = true
    isMovable = false
    isOpaque = false
    isReleasedWhenClosed = false
    level = .floating

    effectView.blendingMode = .behindWindow
    effectView.material = .toolTip
    effectView.state = .active
    effectView.wantsLayer = true
    effectView.layer?.cornerRadius = 8
    effectView.layer?.masksToBounds = true
    effectView.layer?.borderWidth = 1
    effectView.addSubview(label)
    effectView.setAccessibilityElement(false)

    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.drawsBackground = false
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.setAccessibilityElement(false)
    contentView = effectView
    setAccessibilityElement(false)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func show(
    content: TooltipContent,
    anchorRect: CGRect,
    visibleFrame: CGRect,
    parentWindow: NSWindow,
    reduceMotion: Bool,
    reduceTransparency: Bool
  ) {
    appearance = parentWindow.effectiveAppearance
    effectView.state = reduceTransparency ? .inactive : .active
    effectView.layer?.backgroundColor =
      reduceTransparency ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
    effectView.layer?.borderColor = NSColor.separatorColor.cgColor

    let attributed = Self.attributedString(content)
    label.attributedStringValue = attributed
    let maximumPanelWidth = min(
      TooltipGeometry.maximumWidth,
      max(1, visibleFrame.width - TooltipGeometry.screenInset * 2)
    )
    let maximumTextWidth = max(1, maximumPanelWidth - Self.horizontalPadding * 2)
    let textBounds = attributed.boundingRect(
      with: CGSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
      options: [.usesFontLeading, .usesLineFragmentOrigin]
    )
    let textSize = CGSize(
      width: min(maximumTextWidth, max(1, ceil(textBounds.width))),
      height: max(1, ceil(textBounds.height))
    )
    let panelSize = CGSize(
      width: textSize.width + Self.horizontalPadding * 2,
      height: textSize.height + Self.verticalPadding * 2
    )
    label.frame = CGRect(origin: CGPoint(x: Self.horizontalPadding, y: Self.verticalPadding), size: textSize)
    effectView.frame = CGRect(origin: .zero, size: panelSize)

    let placement = TooltipGeometry.placement(
      anchor: anchorRect,
      tooltipSize: panelSize,
      visibleFrame: visibleFrame
    )
    if parent !== parentWindow {
      parent?.removeChildWindow(self)
      parentWindow.addChildWindow(self, ordered: .above)
    }
    ownerWindow = parentWindow
    setFrame(CGRect(origin: placement.origin, size: panelSize), display: false)

    alphaValue = reduceMotion ? 1 : 0
    orderFrontRegardless()
    guard !reduceMotion else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = TooltipTiming.fadeDuration
      animator().alphaValue = 1
    }
  }

  func hide() {
    alphaValue = 0
    ownerWindow?.removeChildWindow(self)
    ownerWindow = nil
    orderOut(nil)
  }

  func tearDown() {
    hide()
    contentView = nil
  }

  private static func attributedString(_ content: TooltipContent) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 2
    let value = NSMutableAttributedString(
      string: content.title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph,
      ]
    )
    value.append(NSAttributedString(string: "\n"))
    for span in content.body {
      let attributes: [NSAttributedString.Key: Any]
      switch span {
      case .code:
        attributes = [
          .backgroundColor: NSColor.quaternaryLabelColor,
          .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
          .foregroundColor: NSColor.labelColor,
          .paragraphStyle: paragraph,
        ]
      case .text:
        attributes = [
          .font: NSFont.systemFont(ofSize: 12),
          .foregroundColor: NSColor.labelColor,
          .paragraphStyle: paragraph,
        ]
      }
      value.append(NSAttributedString(string: span.text, attributes: attributes))
    }
    return value
  }
}
