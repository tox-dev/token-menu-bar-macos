import AppKit
import SwiftUI
import TokenMenuBarCore

public struct SettingsModelFocusRequest: Equatable, Identifiable {
  public let id: UUID
  public let key: WindowKey

  public init(id: UUID = UUID(), key: WindowKey) {
    self.id = id
    self.key = key
  }
}

public struct WindowSelectionList: View {
  @Bindable var environment: UIEnvironment
  @Binding private var highlightedKey: WindowKey?
  @Binding private var labelDrafts: [WindowKey: String]
  public let focusRequest: SettingsModelFocusRequest?
  @State private var query = ""
  @State private var lastUsedAt: [WindowKey: Date] = [:]
  @State private var revealedKey: WindowKey?
  @State private var hoveredReorderTarget: ReorderTarget?
  @FocusState private var focus: Field?

  enum Field: Hashable {
    case filter
    case hideUnused
    case providerSelection(ProviderID)
    case modelSelection(WindowKey)
    case label(WindowKey)
  }

  enum ReorderTarget: Hashable {
    case provider(ProviderID)
    case model(WindowKey)
  }

  public init(
    environment: UIEnvironment, highlightedKey: Binding<WindowKey?> = .constant(nil),
    labelDrafts: Binding<[WindowKey: String]> = .constant([:]), focusRequest: SettingsModelFocusRequest? = nil
  ) {
    self.environment = environment
    _highlightedKey = highlightedKey
    _labelDrafts = labelDrafts
    self.focusRequest = focusRequest
  }

  private var settings: TokenMenuBarCore.Settings { environment.settings }

  var rows: [(key: WindowKey, window: QuotaWindow)] {
    orderedProviders.flatMap { provider in
      orderedWindows(provider).map { (WindowKey(provider, $0), $0) }
    }
  }

  var selection: [WindowKey] {
    settings.hasCustomSelection
      ? settings.selectedWindows : StatusItemBuilder.defaultSelection(environment.state.snapshots)
  }

  var groups: [SettingsProviderGroup] {
    SettingsModelPresentation.groups(
      snapshots: environment.state.snapshots, selected: selection, labels: settings.shortLabels,
      providerOrder: settings.providerOrder, modelOrder: settings.modelOrder, query: query,
      hideUnused: settings.hideUnusedModels, lastUsedAt: lastUsedAt, revealedKey: revealedKey, now: environment.now)
  }

  var orderedProviders: [ProviderID] {
    let available = environment.state.snapshots.keys.sorted()
    return settings.providerOrder.filter { available.contains($0) }
      + available.filter { !settings.providerOrder.contains($0) }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ResponsivePanelLayout {
        HStack(spacing: 8) {
          modelFilter
          Text("⌘F").font(.caption.monospaced()).semanticForeground(.secondary)
          hideUnusedToggle
        }
        .frame(minWidth: 600)
      } narrow: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            modelFilter
            Text("⌘F").font(.caption.monospaced()).semanticForeground(.secondary)
          }
          hideUnusedToggle
        }
      }
      Text("Checked models appear in the menu bar; the range uses retained activity and the current quota window.")
        .font(.caption)
        .semanticForeground(.secondary)
      if groups.isEmpty {
        ContentUnavailableView(
          rows.isEmpty ? "No models yet" : "No matching models",
          systemImage: rows.isEmpty ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle",
          description: Text(
            rows.isEmpty ? "Models appear after the first successful refresh." : "Clear the filter to show all models.")
        )
      } else {
        VStack(spacing: 0) {
          ForEach(groups) { group in
            providerHeader(group)
            ForEach(group.rows) { row in modelRow(row) }
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      if selection.count == 1 {
        Text("At least one model stays selected.").font(.caption).semanticForeground(.secondary)
      }
      Button("Filter Models") { focus = .filter }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .onAppear(perform: prepareDrafts)
    .task(id: activityRequest) { await loadActivity(activityRequest) }
    .onChange(of: focusRequest) { _, request in
      guard let request else { return }
      revealedKey = request.key
      Task { @MainActor in
        await Task.yield()
        focus = .label(request.key)
      }
    }
    .onChange(of: query, queryChangeAction)
    .onChange(of: settings.hideUnusedModels) { _, _ in revealedKey = nil }
    .onChange(of: focus) { old, new in
      guard case .label(let key) = old, old != new else { return }
      commitLabel(key)
    }
    .onDisappear { commitDrafts() }
  }

  var queryChangeAction: (String, String) -> Void {
    { _, _ in revealedKey = nil }
  }

  private var modelFilter: some View {
    TextField("Filter models…", text: $query)
      .textFieldStyle(.roundedBorder)
      .richHelp(
        TooltipContent(
          title: "Filter models",
          body:
            "Matches provider names, model names, identifiers, and effective short labels. "
            + "Filtering does not change selection or stored settings."
        ),
        focus: $focus, equals: .filter
      )
      .accessibilityIdentifier("model-filter")
  }

  private var hideUnusedToggle: some View {
    Toggle("Hide unused in range", isOn: setting(\.hideUnusedModels))
      .toggleStyle(.checkbox)
      .richHelp(
        TooltipContent(
          title: "Hide unused in range",
          body:
            "Filters models with no retained activity in the selected retention range and a current quota window "
            + "at zero. Selection, labels, order, and history stay unchanged."
        ),
        focus: $focus, equals: .hideUnused
      )
  }

  @ViewBuilder
  func providerHeader(_ group: SettingsProviderGroup) -> some View {
    let target = ReorderTarget.provider(group.provider)
    let moveEarlier = { moveProvider(group.provider, by: -1) }
    let moveLater = { moveProvider(group.provider, by: 1) }
    let header = ResponsivePanelLayout {
      HStack(spacing: 8) {
        providerIdentity(group)
        Spacer(minLength: 8)
        providerSelection(group)
        if settings.windowOrder == .provider { providerReorderControls(group.provider, target: target) }
      }
      .frame(minWidth: 600)
    } narrow: {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          providerIdentity(group)
          Spacer(minLength: 8)
          providerSelection(group)
        }
        if settings.windowOrder == .provider { providerReorderControls(group.provider, target: target) }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.05))
    .contentShape(Rectangle())
    .onHover { hoveredReorderTarget = $0 ? target : nil }

    if settings.windowOrder == .provider {
      header
        .dropDestination(for: String.self) { values, _ in
          guard let raw = values.first?.dropPrefix("provider:"), let provider = ProviderID(rawValue: raw) else {
            return false
          }
          moveProvider(provider, before: group.provider)
          return true
        }
        .contextMenu {
          Button("Move Earlier", action: moveEarlier)
            .richHelp(
              TooltipContent(
                title: "Move provider earlier",
                body: "Moves \(group.provider.displayName) one place earlier in Stable order."))
          Button("Move Later", action: moveLater)
            .richHelp(
              TooltipContent(
                title: "Move provider later",
                body: "Moves \(group.provider.displayName) one place later in Stable order."))
        }
        .accessibilityAction(named: "Move Earlier", moveEarlier)
        .accessibilityAction(named: "Move Later", moveLater)
    } else {
      header
    }
  }

  private func providerIdentity(_ group: SettingsProviderGroup) -> some View {
    HStack(spacing: 8) {
      ProviderMarkView(group.provider, size: CGSize(width: 22, height: 18)).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(group.provider.displayName).fontWeight(.semibold)
        Text("\(group.selectedCount) of \(group.totalCount) shown").font(.caption).semanticForeground(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func providerSelection(_ group: SettingsProviderGroup) -> some View {
    let bindings = providerKeys(group.provider).map(selectionBinding)
    return Toggle(sources: bindings, isOn: \.self) { Text("All") }
      .toggleStyle(.checkbox)
      .disabled(selection.count == group.selectedCount && group.selection == .all)
      .accessibilityLabel("Show all \(group.provider.displayName) models")
      .accessibilityValue("\(group.selectedCount) of \(group.totalCount) selected")
      .richHelp(
        TooltipContent(
          title: "Show all \(group.provider.displayName) models",
          body:
            "Selects or clears this provider's models as a group. "
            + "Token Menu Bar keeps at least one model selected across all providers."
        ),
        focus: $focus, equals: .providerSelection(group.provider)
      )
  }

  private func providerReorderControls(_ provider: ProviderID, target: ReorderTarget) -> some View {
    HStack(spacing: 3) {
      reorderButton(
        symbol: "chevron.up", label: "Move \(provider.displayName) earlier",
        explanation: "Moves \(provider.displayName) one place earlier in Stable order.",
        disabled: !canMoveProvider(provider, by: -1)
      ) { moveProvider(provider, by: -1) }
      reorderButton(
        symbol: "chevron.down", label: "Move \(provider.displayName) later",
        explanation: "Moves \(provider.displayName) one place later in Stable order.",
        disabled: !canMoveProvider(provider, by: 1)
      ) { moveProvider(provider, by: 1) }
      reorderHandle(
        payload: "provider:\(provider.rawValue)", target: target, title: "Reorder \(provider.displayName)",
        explanation: "Drag this handle to change Stable provider order.")
    }
  }

  @ViewBuilder
  func modelRow(_ row: SettingsModelRow) -> some View {
    let target = ReorderTarget.model(row.key)
    let moveEarlier = modelMoveAction(row.key, by: -1)
    let moveLater = modelMoveAction(row.key, by: 1)
    let revertLabel = revertAction(row)
    let content = ResponsivePanelLayout {
      wideModelRow(row, target: target).frame(minWidth: 680)
    } narrow: {
      narrowModelRow(row, target: target)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(highlightedKey == row.key ? Color.accentColor.opacity(0.12) : Color.clear)
    .contentShape(Rectangle())
    .onHover { hover($0, row: row, target: target) }
    .id(row.key)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(modelAccessibilityLabel(row))
    .accessibilityValue(modelAccessibilityValue(row))

    if settings.windowOrder == .provider {
      content
        .dropDestination(for: String.self) { values, _ in
          guard let raw = values.first?.dropPrefix("model:"), let key = WindowKey(storageKey: raw) else { return false }
          moveModel(key, before: row.key)
          return true
        }
        .contextMenu {
          Button("Move Earlier", action: moveEarlier)
            .richHelp(
              TooltipContent(
                title: "Move model earlier",
                body: "Moves \(row.window.label) one place earlier in Stable order."))
          Button("Move Later", action: moveLater)
            .richHelp(
              TooltipContent(
                title: "Move model later",
                body: "Moves \(row.window.label) one place later in Stable order."))
          if isOverridden(row) {
            Button("Revert Label", action: revertLabel)
              .richHelp(
                TooltipContent(
                  title: "Revert short label",
                  body: "Restores the unique label derived for \(row.window.label)."))
          }
        }
        .accessibilityAction(named: "Move Earlier", moveEarlier)
        .accessibilityAction(named: "Move Later", moveLater)
    } else if isOverridden(row) {
      content.contextMenu {
        Button("Revert Label", action: revertLabel)
          .richHelp(
            TooltipContent(
              title: "Revert short label",
              body: "Restores the unique label derived for \(row.window.label)."))
      }
    } else {
      content
    }
  }

  func modelMoveAction(_ key: WindowKey, by offset: Int) -> () -> Void {
    { moveModel(key, by: offset) }
  }

  func revertAction(_ row: SettingsModelRow) -> () -> Void {
    { revert(row) }
  }

  func hover(_ inside: Bool, row: SettingsModelRow, target: ReorderTarget) {
    if inside {
      highlightedKey = row.key
      hoveredReorderTarget = target
    } else {
      if highlightedKey == row.key { highlightedKey = nil }
      if hoveredReorderTarget == target { hoveredReorderTarget = nil }
    }
  }

  private func wideModelRow(_ row: SettingsModelRow, target: ReorderTarget) -> some View {
    Grid(horizontalSpacing: 10, verticalSpacing: 0) {
      GridRow(alignment: .center) {
        modelSelection(row)
        modelIdentity(row).frame(maxWidth: .infinity, alignment: .leading)
        modelUsage(row).frame(width: 104)
        labelEditor(row)
        labelBudget(row)
        if settings.windowOrder == .provider { modelReorderControls(row, target: target) }
      }
    }
  }

  private func narrowModelRow(_ row: SettingsModelRow, target: ReorderTarget) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .top, spacing: 8) {
        modelSelection(row)
        modelIdentity(row)
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 1) {
          Text(Format.percent(row.window.usedPercent, decimals: 2)).monospacedDigit()
          Text(row.recency).font(.caption).semanticForeground(.secondary)
        }
      }
      modelGauge(row)
      HStack(spacing: 6) {
        labelEditor(row)
        labelBudget(row)
        Spacer(minLength: 8)
        if settings.windowOrder == .provider { modelReorderControls(row, target: target) }
      }
    }
  }

  private func modelSelection(_ row: SettingsModelRow) -> some View {
    Toggle("", isOn: selectionBinding(row.key))
      .labelsHidden()
      .toggleStyle(.checkbox)
      .disabled(selection == [row.key])
      .accessibilityLabel("Show \(row.window.label) in the menu bar")
      .richHelp(
        TooltipContent(
          title: "Menu bar selection",
          body:
            "Controls whether \(row.window.label) can appear in the status item. "
            + "Its Usage row and history remain available when unchecked."
        ),
        focus: $focus, equals: .modelSelection(row.key)
      )
  }

  private func modelIdentity(_ row: SettingsModelRow) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(row.window.label).fixedSize(horizontal: false, vertical: true)
      Text(row.detail).font(.caption.monospaced()).semanticForeground(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func modelUsage(_ row: SettingsModelRow) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(Format.percent(row.window.usedPercent, decimals: 2)).monospacedDigit()
        Text(row.recency).font(.caption).semanticForeground(.secondary)
      }
      modelGauge(row)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private func modelGauge(_ row: SettingsModelRow) -> some View {
    Gauge(value: row.window.usedPercent, in: 0...100) { Text("Usage") }
      .gaugeStyle(.accessoryLinearCapacity)
      .labelsHidden()
      .tint(Color(UsageColor.color(percent: row.window.usedPercent)))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(row.window.label) usage")
      .accessibilityValue("\(Format.percent(row.window.usedPercent, decimals: 2)), \(row.recency)")
      .richHelp(
        TooltipContent(
          title: "Usage and recency",
          body:
            "Shows the latest \(row.window.label) percentage and when Token Menu Bar last observed usage "
            + "for this model or window."
        ))
  }

  private func labelEditor(_ row: SettingsModelRow) -> some View {
    let conflict = labelConflict(row)
    return HStack(spacing: 4) {
      TextField("Label", text: label(row))
        .font(.caption.monospaced())
        .multilineTextAlignment(.center)
        .frame(width: 64)
        .richHelp(
          TooltipContent(
            title: "Short label",
            body:
              "Sets the model's label in every menu-bar format, up to six characters. "
              + "Clearing the field restores the derived label."
          ),
          focus: $focus, equals: .label(row.key)
        )
        .onSubmit { commitLabel(row.key) }
        .accessibilityLabel("Short label for \(row.key.provider.displayName) \(row.window.label)")
        .accessibilityValue(shortLabelAccessibilityValue(row))
        .accessibilityHint(conflict.map { labelConflictDescription(row, conflictingKey: $0) } ?? "")
        .overlay {
          RoundedRectangle(cornerRadius: 4)
            .stroke(conflict == nil ? Color.clear : Color(.destructive), lineWidth: 1)
        }
      if let conflict {
        Image(systemName: "exclamationmark.triangle.fill")
          .semanticForeground(.destructive)
          .richHelp(
            TooltipContent(
              title: "Duplicate short label",
              body: labelConflictDescription(row, conflictingKey: conflict))
          )
          .accessibilityLabel("Duplicate short label")
          .accessibilityValue(labelConflictDescription(row, conflictingKey: conflict))
      }
      if isOverridden(row) {
        NativeIconButton(
          symbol: "arrow.counterclockwise",
          accessibilityLabel: "Revert label for \(row.key.provider.displayName) \(row.window.label)",
          explanation: "Restores the derived label \(row.defaultLabel) and removes the saved override."
        ) { revert(row) }
        .controlSize(.mini)
        .accessibilityHint("Restores \(row.defaultLabel)")
      } else {
        Color.clear.frame(width: 20, height: 1)
      }
    }
  }

  private func labelBudget(_ row: SettingsModelRow) -> some View {
    Text("\(draft(for: row).count)/\(ShortLabelPolicy.limit)")
      .font(.caption2.monospacedDigit())
      .foregroundStyle(Color(labelConflict(row) == nil ? .secondary : .destructive))
      .frame(width: 28, alignment: .trailing)
  }

  private func modelReorderControls(_ row: SettingsModelRow, target: ReorderTarget) -> some View {
    HStack(spacing: 3) {
      reorderButton(
        symbol: "chevron.up", label: "Move \(row.window.label) earlier",
        explanation: "Moves \(row.window.label) one place earlier within \(row.key.provider.displayName).",
        disabled: !canMoveModel(row.key, by: -1)
      ) { moveModel(row.key, by: -1) }
      reorderButton(
        symbol: "chevron.down", label: "Move \(row.window.label) later",
        explanation: "Moves \(row.window.label) one place later within \(row.key.provider.displayName).",
        disabled: !canMoveModel(row.key, by: 1)
      ) { moveModel(row.key, by: 1) }
      reorderHandle(
        payload: "model:\(row.key.storageKey)", target: target, title: "Reorder \(row.window.label)",
        explanation: "Drag this handle within \(row.key.provider.displayName) to change Stable order.")
    }
  }

  private func reorderButton(
    symbol: String, label: String, explanation: String, disabled: Bool, action: @escaping () -> Void
  ) -> some View {
    NativeIconButton(symbol: symbol, accessibilityLabel: label, explanation: explanation, action: action)
      .controlSize(.mini)
      .disabled(disabled)
  }

  private func reorderHandle(
    payload: String, target: ReorderTarget, title: String, explanation: String
  ) -> some View {
    Image(systemName: "line.3.horizontal")
      .semanticForeground(.secondary)
      .frame(width: 18)
      .contentShape(Rectangle())
      .opacity(hoveredReorderTarget == target ? 1 : 0)
      .allowsHitTesting(hoveredReorderTarget == target)
      .onDrag(reorderDragAction(payload))
      .richHelp(TooltipContent(title: title, body: explanation))
      .accessibilityHidden(true)
  }

  func reorderDragAction(_ payload: String) -> () -> NSItemProvider {
    { NSItemProvider(object: payload as NSString) }
  }

  func canMoveProvider(_ provider: ProviderID, by offset: Int) -> Bool {
    guard let index = orderDraft.providers.firstIndex(of: provider) else { return false }
    return orderDraft.providers.indices.contains(index + offset)
  }

  func canMoveModel(_ key: WindowKey, by offset: Int) -> Bool {
    let keys = orderDraft.models.filter { $0.provider == key.provider }
    guard let index = keys.firstIndex(of: key) else { return false }
    return keys.indices.contains(index + offset)
  }

  func orderedWindows(_ provider: ProviderID) -> [QuotaWindow] {
    guard let windows = environment.state.snapshots[provider]?.windows else { return [] }
    let byKey = Dictionary(uniqueKeysWithValues: windows.map { (WindowKey(provider, $0), $0) })
    return orderDraft.models.filter { $0.provider == provider }.compactMap { byKey[$0] }
  }

  var orderDraft: SettingsOrderDraft {
    SettingsOrderDraft(providers: settings.providerOrder, models: settings.modelOrder, available: availableKeys)
  }

  var availableKeys: [WindowKey] {
    environment.state.snapshots.keys.sorted().flatMap { provider in
      environment.state.snapshots[provider]!.windows.map { WindowKey(provider, $0) }
    }
  }

  var availableWindows: [WindowKey: QuotaWindow] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.window) })
  }

  var activityRequest: SettingsActivityRequest {
    SettingsActivityRequest(
      keys: availableKeys.sorted(), sampleRevision: environment.state.sampleRevision,
      retentionDays: settings.historyRetentionDays,
      rangeHour: Int64(environment.clock.now().timeIntervalSince1970 / 3600))
  }

  func loadActivity(_ request: SettingsActivityRequest) async {
    await Task.yield()
    guard !Task.isCancelled else { return }
    guard !request.keys.isEmpty else {
      lastUsedAt = [:]
      return
    }
    let dates = await environment.settingsActivity(for: request)
    guard !Task.isCancelled else { return }
    lastUsedAt = dates
  }

  func setting<Value>(_ keyPath: ReferenceWritableKeyPath<TokenMenuBarCore.Settings, Value>) -> Binding<Value> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: {
        settings[keyPath: keyPath] = $0
        environment.actions.settingsChanged()
      })
  }

  func selectionBinding(_ key: WindowKey) -> Binding<Bool> {
    Binding(get: { selection.contains(key) }, set: { toggle(key, on: $0) })
  }

  func providerKeys(_ provider: ProviderID) -> [WindowKey] {
    availableKeys.filter { $0.provider == provider }
  }

  func toggle(_ key: WindowKey, on: Bool) {
    var keys = selection
    if on {
      if !keys.contains(key) { keys.append(key) }
    } else if keys.count > 1 {
      keys.removeAll { $0 == key }
    }
    settings.selectedWindows = orderDraft.orderedSelection(keys)
    settings.hasCustomSelection = true
    environment.actions.settingsChanged()
  }

  func label(_ row: SettingsModelRow) -> Binding<String> {
    Binding(
      get: { draft(for: row) },
      set: { setLabel(row.key, $0) })
  }

  func label(_ key: WindowKey, window: QuotaWindow) -> Binding<String> {
    Binding(
      get: {
        labelDrafts[key]
          ?? ShortLabelPolicy.resolvedLabels(windows: availableWindows, overrides: settings.shortLabels)[key]
          ?? StatusItemBuilder.defaultShortLabel(provider: key.provider, window: window)
      },
      set: { setLabel(key, $0) })
  }

  func draft(for row: SettingsModelRow) -> String {
    labelDrafts[row.key] ?? row.label
  }

  func shortLabelAccessibilityValue(_ row: SettingsModelRow) -> String {
    let value = draft(for: row)
    let count = "\(value.count) of \(ShortLabelPolicy.limit) characters"
    guard let conflict = labelConflict(row) else { return "\(value.isEmpty ? "Empty" : value), \(count)" }
    return "\(value), \(count). \(labelConflictDescription(row, conflictingKey: conflict))"
  }

  func modelAccessibilityLabel(_ row: SettingsModelRow) -> String {
    "\(row.window.label), \(row.detail)"
  }

  func modelAccessibilityValue(_ row: SettingsModelRow) -> String {
    "\(row.isSelected ? "shown" : "hidden"), "
      + "\(Format.percent(row.window.usedPercent, decimals: 2)), \(row.recency), label \(draft(for: row))"
  }

  func labelConflict(_ row: SettingsModelRow) -> WindowKey? {
    ShortLabelPolicy.conflictingKey(
      draft(for: row), for: row.key, windows: availableWindows, overrides: settings.shortLabels)
  }

  func labelConflictDescription(_ row: SettingsModelRow, conflictingKey: WindowKey) -> String {
    let window = environment.state.snapshots[conflictingKey.provider]?.window(conflictingKey.windowID)
    let name = window?.label ?? conflictingKey.windowID
    return "Already used by \(conflictingKey.provider.displayName) \(name); saved label remains \(row.label)."
  }

  func setLabel(_ key: WindowKey, _ label: String) {
    guard let row = row(key) else { return }
    let draft = ShortLabelPolicy.draft(label)
    labelDrafts[key] = draft
    guard
      ShortLabelPolicy.conflictingKey(
        draft, for: key, windows: availableWindows, overrides: settings.shortLabels) == nil
    else { return }
    let value = ShortLabelPolicy.override(draft, default: row.defaultLabel)
    guard settings.shortLabels[key] != value else { return }
    labelDrafts[key] = value ?? row.defaultLabel
    settings.setShortLabel(value, for: key)
    environment.actions.settingsChanged()
  }

  func commitLabel(_ key: WindowKey) {
    guard let row = row(key) else { return }
    commitLabel(key, default: row.defaultLabel)
  }

  func commitLabel(_ key: WindowKey, default defaultLabel: String) {
    let draft = labelDrafts[key] ?? defaultLabel
    guard
      ShortLabelPolicy.conflictingKey(
        draft, for: key, windows: availableWindows, overrides: settings.shortLabels) == nil
    else { return }
    let value = ShortLabelPolicy.override(draft, default: defaultLabel)
    guard settings.shortLabels[key] != value else { return }
    settings.setShortLabel(value, for: key)
    labelDrafts[key] = value ?? defaultLabel
    environment.actions.settingsChanged()
  }

  func commitDrafts() {
    for key in labelDrafts.keys { commitLabel(key) }
  }

  func prepareDrafts() {
    for row in groups.flatMap(\.rows) where labelDrafts[row.key] == nil { labelDrafts[row.key] = row.label }
  }

  func revert(_ row: SettingsModelRow) {
    labelDrafts[row.key] = row.defaultLabel
    commitLabel(row.key, default: row.defaultLabel)
  }

  func isOverridden(_ row: SettingsModelRow) -> Bool {
    ShortLabelPolicy.override(draft(for: row), default: row.defaultLabel) != nil
  }

  func row(_ key: WindowKey) -> SettingsModelRow? {
    SettingsModelPresentation.groups(
      snapshots: environment.state.snapshots, selected: selection, labels: settings.shortLabels,
      providerOrder: settings.providerOrder, modelOrder: settings.modelOrder, query: "", hideUnused: false,
      now: environment.now
    ).flatMap(\.rows).first { $0.key == key }
  }

  func moveProvider(_ provider: ProviderID, before target: ProviderID) {
    guard settings.windowOrder == .provider else { return }
    var draft = orderDraft
    draft.moveProvider(provider, before: target)
    commit(draft)
  }

  func moveProvider(_ provider: ProviderID, by offset: Int) {
    guard settings.windowOrder == .provider else { return }
    var draft = orderDraft
    draft.moveProvider(provider, by: offset)
    commit(draft)
  }

  func moveModel(_ key: WindowKey, before target: WindowKey) {
    guard settings.windowOrder == .provider else { return }
    var draft = orderDraft
    draft.moveModel(key, before: target)
    commit(draft)
  }

  func moveModel(_ key: WindowKey, by offset: Int) {
    guard settings.windowOrder == .provider else { return }
    var draft = orderDraft
    draft.moveModel(key, by: offset)
    commit(draft)
  }

  func commit(_ draft: SettingsOrderDraft) {
    guard settings.providerOrder != draft.providers || settings.modelOrder != draft.models else { return }
    settings.providerOrder = draft.providers
    settings.modelOrder = draft.models
    settings.selectedWindows = draft.orderedSelection(selection)
    environment.actions.settingsChanged()
  }
}

private extension String {
  func dropPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}

struct SettingsActivityRequest: Hashable, Sendable {
  let keys: [WindowKey]
  let sampleRevision: UInt64
  let retentionDays: Int
  let rangeHour: Int64
}
