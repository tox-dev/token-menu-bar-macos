import CoreGraphics
import Foundation
import Testing

@testable import TokenMenuBarCore

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

@Test func tiersReshapeTheStatusModel() {
  let configured = StatusItemBuilder.build(input())
  #expect(configured.cells.count == 3)
  #expect(StatusItemBuilder.build(input(tier: .stacked)) == configured)
  let worst = StatusItemBuilder.build(input(tier: .worstPerProvider))
  #expect(worst.cells.map(\.id) == ["claude:weekly", "codex:weekly"])
  let mini = StatusItemBuilder.build(input(tier: .miniBars))
  #expect(mini.cells.allSatisfy { $0.isMiniBar })
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
  #expect(planner.begin(context: "app", ladderCount: 3) == 2)
  #expect(planner.begin(context: "app", ladderCount: 2) == 1)
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
