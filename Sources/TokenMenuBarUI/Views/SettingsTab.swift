import AppKit
import SwiftUI
import TokenMenuBarCore

public struct SettingsTab: View {
  @Bindable var environment: UIEnvironment
  public let providerFocusRequest: ProviderSettingsFocusRequest?
  @State private var confirmClear = false
  @State private var confirmResetAll = false
  @State private var highlightedModel: WindowKey?
  @State private var focusRequest: SettingsModelFocusRequest?
  @State private var labelDrafts: [WindowKey: String] = [:]
  @State private var mountedSections: Set<SettingsSection>
  @State private var modelsMounted: Bool
  @State private var measurementHeight: CGFloat
  @FocusState private var providerFocus: ProviderID?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  private let mountsIncrementally: Bool

  public init(
    environment: UIEnvironment, providerFocusRequest: ProviderSettingsFocusRequest? = nil,
    mountsIncrementally: Bool = true
  ) {
    self.environment = environment
    self.providerFocusRequest = providerFocusRequest
    self.mountsIncrementally = mountsIncrementally
    let mountedSections: Set<SettingsSection> = mountsIncrementally ? [.about] : Set(SettingsSection.allCases)
    let modelsMounted = !mountsIncrementally
    _mountedSections = State(initialValue: mountedSections)
    _modelsMounted = State(initialValue: modelsMounted)
    _measurementHeight = State(
      initialValue: PopoverGeometry.settingsHeight(
        Self.heightInput(environment: environment, mountedSections: mountedSections, modelsMounted: modelsMounted)))
  }

  var settings: TokenMenuBarCore.Settings { environment.settings }
  private var contentMounted: Bool {
    modelsMounted && mountedSections.count == SettingsSection.allCases.count
  }
  public var body: some View {
    ScrollViewReader { scroll in
      ScrollingTab(
        tab: .settings,
        measurementHeight: measurementHeight
      ) {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(SettingsSection.allCases, id: \.self) { scope in
            section(scope) { sectionContent(scope, scroll: scroll) }
              .id(
                scope == .providers
                  ? AnyHashable(SettingsFocusTarget.providers) : AnyHashable(scope))
          }
          HStack {
            Spacer()
            resetDefaultsButton
          }
          .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(dynamicTypeSize.isAccessibilitySize ? .regular : .small)
      }
      .preference(key: SettingsContentReadyKey.self, value: contentMounted)
      .onAppear { focusProvider(providerFocusRequest, scroll: scroll) }
      .onChange(of: providerFocusRequest) { _, request in focusProvider(request, scroll: scroll) }
      .onChange(of: mountedSections.contains(.providers)) { _, ready in
        if ready { focusProvider(providerFocusRequest, scroll: scroll) }
      }
      .onChange(of: heightInput) { _, input in measurementHeight = PopoverGeometry.settingsHeight(input) }
      .task {
        if mountsIncrementally { await mountDeferredContent() }
      }
    }
    .alert("Reset all settings?", isPresented: $confirmResetAll) {
      resetAlertActions
    } message: {
      Text(
        "This restores all stored settings, including model selection, short labels, provider setup, and hidden series."
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(contentMounted ? "settings-content-ready" : "settings-content-loading")
  }

  var resetAlertActions: some View {
    Group {
      Button("Cancel", role: .cancel, action: cancelResetAction)
        .accessibilityHint("Keeps all current settings")
      Button("Reset All Settings", role: .destructive, action: resetAllSettingsAction)
        .accessibilityHint("Restores defaults in all six sections")
    }
  }

  var cancelResetAction: () -> Void {
    { cancelResetDefaults() }
  }

  var resetAllSettingsAction: () -> Void {
    { resetDefaults() }
  }

  var heightInput: SettingsHeightInput {
    Self.heightInput(environment: environment, mountedSections: mountedSections, modelsMounted: modelsMounted)
  }

  private static func heightInput(
    environment: UIEnvironment, mountedSections: Set<SettingsSection>, modelsMounted: Bool
  ) -> SettingsHeightInput {
    let snapshots = environment.state.snapshots
    let modelCount =
      modelsMounted
      ? snapshots.values.reduce(into: 0) { count, snapshot in
        count += snapshot.windows.count { !environment.settings.hideUnusedModels || $0.usedPercent > 0 }
      } : 0
    let providerCount =
      mountedSections.contains(.providers)
      ? ProviderSettingsVisibility.providers(
        states: environment.state.providers, configured: environment.settings.configuredProviderSettings,
        showAll: environment.settings.showAllProviders, revealed: environment.providerFocusRequest?.provider
      ).count
      : Set(snapshots.keys).count
    return SettingsHeightInput(
      mountedSections: mountedSections,
      showsModelFilter: modelsMounted,
      providerCount: providerCount,
      modelCount: modelCount,
      logLineCount: mountedSections.contains(.log) ? min(environment.log.snapshot.count, 200) : 0,
      showsCustomTemplate: environment.settings.statusFormat == .custom,
      showsUpdates: environment.canCheckForUpdates)
  }

  func focusProvider(_ request: ProviderSettingsFocusRequest?, scroll: ScrollViewProxy) {
    guard let request else { return }
    guard !mountsIncrementally || mountedSections.contains(.providers) else { return }
    let provider = request.provider
    let target: SettingsFocusTarget = if let provider { .provider(provider) } else { .providers }
    withAnimation(.easeOut(duration: 0.12)) {
      scroll.scrollTo(target, anchor: .center)
    }
    providerFocus = provider
    if environment.providerFocusRequest?.id == request.id { environment.providerFocusRequest = nil }
  }

  func section<Content: View>(_ scope: SettingsSection, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        SectionLabel(scope.title)
      }
      .accessibilityIdentifier("settings-section-\(scope.rawValue)")
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 2)
    .padding(.bottom, 4)
    .overlay(alignment: .bottom) { Divider() }
  }

  @ViewBuilder func sectionContent(_ scope: SettingsSection, scroll: ScrollViewProxy) -> some View {
    if scope != .about, !mountedSections.contains(scope) {
      sectionPlaceholder(scope)
    } else {
      switch scope {
      case .about: about
      case .menuBar: menuBar(scroll)
      case .providers: providers
      case .data: data
      case .notifications: notifications
      case .log: LogSection(environment: environment)
      }
    }
  }

  private func sectionPlaceholder(_ scope: SettingsSection) -> some View {
    Color.clear
      .frame(height: placeholderHeight(scope))
      .accessibilityHidden(true)
  }

  private func placeholderHeight(_ scope: SettingsSection) -> CGFloat {
    switch scope {
    case .about: 180
    case .menuBar: 620
    case .providers: 420
    case .data, .notifications: 120
    case .log: 260
    }
  }

  private func mountDeferredContent() async {
    await Task.yield()
    guard !Task.isCancelled else { return }
    mountedSections = Set(SettingsSection.allCases)
    modelsMounted = true
  }

  public func setting<Value>(_ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, Value>) -> Binding<Value> {
    Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
  }

  public func menuBarSetting<Value>(
    _ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, Value>
  ) -> Binding<Value> {
    Binding(get: { settings[keyPath: keyPath] }, set: { update(keyPath, to: $0) })
  }

  func update<Value>(_ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, Value>, to value: Value) {
    settings[keyPath: keyPath] = value
    environment.actions.settingsChanged()
  }

  public func resetDefaults() {
    settings.resetToDefaults()
    labelDrafts.removeAll()
    environment.actions.settingsReset()
    environment.actions.settingsChanged()
  }

  func requestResetDefaults() {
    confirmResetAll = true
  }

  func cancelResetDefaults() {
    confirmResetAll = false
  }

  func requestClearHistory() {
    confirmClear = true
  }

  func clearHistory() {
    environment.actions.clearHistory()
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    environment.actions.setLaunchAtLogin(enabled)
  }

  public func setProvider(_ provider: ProviderID, enabled: Bool) {
    settings.setProvider(provider, enabled: enabled)
    environment.actions.settingsChanged()
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

  public var historyRetentionDays: Binding<Int> {
    Binding(
      get: { settings.historyRetentionDays },
      set: {
        settings.historyRetentionDays = $0
        environment.actions.settingsChanged()
      })
  }

  public func missingAccess(_ provider: ProviderID) -> [SandboxResource] {
    settings.missingAccess(for: provider)
  }

  public func openRepository() {
    environment.actions.openURL(environment.appInfo.repository)
  }

  public func grantAccess(_ resource: SandboxResource) {
    environment.actions.grantAccess(resource)
  }

  func resourceGrantAction(_ resource: SandboxResource) -> () -> Void {
    { grantAccess(resource) }
  }

  public func credentialText(_ provider: ProviderID) -> String {
    let state = environment.state.state(for: provider)
    switch state.credentialHealth {
    case .unchecked:
      return state.credentialState?.isMissing == true ? "Not found" : credentialLocation(provider) ?? "Not checked yet"
    case .missing:
      return "Not found"
    case .valid(let source, let expiresAt):
      return uniqueCredentialParts(
        [source.title, source.detail]
          + [expiresAt.map { "expires \($0.formatted(date: .abbreviated, time: .shortened))" }])
    case .expired(let source, let date):
      return uniqueCredentialParts([
        source.title, source.detail,
        "expired \(date.formatted(date: .abbreviated, time: .omitted))",
      ])
    case .unreadable(let source, let detail):
      return uniqueCredentialParts(
        [source?.title, source?.detail, source == nil ? credentialLocation(provider) : nil, "unreadable: \(detail)"])
    }
  }

  func credentialLocation(_ provider: ProviderID) -> String? {
    guard
      let location = environment.credentialDescriptions[provider]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !location.isEmpty
    else { return nil }
    return location
  }

  private func uniqueCredentialParts(_ values: [String?]) -> String {
    var seen: Set<String> = []
    return values.compactMap { value in
      guard let value, seen.insert(value).inserted else { return nil }
      return value
    }
    .joined(separator: " · ")
  }

  public func authenticationHint(_ provider: ProviderID) -> String? {
    guard settings.isProviderActive(provider, state: environment.state.providers[provider]) else { return nil }
    let state = environment.state.state(for: provider)
    if let issue = state.recoveryIssue { return issue.detail }
    return state.availability == .authenticationRequired ? provider.loginHint : nil
  }

  func recoveryIssue(_ provider: ProviderID) -> ProviderRecoveryIssue? {
    let state = environment.state.state(for: provider)
    if let issue = state.recoveryIssue { return issue }
    if let issue = ProviderSetupState.from(
      provider: provider, enabled: true, credential: state.credentialHealth,
      resources: resourceStates(provider)
    ).issue {
      return issue
    }
    return state.availability == .authenticationRequired ? provider.setup.missingCredentialIssue : nil
  }

  func resourceStates(_ provider: ProviderID) -> [ResourceAccessState] {
    let current = environment.state.state(for: provider).resourceAccess
    if !current.isEmpty { return current }
    return provider.sandboxResources.map { resource in
      ResourceAccessState(resource: resource, health: settings.bookmark(for: resource) == nil ? .needed : .granted)
    }
  }

  func perform(_ action: ProviderRecoveryAction, provider: ProviderID, detail: String) {
    switch action {
    case .copyCommand(let command): environment.actions.copy(command)
    case .checkAgain: environment.actions.refreshProvider(provider)
    case .refreshProvider(let provider): environment.actions.refreshProvider(provider)
    case .grantAccess(let resource): grantAccess(resource)
    case .openLoginItems: environment.actions.openLoginItems()
    case .contactAdministrator: environment.actions.copy(detail)
    }
  }

  public func provider(_ provider: ProviderID) -> Binding<Bool> {
    Binding(
      get: { settings.isProviderActive(provider, state: environment.state.providers[provider]) },
      set: { setProvider(provider, enabled: $0) })
  }

  var selection: [WindowKey] {
    settings.hasCustomSelection
      ? settings.selectedWindows : StatusItemBuilder.defaultSelection(environment.state.snapshots)
  }

  var previewModel: StatusItemModel {
    let activeProviders = settings.activeProviders(states: environment.state.providers)
    let snapshots = environment.state.snapshots.filter { activeProviders.contains($0.key) }
    let available = snapshots.keys.sorted().flatMap { provider in
      snapshots[provider]!.windows.map { (WindowKey(provider, $0), $0) }
    }
    let order = SettingsOrderDraft(
      providers: settings.providerOrder, models: settings.modelOrder, available: available.map(\.0))
    let windows = Dictionary(uniqueKeysWithValues: available)
    let labels = ShortLabelPolicy.validOverrides(
      windows: windows, persisted: settings.shortLabels, drafts: labelDrafts)
    return StatusItemBuilder.build(
      StatusItemInput(
        snapshots: snapshots,
        availability: environment.state.availability.filter { activeProviders.contains($0.key) },
        selectedKeys: order.orderedSelection(selection), format: settings.statusFormat,
        customTemplate: settings.customTemplate, decimals: settings.percentDecimals,
        hideZeroCells: settings.hideZeroCells, order: settings.windowOrder,
        labels: labels, now: environment.now))
  }

  private var about: some View {
    VStack(alignment: .leading, spacing: 7) {
      PanelRow("Version") { versionSummary }
      PanelRow("Startup") {
        VStack(alignment: .leading, spacing: 4) {
          WrappingHStack(horizontalSpacing: 8, verticalSpacing: 6) {
            launchAtLoginToggle
            openLoginItemsButton
          }
          launchAtLoginExplanation
        }
      }
      if environment.canCheckForUpdates {
        PanelRow("Updates") {
          WrappingHStack(horizontalSpacing: 8, verticalSpacing: 6) {
            Toggle("Check for updates automatically", isOn: menuBarSetting(\.automaticUpdates))
              .toggleStyle(.checkbox)
              .richHelp(
                TooltipContent(
                  title: "Automatic updates",
                  body:
                    "Checks the direct-download release feed in the background. "
                    + "When off, Token Menu Bar checks only when you choose Check Now."
                ))
            NativeActionButton("Check Now", action: environment.actions.checkForUpdates)
              .richHelp(
                TooltipContent(
                  title: "Check Now",
                  body:
                    "Checks the direct-download release feed now. "
                    + "The check does not change your automatic-update setting."
                ))
          }
        }
      }
      PanelRow("Diagnostics") {
        WrappingHStack(horizontalSpacing: 8, verticalSpacing: 6) {
          NativeActionButton("Copy Diagnostics", action: environment.actions.copyDiagnostics)
            .richHelp(
              TooltipContent(
                title: "Copy Diagnostics",
                body:
                  "Copies the version, build channel, provider auth and refresh state, and recent log. "
                  + "Credentials and tokens are excluded."
              ))
          NativeActionButton("Report Issue", action: environment.actions.reportIssue)
            .richHelp(
              TooltipContent(
                title: "Report Issue",
                body: "Opens a new issue with the diagnostic summary prefilled. Review the text before submitting it."))
          NativeActionButton("Source", action: openRepository)
            .richHelp(
              TooltipContent(
                title: "Source",
                body: "Opens the Token Menu Bar source repository in your default browser."))
        }
      }
    }
  }

  private var versionSummary: some View {
    HStack(spacing: 6) {
      Text("\(environment.appInfo.sourceVersion) (\(environment.appInfo.build))")
      Text(environment.appInfo.distribution.displayName).semanticForeground(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private var resetDefaultsButton: some View {
    NativeActionButton("Reset All Settings", action: requestResetDefaults)
      .richHelp(
        TooltipContent(
          title: "Reset All Settings",
          body:
            "Restores the stored values in all six sections, including model selection, short labels, "
            + "and provider setup. A confirmation appears before any values change."
        ))
  }

  private var launchAtLoginToggle: some View {
    Toggle(
      "Launch at login",
      isOn: launchAtLoginBinding
    )
    .toggleStyle(.checkbox)
    .richHelp(
      TooltipContent(
        title: "Launch at login",
        body: "Registers Token Menu Bar as a macOS login item. When off, open the app yourself after signing in."))
  }

  var launchAtLoginBinding: Binding<Bool> {
    Binding(get: { environment.launchAtLoginStatus.isEnabled }, set: { setLaunchAtLogin($0) })
  }

  private var openLoginItemsButton: some View {
    NativeActionButton("Open Login Items", action: environment.actions.openLoginItems)
      .richHelp(
        TooltipContent(
          title: "Open Login Items",
          body: "Opens macOS Login Items, where you can allow or block Token Menu Bar at the system level."))
  }

  @ViewBuilder private var launchAtLoginExplanation: some View {
    if let explanation = environment.launchAtLoginStatus.explanation {
      Text(explanation)
        .font(.caption)
        .semanticForeground(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func menuBar(_ scroll: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      VStack(alignment: .leading, spacing: 7) {
        PanelRow("Order") {
          ResponsivePanelLayout {
            HStack(spacing: 12) {
              orderPicker
              Text("Format").semanticForeground(.secondary)
              formatPicker
              Spacer()
              decimalsStepper
            }
            .frame(minWidth: 610)
          } narrow: {
            VStack(alignment: .leading, spacing: 7) {
              orderPicker
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Format").semanticForeground(.secondary)
                formatPicker
              }
              decimalsStepper
            }
          }
        }
        PanelRow("Options") {
          WrappingHStack(horizontalSpacing: 16, verticalSpacing: 6) {
            Toggle("Hide 0%", isOn: menuBarSetting(\.hideZeroCells))
              .toggleStyle(.checkbox)
              .richHelp(
                TooltipContent(
                  title: "Hide 0%",
                  body:
                    "Removes zero-usage models from the menu bar to save width. "
                    + "Their data and Usage rows remain available."
                ))
            Toggle("Fit to space", isOn: menuBarSetting(\.adaptiveWidth))
              .toggleStyle(.checkbox)
              .richHelp(
                TooltipContent(
                  title: "Fit to space",
                  body:
                    "Uses shorter status renderings when menu bar room runs low. "
                    + "When off, macOS may truncate a wide status item."
                ))
          }
        }
        if settings.statusFormat == .custom {
          PanelRow("Template") {
            VStack(alignment: .leading, spacing: 3) {
              TextField("Template", text: menuBarSetting(\.customTemplate))
                .font(.body.monospaced())
                .richHelp(
                  TooltipContent(
                    title: "Custom template",
                    body:
                      "Builds each status cell from the listed tokens. "
                      + "The {label} token uses the short label beside each model; unknown tokens render no text."
                  ))
              Text("{cell}  {pct}  {label}  {provider}  {window}  {reset}")
                .font(.caption.monospaced())
                .semanticForeground(.secondary)
            }
          }
        }
        PanelRow("Preview") {
          StatusPreview(model: previewModel, highlightedKey: $highlightedModel) { key in
            focusRequest = SettingsModelFocusRequest(key: key)
            Task { @MainActor in
              await Task.yield()
              withAnimation(.easeOut(duration: 0.12)) { scroll.scrollTo(key, anchor: .center) }
            }
          }
        }
      }
      WindowSelectionList(
        environment: environment, highlightedKey: $highlightedModel, labelDrafts: $labelDrafts,
        focusRequest: focusRequest)
    }
  }

  private var orderPicker: some View {
    NativeSegmentedControl(
      [(value: WindowOrder.provider, label: "Stable"), (value: .percent, label: "Usage")],
      selection: menuBarSetting(\.windowOrder),
      accessibilityLabel: "Order"
    )
    .fixedSize()
    .richHelp(
      TooltipContent(
        title: "Model order",
        body:
          "Stable uses the provider and model order set below. "
          + "Usage sorts current percentages from highest to lowest; drag ordering has no effect in that mode."
      ))
  }

  private var formatPicker: some View {
    NativeSegmentedControl(
      StatusFormat.allCases.map { (value: $0, label: $0.rawValue) },
      selection: menuBarSetting(\.statusFormat),
      accessibilityLabel: "Format"
    )
    .fixedSize()
    .richHelp(
      TooltipContent(
        title: "Format",
        body:
          "Stacked places the percentage under its label. Inline keeps both on one line. "
          + "Mini bars use compact gauges. Custom uses the template and per-model short labels."
      ))
  }

  private var decimalsStepper: some View {
    Stepper("Decimals: \(settings.percentDecimals)", value: menuBarSetting(\.percentDecimals), in: 0...2)
      .richHelp(
        TooltipContent(
          title: "Percentage decimals",
          body: "Shows zero, one, or two decimal places in the menu bar. More precision uses more menu bar width."))
  }

  private var providers: some View {
    VStack(alignment: .leading, spacing: 7) {
      Toggle("Show all providers", isOn: settingWithoutRefresh(\.showAllProviders))
        .toggleStyle(.checkbox)
        .richHelp(
          TooltipContent(
            title: "Show all providers",
            body:
              "Reveals providers that have no discovered credentials or cached data so you can set them up. "
              + "Turning it off keeps configured providers visible."
          ))
      if visibleProviders.isEmpty {
        EmptyStateView(
          title: "No providers discovered", systemImage: "person.crop.circle.badge.questionmark",
          description: "Select Show all providers to set up a provider on this Mac.")
      } else {
        ForEach(visibleProviders, id: \.self) { provider in providerRow(provider) }
      }
      ResponsivePanelLayout {
        HStack {
          tokenRefreshToggle
          Spacer()
          tokenRefreshFloor
        }
        .frame(minWidth: 600)
      } narrow: {
        VStack(alignment: .leading, spacing: 4) {
          tokenRefreshToggle
          tokenRefreshFloor
        }
      }
      Text("Token refresh supports Claude, Codex, and Gemini and writes rotated tokens to their credential stores.")
        .font(.caption)
        .semanticForeground(.secondary)
    }
  }

  var visibleProviders: [ProviderID] {
    ProviderSettingsVisibility.providers(
      states: environment.state.providers, configured: settings.configuredProviderSettings,
      showAll: settings.showAllProviders, revealed: providerFocusRequest?.provider)
  }

  func settingWithoutRefresh<Value>(
    _ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, Value>
  ) -> Binding<Value> {
    Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
  }

  private var tokenRefreshToggle: some View {
    Toggle("Refresh expired Claude, Codex, and Gemini tokens on my behalf", isOn: setting(\.allowTokenRefresh))
      .toggleStyle(.checkbox)
      .richHelp(
        TooltipContent(
          title: "Token refresh",
          body:
            "Rotates supported Claude, Codex, and Gemini refresh tokens and writes them to the credential "
            + "file or Keychain. When off, an expired provider stops updating until you sign in again."
        ))
  }

  private var tokenRefreshFloor: some View {
    Text("Floors: Claude 2 min, others 1 min; the panel polls at the floor while open.")
      .font(.caption)
      .semanticForeground(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  func providerRow(_ providerID: ProviderID) -> some View {
    let state = environment.state.state(for: providerID)
    let presentation = SettingsProviderPresentation(state: state, now: environment.now)
    let issue = recoveryIssue(providerID)
    return VStack(alignment: .leading, spacing: 3) {
      ResponsivePanelLayout {
        HStack(spacing: 8) {
          providerControl(providerID)
          Text(providerAvailabilityText(providerID)).font(.caption).semanticForeground(.secondary)
          Spacer()
          providerRefreshStepper(providerID)
        }
        .frame(minWidth: 560)
      } narrow: {
        VStack(alignment: .leading, spacing: 5) {
          providerControl(providerID)
          Text(providerAvailabilityText(providerID)).font(.caption).semanticForeground(.secondary)
          providerRefreshStepper(providerID)
        }
      }
      ResponsivePanelLayout {
        HStack(alignment: .bottom, spacing: 8) {
          providerDetails(providerID, presentation: presentation, issue: issue)
          Spacer(minLength: 8)
          providerRecoveryButton(actionableRecoveryIssue(providerID), provider: providerID)
        }
        .frame(minWidth: 520)
      } narrow: {
        VStack(alignment: .leading, spacing: 5) {
          providerDetails(providerID, presentation: presentation, issue: issue)
          providerRecoveryButton(actionableRecoveryIssue(providerID), provider: providerID)
        }
      }
      .padding(.leading, 30)
      if environment.isSandboxed {
        ForEach(visibleResourceStates(providerID)) { access in
          providerResourceRow(access, provider: providerID).padding(.leading, 30)
        }
      }
    }
    .id(SettingsFocusTarget.provider(providerID))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(providerID.displayName) setup")
    .accessibilityValue(
      [
        providerAvailabilityText(providerID), presentation.identity, credentialText(providerID),
        presentation.lastSuccess,
        presentation.service, recoveryIssue(providerID)?.detail,
      ]
      .compactMap { $0 }
      .joined(separator: ", ")
    )
  }

  func providerAvailabilityText(_ provider: ProviderID) -> String {
    if settings.providerOverride(for: provider) == false { return "Off" }
    guard settings.isProviderActive(provider, state: environment.state.providers[provider]) else {
      return "Not configured"
    }
    return environment.state.state(for: provider).availability.title
  }

  private func providerControl(_ providerID: ProviderID) -> some View {
    HStack(spacing: 8) {
      ProviderMarkView(providerID, size: CGSize(width: 22, height: 18)).accessibilityHidden(true)
      Toggle(providerID.displayName, isOn: provider(providerID))
        .toggleStyle(.checkbox)
        .fixedSize(horizontal: false, vertical: true)
        .richHelp(
          TooltipContent(
            title: "\(providerID.displayName) provider",
            body:
              "Discovered providers turn on automatically. Changing this checkbox creates an explicit polling "
              + "override until Reset All Settings. Turning it off keeps stored history, account details, "
              + "and provider settings."
          ),
          focus: $providerFocus, equals: providerID
        )
    }
  }

  private func providerRefreshStepper(_ providerID: ProviderID) -> some View {
    Stepper(
      "Every \(settings.refreshInterval(for: providerID) / 60) min", value: refreshMinutes(providerID),
      in: Int(PollingPolicy.defaults(for: providerID).minimumInterval) / 60...TokenMenuBarCore.Settings
        .maximumRefreshSeconds / 60
    )
    .richHelp(
      TooltipContent(
        title: "\(providerID.displayName) refresh interval",
        body:
          "Sets background usage polling. Shorter intervals use more network and CPU; while the panel is open, "
          + "polling uses this provider's minimum interval."
      ))
  }

  private func providerDetails(
    _ providerID: ProviderID, presentation: SettingsProviderPresentation, issue: ProviderRecoveryIssue?
  ) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      ResponsivePanelLayout {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("Authentication").fontWeight(.medium)
          Text(credentialText(providerID)).fixedSize(horizontal: false, vertical: true)
        }
      } narrow: {
        VStack(alignment: .leading, spacing: 1) {
          Text("Authentication").fontWeight(.medium)
          Text(credentialText(providerID)).fixedSize(horizontal: false, vertical: true)
        }
      }
      .richHelp(
        TooltipContent(
          title: "Authentication source",
          body:
            "Shows the credential store or session used for \(providerID.displayName), including its safe local "
            + "location when available. Tokens and account secrets never appear."
        ))
      Text(
        [presentation.identity, presentation.lastSuccess, presentation.service]
          .compactMap { $0 }
          .joined(separator: " · ")
      )
      if let issue {
        Text(issue.title).fontWeight(.medium)
        Text(issue.detail)
      }
    }
    .font(.caption)
    .semanticForeground(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func providerRecoveryButton(_ issue: ProviderRecoveryIssue?, provider: ProviderID) -> some View {
    if let issue {
      NativeActionButton(issue.action.title) {
        perform(issue.action, provider: provider, detail: issue.detail)
      }
      .richHelp(
        TooltipContent(
          title: issue.title,
          body:
            "\(issue.detail) The action checks only \(provider.displayName); stored usage and the last successful "
            + "snapshot remain available."
        ))
    }
  }

  func actionableRecoveryIssue(_ provider: ProviderID) -> ProviderRecoveryIssue? {
    guard settings.providerOverride(for: provider) != false else { return nil }
    let setupIsVisible = settings.showAllProviders || providerFocusRequest?.provider == provider
    if settings.isProviderActive(provider, state: environment.state.providers[provider]) {
      return recoveryIssue(provider)
    }
    if setupIsVisible { return recoveryIssue(provider) }
    return nil
  }

  func visibleResourceStates(_ provider: ProviderID) -> [ResourceAccessState] {
    resourceStates(provider).filter { $0.isRequired && $0.health != .notRequired }
  }

  private func providerResourceRow(_ access: ResourceAccessState, provider: ProviderID) -> some View {
    ResponsivePanelLayout {
      HStack(spacing: 8) {
        Text(access.resource.label).font(.caption)
        Text(resourceText(access.health)).font(.caption).semanticForeground(.secondary)
        Spacer(minLength: 8)
        resourceGrantButton(access, provider: provider)
      }
      .frame(minWidth: 420)
    } narrow: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(access.resource.label).font(.caption)
          Text(resourceText(access.health)).font(.caption).semanticForeground(.secondary)
        }
        resourceGrantButton(access, provider: provider)
      }
    }
  }

  @ViewBuilder private func resourceGrantButton(_ access: ResourceAccessState, provider: ProviderID) -> some View {
    if resourceNeedsGrant(access.health) {
      NativeActionButton(resourceGrantTitle(access.health), action: resourceGrantAction(access.resource))
        .richHelp(
          TooltipContent(
            title: "Grant \(access.resource.label) access",
            body:
              "Opens a macOS file picker for this sandbox resource. "
              + "Without access, \(provider.displayName) cannot read the local data it needs."
          ))
    }
  }

  func resourceText(_ health: ResourceAccessHealth) -> String {
    switch health {
    case .notRequired: "Not required"
    case .needed: "Needed"
    case .granted: "Granted"
    case .stale: "Stale"
    case .error(let detail): "Error: \(detail)"
    }
  }

  func resourceNeedsGrant(_ health: ResourceAccessHealth) -> Bool {
    switch health {
    case .needed, .stale, .error: true
    case .notRequired, .granted: false
    }
  }

  func resourceGrantTitle(_ health: ResourceAccessHealth) -> String {
    switch health {
    case .notRequired: "Not required"
    case .needed: "Grant"
    case .stale, .error: "Grant Again"
    case .granted: "Granted"
    }
  }

  private var data: some View {
    VStack(alignment: .leading, spacing: 7) {
      PanelRow("Retention") {
        Stepper("\(settings.historyRetentionDays) days", value: historyRetentionDays, in: 7...365)
          .richHelp(
            TooltipContent(
              title: "History retention",
              body:
                "Keeps usage samples for 7 to 365 days. A longer period uses more disk space "
                + "and makes older ranges available in History."
            ))
      }
      PanelRow("Analytics") {
        Stepper(
          "Every \(settings.analyticsRefreshMinutes) min", value: setting(\.analyticsRefreshMinutes),
          in: 5...120, step: 5
        )
        .richHelp(
          TooltipContent(
            title: "Analytics refresh interval",
            body:
              "Sets the separate clock for transcript and provider analytics. "
              + "Shorter intervals use more disk, network, and CPU."
          ))
      }
      PanelRow("History") {
        ResponsivePanelLayout {
          HStack(spacing: 8) {
            historyPath
            Spacer(minLength: 8)
            historyActions
          }
          .frame(minWidth: 570)
        } narrow: {
          VStack(alignment: .leading, spacing: 6) {
            historyPath
            historyActions
          }
        }
      }
    }
  }

  private var historyPath: some View {
    HorizontallyScrollableText(environment.history.location?.path ?? "History kept in memory")
      .frame(minWidth: 180, maxWidth: .infinity, minHeight: 18, maxHeight: 18)
      .layoutPriority(-1)
      .richHelp(
        TooltipContent(
          title: "History file",
          body:
            "Shows the complete path to the local history database. Scroll horizontally or select the text to copy it."
        ))
  }

  private var historyActions: some View {
    WrappingHStack(horizontalSpacing: 8, verticalSpacing: 6) {
      NativeActionButton("Open", action: environment.actions.revealHistory)
        .richHelp(
          TooltipContent(
            title: "Open History",
            body: "Reveals the history database in Finder. This does not stop collection or change the file."))
      NativeActionButton("Export…", action: environment.actions.exportHistory)
        .richHelp(
          TooltipContent(
            title: "Export History",
            body: "Writes stored usage history to a file you choose. Exporting keeps the database unchanged."))
      NativeActionButton("Clear…", intent: .destructive, action: requestClearHistory)
        .richHelp(
          TooltipContent(
            title: "Clear History",
            body: "Deletes stored usage samples after confirmation. Provider settings and current snapshots remain.")
        )
        .confirmationDialog("Clear all stored history?", isPresented: $confirmClear) {
          clearHistoryConfirmationAction
        }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  var clearHistoryConfirmationAction: some View {
    Button("Clear History", role: .destructive, action: clearHistoryAction)
      .accessibilityHint("Deletes stored usage samples and keeps provider settings")
  }

  var clearHistoryAction: () -> Void {
    { clearHistory() }
  }

  private var notifications: some View {
    VStack(alignment: .leading, spacing: 7) {
      PanelRow("Notify at") {
        WrappingHStack(horizontalSpacing: 12, verticalSpacing: 6) {
          Toggle("Notifications", isOn: setting(\.notifications.enabled))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel("Enable threshold notifications")
            .richHelp(
              TooltipContent(
                title: "Usage notifications",
                body:
                  "Allows the selected usage thresholds, reset notices, and sign-in notices. "
                  + "When off, Token Menu Bar sends no notifications."
              ))
          ForEach([50, 75, 90, 100], id: \.self) { value in
            Toggle("\(value)%", isOn: threshold(value))
              .toggleStyle(.checkbox)
              .disabled(!settings.notifications.enabled)
              .richHelp(
                TooltipContent(
                  title: "Notify at \(value)%",
                  body:
                    "Sends one notice when a usage window reaches \(value) percent. "
                    + "Disabled while usage notifications are off."
                ))
          }
        }
      }
      PanelRow("") {
        WrappingHStack(horizontalSpacing: 16, verticalSpacing: 6) {
          Toggle("Window resets", isOn: setting(\.notifications.notifyOnReset))
            .toggleStyle(.checkbox)
            .disabled(!settings.notifications.enabled)
            .richHelp(
              TooltipContent(
                title: "Window resets",
                body: "Sends a notice when a tracked usage window resets. Disabled while usage notifications are off."))
          Toggle("Sign-in needed", isOn: setting(\.notifications.notifyOnAuthProblems))
            .toggleStyle(.checkbox)
            .disabled(!settings.notifications.enabled)
            .richHelp(
              TooltipContent(
                title: "Sign-in needed",
                body: "Sends a notice when a provider needs authentication. Disabled while usage notifications are off."
              ))
        }
      }
    }
  }
}

private struct HorizontallyScrollableText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    ScrollView(.horizontal) {
      Text(text)
        .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
        .semanticForeground(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .textSelection(.enabled)
    }
    .frame(height: 18)
    .accessibilityLabel("History file")
    .accessibilityValue(text)
  }
}

struct SettingsContentReadyKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

private enum SettingsFocusTarget: Hashable {
  case providers
  case provider(ProviderID)
}
