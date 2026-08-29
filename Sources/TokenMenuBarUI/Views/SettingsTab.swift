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
      VStack(alignment: .leading, spacing: 10) {
        section("About") { about }
        section("Menu bar") { menuBar }
        section("Providers") { providers }
        section("Data") { data }
        section("Notifications") { notifications }
        section("Log") { LogSection(environment: environment) }
      }
      .frame(minWidth: PopoverGeometry.contentWidth(for: .settings), alignment: .leading)
      .controlSize(.small)
    }
  }

  func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      content()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
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

  public func refreshMinutes(_ provider: ProviderID) -> Binding<Int> {
    Binding(
      get: { settings.refreshInterval(for: provider) / 60 },
      set: { settings.setRefreshInterval($0 * 60, for: provider) })
  }

  public func provider(_ provider: ProviderID) -> Binding<Bool> {
    Binding(get: { settings.enabledProviders.contains(provider) }, set: { setProvider(provider, enabled: $0) })
  }

  private var about: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        AppIconView(size: 26)
        Text("\(environment.appInfo.name) \(environment.appInfo.version) (\(environment.appInfo.build))")
        Text(environment.appInfo.isAppStore ? "App Store" : "Direct").foregroundStyle(.secondary)
        Spacer()
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { environment.launchAtLoginStatus.isEnabled }, set: { environment.actions.setLaunchAtLogin($0) }))
        if environment.launchAtLoginStatus == .requiresApproval {
          Button("Open Login Items") { environment.actions.openLoginItems() }
        }
        Button("Reset Defaults") { resetDefaults() }
      }
      if let explanation = environment.launchAtLoginStatus.explanation {
        Text(explanation).font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Button("Copy Diagnostics") { environment.actions.copyDiagnostics() }
        Button("Report Issue") { environment.actions.reportIssue() }
        Button("Source") { environment.actions.openURL(environment.appInfo.repository) }
        Spacer()
        if environment.canCheckForUpdates {
          Toggle("Check for updates automatically", isOn: menuBarSetting(\.automaticUpdates))
          Button("Check Now") { environment.actions.checkForUpdates() }
        }
      }
    }
  }

  private var menuBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Picker("Order", selection: menuBarSetting(\.windowOrder)) {
          ForEach(WindowOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Picker("Format", selection: menuBarSetting(\.statusFormat)) {
          ForEach(StatusFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Stepper("Decimals: \(settings.percentDecimals)", value: menuBarSetting(\.percentDecimals), in: 0...2)
        Toggle("Hide 0%", isOn: menuBarSetting(\.hideZeroCells))
        Toggle("Fit to space", isOn: menuBarSetting(\.adaptiveWidth))
          .help("Switch to narrower layouts when the menu bar runs out of room, for example next to the notch.")
      }
      if settings.statusFormat == .custom {
        TextField("Template", text: menuBarSetting(\.customTemplate)).font(.body.monospaced())
        Text(StatusTemplate.tokens.map { "\($0.token) \($0.help)" }.joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 12) {
        StatusPreview(model: environment.state.statusModel)
        Text("Windows shown:").foregroundStyle(.secondary)
      }
      WindowSelectionList(environment: environment)
    }
  }

  private var providers: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(ProviderID.allCases, id: \.self) { provider in
        HStack(spacing: 10) {
          Toggle(provider.displayName, isOn: self.provider(provider)).frame(width: 80, alignment: .leading)
          Text(environment.state.state(for: provider).credentialState?.description ?? "Not checked yet")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(environment.credentialDescriptions[provider] ?? provider.loginHint)
          Spacer()
          Stepper(
            "Every \(settings.refreshInterval(for: provider) / 60) min", value: refreshMinutes(provider),
            in: Int(PollingPolicy.defaults(for: provider).minimumInterval) / 60...TokenMenuBarCore.Settings
              .maximumRefreshSeconds / 60
          )
          if provider == .codex, environment.isSandboxed {
            Button("Grant access to ~/.codex") { environment.actions.grantCodexAccess() }
          }
        }
      }
      HStack(spacing: 10) {
        Toggle("Refresh expired tokens on my behalf", isOn: setting(\.allowTokenRefresh))
        Spacer()
        Text("Floors: Claude 2 min, others 1 min; the popover polls at the floor while open.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text("Token refresh rotates the CLI's refresh token and writes it back to its credential file or Keychain.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var data: some View {
    HStack(spacing: 10) {
      Stepper(
        "Analytics every \(settings.analyticsRefreshMinutes) min", value: setting(\.analyticsRefreshMinutes),
        in: 5...120, step: 5)
      Text(environment.history.location?.lastPathComponent ?? "History kept in memory")
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(environment.history.location?.path ?? "")
      Spacer()
      Button("Open") { environment.actions.revealHistory() }
      Button("Export…") { environment.actions.exportHistory() }
      Button("Clear…", role: .destructive) { confirmClear = true }
        .confirmationDialog("Clear all stored history?", isPresented: $confirmClear) {
          Button("Clear History", role: .destructive) { environment.actions.clearHistory() }
        }
    }
  }

  private var notifications: some View {
    HStack(spacing: 10) {
      Toggle("Notify at", isOn: setting(\.notifications.enabled))
      ForEach([50, 75, 90, 100], id: \.self) { value in
        Toggle("\(value)%", isOn: threshold(value)).disabled(!settings.notifications.enabled)
      }
      Spacer()
      Toggle("Window resets", isOn: setting(\.notifications.notifyOnReset)).disabled(!settings.notifications.enabled)
      Toggle("Sign-in needed", isOn: setting(\.notifications.notifyOnAuthProblems)).disabled(
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
    HStack(spacing: 6) {
      Text("Preview").foregroundStyle(.secondary)
      Image(nsImage: StatusItemRenderer.previewImage(for: model, height: 24, dark: colorScheme == .dark))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
          colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
          in: RoundedRectangle(cornerRadius: 6))
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
        Text("Windows appear after the first successful refresh.").foregroundStyle(.secondary)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 4) {
        ForEach(rows, id: \.key) { row in
          HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { selection.contains(row.key) }, set: { toggle(row.key, on: $0) })) {
              HStack(spacing: 4) {
                Image(systemName: ProviderGlyph.symbolName(row.key.provider)).foregroundStyle(
                  ProviderGlyph.color(row.key.provider))
                Text("\(row.key.provider.displayName) \(row.window.label)")
              }
            }
            .disabled(selection == [row.key])
            Text(Format.percent(row.window.usedPercent)).monospacedDigit().foregroundStyle(.secondary)
            if settings.activeTemplate.contains("{label}") {
              TextField(
                "Label", text: Binding(get: { settings.shortLabels[row.key] ?? "" }, set: { setLabel(row.key, $0) })
              ).frame(width: 56)
            }
          }
        }
      }
      if selection.count == 1 {
        Text("At least one window stays selected.").font(.caption).foregroundStyle(.secondary)
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
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button("Copy") { environment.actions.copy(environment.log.text) }
        Button("Clear") { environment.log.clear() }
        Button("Show Full Log") { environment.actions.showFullLog() }
        Spacer()
        Toggle(
          "Demo data",
          isOn: Binding(
            get: { environment.isDemo || environment.settings.demoMode }, set: { environment.actions.setDemoMode($0) })
        )
        .help("Replace real providers with generated data and a separate history file; relaunches the app.")
        Toggle(
          "Detailed logging",
          isOn: Binding(get: { environment.settings.detailedLogging }, set: { setDetailedLogging($0) }))
      }
      LogTextView(entries: environment.log.tail(200).reversed(), height: 240)
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
