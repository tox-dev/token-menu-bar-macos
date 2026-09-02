import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func coverageGateSettingsBindingsUseVisibleContentCounts() throws {
  let environment = try makeEnvironment()
  environment.settings.hideUnusedModels = true
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)
  let usedModels = environment.state.snapshots.values.reduce(0) {
    $0 + $1.windows.count(where: { $0.usedPercent > 0 })
  }

  #expect(tab.heightInput.modelCount == usedModels)

  tab.refreshMinutes(.claude).wrappedValue = 7
  #expect(environment.settings.refreshInterval(for: .claude) == 420)

  tab.settingWithoutRefresh(\.showAllProviders).wrappedValue = true
  #expect(environment.settings.showAllProviders)
}

@Test @MainActor func coverageGateInactiveProviderRecoveryAppearsOnlyWhenSetupIsVisible() throws {
  let environment = try makeEnvironment(populate: false)
  let issue = ProviderRecoveryIssue(
    kind: .credentialMissing, title: "Sign in needed", detail: "No credential was found.", action: .checkAgain)
  environment.state.update(.gemini) { $0.recoveryIssue = issue }
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)

  #expect(tab.actionableRecoveryIssue(.gemini) == nil)
  environment.settings.showAllProviders = true
  #expect(tab.actionableRecoveryIssue(.gemini) == issue)
}

@Test @MainActor func coverageGateSettingsProviderResourceActionGrantsAccess() throws {
  let environment = try makeEnvironment()
  let resource = try #require(ProviderID.claude.sandboxResources.first)
  environment.state.update(.claude) {
    $0.resourceAccess = [ResourceAccessState(resource: resource, health: .needed)]
  }
  var granted: [SandboxResource] = []
  environment.actions.grantAccess = { granted.append($0) }
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)

  #expect(tab.actionableRecoveryIssue(.claude)?.action == .grantAccess(resource))
  tab.resourceGrantAction(resource)()

  let buttons = settingsGateNativeButtons(in: tab.providerRow(.claude))
  for button in buttons { button.action() }
  #expect(!granted.isEmpty)
  #expect(granted.allSatisfy { $0 == resource })
}

@Test @MainActor func coverageGateSettingsRespondsToAChangedProviderFocusRequest() async throws {
  let environment = try makeEnvironment()
  let hosting = host(
    SettingsTab(environment: environment, providerFocusRequest: nil, mountsIncrementally: false),
    width: 880, height: 1_200)
  let request = ProviderSettingsFocusRequest(provider: .codex)
  environment.providerFocusRequest = request
  hosting.rootView = SettingsTab(
    environment: environment, providerFocusRequest: request, mountsIncrementally: false)
  hosting.layoutSubtreeIfNeeded()

  await waitUntil { environment.providerFocusRequest == nil }
  #expect(environment.providerFocusRequest == nil)
}

@MainActor
private func settingsGateNativeButtons(in value: Any, depth: Int = 0) -> [NativeActionButton<Text>] {
  if let button = value as? NativeActionButton<Text> { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap {
    settingsGateNativeButtons(in: $0.value, depth: depth + 1)
  }
}
