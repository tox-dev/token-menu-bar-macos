import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

@Test(arguments: [
  (QuotaAvailability.current, ProviderPrimaryAction.refresh), (.stale, .refresh), (.loading, .refresh),
  (.authenticationRequired, .signIn), (.disabled, .setup), (.networkUnavailable, .retry),
  (.rateLimited, .retry), (.unavailable, .retry),
])
func providerPrimaryActionMatchesRecovery(availability: QuotaAvailability, expected: ProviderPrimaryAction) {
  #expect(ProviderPrimaryAction(availability: availability, issue: nil) == expected)
}

@Test(arguments: [
  ProviderRecoveryIssue.Kind.credentialUnreadable, .resourceAccess, .accountUnsupported,
])
func providerPrimaryActionDoesNotLoginToRepairAccess(kind: ProviderRecoveryIssue.Kind) {
  let issue = ProviderRecoveryIssue(kind: kind, title: "Access needed", detail: "Fixture", action: .checkAgain)
  #expect(ProviderPrimaryAction(availability: .authenticationRequired, issue: issue) == .setup)
}

@Test func providerPrimaryActionKeepsRefreshForCurrentDataWithSupportingAccessIssues() {
  let issue = ProviderRecoveryIssue(
    kind: .resourceAccess, title: "Local history access", detail: "Quota is available", action: .checkAgain)
  #expect(ProviderPrimaryAction(availability: .current, issue: issue) == .refresh)
}

@Test(arguments: [
  (ProviderPrimaryAction.refresh, "Refresh", "arrow.clockwise"), (.retry, "Retry", "arrow.clockwise"),
  (.signIn, "Sign in…", "key.fill"), (.setup, "Set up…", "slider.horizontal.3"),
])
func providerPrimaryActionExplainsItsControl(action: ProviderPrimaryAction, title: String, symbol: String) {
  #expect(action.title == title)
  #expect(action.symbol == symbol)
  #expect(!action.explanation.isEmpty)
}

@Test(arguments: [
  (ProviderID.claude, "claude.file", ProviderLoginCommand.claude), (.codex, "codex.keyring", .codex),
  (.cursor, "cursor.agent", .cursor), (.copilot, "copilot.keychain", .copilot), (.copilot, "copilot.file", .copilot),
])
func providerLoginUsesTheCredentialOwner(provider: ProviderID, source: String, expected: ProviderLoginCommand) {
  #expect(ProviderLoginCommand(provider: provider, source: provider.credentialSource(source)) == expected)
}

@Test(arguments: [
  (ProviderID.cursor, "cursor.app"), (.copilot, "copilot.environment"), (.copilot, "copilot.legacy-file"),
  (.gemini, "gemini.file"), (.antigravity, "antigravity.keychain"),
])
func providerLoginDoesNotReplaceOtherCredentialSources(provider: ProviderID, source: String) {
  #expect(ProviderLoginCommand(provider: provider, source: provider.credentialSource(source)) == nil)
}

@Test(arguments: ProviderLoginCommand.allCases)
func providerLoginWritesOnlyTheFixedCommand(command: ProviderLoginCommand) throws {
  let directory = temporaryDirectory().appendingPathComponent("Login")
  let url = try command.write(in: directory)

  #expect(try String(contentsOf: url, encoding: .utf8) == command.script)
  #expect(command.script.contains("\n\(command.rawValue)\n"))
  #expect(command.script.hasPrefix("#!/bin/zsh -l\n"))
  #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o700)
  #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
  #expect(try command.write(in: directory) == url)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
}

@Test func providerLoginPropagatesDocumentFailures() throws {
  let file = temporaryDirectory().appendingPathComponent("not-a-directory")
  try Data().write(to: file)
  #expect(throws: (any Error).self) { try ProviderLoginCommand.claude.write(in: file) }
}

@Test func providerLoginPreservesConfiguredHomesAndDoesNotExportTokens() {
  let configured = ProviderLoginCommand.configurationDirectories(
    environment: ["CODEX_HOME": "/fixture/team home", "GITHUB_TOKEN": "fixture-secret"])
  #expect(configured[.codex]?.path == "/fixture/team home")
  #expect(configured[.claude] == nil)
  #expect(configured[.copilot] == nil)
  #expect(!ProviderLoginCommand.copilot.script(configurationDirectory: configured[.copilot]).contains("fixture-secret"))
}

@Test func providerLoginDoesNotChangeTheDefaultClaudeKeychainNamespace() {
  #expect(ProviderLoginCommand.claude.script.contains("unset CLAUDE_CONFIG_DIR\nclaude auth login"))
}

@Test func providerLoginFlowWaitsForLaunchBeforeHandlingReturn() {
  var flow = ProviderLoginFlow()
  #expect(flow.begin(.claude) == true)
  #expect(flow.takeReturnedProviders().isEmpty)
  #expect(flow.begin(.claude) == false)
  flow.opened(.claude)
  #expect(flow.begin(.claude) == false)
  #expect(flow.takeReturnedProviders() == [.claude])
  #expect(flow.takeReturnedProviders().isEmpty)
  #expect(flow.begin(.claude) == true)
}

@Test func providerLoginFlowAllowsRetryAfterFailure() {
  var flow = ProviderLoginFlow()
  #expect(flow.begin(.codex) == true)
  flow.failed(.codex)
  #expect(flow.begin(.codex) == true)
}

@Test func providerLoginQuotesConfigurationPaths() {
  let script = ProviderLoginCommand.claude.script(configurationDirectory: URL(filePath: "/fixture/O'Brien; space"))
  #expect(script.contains("export CLAUDE_CONFIG_DIR='/fixture/O'\\''Brien; space'\nclaude auth login"))
}
