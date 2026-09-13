import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let identity = ProviderIdentity(
  planName: "Team", tier: "Standard", email: "dev@example.com", organization: "Acme Corp",
  subscriptionActiveUntil: fixedNow.addingTimeInterval(86400))

private func snapshot(_ identity: ProviderIdentity) -> ProviderSnapshot {
  ProviderSnapshot(provider: .codex, identity: identity, windows: [], fetchedAt: fixedNow)
}

@Test func hiddenIdentityKeepsThePlanAndMasksTheAccount() {
  let hidden = identity.hidingPersonalInformation
  #expect(hidden.email == "account")
  #expect(hidden.organization == "workspace")
  #expect(hidden.planName == "Team")
  #expect(hidden.tier == "Standard")
  #expect(hidden.subscriptionActiveUntil == identity.subscriptionActiveUntil)
  #expect(identity.personalReplacements.map(\.value) == ["dev@example.com", "Acme Corp"])
  #expect(identity.personalReplacements.map(\.replacement) == ["account", "workspace"])
  let plain = ProviderIdentity(planName: "Pro")
  #expect(plain.hidingPersonalInformation == plain)
  #expect(plain.personalReplacements.isEmpty)
}

@Test func chipsMaskTheAccountAndWorkspaceWhenAsked() {
  let renews = "Renews \(fixedNow.addingTimeInterval(86400).formatted(date: .abbreviated, time: .omitted))"
  #expect(
    UsagePresenter.chips(provider: .codex, snapshot: snapshot(identity), hidePersonalInformation: true).map(\.text)
      == ["Team", "account", "workspace", renews])
  #expect(
    UsagePresenter.chips(provider: .codex, snapshot: snapshot(identity)).map(\.text)
      == ["Team", "dev@example.com", "Acme Corp", renews])
}

@Test func chipsStillDropThePersonalOrganizationWhenMasked() {
  let personal = ProviderIdentity(
    planName: "Pro", email: "dev@example.com", organization: "dev@example.com's Organization")
  #expect(
    UsagePresenter.chips(provider: .codex, snapshot: snapshot(personal), hidePersonalInformation: true).map(\.text)
      == ["Pro", "account"])
}

@Test func cardIdentityFollowsTheSetting() {
  let state = ProviderState(snapshot: snapshot(identity), availability: .current)
  let hidden = UsagePresenter.card(
    provider: .codex, state: state, samples: [:], options: UsageDisplayOptions(hidePersonalInformation: true),
    now: fixedNow)
  #expect(hidden.identity == identity.hidingPersonalInformation)
  #expect(UsagePresenter.card(provider: .codex, state: state, samples: [:], now: fixedNow).identity == identity)
}

@Test func settingsProviderPresentationMasksTheAccount() {
  let state = ProviderState(snapshot: snapshot(identity), availability: .current)
  #expect(
    SettingsProviderPresentation(state: state, now: fixedNow, hidePersonalInformation: true).identity
      == "account · workspace · Team · Standard")
  #expect(
    SettingsProviderPresentation(state: state, now: fixedNow).identity
      == "dev@example.com · Acme Corp · Team · Standard")
}

@Test @MainActor func diagnosticsMaskTheWorkspaceWhereverItAppears() {
  let settings = Settings(defaults: testDefaults())
  settings.setProvider(.codex, enabled: true)
  let state = AppState()
  state.update(.codex) {
    $0.snapshot = snapshot(identity)
    $0.availability = .current
    $0.lastError = "Acme Corp rejected the request"
  }
  let log = makeLog()
  log.log("workspace Acme Corp")
  let app = AppInfo(
    name: "Token Menu Bar", version: "1", build: "1", bundleIdentifier: "dev.tox.token-menu-bar", isAppStore: false,
    repository: AppInfo.repositoryURL)
  let visible = Diagnostics.report(
    app: app, osVersion: "26", settings: settings, state: state, historyLocation: nil, log: log, now: fixedNow)
  #expect(visible.contains("error: Acme Corp rejected"))
  settings.hidePersonalInformation = true
  let hidden = Diagnostics.report(
    app: app, osVersion: "26", settings: settings, state: state, historyLocation: nil, log: log, now: fixedNow)
  #expect(!hidden.contains("Acme Corp"))
  #expect(hidden.contains("error: workspace rejected the request"))
  #expect(hidden.hasSuffix("[info] workspace workspace"))
  #expect(hidden.contains("plan Team"))
}
