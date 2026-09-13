import AppKit
import Foundation
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test(arguments: [ProviderPrimaryAction.refresh, .retry, .signIn, .setup]) @MainActor
func providerPrimaryActionsUseAvailableSymbols(action: ProviderPrimaryAction) {
  #expect(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil)
}

@Test(arguments: [
  (QuotaAvailability.current, ProviderPrimaryAction.refresh), (.networkUnavailable, .retry),
  (.authenticationRequired, .signIn), (.disabled, .setup),
]) @MainActor
func providerPrimaryButtonRoutesTheState(availability: QuotaAvailability, expected: ProviderPrimaryAction) throws {
  let environment = try makeEnvironment()
  var actions: [ProviderPrimaryAction] = []
  environment.actions.signInProvider = {
    #expect($0 == .claude)
    actions.append(.signIn)
  }
  environment.actions.showProviders = {
    #expect($0 == .claude)
    actions.append(.setup)
  }
  let card = UsagePresenter.card(
    provider: .claude,
    state: ProviderState(snapshot: sampleSnapshot(.claude), availability: availability), samples: [:], now: fixedNow)
  let view = ProviderCardView(card: card, environment: environment) {
    #expect($0 == .claude)
    actions.append(availability == .networkUnavailable ? .retry : .refresh)
  }

  view.refresh()

  #expect(view.primaryAction == expected)
  #expect(actions == [expected])
  #expect(inkFraction(view) > 0)
}

@Test @MainActor func providerLoginLauncherOpensThePreparedDocument() async throws {
  let directory = loginTestDirectory()
  var opened: [URL] = []
  let launch = try #require(ProviderLoginLauncher.make(directory: directory, enabled: true) { opened.append($0) })

  try await launch(.claude)

  #expect(opened.count == 1)
  #expect(try String(contentsOf: #require(opened.first), encoding: .utf8) == ProviderLoginCommand.claude.script)
}

@Test(arguments: [QuotaAvailability.current, .networkUnavailable]) @MainActor
func providerRefreshIconRequestsOnlyItsProvider(availability: QuotaAvailability) throws {
  let environment = try makeEnvironment()
  let card = UsagePresenter.card(
    provider: .claude,
    state: ProviderState(snapshot: sampleSnapshot(.claude), availability: availability), samples: [:], now: fixedNow)
  var requested: [ProviderID] = []
  let view = ProviderCardView(card: card, environment: environment) { requested.append($0) }
  let label = availability == .current ? "Refresh Claude" : "Retry Claude"

  try #require(loginButtons(in: view.body, of: NativeIconButton.self).first { $0.accessibilityLabel == label }).action()

  #expect(requested == [.claude])
}

@Test @MainActor func providerLoginLauncherIsAbsentInIsolatedBuilds() {
  let directory = loginTestDirectory().appendingPathComponent("unused")
  let launch = ProviderLoginLauncher.make(directory: directory, enabled: false) { _ in Issue.record("Opened login") }

  #expect(launch == nil)
  #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test @MainActor func providerLoginLauncherReportsLaunchFailure() async throws {
  let launch = try #require(
    ProviderLoginLauncher.make(directory: loginTestDirectory(), enabled: true) { _ in
      throw CocoaError(.fileNoSuchFile)
    })

  await #expect(throws: CocoaError(.fileNoSuchFile)) { try await launch(.claude) }
}

private func loginTestDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("tmb-login-test-\(UUID().uuidString)")
}

@Test @MainActor func providerLoginSettingsButtonStartsItsProviderFlow() throws {
  let environment = try makeEnvironment(populate: false)
  environment.canLaunchProviderLogin = true
  environment.settings.setProvider(.claude, enabled: true)
  environment.state.update(.claude) {
    $0.snapshot = sampleSnapshot(.claude)
    $0.availability = .authenticationRequired
    $0.recoveryIssue = ProviderRecoveryIssue(
      kind: .credentialExpired, title: "Sign in", detail: "Fixture expired", action: .copyCommand("claude auth login"))
  }
  environment.providerLoginErrors[.claude] = "Fixture launch failure"
  var requested: [ProviderID] = []
  environment.actions.signInProvider = { requested.append($0) }
  let view = SettingsTab(environment: environment)
  let buttons = loginButtons(in: view.providerRow(.claude), of: NativeActionButton<Label<Text, Image>>.self)
  try #require(buttons.first).action()
  #expect(requested == [.claude])
  #expect(inkFraction(view.providerRow(.claude)) > 0)
  let card = UsagePresenter.card(
    provider: .claude, state: environment.state.state(for: .claude), samples: [:], now: fixedNow)
  #expect(inkFraction(ProviderCardView(card: card, environment: environment, onRefreshProvider: { _ in })) > 0)
}

@MainActor private func loginButtons<Value>(in value: Any, of type: Value.Type, depth: Int = 0) -> [Value] {
  if let button = value as? Value { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap { loginButtons(in: $0.value, of: type, depth: depth + 1) }
}
