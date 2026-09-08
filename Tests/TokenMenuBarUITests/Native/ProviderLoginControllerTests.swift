import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func appProviderLoginStartsOnceAndRetainsStaleState() async throws {
  var (dependencies, _) = try makeDependencies()
  dependencies.isSandboxed = false
  dependencies.state.update(.claude) {
    $0.snapshot = sampleSnapshot(.claude)
    $0.availability = .authenticationRequired
  }
  var commands: [ProviderLoginCommand] = []
  dependencies.openProviderLogin = { commands.append($0) }
  let controller = AppController(dependencies: dependencies)
  defer { controller.stop() }

  controller.environment.actions.signInProvider(.claude)
  #expect(await waitUntil { commands == [.claude] })
  await controller.signInProvider(.claude)

  #expect(commands == [.claude])
  #expect(dependencies.state.state(for: .claude).availability == .authenticationRequired)
  #expect(dependencies.state.state(for: .claude).snapshot == sampleSnapshot(.claude))
}

@Test(arguments: ["demo", "sandbox", "unsupported", "no-launcher"]) @MainActor
func appProviderLoginFallsBackToInstructions(reason: String) async throws {
  var (dependencies, _) = try makeDependencies(isDemo: reason == "demo")
  dependencies.isSandboxed = reason == "sandbox"
  if reason != "no-launcher" { dependencies.openProviderLogin = { _ in Issue.record("Opened a login") } }
  let controller = AppController(dependencies: dependencies)
  defer { controller.stop() }
  let provider: ProviderID = reason == "unsupported" ? .gemini : .claude

  await controller.signInProvider(provider)

  #expect(controller.environment.providerFocusRequest?.provider == provider)
  #expect(dependencies.settings.lastTab == .settings)
}

@Test @MainActor func appProviderLoginFailureShowsRecoveryAndAllowsRetry() async throws {
  var (dependencies, _) = try makeDependencies()
  dependencies.isSandboxed = false
  var attempts = 0
  dependencies.openProviderLogin = { _ in
    attempts += 1
    throw CocoaError(.fileNoSuchFile)
  }
  let controller = AppController(dependencies: dependencies)
  defer { controller.stop() }

  await controller.signInProvider(.claude)
  await controller.signInProvider(.claude)

  #expect(attempts == 2)
  #expect(controller.environment.providerLoginErrors[.claude]?.contains("Could not open sign-in") == true)
  #expect(controller.environment.providerFocusRequest?.provider == .claude)
}

@Test @MainActor func appProviderLoginRefreshesWhenReturningFromTerminal() async throws {
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  var (dependencies, _) = try makeDependencies(providers: [provider])
  dependencies.isSandboxed = false
  dependencies.settings.setProvider(.claude, enabled: true)
  dependencies.openProviderLogin = { _ in }
  dependencies.state.update(.claude) { $0.availability = .authenticationRequired }
  let controller = AppController(dependencies: dependencies)
  defer { controller.stop() }
  await controller.signInProvider(.claude)

  controller.handleApplicationActivation()

  #expect(await waitUntil { dependencies.state.state(for: .claude).availability == .current })
  #expect(dependencies.state.state(for: .claude).snapshot == sampleSnapshot(.claude))
}
