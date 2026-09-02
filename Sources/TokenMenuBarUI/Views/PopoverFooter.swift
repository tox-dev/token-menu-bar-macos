import SwiftUI
import TokenMenuBarCore

public struct PopoverFooter: View {
  @Bindable var environment: UIEnvironment

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  public var body: some View {
    HStack(spacing: 8) {
      NativeActionButton(action: environment.actions.refresh) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .accessibilityIdentifier("footer-refresh")
      .keyboardShortcut("r", modifiers: .command)
      .richHelp(
        TooltipContent(
          title: "Refresh",
          body: "Fetches current usage from each active provider. History analytics stay on their separate clock."))
      NativeActionButton(action: environment.actions.reportIssue) {
        Label("Report Issue", systemImage: "ladybug")
      }
      .accessibilityIdentifier("footer-report-issue")
      .richHelp(
        TooltipContent(
          title: "Report Issue",
          body: "Opens a new issue with a diagnostic summary. Review the text before submitting it."))
      if environment.canCheckForUpdates {
        NativeActionButton(action: environment.actions.checkForUpdates) {
          Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
        }
        .accessibilityIdentifier("footer-check-updates")
        .richHelp(
          TooltipContent(
            title: "Check for Updates",
            body: "Checks the direct-download release feed without changing the automatic-update setting."))
      }
      Spacer(minLength: 8)
      NativeActionButton(action: environment.actions.quit) {
        Label("Quit", systemImage: "power")
      }
      .accessibilityIdentifier("footer-quit")
      .keyboardShortcut("q", modifiers: .command)
      .richHelp(
        TooltipContent(
          title: "Quit",
          body: "Stops provider polling and exits Token Menu Bar. Your settings and stored history remain."))
    }
    .controlSize(.small)
    .padding(.horizontal, PopoverGeometry.contentPadding)
    .frame(height: PopoverGeometry.footerHeight)
    .overlay(alignment: .top) { Divider() }
    .panelSurface(.popoverChrome)
  }
}
