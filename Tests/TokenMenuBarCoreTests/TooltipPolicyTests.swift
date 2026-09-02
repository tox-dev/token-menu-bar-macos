import CoreGraphics
import Testing

@testable import TokenMenuBarCore

@Test func tooltipTimingMatchesInteractionContract() {
  #expect(TooltipTiming.presentationDelay == .milliseconds(150))
  #expect(TooltipTiming.dismissalDelay == .milliseconds(150))
  #expect(TooltipTiming.fadeDuration == 0.09)
}

@Test func tooltipArbiterRejectsStalePresentation() {
  var arbiter = TooltipArbiter()
  let first = arbiter.arm(owner: TooltipOwner(rawValue: 1))!
  let second = arbiter.arm(owner: TooltipOwner(rawValue: 2))!
  let firstPresented = arbiter.present(first)
  let secondPresented = arbiter.present(second)

  #expect(!firstPresented)
  #expect(secondPresented)
  #expect(arbiter.visible == second)
}

@Test func tooltipArbiterIgnoresStaleDismissal() {
  var arbiter = TooltipArbiter()
  _ = arbiter.arm(owner: TooltipOwner(rawValue: 1))
  let second = arbiter.arm(owner: TooltipOwner(rawValue: 2))!
  let dismissed = arbiter.dismiss(owner: TooltipOwner(rawValue: 1))

  #expect(!dismissed)
  #expect(arbiter.pending == second)
}

@Test func tooltipArbiterKeepsVisibleContentWhileItsReplacementIsPending() {
  var arbiter = TooltipArbiter()
  let first = arbiter.arm(owner: TooltipOwner(rawValue: 1))!
  _ = arbiter.present(first)
  let second = arbiter.arm(owner: TooltipOwner(rawValue: 2))!

  #expect(arbiter.visible == first)
  #expect(arbiter.pending == second)
}

@Test func tooltipArbiterCancelsAPendingReplacementWithoutDismissingVisibleContent() {
  var arbiter = TooltipArbiter()
  let first = arbiter.arm(owner: TooltipOwner(rawValue: 1))!
  _ = arbiter.present(first)
  let second = arbiter.arm(owner: TooltipOwner(rawValue: 2))!
  let dismissed = arbiter.dismiss(owner: second.owner)

  #expect(dismissed)
  #expect(arbiter.pending == nil)
  #expect(arbiter.visible == first)
}

@Test func tooltipArbiterDoesNotRearmCurrentOwner() {
  var arbiter = TooltipArbiter()
  let request = arbiter.arm(owner: TooltipOwner(rawValue: 1))!
  let duplicatePending = arbiter.arm(owner: request.owner)
  let presented = arbiter.present(request)
  let duplicateVisible = arbiter.arm(owner: request.owner)
  #expect(duplicatePending == nil)
  #expect(presented)
  #expect(duplicateVisible == nil)
}

@Test func tooltipArbiterDismissesMatchingOwner() {
  var arbiter = TooltipArbiter()
  let request = arbiter.arm(owner: TooltipOwner(rawValue: 1))!
  let presented = arbiter.present(request)
  let dismissed = arbiter.dismiss(owner: request.owner)
  #expect(presented)
  #expect(dismissed)
  #expect(arbiter.pending == nil)
  #expect(arbiter.visible == nil)
  let duplicateDismiss = arbiter.dismiss(owner: request.owner)
  #expect(!duplicateDismiss)
}

@Test(
  arguments: [
    (
      "center below", CGRect(x: 100, y: 200, width: 40, height: 20), CGSize(width: 80, height: 40),
      CGRect(x: 0, y: 0, width: 300, height: 300), CGPoint(x: 80, y: 153), TooltipSide.below
    ),
    (
      "flip above", CGRect(x: 100, y: 20, width: 40, height: 20), CGSize(width: 80, height: 40),
      CGRect(x: 0, y: 0, width: 300, height: 300), CGPoint(x: 80, y: 47), TooltipSide.above
    ),
    (
      "clamp left", CGRect(x: -95, y: 200, width: 10, height: 20), CGSize(width: 80, height: 40),
      CGRect(x: -100, y: 0, width: 300, height: 300), CGPoint(x: -92, y: 153), TooltipSide.below
    ),
    (
      "clamp right", CGRect(x: 185, y: 200, width: 10, height: 20), CGSize(width: 80, height: 40),
      CGRect(x: -100, y: 0, width: 300, height: 300), CGPoint(x: 112, y: 153), TooltipSide.below
    ),
  ]
)
func tooltipPlacementStaysInsideVisibleFrame(
  _: String,
  anchor: CGRect,
  size: CGSize,
  visibleFrame: CGRect,
  expectedOrigin: CGPoint,
  expectedSide: TooltipSide
) {
  let placement = TooltipGeometry.placement(anchor: anchor, tooltipSize: size, visibleFrame: visibleFrame)
  #expect(placement.origin == expectedOrigin)
  #expect(placement.side == expectedSide)
}

@Test func tooltipPlacementClampsOversizedContentToTheSafeOrigin() {
  let placement = TooltipGeometry.placement(
    anchor: CGRect(x: 20, y: 20, width: 10, height: 10),
    tooltipSize: CGSize(width: 500, height: 500),
    visibleFrame: CGRect(x: -100, y: -50, width: 300, height: 200)
  )
  #expect(placement.origin == CGPoint(x: -92, y: -42))
  #expect(placement.side == .above)
}
