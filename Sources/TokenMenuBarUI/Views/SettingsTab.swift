import AppKit
import SwiftUI
import TokenMenuBarCore

public struct SettingsTab: View {
  @Bindable var environment: UIEnvironment
  @State private var confirmClear = false

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  var settings: TokenMenuBarCore.Settings { environment.settings }

  public var body: some View {
    ScrollingTab {
      VStack(alignment: .leading, spacing: 14) {
        section("About") { about }
        section("Menu bar") { menuBar }
        section("Providers") { providers }
        section("Data") { data }
        section("Notifications") { notifications }
        section("Log") { LogSection(environment: environment) }
      }
      .frame(minWidth: 540, alignment: .leading)
    }
  }

  func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
  }

  public func setting<T>(_ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, T>) -> Binding<T> {
    Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
  }

  public func menuBarSetting<T>(_ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, T>) -> Binding<T> {
    Binding(get: { settings[keyPath: keyPath] }, set: { update(keyPath, to: $0) })
  }

  func update<T>(_ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, T>, to value: T) {
    settings[keyPath: keyPath] = value
    environment.actions.settingsChanged()
  }

  public func resetDefaults() {
    settings.resetToDefaults()
    environment.actions.settingsChanged()
  }

  public func setProvider(_ provider: ProviderID, enabled: Bool) {
    var providers = settings.enabledProviders
    if enabled { providers.insert(provider) } else { providers.remove(provider) }
    update(\.enabledProviders, to: providers)
  }

  public func setThreshold(_ threshold: Int, on: Bool) {
    var thresholds = Set(settings.notifications.thresholds)
    if on { thresholds.insert(threshold) } else { thresholds.remove(threshold) }
    settings.notifications = NotificationSettings(
      enabled: settings.notifications.enabled, thresholds: Array(thresholds),
      notifyOnReset: settings.notifications.notifyOnReset,
      notifyOnAuthProblems: settings.notifications.notifyOnAuthProblems)
  }

  public func threshold(_ threshold: Int) -> Binding<Bool> {
    Binding(get: { settings.notifications.thresholds.contains(threshold) }, set: { setThreshold(threshold, on: $0) })
  }

  public func provider(_ provider: ProviderID) -> Binding<Bool> {
    Binding(get: { settings.enabledProviders.contains(provider) }, set: { setProvider(provider, enabled: $0) })
  }

  private var about: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        AppIconView(size: 28)
        VStack(alignment: .leading) {
          Text("\(environment.appInfo.name) \(environment.appInfo.version) (\(environment.appInfo.build))")
          Text(environment.appInfo.isAppStore ? "Mac App Store build" : "Direct download build")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Reset Defaults") { resetDefaults() }
      }
      Toggle(
        "Launch at login",
        isOn: Binding(
          get: { environment.launchAtLoginStatus.isEnabled }, set: { environment.actions.setLaunchAtLogin($0) }))
      if let explanation = environment.launchAtLoginStatus.explanation {
        HStack {
          Text(explanation).font(.caption).foregroundStyle(.secondary)
          if environment.launchAtLoginStatus == .requiresApproval {
            Button("Open Login Items") { environment.actions.openLoginItems() }.controlSize(.small)
          }
        }
      }
      if environment.canCheckForUpdates {
        HStack {
          Toggle("Check for updates automatically", isOn: menuBarSetting(\.automaticUpdates))
          Spacer()
          Button("Check Now") { environment.actions.checkForUpdates() }.controlSize(.small)
        }
      }
      HStack {
        Button("Copy Diagnostics") { environment.actions.copyDiagnostics() }
        Button("Report Issue") { environment.actions.reportIssue() }
        Button("Source") { environment.actions.openURL(environment.appInfo.repository) }
      }
      .controlSize(.small)
    }
  }

  private var menuBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Order", selection: menuBarSetting(\.windowOrder)) {
        ForEach(WindowOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      Picker("Format", selection: menuBarSetting(\.statusFormat)) {
        ForEach(StatusFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      if settings.statusFormat == .custom {
        TextField("Template", text: menuBarSetting(\.customTemplate)).font(.body.monospaced())
        Text(StatusTemplate.tokens.map { "\($0.token) \($0.help)" }.joined(separator: " · "))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Stepper("Percent decimals: \(settings.percentDecimals)", value: menuBarSetting(\.percentDecimals), in: 0...2)
      Toggle("Hide windows at 0%", isOn: menuBarSetting(\.hideZeroCells))
      StatusPreview(model: environment.state.statusModel)
      Text("Windows shown in the menu bar").font(.body.weight(.medium))
      WindowSelectionList(environment: environment)
    }
  }

  private var providers: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(ProviderID.allCases, id: \.self) { provider in
        HStack(alignment: .top) {
          Toggle(provider.displayName, isOn: self.provider(provider)).frame(width: 90, alignment: .leading)
          VStack(alignment: .leading, spacing: 2) {
            Text(environment.state.state(for: provider).credentialState?.description ?? "Not checked yet").font(
              .caption)
            Text(environment.credentialDescriptions[provider] ?? provider.loginHint)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          Spacer()
          if provider == .codex, environment.isSandboxed {
            Button("Grant access to ~/.codex") { environment.actions.grantCodexAccess() }.controlSize(.small)
          }
        }
      }
      Toggle("Refresh expired tokens on my behalf", isOn: setting(\.allowTokenRefresh))
      Text(
        "Off by default: refreshing rotates the CLI's refresh token and writes it back to the Keychain or ~/.codex/auth.json."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var data: some View {
    VStack(alignment: .leading, spacing: 8) {
      Stepper(
        "Refresh every \(settings.refreshSeconds)s", value: setting(\.refreshSeconds),
        in: TokenMenuBarCore.Settings.minimumRefreshSeconds...TokenMenuBarCore.Settings.maximumRefreshSeconds, step: 30)
      Stepper(
        "Analytics every \(settings.analyticsRefreshMinutes) min", value: setting(\.analyticsRefreshMinutes),
        in: 5...120, step: 5)
      HStack {
        Text(environment.history.location?.path ?? "History kept in memory")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Button("Open") { environment.actions.revealHistory() }
        Button("Export…") { environment.actions.exportHistory() }
        Button("Clear…", role: .destructive) { confirmClear = true }
      }
      .controlSize(.small)
      .confirmationDialog("Clear all stored history?", isPresented: $confirmClear) {
        Button("Clear History", role: .destructive) { environment.actions.clearHistory() }
      }
    }
  }

  private var notifications: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Notify when limits are crossed", isOn: setting(\.notifications.enabled))
      HStack {
        Text("Thresholds").font(.caption)
        ForEach([50, 75, 90, 100], id: \.self) { value in
          Toggle("\(value)%", isOn: threshold(value)).toggleStyle(.checkbox)
        }
      }
      .disabled(!settings.notifications.enabled)
      Toggle("Notify when a window resets", isOn: setting(\.notifications.notifyOnReset)).disabled(
        !settings.notifications.enabled)
      Toggle("Notify when sign-in is needed", isOn: setting(\.notifications.notifyOnAuthProblems)).disabled(
        !settings.notifications.enabled)
    }
  }
}

public struct StatusPreview: View {
  public let model: StatusItemModel
  @Environment(\.colorScheme) private var colorScheme

  public init(model: StatusItemModel) {
    self.model = model
  }

  public var body: some View {
    HStack {
      Text("Preview").font(.callout).foregroundStyle(.secondary)
      Image(nsImage: StatusItemRenderer.previewImage(for: model, height: 24, dark: colorScheme == .dark))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
          in: RoundedRectangle(cornerRadius: 6))
      Spacer()
    }
  }
}

public struct WindowSelectionList: View {
  @Bindable var environment: UIEnvironment

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  private var settings: TokenMenuBarCore.Settings { environment.settings }

  var rows: [(key: WindowKey, window: QuotaWindow)] {
    environment.state.orderedProviders.flatMap { provider in
      (environment.state.state(for: provider).snapshot?.windows ?? []).map { (WindowKey(provider, $0), $0) }
    }
  }

  var selection: [WindowKey] {
    settings.hasCustomSelection
      ? settings.selectedWindows : StatusItemBuilder.defaultSelection(environment.state.snapshots)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if rows.isEmpty {
        Text("Windows appear after the first successful refresh.").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(rows, id: \.key) { row in
        HStack {
          Toggle(isOn: Binding(get: { selection.contains(row.key) }, set: { toggle(row.key, on: $0) })) {
            HStack(spacing: 6) {
              Image(systemName: ProviderGlyph.symbolName(row.key.provider))
                .foregroundStyle(ProviderGlyph.color(row.key.provider))
              Text("\(row.key.provider.displayName) \(row.window.label)")
            }
          }
          .toggleStyle(.checkbox)
          .disabled(selection == [row.key])
          Spacer()
          Text(Format.percent(row.window.usedPercent)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          if settings.activeTemplate.contains("{label}") {
            TextField(
              "Label", text: Binding(get: { settings.shortLabels[row.key] ?? "" }, set: { setLabel(row.key, $0) })
            )
            .frame(width: 60)
            .controlSize(.small)
          }
        }
      }
      if selection.count == 1 {
        Text("At least one window stays selected.").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  func toggle(_ key: WindowKey, on: Bool) {
    var keys = selection
    if on {
      if !keys.contains(key) { keys.append(key) }
    } else if keys.count > 1 {
      keys.removeAll { $0 == key }
    }
    settings.selectedWindows = keys
    settings.hasCustomSelection = true
    environment.actions.settingsChanged()
  }

  func setLabel(_ key: WindowKey, _ label: String) {
    var labels = settings.shortLabels
    if label.isEmpty { labels[key] = nil } else { labels[key] = label }
    settings.shortLabels = labels
    environment.actions.settingsChanged()
  }
}

public struct LogSection: View {
  @Bindable var environment: UIEnvironment

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button("Copy") { environment.actions.copy(environment.log.text) }
        Button("Clear") { environment.log.clear() }
        Button("Show Full Log") { environment.actions.showFullLog() }
        Spacer()
        Toggle(
          "Detailed logging",
          isOn: Binding(get: { environment.settings.detailedLogging }, set: { setDetailedLogging($0) })
        )
        .toggleStyle(.checkbox)
      }
      .controlSize(.small)
      LogTextView(entries: environment.log.tail(200).reversed(), height: 140)
    }
  }

  public func setDetailedLogging(_ enabled: Bool) {
    environment.settings.detailedLogging = enabled
    environment.log.debugEnabled = enabled
  }
}

public struct LogTextView: NSViewRepresentable {
  public let entries: [LogEntry]
  public let height: CGFloat

  public init(entries: [LogEntry], height: CGFloat) {
    self.entries = entries
    self.height = height
  }

  public func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = scrollView.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    textView.textContainerInset = CGSize(width: 4, height: 4)
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
    return scrollView
  }

  public func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let textView = scrollView.documentView as! NSTextView
    let text = entries.map(\.line).joined(separator: "\n")
    guard textView.string != text else { return }
    let visible = scrollView.contentView.bounds.origin
    textView.string = text
    scrollView.contentView.scroll(to: visible)
  }
}
