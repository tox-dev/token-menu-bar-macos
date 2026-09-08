import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test(arguments: [ProviderID.claude, .codex, .gemini, .cursor, .copilot, .antigravity], [true, false]) @MainActor
func settingsShowsOnlyApplicableCollectionControls(provider: ProviderID, enabled: Bool) {
  let settings = Settings(defaults: testDefaults())
  settings.setProvider(provider, enabled: enabled)
  settings.notifications.notifyOnExpiringCredits = false
  let state = ProviderState(
    snapshot: ProviderSnapshot(
      provider: provider,
      windows: [
        QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 0, resetsAt: nil, duration: 604800)
      ],
      resetCredits: provider == .codex ? ResetCredits(available: 0, applicable: 0) : nil, fetchedAt: fixedNow),
    credentialState: .valid(expiresAt: nil))
  let presentation = SettingsContextPresentation(
    settings: settings, states: [provider: state], isSandboxed: false, loginStatus: .notRegistered)
  #expect(presentation.showsAnalyticsInterval == (enabled && [.claude, .codex].contains(provider)))
  #expect(presentation.showsPaceWorkdays == enabled)
  #expect(presentation.showsTokenRefresh == (enabled && [.claude, .codex, .gemini, .antigravity].contains(provider)))
  #expect(presentation.showsExpiringCredits == (enabled && provider == .codex))
}

@Test(arguments: [true, false]) @MainActor
func settingsSandboxHidesUnsupportedTokenRefresh(isSandboxed: Bool) {
  let settings = Settings(defaults: testDefaults())
  settings.setProvider(.gemini, enabled: true)
  let presentation = SettingsContextPresentation(
    settings: settings, states: [.gemini: ProviderState(credentialState: .valid(expiresAt: nil))],
    isSandboxed: isSandboxed, loginStatus: .enabled)
  #expect(presentation.showsTokenRefresh == !isSandboxed)
}

@Test @MainActor func localAntigravityDoesNotOfferUnrelatedOAuthRefresh() {
  let settings = Settings(defaults: testDefaults())
  let source = CredentialSource(
    id: "antigravity.local", provider: .antigravity, title: "Local session", detail: "Fixture")
  let presentation = SettingsContextPresentation(
    settings: settings, states: [.antigravity: ProviderState(credentialHealth: .valid(source: source, expiresAt: nil))],
    isSandboxed: false, loginStatus: .enabled)
  #expect(!presentation.showsTokenRefresh)
}

@Test(arguments: [nil, 3600.0]) @MainActor
func settingsOmitsWorkdaysForQuotasWithoutAWeeklyDuration(duration: TimeInterval?) {
  let settings = Settings(defaults: testDefaults())
  let snapshot = ProviderSnapshot(
    provider: .codex,
    windows: [
      QuotaWindow(id: "quota", label: "Quota", group: .other, usedPercent: 0, resetsAt: nil, duration: duration)
    ],
    fetchedAt: fixedNow)
  let presentation = SettingsContextPresentation(
    settings: settings, states: [.codex: ProviderState(snapshot: snapshot)], isSandboxed: false, loginStatus: .enabled)
  #expect(!presentation.showsPaceWorkdays)
}

@Test @MainActor func customizedCollectionSettingsRemainReachableWithoutProviders() {
  let settings = Settings(defaults: testDefaults())
  settings.analyticsRefreshMinutes = 30
  settings.paceWorkdays = 5
  settings.writeUsageFile = true
  settings.allowTokenRefresh = true
  let presentation = SettingsContextPresentation(
    settings: settings, states: [:], isSandboxed: true, loginStatus: .enabled)
  #expect(presentation.showsAnalyticsInterval && presentation.showsPaceWorkdays && presentation.showsTokenRefresh)
  #expect(presentation.collectionSummary == "Analytics every 30 min · 5 workdays · usage.json export is on")
}

@Test @MainActor func defaultCollectionDoesNotInventAnActiveIntegration() {
  let presentation = SettingsContextPresentation(
    settings: Settings(defaults: testDefaults()), states: [:], isSandboxed: true, loginStatus: .enabled)
  #expect(presentation.collectionSummary == nil)
  #expect(presentation.displaySummary == "Used · 0 decimals · Zero hidden · Fits to space")
}

@Test @MainActor func collapsedDisplayOptionsShowTheirNonDefaultValues() {
  let settings = Settings(defaults: testDefaults())
  settings.usageDisplay = .remaining
  settings.percentDecimals = 2
  settings.hideZeroCells = false
  settings.adaptiveWidth = false
  #expect(
    SettingsContextPresentation(settings: settings, states: [:], isSandboxed: false, loginStatus: .enabled)
      .displaySummary == "Left · 2 decimals · Zero shown · Full width")
}

@Test(arguments: [
  (NotificationSettings(), "On · 75%, 90%, 100%, resets, sign-in, pace, credit expiry"),
  (NotificationSettings(enabled: false), "Off"),
  (
    NotificationSettings(
      thresholds: [], notifyOnReset: false, notifyOnAuthProblems: false,
      notifyOnExpiringCredits: false, notifyOnPace: false), "On · No alerts selected"
  ),
]) @MainActor
func collapsedNotificationsDescribeConfiguredAlerts(notifications: NotificationSettings, expected: String) {
  let settings = Settings(defaults: testDefaults())
  settings.notifications = notifications
  #expect(
    SettingsContextPresentation(settings: settings, states: [:], isSandboxed: false, loginStatus: .enabled)
      .notificationSummary == expected)
}

@Test(arguments: [
  (LaunchAtLoginBackend.Status.enabled, false), (.notRegistered, false), (.notFound, true), (.requiresApproval, true),
]) @MainActor
func startupKeepsRequiredLoginItemRecoveryVisible(status: LaunchAtLoginBackend.Status, expected: Bool) {
  #expect(
    SettingsContextPresentation(
      settings: Settings(defaults: testDefaults()), states: [:], isSandboxed: false, loginStatus: status
    )
    .needsLoginItemAction == expected)
}
