import CoreGraphics
import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func tiersReshapeTheStatusModel() {
  let configured = StatusItemBuilder.build(input())
  #expect(configured.cells.count == 3)
  #expect(StatusItemBuilder.build(input(tier: .stacked)) == configured)
  #expect(StatusItemBuilder.build(input(tier: .worstPerProvider)).cells.map(\.id) == ["claude:weekly", "codex:weekly"])
  #expect(StatusItemBuilder.build(input(tier: .miniBars)).cells.allSatisfy { $0.isMiniBar })
  let icon = StatusItemBuilder.build(input(tier: .iconOnly))
  #expect(icon.cells.isEmpty && icon.showsIcon && !icon.countdownActive)
  #expect(StatusItemBuilder.build(input(format: .inline, tier: .stacked)).cells.first?.lines.count == 2)
  #expect(input(format: .miniBars, tier: .iconOnly).effectiveFormat == .miniBars)
  #expect(input(format: .inline).with(tier: .miniBars).tier == .miniBars)
  let percentOrdered = StatusItemInput(
    snapshots: input().snapshots, availability: [:], selectedKeys: input().selectedKeys, format: .stacked,
    customTemplate: "", decimals: 0, hideZeroCells: true, order: .percent, labels: [:], now: fixedNow,
    tier: .worstPerProvider)
  #expect(StatusItemBuilder.build(percentOrdered).cells.map(\.id) == ["codex:weekly", "claude:weekly"])
}

private func input(
  format: StatusFormat = .stacked, tier: StatusTier = .configured, hideZero: Bool = true
)
  -> StatusItemInput
{
  let claude = ProviderSnapshot(
    provider: .claude,
    windows: [
      QuotaWindow(id: "session", label: "Session", group: .session, usedPercent: 36, resetsAt: fixedNow),
      QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 61, resetsAt: fixedNow),
    ], fetchedAt: fixedNow)
  let codex = ProviderSnapshot(
    provider: .codex,
    windows: [QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 80, resetsAt: fixedNow)],
    fetchedAt: fixedNow)
  let snapshots: [ProviderID: ProviderSnapshot] = [.claude: claude, .codex: codex]
  return StatusItemInput(
    snapshots: snapshots, availability: [.claude: .current, .codex: .current],
    selectedKeys: StatusItemBuilder.defaultSelection(snapshots), format: format, customTemplate: "{cell}",
    decimals: 0, hideZeroCells: hideZero, order: .provider, labels: [:], now: fixedNow, tier: tier)
}

@Test func candidatesDedupeEqualModels() {
  let candidates = StatusItemBuilder.candidates(input())
  #expect(candidates.count == 4)
  #expect(candidates.first == StatusItemBuilder.build(input()))
  #expect(candidates.last?.cells.isEmpty == true)
  #expect(Set(candidates).count == candidates.count)
  #expect(StatusItemBuilder.candidates(input(format: .miniBars)).count == 4)
}

@Test func plannerStepsDownRemembersAndForgets() {
  var planner = AdaptiveWidthPlanner()
  #expect(planner.begin(context: "app", ladderCount: 3) == 0)
  #expect(planner.didNotFit(ladderCount: 3) == 1)
  #expect(planner.didNotFit(ladderCount: 3) == 2)
  #expect(planner.didNotFit(ladderCount: 3) == nil)
  #expect(planner.index == 2)
  planner.didFit(context: "app")
  #expect(planner.begin(context: "other", ladderCount: 3) == 0)
  // one tier wider than what last fit, so space freed since then gets retried
  #expect(planner.begin(context: "app", ladderCount: 3) == 1)
  #expect(planner.begin(context: "app", ladderCount: 2) == 0)
  #expect(planner.didNotFit(ladderCount: 3) == 1)
  planner.didFit(context: "app")
  #expect(planner.begin(context: "app", ladderCount: 3) == 0)
  planner.forget()
  #expect(planner.begin(context: "app", ladderCount: 3) == 0)
  #expect(planner.begin(context: "app", ladderCount: 0) == 0)
  #expect(planner == AdaptiveWidthPlanner())
}

@Test func ladderKeepsOnlyNarrowerUniqueModels() {
  let candidates = StatusItemBuilder.candidates(input())
  let ladder = AdaptiveWidthPlanner.ladder(candidates, widths: [100, 120, 60, 80])
  #expect(ladder == [candidates[0], candidates[3], candidates[2]])
  #expect(AdaptiveWidthPlanner.ladder([candidates[0], candidates[0]], widths: [100, 50]) == [candidates[0]])
  #expect(AdaptiveWidthPlanner.ladder([], widths: []).isEmpty)
}

@Test func plannerCanSelectItsNarrowestTier() {
  var planner = AdaptiveWidthPlanner()
  #expect(planner.selectNarrowest(ladderCount: 5) == 4)
  #expect(planner.index == 4)
  #expect(planner.selectNarrowest(ladderCount: 0) == 0)
}

@Test func notchDetectionUsesAuxiliaryAreas() {
  let left = CGRect(x: 0, y: 0, width: 400, height: 30)
  let right = CGRect(x: 600, y: 0, width: 400, height: 30)
  #expect(
    AdaptiveWidthPlanner.hiddenByNotch(
      itemFrame: CGRect(x: 500, y: 0, width: 50, height: 30), leftArea: left, rightArea: right))
  #expect(
    AdaptiveWidthPlanner.hiddenByNotch(
      itemFrame: CGRect(x: 580, y: 0, width: 50, height: 30), leftArea: left, rightArea: right))
  #expect(
    !AdaptiveWidthPlanner.hiddenByNotch(
      itemFrame: CGRect(x: 700, y: 0, width: 50, height: 30), leftArea: left, rightArea: right))
  #expect(
    !AdaptiveWidthPlanner.hiddenByNotch(
      itemFrame: CGRect(x: 100, y: 0, width: 50, height: 30), leftArea: left, rightArea: right))
  #expect(
    !AdaptiveWidthPlanner.hiddenByNotch(
      itemFrame: CGRect(x: 500, y: 0, width: 50, height: 30), leftArea: nil, rightArea: right))
}

@Test func onScreenNeedsOverlapAndWidth() {
  let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
  #expect(
    AdaptiveWidthPlanner.isOnScreen(itemFrame: CGRect(x: 100, y: 0, width: 60, height: 24), screenFrames: [screen]))
  #expect(
    AdaptiveWidthPlanner.isOnScreen(itemFrame: CGRect(x: 1430, y: 0, width: 60, height: 24), screenFrames: [screen]))
  #expect(
    !AdaptiveWidthPlanner.isOnScreen(itemFrame: CGRect(x: 5000, y: 0, width: 60, height: 24), screenFrames: [screen]))
  #expect(
    !AdaptiveWidthPlanner.isOnScreen(itemFrame: CGRect(x: 10, y: 0, width: 0, height: 24), screenFrames: [screen]))
  #expect(!AdaptiveWidthPlanner.isOnScreen(itemFrame: screen, screenFrames: []))
}

@Test(arguments: [(1, [13.0]), (2, [9.0, 11.5])])
func fontSizesMatchTheLineCount(lineCount: Int, expected: [Double]) {
  #expect(StatusMetrics.fontSizes(height: 24, lineCount: lineCount) == expected)
}

@Test func threeLinesShrinkWithTheBarHeight() {
  #expect(StatusMetrics.fontSizes(height: 24, lineCount: 3) == [8, 8, 8])
  #expect(StatusMetrics.fontSizes(height: 120, lineCount: 3) == [9, 9, 9])
  #expect(StatusMetrics.fontSizes(height: 1, lineCount: 3).allSatisfy { $0 == StatusMetrics.minFontSize })
}
