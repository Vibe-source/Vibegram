import SwiftUI
import PhotosUI

struct VibeAgentToolsSheet: View {
  var appearance: VibeAgentKitChatAppearance
  var provider: String
  var chatId: String?
  /// Providers whose Usage row should appear (DM: current only; multi-agent group:
  /// each member agent). Each row opens a real bridge-backed detail panel.
  var usageProviders: [String]
  var allCommands: [VibeAgentSlashCommand]

  var onAttach: (() -> Void)?
  var onCamera: (() -> Void)?
  var onFile: (() -> Void)?
  var onSelectCommand: ((VibeAgentSlashCommand) -> Void)?
  var onDismiss: (() -> Void)?

  @State private var selectedModel: String?
  @State private var selectedAdvisor: String?
  @State private var selectedIntelligence: AgentBridgeIntelligenceLevel = .medium
  @State private var selectedWorkMode: AgentBridgeWorkMode = .askAuto
  /// Bumps when live model catalogs arrive so model/thinking lists re-render.
  @State private var catalogEpoch: Int = 0

  init(
    appearance: VibeAgentKitChatAppearance,
    provider: String,
    chatId: String? = nil,
    usageProviders: [String] = [],
    allCommands: [VibeAgentSlashCommand],
    onAttach: (() -> Void)? = nil,
    onCamera: (() -> Void)? = nil,
    onFile: (() -> Void)? = nil,
    onSelectCommand: ((VibeAgentSlashCommand) -> Void)? = nil,
    onDismiss: (() -> Void)? = nil
  ) {
    self.appearance = appearance
    self.provider = provider
    self.chatId = chatId
    // Prefer an explicit list; fall back to the sheet's run provider so DMs still work.
    let normalized = usageProviders
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    let ordered = ["claude", "codex", "grok", "agy"].filter { normalized.contains($0) }
    let rest = normalized.filter { !["claude", "codex", "grok", "agy"].contains($0) }
    let resolved = ordered + rest
    let fallback = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self.usageProviders = resolved.isEmpty
      ? (fallback.isEmpty ? [] : [fallback])
      : resolved
    self.allCommands = allCommands
    self.onAttach = onAttach
    self.onCamera = onCamera
    self.onFile = onFile
    self.onSelectCommand = onSelectCommand
    self.onDismiss = onDismiss

    let opts = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    _selectedModel = State(initialValue: opts.model)
    _selectedAdvisor = State(initialValue: opts.advisor)
    _selectedIntelligence = State(initialValue: opts.intelligence)
    _selectedWorkMode = State(initialValue: AgentBridgeSelectionStore.selectedWorkMode())
  }

  // MARK: - Theme

  /// Row fill. In dark mode `appearance.surface` is a warm brown that reads too light
  /// over the sheet's glass — use a neutral, slightly-elevated fill instead so rows
  /// sit correctly in both themes.
  private var rowFill: Color {
    appearance.isDark
      ? Color.white.opacity(0.05)
      : Color(uiColor: appearance.surface)
  }

  private var text: Color { Color(uiColor: appearance.text) }
  private var textSecondary: Color { Color(uiColor: appearance.textSecondary) }
  private var textTertiary: Color { Color(uiColor: appearance.textTertiary) }

  // MARK: - Command buckets

  // `usage` is promoted to a dedicated push panel (progress bars), so drop it from the
  // flat INFO command list to avoid a duplicate that would just print text.
  private var info: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .bridge && $0.name != "usage" } }
  private var options: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .runOption } }
  private var slash: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .providerSlash } }
  private var cli: [VibeAgentSlashCommand] { allCommands.filter { $0.kind == .cli } }

  var body: some View {
    NavigationStack {
      List {
        // Attachment pills
        Section {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              Button {
                onCamera?(); onDismiss?()
              } label: {
                VibeComposerAttachmentPill(title: "Camera", icon: "camera.fill", appearance: appearance)
              }
              .buttonStyle(.plain)

              Button {
                onAttach?(); onDismiss?()
              } label: {
                VibeComposerAttachmentPill(title: "Photo", icon: "photo.on.rectangle", appearance: appearance)
              }
              .buttonStyle(.plain)

              Button {
                onFile?(); onDismiss?()
              } label: {
                VibeComposerAttachmentPill(title: "File", icon: "doc.fill", appearance: appearance)
              }
              .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
          }
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }

        // Run options — each pushes an inner selection page
        Section {
          NavigationLink {
            modelPage
          } label: {
            settingRowLabel(
              title: "Model",
              systemImage: "cpu",
              value: selectedModel == nil
                ? "\(AgentBridgeSelectionStore.defaultModelTitle(provider: provider)) default"
                : AgentBridgeSelectionStore.modelTitle(provider: provider, model: selectedModel)
            )
          }
          .listRowBackground(rowFill)

          if provider.lowercased() == "claude" {
            NavigationLink {
              advisorPage
            } label: {
              settingRowLabel(
                title: "Advisor",
                systemImage: "person.crop.circle.badge.checkmark",
                value: AgentBridgeSelectionStore.advisorTitle(provider: provider, advisor: selectedAdvisor)
              )
            }
            .listRowBackground(rowFill)
          }

          NavigationLink {
            thinkingPage
          } label: {
            settingRowLabel(title: "Thinking", systemImage: "brain", value: selectedIntelligence.title)
          }
          .listRowBackground(rowFill)

          NavigationLink {
            permissionPage
          } label: {
            settingRowLabel(title: "Permission", systemImage: selectedWorkMode.icon, value: selectedWorkMode.title)
          }
          .listRowBackground(rowFill)
        }

        // Usage — one row per provider. Each pushes a detail panel that fetches the
        // real bridge `usage_result` payload (buckets + chat tokens + limitHit). No
        // synthetic percentages. DM: single row; multi-agent group: Claude/Codex/…
        if let chatId, !chatId.isEmpty, !usageProviders.isEmpty {
          Section {
            ForEach(usageProviders, id: \.self) { p in
              NavigationLink {
                VibeAgentUsagePanel(chatId: chatId, provider: p, appearance: appearance)
              } label: {
                settingRowLabel(
                  title: Self.providerDisplayName(p),
                  systemImage: "gauge.with.dots.needle.bottom.50percent",
                  value: usageProviders.count == 1 ? "Usage" : "Limits"
                )
              }
              .listRowBackground(rowFill)
            }
          } header: {
            Text(usageProviders.count == 1 ? "USAGE" : "USAGE BY AGENT")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(textSecondary)
          }
        }

        commandSection("INFO", info)
        commandSection("OPTIONS", options)
        commandSection("COMMANDS", slash)
        commandSection("TERMINAL", cli)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .navigationTitle("Add to Chat")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            onDismiss?()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
          }
        }
      }
      .tint(text)
      .onAppear {
        AgentBridgeSelectionStore.refreshModelsIfPossible()
      }
      .onReceive(NotificationCenter.default.publisher(for: AgentBridgeSelectionStore.didChangeNotification)) { _ in
        catalogEpoch &+= 1
        // Re-sync selection titles if the live catalog remapped ids.
        let opts = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
        selectedModel = opts.model
        selectedAdvisor = opts.advisor
        selectedIntelligence = opts.intelligence
      }
    }
  }

  private static func providerDisplayName(_ provider: String) -> String {
    let p = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch p {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "grok": return "Grok"
    case "agy", "antigravity": return "Agy"
    default:
      guard !p.isEmpty else { return "Usage" }
      return p.prefix(1).uppercased() + p.dropFirst()
    }
  }

  // MARK: - Command list section

  @ViewBuilder
  private func commandSection(_ title: String, _ commands: [VibeAgentSlashCommand]) -> some View {
    if !commands.isEmpty {
      Section(title) {
        ForEach(commands, id: \.name) { cmd in
          VibeToolCommandRow(command: cmd, appearance: appearance) {
            onSelectCommand?(cmd); onDismiss?()
          }
          .listRowBackground(rowFill)
        }
      }
    }
  }

  // MARK: - Inline setting row label

  @ViewBuilder
  private func settingRowLabel(title: String, systemImage: String, value: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .regular))
        .frame(width: 24)
        .foregroundStyle(text.opacity(0.85))

      Text(title)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(text)

      Spacer()

      Text(value)
        .font(.system(size: 15))
        .foregroundStyle(textSecondary)
    }
    .padding(.vertical, 4)
  }

  // MARK: - Inner pages

  private var modelPage: some View {
    let primary = AgentBridgeSelectionStore.primaryModelChoices(provider: provider)
    let other = AgentBridgeSelectionStore.otherModelChoices(provider: provider)
    return List {
      Section {
        selectRow(
          title: "\(AgentBridgeSelectionStore.defaultModelTitle(provider: provider)) default",
          isSelected: selectedModel == nil
        ) {
          AgentBridgeSelectionStore.setModel(provider: provider, model: nil)
          selectedModel = nil
        }
        // Latest / CLI-current models only in the main list.
        ForEach(primary, id: \.value) { choice in
          selectRow(
            title: choice.title,
            isSelected: selectedModel == choice.value || (selectedModel != nil && selectedModel?.caseInsensitiveCompare(choice.value) == .orderedSame)
          ) {
            AgentBridgeSelectionStore.setModel(provider: provider, model: choice.value)
            selectedModel = choice.value
          }
        }
      } footer: {
        Text(modelCatalogFooter)
          .font(.system(size: 12))
          .foregroundStyle(textTertiary)
      }

      if !other.isEmpty {
        Section("Other Models") {
          ForEach(other, id: \.value) { choice in
            selectRow(
              title: choice.title,
              isSelected: selectedModel == choice.value || (selectedModel != nil && selectedModel?.caseInsensitiveCompare(choice.value) == .orderedSame)
            ) {
              AgentBridgeSelectionStore.setModel(provider: provider, model: choice.value)
              selectedModel = choice.value
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Model")
    .navigationBarTitleDisplayMode(.inline)
    .id(catalogEpoch)
    .onAppear {
      // Force status re-fetch so provider updates (new models) appear immediately.
      AgentBridgeSelectionStore.refreshModelsIfPossible()
    }
  }

  private var modelCatalogFooter: String {
    let live = AgentBridgeSelectionStore.liveModelChoices(provider: provider)
    if live.isEmpty {
      return "Showing seed list until the paired computer reports live models."
    }
    let source = live.first?.source ?? "live"
    return "Live from provider (\(source)) · \(live.count) models"
  }

  private var thinkingPage: some View {
    let levels = AgentBridgeSelectionStore.intelligenceChoices(
      provider: provider, model: selectedModel)
    return List {
      Section {
        if levels.isEmpty {
          Text("This model bakes thinking into the model name (pick another model row).")
            .font(.system(size: 14))
            .foregroundStyle(textSecondary)
        } else {
          ForEach(levels, id: \.self) { level in
            selectRow(title: level.title, isSelected: selectedIntelligence == level) {
              AgentBridgeSelectionStore.setIntelligence(level)
              selectedIntelligence = level
            }
          }
        }
      } footer: {
        Text("Thinking levels come from the provider for the selected model when available.")
          .font(.system(size: 12))
          .foregroundStyle(textTertiary)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Thinking")
    .navigationBarTitleDisplayMode(.inline)
    .id(catalogEpoch)
    .onAppear {
      AgentBridgeSelectionStore.refreshModelsIfPossible()
    }
  }

  private var advisorPage: some View {
    List {
      Section {
        ForEach(AgentBridgeSelectionStore.advisorChoices(provider: provider), id: \.title) { choice in
          selectRow(title: choice.title, isSelected: selectedAdvisor == choice.value) {
            AgentBridgeSelectionStore.setAdvisor(
              provider: provider,
              advisor: choice.value ?? "off"
            )
            selectedAdvisor = choice.value
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Advisor")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var permissionPage: some View {
    List {
      Section {
        ForEach(AgentBridgeWorkMode.allCases, id: \.self) { mode in
          selectRow(title: mode.title, systemImage: mode.icon, isSelected: selectedWorkMode == mode) {
            AgentBridgeSelectionStore.setWorkMode(mode)
            selectedWorkMode = mode
            NotificationCenter.default.post(name: NSNotification.Name("AgentBridgeWorkModeChanged"), object: nil)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Permission")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private func selectRow(
    title: String,
    systemImage: String? = nil,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 16, weight: .regular))
            .frame(width: 24)
            .foregroundStyle(text.opacity(0.85))
        }
        Text(title)
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(text)
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(uiColor: appearance.primary))
        }
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(rowFill)
  }
}

private struct VibeComposerAttachmentPill: View {
  let title: String
  let icon: String
  let appearance: VibeAgentKitChatAppearance

  var body: some View {
    VStack(alignment: .center, spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .regular))
      Text(title)
        .font(.system(size: 14, weight: .medium))
    }
    .frame(width: 105, height: 95)
    .background(
      appearance.isDark
        ? Color.white.opacity(0.08)
        : Color(uiColor: appearance.text).opacity(0.06)
    )
    .foregroundStyle(Color(uiColor: appearance.text))
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

private struct VibeToolCommandRow: View {
  let command: VibeAgentSlashCommand
  let appearance: VibeAgentKitChatAppearance
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: paletteIcon(command))
          .font(.system(size: 16, weight: .regular))
          .frame(width: 24)
          .foregroundStyle(Color(uiColor: appearance.text).opacity(0.85))

        VStack(alignment: .leading, spacing: 2) {
          Text(command.display)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color(uiColor: appearance.text))

          if !command.subtitle.isEmpty {
            Text(command.subtitle)
              .font(.system(size: 12.5))
              .foregroundStyle(Color(uiColor: appearance.textSecondary))
          }
        }

        Spacer()
      }
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func paletteIcon(_ command: VibeAgentSlashCommand) -> String {
    if command.kind == .providerSlash { return "command" }
    if command.kind == .runOption { return "slider.horizontal.3" }
    return "terminal"
  }
}

// MARK: - Usage panel

struct VibeAgentUsageBucket: Identifiable {
  let id = UUID()
  let label: String
  let utilization: Int
  let resetsAt: String?
}

/// Glass-sheet wrapper matching agent progress / ask sheets.
struct VibeAgentUsageSheetRoot: View {
  let chatId: String
  let provider: String
  let appearance: VibeAgentKitChatAppearance
  /// Prefetched payload so the first frame is not empty.
  var seedPayload: [String: Any]? = nil
  /// In-flight request id kicked off by the presenter (quiet refresh).
  var pendingRequestId: String? = nil
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    NavigationStack {
      VibeAgentUsagePanel(
        chatId: chatId,
        provider: provider,
        appearance: appearance,
        seedPayload: seedPayload,
        pendingRequestId: pendingRequestId
      )
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(Color(uiColor: appearance.textSecondary))
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    // Progress-node sheet tint: ultra-thin material light/dark (not solid, not pure clear).
    .presentationBackground(.ultraThinMaterial)
  }
}

/// Live usage detail for one provider. Prefers a prefetched `seedPayload`, then
/// quietly refreshes from the bridge. Buckets + reset times are payload-only.
struct VibeAgentUsagePanel: View {
  let chatId: String
  let provider: String
  let appearance: VibeAgentKitChatAppearance
  var seedPayload: [String: Any]? = nil
  var pendingRequestId: String? = nil

  @State private var requestId: String?
  @State private var buckets: [VibeAgentUsageBucket] = []
  @State private var chatTokens: String?
  @State private var modelLabel: String?
  @State private var limitHit = false
  @State private var limitMessage: String?
  @State private var loading = true
  @State private var errorText: String?
  @State private var emptyHint: String?

  private var text: Color { Color(uiColor: appearance.text) }
  private var textSecondary: Color { Color(uiColor: appearance.textSecondary) }
  /// Soft elevated row over glass — mirrors progress/ask sheet neutral fills.
  private var rowFill: Color {
    appearance.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
  }

  private var providerTitle: String {
    let p = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch p {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "grok": return "Grok"
    case "agy", "antigravity": return "Agy"
    default:
      guard !p.isEmpty else { return "Usage" }
      return p.prefix(1).uppercased() + p.dropFirst()
    }
  }

  var body: some View {
    List {
      if loading && buckets.isEmpty && errorText == nil && limitMessage == nil {
        Section {
          HStack(spacing: 12) {
            ProgressView()
            Text("Fetching \(providerTitle) usage…")
              .font(.system(size: 15))
              .foregroundStyle(textSecondary)
          }
          .padding(.vertical, 4)
          .listRowBackground(rowFill)
        }
      }

      if limitHit, let limitMessage, !limitMessage.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Label("Rate limit hit", systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(Color.orange)
            Text(limitMessage)
              .font(.system(size: 14))
              .foregroundStyle(textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 4)
          .listRowBackground(rowFill)
        }
      }

      if !buckets.isEmpty {
        Section {
          ForEach(buckets) { bucket in
            VibeUsageBar(bucket: bucket, appearance: appearance)
              .listRowBackground(rowFill)
          }
        } header: {
          Text("LIMITS & RESET")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(textSecondary)
        }
      } else if !loading, errorText == nil {
        Section {
          Text(
            emptyHint
              ?? "No rate-limit windows reported for \(providerTitle) yet."
          )
          .font(.system(size: 14))
          .foregroundStyle(textSecondary)
          .listRowBackground(rowFill)
        } header: {
          Text("LIMITS & RESET")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(textSecondary)
        }
      }

      if modelLabel != nil || chatTokens != nil {
        Section {
          if let modelLabel, !modelLabel.isEmpty {
            HStack {
              Text("Model")
                .foregroundStyle(textSecondary)
              Spacer()
              Text(modelLabel)
                .foregroundStyle(text)
                .lineLimit(1)
            }
            .font(.system(size: 14))
            .listRowBackground(rowFill)
          }
          if let chatTokens {
            VStack(alignment: .leading, spacing: 4) {
              Text("This chat (last run)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textSecondary)
              Text(chatTokens)
                .font(.system(size: 14))
                .foregroundStyle(text)
            }
            .padding(.vertical, 2)
            .listRowBackground(rowFill)
          }
        } header: {
          Text("DETAILS")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(textSecondary)
        }
      }

      if let errorText {
        Section {
          Text(errorText)
            .font(.system(size: 14))
            .foregroundStyle(textSecondary)
            .listRowBackground(rowFill)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("\(providerTitle) usage")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .onAppear(perform: bootstrap)
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
      guard
        let info = note.userInfo,
        (info["reason"] as? String) == "agentBridgeUsage"
      else { return }
      let rid = info["requestId"] as? String
      if let requestId, let rid, rid == requestId {
        ingest(requestId: requestId)
        return
      }
      // Also accept provider-keyed cache updates while the sheet is open.
      if let p = (info["provider"] as? String)?.lowercased(),
        p == provider.lowercased()
      {
        if let cached = ChatEngine.shared.cachedAgentBridgeUsage(chatId: chatId, provider: provider) {
          applyPayload(cached)
        }
      }
    }
  }

  private func bootstrap() {
    // 1) Seed from prefetched cache / presenter seed so first paint has data.
    if let seedPayload {
      applyPayload(seedPayload)
    } else if let cached = ChatEngine.shared.cachedAgentBridgeUsage(chatId: chatId, provider: provider) {
      applyPayload(cached)
    }

    // 2) Quiet refresh (or use presenter's pending request).
    if let pendingRequestId, !pendingRequestId.isEmpty {
      requestId = pendingRequestId
      ingest(requestId: pendingRequestId)
      // If not yet arrived, wait on notification (already loading if no seed).
      if buckets.isEmpty && chatTokens == nil && !limitHit {
        loading = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        if loading && buckets.isEmpty && limitMessage == nil {
          loading = false
          if errorText == nil {
            errorText = "Couldn't reach the bridge for usage. Make sure your Mac bridge is connected."
          }
        }
      }
      return
    }

    let result = ChatEngine.shared.requestAgentBridgeUsage([
      "chatId": chatId,
      "provider": provider,
    ])
    if let rid = result["requestId"] as? String, (result["accepted"] as? Bool) == true {
      requestId = rid
      if buckets.isEmpty && chatTokens == nil && !limitHit {
        loading = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        if loading && buckets.isEmpty && limitMessage == nil {
          loading = false
          if errorText == nil {
            errorText = "Couldn't reach the bridge for usage. Make sure your Mac bridge is connected."
          }
        }
      }
    } else if buckets.isEmpty {
      loading = false
      errorText =
        "Usage is unavailable right now (\(result["reason"] as? String ?? "not connected"))."
    } else {
      loading = false
    }
  }

  private func ingest(requestId rid: String) {
    guard let payload = ChatEngine.shared.latestAgentBridgeUsage(requestId: rid) else { return }
    applyPayload(payload)
  }

  private func applyPayload(_ payload: [String: Any]) {
    loading = false
    errorText = nil
    emptyHint = nil
    if (payload["ok"] as? Bool) == false {
      // Keep any seed data; only set error if we have nothing useful.
      if buckets.isEmpty && chatTokens == nil {
        errorText = (payload["message"] as? String) ?? "Usage request failed."
      }
      return
    }
    guard let report = payload["report"] as? [String: Any] else {
      if buckets.isEmpty {
        errorText = "The bridge returned no usage data."
      }
      return
    }

    limitHit = (report["limitHit"] as? Bool) == true
    if let msg = report["limitMessage"] as? String, !msg.isEmpty {
      limitMessage = msg
    } else if !limitHit {
      limitMessage = nil
    }

    if let model = report["model"] as? String, !model.isEmpty {
      modelLabel = model
    }

    var parsed: [VibeAgentUsageBucket] = []
    if let rawBuckets = report["buckets"] as? [[String: Any]] {
      for b in rawBuckets {
        guard let label = b["label"] as? String, !label.isEmpty else { continue }
        let util: Int?
        if let i = b["utilization"] as? Int { util = i }
        else if let d = b["utilization"] as? Double, d.isFinite { util = Int(d.rounded()) }
        else if let n = b["utilization"] as? NSNumber { util = n.intValue }
        else { util = nil }
        guard let util else { continue }
        parsed.append(
          VibeAgentUsageBucket(
            label: label,
            utilization: util,
            resetsAt: b["resetsAt"] as? String ?? b["resets_at"] as? String
          )
        )
      }
    }
    if !parsed.isEmpty {
      buckets = parsed
    }

    if let chat = report["chat"] as? [String: Any] {
      chatTokens = Self.formatChatTokens(chat)
    }

    if buckets.isEmpty && chatTokens == nil && !limitHit {
      let p = provider.lowercased()
      emptyHint =
        p == "claude"
        ? "No subscription usage yet — sign in to Claude on your Mac, or run a task first."
        : p == "codex"
          ? "No Codex rate-limit windows found yet. Run a Codex task so the bridge can read limits."
          : "No rate-limit windows reported yet for \(providerTitle)."
    }
  }

  private static func formatChatTokens(_ chat: [String: Any]) -> String? {
    func n(_ key: String) -> Int? {
      if let i = chat[key] as? Int { return i }
      if let d = chat[key] as? Double { return Int(d) }
      if let n = chat[key] as? NSNumber { return n.intValue }
      return nil
    }
    var parts: [String] = []
    if let i = n("inputTokens") { parts.append("input \(i)") }
    if let c = n("cachedInputTokens") { parts.append("cached \(c)") }
    if let o = n("outputTokens") { parts.append("output \(o)") }
    if let cost = chat["totalCostUsd"] as? Double {
      parts.append(String(format: "cost $%.4f", cost))
    } else if let cost = chat["totalCostUsd"] as? NSNumber {
      parts.append(String(format: "cost $%.4f", cost.doubleValue))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

private struct VibeUsageBar: View {
  let bucket: VibeAgentUsageBucket
  let appearance: VibeAgentKitChatAppearance

  private var pct: Double { max(0, min(100, Double(bucket.utilization))) }

  private var tint: Color {
    if pct >= 90 { return .red }
    if pct >= 70 { return .orange }
    return Color(uiColor: appearance.primary)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(bucket.label)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(uiColor: appearance.text))
        Spacer()
        Text("\(bucket.utilization)% used")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint)
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color(uiColor: appearance.text).opacity(0.12))
          Capsule()
            .fill(tint)
            .frame(width: max(6, geo.size.width * pct / 100))
        }
      }
      .frame(height: 8)
      // Always surface reset timing when the payload provides it.
      if let reset = Self.resetDetail(bucket.resetsAt) {
        HStack(spacing: 6) {
          Image(systemName: "clock")
            .font(.system(size: 12, weight: .medium))
          Text(reset)
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Color(uiColor: appearance.textSecondary))
      }
    }
    .padding(.vertical, 8)
  }

  /// "Resets in 3h 12m · Fri 3:49 PM" from ISO / fractional ISO.
  private static func resetDetail(_ iso: String?) -> String? {
    guard let iso, !iso.isEmpty else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let date else { return nil }
    let secs = date.timeIntervalSinceNow
    let relative: String
    if secs <= 0 {
      relative = "resetting now"
    } else {
      let h = Int(secs) / 3600
      let m = (Int(secs) % 3600) / 60
      if h >= 24 {
        relative = "resets in \(h / 24)d \(h % 24)h"
      } else if h >= 1 {
        relative = m > 0 ? "resets in \(h)h \(m)m" : "resets in \(h)h"
      } else {
        relative = "resets in \(max(1, m))m"
      }
    }
    let absFmt = DateFormatter()
    absFmt.dateStyle = .short
    absFmt.timeStyle = .short
    return "\(relative) · \(absFmt.string(from: date))"
  }
}
