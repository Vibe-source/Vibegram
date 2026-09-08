import SwiftUI
import UIKit

/// One entry in the agent tool catalog (mirrors the backend ToolRegistry).
struct ChatAgentToolInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
}

/// A prompt argument the agent's system prompt references via {{name}}.
/// `locked` is true when the value is pinned in backend code and cannot be
/// edited from the app (shown read-only).
struct ChatAgentPromptVariable: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    var value: String
    let locked: Bool
}

struct ChatAgentModelInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let tier: String
    let recommended: Bool
    let thinkingLevels: [String]
    let defaultThinkingLevel: String
}

struct ChatAgentModelProviderInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let available: Bool
    let models: [ChatAgentModelInfo]
}

struct ChatAgentModelRegistry: Equatable {
    let defaultProvider: String
    let defaultModelId: String
    let providers: [ChatAgentModelProviderInfo]
    let isFallback: Bool

    func provider(id: String) -> ChatAgentModelProviderInfo? {
        providers.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func model(providerId: String, modelId: String) -> ChatAgentModelInfo? {
        provider(id: providerId)?.models.first {
            $0.id.caseInsensitiveCompare(modelId) == .orderedSame
        }
    }

    func selection(modelId: String) -> (provider: ChatAgentModelProviderInfo, model: ChatAgentModelInfo)? {
        for provider in providers {
            if let model = provider.models.first(where: {
                $0.id.caseInsensitiveCompare(modelId) == .orderedSame
            }) {
                return (provider, model)
            }
        }
        return nil
    }

    static let fallback = ChatAgentModelRegistry(
        defaultProvider: "anthropic",
        defaultModelId: "claude-sonnet-5",
        providers: [
            ChatAgentModelProviderInfo(
                id: "anthropic",
                name: "Anthropic",
                available: true,
                models: [
                    ChatAgentModelInfo(
                        id: "claude-fable-5",
                        name: "Fable 5",
                        description: "Deep reasoning for complex decisions.",
                        tier: "frontier",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "claude-opus-4-8",
                        name: "Opus 4.8",
                        description: "Maximum capability for demanding work.",
                        tier: "frontier",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "claude-sonnet-5",
                        name: "Sonnet 5",
                        description: "Fast, capable, and recommended for most agents.",
                        tier: "balanced",
                        recommended: true,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "claude-haiku-4-5-20251001",
                        name: "Haiku 4.5",
                        description: "Quick responses for lightweight tasks.",
                        tier: "fast",
                        recommended: false,
                        thinkingLevels: ["medium"],
                        defaultThinkingLevel: "medium"),
                ]),
            ChatAgentModelProviderInfo(
                id: "openai",
                name: "OpenAI",
                available: true,
                models: [
                    ChatAgentModelInfo(
                        id: "gpt-5.6-sol",
                        name: "GPT-5.6 Sol",
                        description: "Maximum capability for demanding work.",
                        tier: "frontier",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high", "xhigh", "max"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "gpt-5.6-terra",
                        name: "GPT-5.6 Terra",
                        description: "A strong balance of speed and capability.",
                        tier: "balanced",
                        recommended: true,
                        thinkingLevels: ["low", "medium", "high", "xhigh"],
                        defaultThinkingLevel: "medium"),
                    ChatAgentModelInfo(
                        id: "gpt-5.6-luna",
                        name: "GPT-5.6 Luna",
                        description: "Fast and efficient for everyday tasks.",
                        tier: "fast",
                        recommended: false,
                        thinkingLevels: ["low", "medium", "high"],
                        defaultThinkingLevel: "medium"),
                ]),
        ],
        isFallback: true
    )
}

enum ChatAgentModelRegistryService {
    static func load(
        apiBaseURL: URL,
        token: String,
        completion: @escaping (ChatAgentModelRegistry) -> Void
    ) {
        let base = apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/agents/model_registry") else {
            completion(.fallback)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
            data, response, error in
            DispatchQueue.main.async {
                guard
                    error == nil,
                    (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                    let data,
                    let payload =
                        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    let registry = parse(payload)
                else {
                    completion(.fallback)
                    return
                }
                completion(registry)
            }
        }.resume()
    }

    static func parse(_ payload: [String: Any]) -> ChatAgentModelRegistry? {
        guard
            let defaultSelection = payload["default"] as? [String: Any],
            let defaultProvider = normalizedString(defaultSelection["provider"]),
            let defaultModelId = normalizedString(
                defaultSelection["modelId"] ?? defaultSelection["model_id"]),
            let rawProviders = payload["providers"] as? [[String: Any]]
        else {
            return nil
        }

        let providers: [ChatAgentModelProviderInfo] = rawProviders.compactMap { rawProvider in
            guard
                let id = normalizedString(rawProvider["id"]),
                let rawModels = rawProvider["models"] as? [[String: Any]]
            else {
                return nil
            }
            let models: [ChatAgentModelInfo] = rawModels.compactMap { rawModel in
                guard let modelId = normalizedString(rawModel["id"]) else { return nil }
                let fallbackModel = ChatAgentModelRegistry.fallback.selection(modelId: modelId)?.model
                let rawThinkingLevels =
                    normalizedStringList(
                        rawModel["thinkingLevels"] ?? rawModel["thinking_levels"])
                    ?? fallbackModel?.thinkingLevels
                    ?? ["medium"]
                let thinkingLevels = normalizedThinkingLevels(rawThinkingLevels)
                let requestedDefault =
                    normalizedString(
                        rawModel["defaultThinkingLevel"]
                            ?? rawModel["default_thinking_level"])
                    ?? fallbackModel?.defaultThinkingLevel
                    ?? "medium"
                let defaultThinkingLevel =
                    thinkingLevels.first(where: {
                        $0.caseInsensitiveCompare(requestedDefault) == .orderedSame
                    })
                    ?? thinkingLevels.first(where: { $0 == "medium" })
                    ?? thinkingLevels.first
                    ?? "medium"
                return ChatAgentModelInfo(
                    id: modelId,
                    name: normalizedString(rawModel["name"]) ?? modelId,
                    description: normalizedString(rawModel["description"]) ?? "",
                    tier: normalizedString(rawModel["tier"]) ?? "",
                    recommended: boolean(rawModel["recommended"]) ?? false,
                    thinkingLevels: thinkingLevels.isEmpty ? ["medium"] : thinkingLevels,
                    defaultThinkingLevel: defaultThinkingLevel
                )
            }
            let providerName: String
            switch id.lowercased() {
            case "anthropic":
                providerName = "Anthropic"
            case "openai":
                providerName = "OpenAI"
            default:
                providerName = normalizedString(rawProvider["name"]) ?? id
            }
            return ChatAgentModelProviderInfo(
                id: id,
                name: providerName,
                available: boolean(rawProvider["available"]) ?? false,
                models: models
            )
        }

        guard !providers.isEmpty else { return nil }
        return ChatAgentModelRegistry(
            defaultProvider: defaultProvider,
            defaultModelId: defaultModelId,
            providers: providers,
            isFallback: false
        )
    }

    private static func normalizedString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func normalizedStringList(_ raw: Any?) -> [String]? {
        guard let values = raw as? [Any] else { return nil }
        return values.compactMap { normalizedString($0) }
    }

    private static func normalizedThinkingLevels(_ values: [String]) -> [String] {
        let accepted = Set(["low", "medium", "high", "xhigh", "max"])
        var seen = Set<String>()
        return values.compactMap { raw in
            let level = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard accepted.contains(level), seen.insert(level).inserted else { return nil }
            return level
        }
    }
}

class ChatAgentConfigViewModel: ObservableObject {
    @Published var card: ChatListRow.AgentCard
    @Published var modelRegistry: ChatAgentModelRegistry = .fallback

    var onRename: ((String, @escaping (Bool) -> Void) -> Void)?
    var onSavePrompt: ((String, @escaping (Bool) -> Void) -> Void)?
    var onSetStatus: ((Bool) -> Void)?
    var onUpdateEventInboxMode: ((String, String, Int, [String], @escaping (Bool) -> Void) -> Void)?
    var onCopy: ((String) -> Void)?
    var onToast: ((String) -> Void)?

    /// Present the native photo picker / camera flow to set the agent avatar.
    var onPickAvatar: (() -> Void)?
    /// Live handle availability check. Returns (available, reason?) where reason
    /// is a short server code such as "username_taken" when unavailable.
    var onCheckUsername: ((String, @escaping (Bool, String?) -> Void) -> Void)?
    /// Persist a new handle. Returns (success, errorMessage?).
    var onSaveUsername: ((String, @escaping (Bool, String?) -> Void) -> Void)?
    /// Load the tool catalog the agent can be granted.
    var onLoadToolRegistry: ((@escaping ([ChatAgentToolInfo]) -> Void) -> Void)?
    /// Persist the agent's enabled tool ids.
    var onSaveTools: (([String], @escaping (Bool) -> Void) -> Void)?
    /// Load the agent's configured prompt variables (name/value/locked).
    var onLoadPromptVariables: ((@escaping ([ChatAgentPromptVariable]) -> Void) -> Void)?
    /// Persist updated prompt variable values. Returns success.
    var onSavePromptVariables: (([ChatAgentPromptVariable], @escaping (Bool) -> Void) -> Void)?
    /// Load the server-authoritative provider/model catalog.
    var onLoadModelRegistry: ((@escaping (ChatAgentModelRegistry) -> Void) -> Void)?
    /// Persist one exact provider/model pair.
    var onSaveModelSelection: ((String, String, @escaping (Bool) -> Void) -> Void)?
    /// Persist the agent's voice provider ("google" or "openai_realtime").
    var onSaveVoiceProvider: ((String, @escaping (Bool) -> Void) -> Void)?

    /// Whether the current session's `card.latestSecret` (a just-minted invoke secret) is
    /// shown in the clear right now. Resets to false whenever the view is torn down —
    /// there is no way to re-reveal it after that, by design (hashed at rest server-side).
    @Published var isInvokeSecretRevealed = false
    @Published var isRotatingInvokeSecret = false
    /// Mints a new invoke secret (`POST /agents/:id/rotate_secret`). Completion carries
    /// (success, freshSecret, freshSecretHint).
    var onRotateInvokeSecret: ((@escaping (Bool, String?, String?) -> Void) -> Void)?

    /// Webhook signing secret state — a DIFFERENT, reversibly-stored secret (verifies
    /// inbound webhook signatures) that can be fetched again anytime, unlike the
    /// hashed-at-rest invoke secret above.
    @Published var webhookSecret: String?
    @Published var webhookSecretHint: String?
    @Published var isWebhookSecretRevealed = false
    @Published var isLoadingWebhookSecret = false
    /// Fetches the webhook signing secret (`GET /agents/:id/secret`).
    var onLoadWebhookSecret: ((@escaping (String?, String?) -> Void) -> Void)?

    init(card: ChatListRow.AgentCard) {
        self.card = card
    }
}

/// A Settings-app-style row label: a colored icon tile followed by a title. Gives the
/// Configuration list instant visual scannability instead of a column of plain text rows.
private struct ChatAgentSettingsRowLabel: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
            Text(title)
        }
    }
}

private struct ChatAgentSecretMetalCover: UIViewRepresentable {
    let isDark: Bool
    let isConcealed: Bool

    final class Coordinator {
        let renderer = MetalKeyMaskView.Coordinator(appearance: .softSpoiler)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SecureParticleMaskView {
        let view = SecureParticleMaskView(frame: .zero, device: context.coordinator.renderer.device)
        view.delegate = context.coordinator.renderer
        view.layer.cornerRadius = 10
        view.layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.05 : 0.12).cgColor
        applySurface(to: view)
        context.coordinator.renderer.setConcealed(isConcealed, animated: false)
        return view
    }

    func updateUIView(_ uiView: SecureParticleMaskView, context: Context) {
        applySurface(to: uiView)
        context.coordinator.renderer.setConcealed(isConcealed, animated: true)
    }

    private func applySurface(to view: SecureParticleMaskView) {
        view.setSurfaceColor(
            isDark
                ? UIColor(red: 0.22, green: 0.23, blue: 0.25, alpha: 1)
                : UIColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1)
        )
    }
}

private struct ChatAgentInvokeSecretCard: View {
    let secret: String?
    let hint: String?
    let isLoading: Bool
    let isRevealed: Bool
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onRotate: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("INVOKE SECRET", systemImage: "key.horizontal.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            ZStack {
                if let secret, !secret.isEmpty {
                    // The returned key is committed underneath first. The still-mounted
                    // shader exits only in the next animation phase.
                    Text(secret)
                        .font(.system(size: 13.5, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                        .padding(.trailing, 48)
                }

                ChatAgentSecretMetalCover(
                    isDark: colorScheme == .dark,
                    isConcealed: !isRevealed || secret == nil || isLoading
                )

                if secret != nil && !isLoading {
                    HStack {
                        Spacer()
                        Button(action: onReveal) {
                            Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityLabel(isLoading ? "Issuing new secret" : "Invoke secret")

            HStack(spacing: 10) {
                Button(action: onCopy) {
                    Text("Copy").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(secret == nil || isLoading)
                    .frame(maxWidth: .infinity)

                Button(action: onRotate) {
                    Text("Rotate").frame(maxWidth: .infinity)
                }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Text("Anyone with this secret can invoke your agent. Keep it private and rotate it if it leaks.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ChatAgentSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftName: String = ""
    @State private var isSavingName = false
    @State private var didLoadModelRegistry = false
    @State private var showRotateInvokeSecretConfirm = false

    private var promptSummary: String {
        let prompt = (viewModel.card.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? "Not set" : prompt
    }

    private var toolsSummary: String {
        let count = viewModel.card.enabledTools.count
        switch count {
        case 0: return "None"
        case 1: return "1 tool"
        default: return "\(count) tools"
        }
    }

    private var modelSummary: String {
        // A cached card without the new fields represents an existing agent,
        // whose previous effective runtime was Anthropic Haiku 4.5.
        let providerId = viewModel.card.modelProvider ?? "anthropic"
        let modelId = viewModel.card.modelId ?? "claude-haiku-4-5-20251001"
        let provider =
            viewModel.modelRegistry.provider(id: providerId)
            ?? ChatAgentModelRegistry.fallback.provider(id: providerId)
        let model =
            viewModel.modelRegistry.model(providerId: providerId, modelId: modelId)
            ?? ChatAgentModelRegistry.fallback.model(providerId: providerId, modelId: modelId)
        return "\(provider?.name ?? providerId) · \(model?.name ?? modelId)"
    }

    var body: some View {
        Form {
            // Profile / avatar — a single tappable affordance (the camera badge) instead
            // of a duplicate "Change Photo" button doing the same thing underneath it.
            Section {
                HStack {
                    Spacer()
                    Button(action: { viewModel.onPickAvatar?() }) {
                        ChatAgentGlobalAvatarView(
                            avatarUrl: viewModel.card.avatarUrl,
                            displayName: viewModel.card.displayName,
                            peerUserId: viewModel.card.agentUserId,
                            size: 88
                        )
                        .frame(width: 88, height: 88)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            } header: {
                Text("Profile")
            }

            Section {
                HStack {
                    TextField("Agent Name", text: $draftName)
                        .onSubmit { saveName() }

                    if isSavingName {
                        ProgressView().controlSize(.small)
                    } else if draftName != viewModel.card.displayName {
                        Button("Save") { saveName() }
                    }
                }

                NavigationLink(destination: ChatAgentUsernameView(viewModel: viewModel)) {
                    HStack {
                        Text("Handle")
                        Spacer()
                        Text(viewModel.card.username.map { "@\($0)" } ?? "Not set")
                            .foregroundColor(.secondary)
                    }
                }

                Toggle("Active (Published)", isOn: Binding(
                    get: { viewModel.card.status.lowercased() == "published" },
                    set: { newValue in viewModel.onSetStatus?(newValue) }
                ))
            } header: {
                Text("Agent Identity")
            } footer: {
                if viewModel.card.status.lowercased() == "published" {
                    Text("The handle is locked while the agent is published. Revert to draft to change it.")
                }
            }

            Section {
                ChatAgentInvokeSecretCard(
                    secret: viewModel.card.latestSecret,
                    hint: viewModel.card.secretHint,
                    isLoading: viewModel.isRotatingInvokeSecret,
                    isRevealed: viewModel.isInvokeSecretRevealed,
                    onReveal: { viewModel.isInvokeSecretRevealed.toggle() },
                    onCopy: {
                        guard let secret = viewModel.card.latestSecret else { return }
                        viewModel.onCopy?(secret)
                    },
                    onRotate: { showRotateInvokeSecretConfirm = true }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Invoke Secret")
            } footer: {
                Text(
                    viewModel.card.latestSecret != nil
                        ? "Shown once — copy it now. It cannot be viewed again after you leave this screen."
                        : "For security this can only be viewed right after it's created or rotated. Rotate to generate a new one."
                )
            }

            Section {
                NavigationLink(destination: ChatAgentModelPickerView(viewModel: viewModel)) {
                    HStack {
                        ChatAgentSettingsRowLabel(icon: "cpu", tint: .purple, title: "Model")
                        Spacer()
                        Text(modelSummary)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                NavigationLink(destination: ChatAgentPromptView(viewModel: viewModel)) {
                    HStack {
                        ChatAgentSettingsRowLabel(icon: "text.alignleft", tint: .blue, title: "System Prompt")
                        Spacer()
                        Text(promptSummary)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                NavigationLink(destination: ChatAgentToolsView(viewModel: viewModel)) {
                    HStack {
                        ChatAgentSettingsRowLabel(icon: "wrench.and.screwdriver.fill", tint: .orange, title: "Tools")
                        Spacer()
                        Text(toolsSummary)
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink(destination: ChatAgentPromptVariablesView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "curlybraces", tint: .teal, title: "Prompt Variables")
                }

                NavigationLink(destination: ChatAgentIntegrationView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "bolt.horizontal.circle.fill", tint: .indigo, title: "Integration & Delivery")
                }
                NavigationLink(destination: ChatAgentEnvironmentView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "terminal.fill", tint: .mint, title: "Environment & IDs")
                }
                NavigationLink(destination: ChatAgentAPIDocumentationView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "book.closed.fill", tint: .cyan, title: "API Documentation")
                }
                NavigationLink(destination: ChatAgentOutputSettingsView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "slider.horizontal.3", tint: .pink, title: "Output Controls")
                }
                NavigationLink(destination: ChatAgentVoiceSettingsView(viewModel: viewModel)) {
                    ChatAgentSettingsRowLabel(icon: "waveform", tint: .green, title: "Voice Settings")
                }
            } header: {
                Text("Configuration")
            }
        }
        .onAppear {
            draftName = viewModel.card.displayName
            guard !didLoadModelRegistry else { return }
            didLoadModelRegistry = true
            viewModel.onLoadModelRegistry? { registry in
                viewModel.modelRegistry = registry
            }
        }
        .onChange(of: viewModel.card) { newCard in
            if !isSavingName {
                draftName = newCard.displayName
            }
        }
        .alert("Rotate invoke secret?", isPresented: $showRotateInvokeSecretConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) {
                // Keep the one persistent row covered for the entire request. Once
                // the new key is in the model, reveal it on a later animation phase.
                viewModel.isInvokeSecretRevealed = false
                viewModel.isRotatingInvokeSecret = true
                viewModel.onRotateInvokeSecret? { success, _, _ in
                    viewModel.isRotatingInvokeSecret = false
                    if success {
                        // updateCard has already installed the returned key. One main-
                        // queue turn is enough to paint it underneath before UIKit flies
                        // the still-mounted Metal cover out.
                        DispatchQueue.main.async {
                            viewModel.isInvokeSecretRevealed = true
                        }
                    }
                }
            }
        } message: {
            Text("The current secret stops working immediately. Anything invoking this agent with it will need the new one.")
        }
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != viewModel.card.displayName else { return }
        isSavingName = true
        viewModel.onRename?(trimmed) { success in
            isSavingName = false
            if !success {
                draftName = viewModel.card.displayName
            }
        }
    }
}

private struct ChatAgentDeveloperValueRow: View {
    let title: String
    let value: String
    let onCopy: (String) -> Void

    var body: some View {
        Button {
            onCopy(value)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies \(title)")
    }
}

struct ChatAgentEnvironmentView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel

    private var destinationChatId: String? {
        viewModel.card.defaultDestinationChat?.chatId
            ?? viewModel.card.attachedChats.first(where: {
                ($0.type ?? "dm").lowercased() == "dm"
            })?.chatId
            ?? viewModel.card.attachedChats.first?.chatId
    }

    var body: some View {
        Form {
            Section {
                valueRow("VIBE_API_BASE_URL", viewModel.card.apiBaseURL)
                valueRow("VIBE_AGENT_IDENTIFIER", viewModel.card.agentId)
                valueRow("VIBE_DESTINATION_CHAT_ID", destinationChatId)
            } header: {
                Text("Environment")
            } footer: {
                Text("Use these values in your backend environment. The invoke secret is intentionally shown only immediately after creation or rotation.")
            }

            Section {
                valueRow("Agent ID", viewModel.card.agentId)
                valueRow("Agent User ID", viewModel.card.agentUserId)
                if let defaultChat = viewModel.card.defaultDestinationChat {
                    valueRow("Default Chat ID", defaultChat.chatId)
                }
                ForEach(Array(viewModel.card.attachedChats.enumerated()), id: \.element.chatId) {
                    index, chat in
                    valueRow(
                        viewModel.card.attachedChats.count == 1
                            ? "Attached Chat ID"
                            : "Attached Chat ID \(index + 1)",
                        chat.chatId
                    )
                }
            } header: {
                Text("Identifiers")
            } footer: {
                Text("Agent ID addresses the agent API. Chat ID identifies the conversation or delivery destination attached to this agent.")
            }
        }
        .navigationTitle("Environment & IDs")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func valueRow(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            ChatAgentDeveloperValueRow(title: title, value: value) {
                viewModel.onCopy?($0)
            }
        }
    }
}

struct ChatAgentAPIDocumentationView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel

    private let docsBase = URL(string: "https://vibegram.io/docs/agents")!

    private var destinationChatId: String? {
        viewModel.card.defaultDestinationChat?.chatId
            ?? viewModel.card.attachedChats.first(where: {
                ($0.type ?? "dm").lowercased() == "dm"
            })?.chatId
            ?? viewModel.card.attachedChats.first?.chatId
    }

    var body: some View {
        Form {
            Section {
                developerValueRow(
                    title: "Agent ID",
                    value: viewModel.card.agentId
                )
                developerValueRow(
                    title: "Destination Chat ID",
                    value: destinationChatId
                )
            } header: {
                Text("Integration")
            } footer: {
                Text("Use the Agent ID in the endpoint path. Send Destination Chat ID as destinationChatId for event delivery when the agent has no default destination.")
            }

            Section {
                developerValueRow(
                    title: "Invoke URL",
                    value: viewModel.card.invokeURL
                )
                developerValueRow(
                    title: "Events URL",
                    value: viewModel.card.eventsURL
                )
            } header: {
                Text("Endpoints")
            }

            Section {
                documentationLink(
                    icon: "bolt.fill",
                    tint: .blue,
                    title: "API Quickstart",
                    subtitle: "Authentication, invoke requests, and first response",
                    path: ""
                )
                documentationLink(
                    icon: "terminal.fill",
                    tint: .mint,
                    title: "Environment Variables",
                    subtitle: "Production .env setup and destination chat IDs",
                    path: "/env"
                )
                documentationLink(
                    icon: "chevron.left.forwardslash.chevron.right",
                    tint: .orange,
                    title: "Request Examples",
                    subtitle: "Node, Python, curl, events, and callbacks",
                    path: "/examples"
                )
                documentationLink(
                    icon: "slider.horizontal.3",
                    tint: .purple,
                    title: "Configuration Reference",
                    subtitle: "Agent fields, attached chats, delivery, and security",
                    path: "/config"
                )
            } header: {
                Text("Guides")
            }
        }
        .navigationTitle("API Documentation")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func developerValueRow(title: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            ChatAgentDeveloperValueRow(title: title, value: value) {
                viewModel.onCopy?($0)
            }
        } else {
            HStack {
                Text(title)
                Spacer()
                Text("Not configured")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func documentationLink(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        path: String
    ) -> some View {
        Link(destination: path.isEmpty ? docsBase : docsBase.appendingPathComponent(String(path.dropFirst()))) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }
}

struct ChatAgentModelPickerView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel

    var body: some View {
        ChatProviderModelPickerView(
            registry: viewModel.modelRegistry,
            currentProviderId: viewModel.card.modelProvider ?? "anthropic",
            currentModelId: viewModel.card.modelId ?? "claude-haiku-4-5-20251001",
            currentThinkingLevel: nil
        ) { providerId, modelId, _, completion in
            // Standalone-agent persistence currently stores the provider/model pair.
            // The reusable picker still resolves thinking locally without inventing
            // a separate backend update contract here.
            viewModel.onSaveModelSelection?(providerId, modelId, completion)
        }
    }
}

/// Reusable server-registry-backed model/thinking picker. Provider is inferred
/// from the selected model and returned only as persistence/runtime metadata.
struct ChatProviderModelPickerView: View {
    let registry: ChatAgentModelRegistry
    let currentProviderId: String
    let currentModelId: String
    let currentThinkingLevel: String?
    let onSave: (String, String, String, @escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderId = ""
    @State private var selectedModelId = ""
    @State private var selectedThinkingLevel = ""
    @State private var isSaving = false

    private var selectedProvider: ChatAgentModelProviderInfo? {
        registry.provider(id: selectedProviderId)
    }

    private var selectedModel: ChatAgentModelInfo? {
        registry.model(providerId: selectedProviderId, modelId: selectedModelId)
    }

    private var selectedCombinationIsValid: Bool {
        guard
            let provider = selectedProvider,
            provider.available,
            let model = selectedModel
        else {
            return false
        }
        return model.thinkingLevels.contains(selectedThinkingLevel)
    }

    private var isDirty: Bool {
        selectedProviderId.caseInsensitiveCompare(currentProviderId) != .orderedSame
            || selectedModelId.caseInsensitiveCompare(currentModelId) != .orderedSame
            || selectedThinkingLevel.caseInsensitiveCompare(resolvedCurrentThinkingLevel)
                != .orderedSame
    }

    private var resolvedCurrentThinkingLevel: String {
        let model =
            registry.model(providerId: currentProviderId, modelId: currentModelId)
            ?? ChatAgentModelRegistry.fallback.model(
                providerId: currentProviderId,
                modelId: currentModelId)
        guard let model else { return currentThinkingLevel ?? "medium" }
        if let currentThinkingLevel,
            let supported = model.thinkingLevels.first(where: {
                $0.caseInsensitiveCompare(currentThinkingLevel) == .orderedSame
            })
        {
            return supported
        }
        return model.defaultThinkingLevel
    }

    var body: some View {
        Form {
            Section {
                ForEach(registry.providers) { provider in
                    ForEach(provider.models) { model in
                        Button {
                            selectModel(model, from: provider)
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(model.name)
                                            .foregroundColor(provider.available ? .primary : .secondary)
                                        if model.recommended {
                                            Text("Recommended")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    Text(
                                        provider.available
                                            ? model.description
                                            : "Unavailable")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                if selectedProviderId == provider.id
                                    && selectedModelId == model.id
                                {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                        .disabled(!provider.available)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                if registry.isFallback {
                    Text("Showing the built-in catalog while the live registry is unavailable. The server validates every selection.")
                }
            }

            Section {
                if let model = selectedModel {
                    ForEach(model.thinkingLevels, id: \.self) { level in
                        Button {
                            selectedThinkingLevel = level
                        } label: {
                            HStack {
                                Text(thinkingLevelTitle(level))
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedThinkingLevel == level {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                    }
                } else {
                    Text("Select an available model first.")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Thinking")
            } footer: {
                Text("Higher levels spend more time reasoning before answering.")
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .presentationBackground(.ultraThinMaterial)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { saveSelection() }
                        .disabled(!isDirty || !selectedCombinationIsValid)
                }
            }
        }
        .onAppear {
            resolveSelection()
        }
        .onChange(of: registry) { _ in
            resolveSelection()
        }
    }

    private func resolveSelection() {
        if let currentProvider = registry.provider(id: currentProviderId),
            let currentModel = registry.model(
                providerId: currentProvider.id,
                modelId: currentModelId)
        {
            selectedProviderId = currentProvider.id
            selectedModelId = currentModel.id
            selectedThinkingLevel =
                currentModel.thinkingLevels.first(where: {
                    guard let currentThinkingLevel else { return false }
                    return $0.caseInsensitiveCompare(currentThinkingLevel) == .orderedSame
                })
                ?? currentModel.defaultThinkingLevel
            return
        }

        guard
            let fallbackProvider =
                registry.provider(id: registry.defaultProvider)
                ?? registry.providers.first(where: \.available)
                ?? registry.providers.first
        else {
            selectedProviderId = ""
            selectedModelId = ""
            selectedThinkingLevel = ""
            return
        }
        guard
            let fallbackModel =
                registry.model(
                    providerId: fallbackProvider.id,
                    modelId: registry.defaultModelId)
                ?? fallbackProvider.models.first(where: \.recommended)
                ?? fallbackProvider.models.first
        else {
            selectedProviderId = fallbackProvider.id
            selectedModelId = ""
            selectedThinkingLevel = ""
            return
        }
        selectModel(fallbackModel, from: fallbackProvider)
    }

    private func selectModel(
        _ model: ChatAgentModelInfo,
        from provider: ChatAgentModelProviderInfo
    ) {
        guard provider.available else { return }
        let previousThinkingLevel = selectedThinkingLevel
        selectedProviderId = provider.id
        selectedModelId = model.id
        selectedThinkingLevel =
            model.thinkingLevels.first(where: {
                $0.caseInsensitiveCompare(previousThinkingLevel) == .orderedSame
            })
            ?? model.defaultThinkingLevel
    }

    private func saveSelection() {
        guard selectedCombinationIsValid, !isSaving else { return }
        isSaving = true
        onSave(selectedProviderId, selectedModelId, selectedThinkingLevel) { success in
            isSaving = false
            if success {
                dismiss()
            }
        }
    }

    private func thinkingLevelTitle(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Circular agent avatar: remote image when available, gradient initial otherwise.
/// Bridges the SAME global avatar component the Chats home list and the Agents list use
/// (`ChatAvatarNodeView` — real photo, real per-identity gradient fallback, real image
/// cache) into SwiftUI, so an agent's avatar looks identical everywhere it appears instead
/// of this screen inventing its own one-off placeholder style.
struct ChatAgentGlobalAvatarView: UIViewRepresentable {
    let avatarUrl: String?
    let displayName: String
    let peerUserId: String?
    var size: CGFloat = 44
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> ChatAvatarNodeView {
        ChatAvatarNodeView()
    }

    func updateUIView(_ uiView: ChatAvatarNodeView, context: Context) {
        uiView.configure(
            with: ChatAvatarDescriptor(
                title: displayName,
                rawAvatarURI: avatarUrl,
                peerUserId: peerUserId,
                chatId: nil,
                kind: .standard,
                isGroup: false,
                members: [],
                preferPushAvatar: false,
                gradientColors: nil
            ),
            isDark: colorScheme == .dark,
            renderingSide: size
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatAvatarNodeView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

/// Inner page for editing the agent's system prompt.
struct ChatAgentPromptView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftPrompt: String = ""
    @State private var isSaving = false

    private var isDirty: Bool {
        draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            != (viewModel.card.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draftPrompt)
                    .frame(minHeight: 240)
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Defines how the agent behaves and responds.")
            }
        }
        .navigationTitle("System Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { savePrompt() }
                        .disabled(!isDirty)
                }
            }
        }
        .onAppear { draftPrompt = viewModel.card.systemPrompt ?? "" }
    }

    private func savePrompt() {
        let trimmed = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        viewModel.onSavePrompt?(trimmed) { success in
            isSaving = false
            if success {
                dismiss()
            } else {
                draftPrompt = viewModel.card.systemPrompt ?? ""
            }
        }
    }
}

/// Inner page to change the agent handle with live availability checking.
struct ChatAgentUsernameView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var isChecking = false
    @State private var isSaving = false
    @State private var availability: Availability = .unknown
    @State private var debounceWork: DispatchWorkItem?

    private enum Availability: Equatable {
        case unknown
        case available
        case unavailable(String)
    }

    private var normalized: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    private var isUnchanged: Bool {
        normalized == (viewModel.card.username ?? "").lowercased()
    }

    private var published: Bool {
        viewModel.card.status.lowercased() == "published"
    }

    private var canSave: Bool {
        if published || isSaving || normalized.isEmpty || isUnchanged { return false }
        if case .available = availability { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("@")
                        .foregroundColor(.secondary)
                    TextField("handle", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .disabled(published)
                        .onChange(of: draft) { _ in scheduleCheck() }
                    statusIcon
                }
            } header: {
                Text("Handle")
            } footer: {
                footerText
            }
        }
        .navigationTitle("Handle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
        .onAppear { draft = viewModel.card.username ?? "" }
    }

    @ViewBuilder private var statusIcon: some View {
        if isChecking {
            ProgressView().controlSize(.small)
        } else if isUnchanged || normalized.isEmpty {
            EmptyView()
        } else {
            switch availability {
            case .available:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .unavailable:
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            case .unknown:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var footerText: some View {
        if published {
            Text("The handle is locked while the agent is published. Revert to draft to change it.")
        } else if isUnchanged || normalized.isEmpty {
            Text("3–30 characters: lowercase letters, numbers, and underscores.")
        } else {
            switch availability {
            case .available:
                Text("@\(normalized) is available.").foregroundColor(.green)
            case .unavailable(let reason):
                Text(Self.message(for: reason)).foregroundColor(.red)
            case .unknown:
                Text("3–30 characters: lowercase letters, numbers, and underscores.")
            }
        }
    }

    private func scheduleCheck() {
        debounceWork?.cancel()
        availability = .unknown
        guard !normalized.isEmpty, !isUnchanged, !published else {
            isChecking = false
            return
        }
        let work = DispatchWorkItem { runCheck() }
        debounceWork = work
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func runCheck() {
        let candidate = normalized
        viewModel.onCheckUsername?(candidate) { available, reason in
            guard candidate == normalized else { return }
            isChecking = false
            availability = available ? .available : .unavailable(reason ?? "unavailable")
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSaveUsername?(normalized) { success, errorMessage in
            isSaving = false
            if success {
                dismiss()
            } else if let errorMessage {
                availability = .unavailable(errorMessage)
            }
        }
    }

    static func message(for reason: String) -> String {
        switch reason {
        case "username_taken": return "That handle is already taken."
        case "reserved_username": return "That handle is reserved."
        case "invalid_username": return "Use 3–30 lowercase letters, numbers, or underscores."
        case "username_locked_after_publish": return "Handle is locked while published."
        default: return reason
        }
    }
}

/// Inner page to grant/revoke the agent's tools.
struct ChatAgentToolsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tools: [ChatAgentToolInfo] = []
    @State private var enabled: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false

    private var isDirty: Bool {
        enabled != Set(viewModel.card.enabledTools)
    }

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(tools) { tool in
                        Toggle(isOn: Binding(
                            get: { enabled.contains(tool.id) },
                            set: { on in
                                if on { enabled.insert(tool.id) } else { enabled.remove(tool.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                Text(tool.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Choose which capabilities this agent can use.")
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!isDirty)
                }
            }
        }
        .onAppear {
            enabled = Set(viewModel.card.enabledTools)
            loadTools()
        }
    }

    private func loadTools() {
        guard let loader = viewModel.onLoadToolRegistry else {
            isLoading = false
            return
        }
        loader { loaded in
            tools = loaded
            isLoading = false
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSaveTools?(Array(enabled)) { success in
            isSaving = false
            if success { dismiss() }
        }
    }
}

struct ChatAgentPromptVariablesView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var variables: [ChatAgentPromptVariable] = []
    @State private var original: [ChatAgentPromptVariable] = []
    @State private var isLoading = true
    @State private var isSaving = false

    private var isDirty: Bool { variables != original }

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if variables.isEmpty {
                Section {
                    Text("No prompt variables yet. Add {{variable}} placeholders in your system prompt, then define their values here so you can change wording without rewriting the prompt.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach($variables) { $variable in
                    Section {
                        if variable.locked {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("{{\(variable.name)}}").font(.subheadline.monospaced())
                                    Text(variable.value.isEmpty ? "—" : variable.value)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "lock.fill").foregroundColor(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("{{\(variable.name)}}").font(.subheadline.monospaced())
                                TextField("Value", text: $variable.value)
                            }
                        }
                    } footer: {
                        if !variable.description.isEmpty {
                            Text(variable.locked ? "\(variable.description) · pinned in code" : variable.description)
                        } else if variable.locked {
                            Text("Pinned in code")
                        }
                    }
                }
            }
        }
        .navigationTitle("Prompt Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!isDirty)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let loader = viewModel.onLoadPromptVariables else {
            isLoading = false
            return
        }
        loader { loaded in
            variables = loaded
            original = loaded
            isLoading = false
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSavePromptVariables?(variables) { success in
            isSaving = false
            if success { dismiss() }
        }
    }
}

struct ChatAgentIntegrationView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var inboxMode: String = "per_event"
    @State private var incomingChatEnabled: Bool = true
    
    var body: some View {
        Form {
            Section {
                copyableRow(title: "API Base", value: viewModel.card.apiBaseURL)
                copyableRow(title: "Events URL", value: viewModel.card.eventsURL)
                copyableRow(title: "Invoke URL", value: viewModel.card.invokeURL)
                copyableRow(title: "Callback URL", value: viewModel.card.callbackURL)
            } header: {
                Text("Endpoints")
            }
            
            Section {
                copyableRow(title: "Default Chat", value: viewModel.card.defaultDestinationChat?.chatId)
                ForEach(viewModel.card.attachedChats, id: \.chatId) { chat in
                    copyableRow(title: "Attached Chat", value: chat.chatId)
                }
            } header: {
                Text("Delivery Channels")
            }
            
            Section {
                Picker("Inbox Mode", selection: $inboxMode) {
                    Text("Per Event").tag("per_event")
                    Text("Batched Summary").tag("batched_summary")
                }
                .onChange(of: inboxMode) { newValue in
                    // Call backend later
                    viewModel.onToast?("Inbox mode set to \(newValue == "batched_summary" ? "Batched" : "Per Event")")
                }

                Toggle("Accept Incoming Chat", isOn: $incomingChatEnabled)
            } header: {
                Text("Settings")
            }

            Section {
                HStack {
                    Text("Webhook Signing Secret")
                    Spacer()
                    if viewModel.isLoadingWebhookSecret {
                        ProgressView().controlSize(.small)
                    } else if viewModel.isWebhookSecretRevealed, let secret = viewModel.webhookSecret {
                        Text(secret)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(maskedWebhookSecret)
                            .foregroundColor(.secondary)
                    }

                    Button(action: toggleWebhookSecretRevealed) {
                        Image(systemName: viewModel.isWebhookSecretRevealed ? "eye.slash.fill" : "eye.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoadingWebhookSecret)

                    if viewModel.isWebhookSecretRevealed, let secret = viewModel.webhookSecret {
                        Button(action: {
                            viewModel.onCopy?(secret)
                            viewModel.onToast?("Copied webhook signing secret")
                        }) {
                            Image(systemName: "square.on.square")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Webhook Signing Secret")
            } footer: {
                Text("Verifies inbound webhook signatures. This is separate from the invoke secret used to call your agent, and can be viewed anytime.")
            }
        }
        .navigationTitle("Integration & Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            inboxMode = viewModel.card.eventInboxMode
            incomingChatEnabled = viewModel.card.incomingChatEnabled
        }
    }

    private var maskedWebhookSecret: String {
        let hint = viewModel.webhookSecretHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (hint?.isEmpty == false) ? "•••• \(hint!)" : "Tap to reveal"
    }

    private func toggleWebhookSecretRevealed() {
        if viewModel.isWebhookSecretRevealed {
            viewModel.isWebhookSecretRevealed = false
            return
        }
        if viewModel.webhookSecret != nil {
            viewModel.isWebhookSecretRevealed = true
            return
        }
        viewModel.isLoadingWebhookSecret = true
        viewModel.onLoadWebhookSecret? { secret, hint in
            viewModel.isLoadingWebhookSecret = false
            viewModel.webhookSecret = secret
            if let hint {
                viewModel.webhookSecretHint = hint
            }
            viewModel.isWebhookSecretRevealed = secret != nil
            if secret == nil {
                viewModel.onToast?("Could not load webhook secret")
            }
        }
    }

    private func copyableRow(title: String, value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? "Not set")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let value = value, !value.isEmpty {
                Button(action: {
                    viewModel.onCopy?(value)
                    viewModel.onToast?("Copied \(title)")
                }) {
                    Image(systemName: "square.on.square")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChatAgentOutputSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var enableText = true
    @State private var enableMessages = true
    @State private var enableMedia = false
    @State private var enableVoice = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Text Output", isOn: $enableText)
                Toggle("Messages", isOn: $enableMessages)
                Toggle("Media Generation", isOn: $enableMedia)
                Toggle("Voice Output", isOn: $enableVoice)
            } header: {
                Text("Allowed Modalities")
            } footer: {
                Text("Control what modalities the agent is permitted to return. Backend sync to be added.")
            }
        }
        .navigationTitle("Output Controls")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let modes = viewModel.card.outputModes
            enableText = modes.contains("text") || modes.isEmpty // default
            enableMessages = modes.contains("messages") || modes.isEmpty
            enableMedia = modes.contains("media")
            enableVoice = modes.contains("voice")
        }
    }
}

private struct ChatAgentVoiceProviderOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
}

private let chatAgentVoiceProviderOptions: [ChatAgentVoiceProviderOption] = [
    ChatAgentVoiceProviderOption(
        id: "google",
        title: "Google",
        subtitle: "Gemini TTS — natural, steerable voices in 70+ languages.",
        icon: "waveform",
        tint: .blue
    ),
    ChatAgentVoiceProviderOption(
        id: "openai_realtime",
        title: "OpenAI Realtime",
        subtitle: "Low-latency, live spoken conversation — not the older OpenAI TTS API.",
        icon: "waveform.badge.mic",
        tint: .green
    ),
]

struct ChatAgentVoiceSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                ForEach(chatAgentVoiceProviderOptions) { option in
                    Button {
                        select(option)
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(option.tint.gradient)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: option.icon)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .foregroundColor(.primary)
                                Text(option.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if viewModel.card.voiceProvider == option.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .disabled(isSaving)
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("Which speech engine this agent uses when it talks back with voice.")
            }
        }
        .navigationTitle("Voice Settings")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isSaving {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func select(_ option: ChatAgentVoiceProviderOption) {
        guard viewModel.card.voiceProvider != option.id else { return }
        isSaving = true
        viewModel.onSaveVoiceProvider?(option.id) { _ in
            isSaving = false
        }
    }
}

// MARK: - Group VoIP / AI agent configuration sheet
// Presented as a pageSheet (same API as AgentBridgeHistorySheet / connect sheets):
// summary root + inner NavigationLink pushes — not one long full-screen form.

final class GroupAgentConfigModel: ObservableObject {
  let chatId: String
  let existingId: Any?
  let documents: [(id: String, name: String, url: String)]

  @Published var name: String
  @Published var systemPrompt: String
  @Published var enabled: Bool
  @Published var enabledTools: Set<String>
  @Published var generateInput: String = ""
  @Published var isGenerating = false
  @Published var errorMessage: String?

  var onSave: (([String: Any]) -> Void)?
  var onDelete: (() -> Void)?

  static let toolOptions: [(id: String, title: String, subtitle: String)] = [
    ("search_google", "Web Search", "Search Google for up-to-date results"),
    ("analyze_image", "Image Analysis", "Understand images and OCR text"),
    ("analyze_document", "Document Analysis", "Read and summarize document files"),
    ("create_document", "Create Document", "Generate formatted document drafts"),
  ]

  init(
    chatId: String,
    config: [String: Any]?,
    documents: [(id: String, name: String, url: String)] = []
  ) {
    self.chatId = chatId
    self.existingId = config?["id"]
    self.documents = documents
    self.name = (config?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let snake = (config?["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let camel = (config?["systemPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.systemPrompt = snake.isEmpty ? camel : snake
    if let raw = config?["enabled"] as? Bool {
      self.enabled = raw
    } else if let n = config?["enabled"] as? NSNumber {
      self.enabled = n.boolValue
    } else {
      self.enabled = true
    }
    let tools =
      Self.parseTools(config?["enabled_tools"])
      ?? Self.parseTools(config?["enabledTools"])
      ?? ["search_google", "analyze_image", "analyze_document", "create_document"]
    self.enabledTools = Set(tools)
  }

  var isExisting: Bool { existingId != nil }

  var promptSummary: String {
    let p = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return p.isEmpty ? "Not set" : p
  }

  var toolsSummary: String {
    switch enabledTools.count {
    case 0: return "None"
    case 1: return "1 tool"
    default: return "\(enabledTools.count) tools"
    }
  }

  func buildConfig() -> [String: Any]? {
    let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      errorMessage = "System prompt is required."
      return nil
    }
    guard !enabledTools.isEmpty else {
      errorMessage = "Enable at least one tool."
      return nil
    }
    errorMessage = nil
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var config: [String: Any] = [
      "chat_id": chatId,
      "name": trimmedName.isEmpty ? "Vibe AI" : trimmedName,
      "system_prompt": prompt,
      "enabled": enabled,
      "enabled_tools": Array(enabledTools).sorted(),
    ]
    if let existingId {
      config["id"] = existingId
    }
    return config
  }

  func generatePrompt(completion: @escaping (Bool) -> Void) {
    let input = generateInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else {
      errorMessage = "Describe the agent first."
      completion(false)
      return
    }
    guard !enabledTools.isEmpty else {
      errorMessage = "Enable at least one tool before generating."
      completion(false)
      return
    }
    isGenerating = true
    errorMessage = nil
    ChatEngine.shared.generateAgentPrompt(
      chatId: chatId,
      input: input,
      enabledTools: Array(enabledTools)
    ) { [weak self] payload in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isGenerating = false
        let generated =
          (payload?["systemPrompt"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !generated.isEmpty else {
          self.errorMessage = "Could not generate a prompt. Try adjusting your input."
          completion(false)
          return
        }
        self.systemPrompt = generated
        completion(true)
      }
    }
  }

  private static func parseTools(_ raw: Any?) -> [String]? {
    guard let list = raw as? [Any] else { return nil }
    let out = list.compactMap { item -> String? in
      if let s = item as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
      }
      if let n = item as? NSNumber { return n.stringValue }
      return nil
    }
    return out.isEmpty ? nil : out
  }
}

/// Clean pageSheet for group agent config — summary + inner pushes.
struct GroupAgentConfigSheet: View {
  @StateObject var model: GroupAgentConfigModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var showDeleteConfirm = false

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  /// Soft elevated row over glass — mirrors ask/progress sheet `neutralFill`.
  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }
  private var accentTint: Color { palette.text }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Text("Name")
              .font(.system(size: 16, weight: .regular))
              .foregroundStyle(palette.text)
            Spacer(minLength: 12)
            TextField("Vibe AI", text: $model.name)
              .multilineTextAlignment(.trailing)
              .foregroundStyle(palette.secondaryText)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          Toggle("Agent Enabled", isOn: $model.enabled)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
        } header: {
          Text("Agent")
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(palette.secondaryText)
        } footer: {
          Text("When enabled, the agent can participate in this group chat.")
            .foregroundStyle(palette.secondaryText)
        }

        Section {
          NavigationLink {
            GroupAgentPromptEditor(model: model)
          } label: {
            configRow(title: "System Prompt", value: model.promptSummary)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          NavigationLink {
            GroupAgentToolsEditor(model: model)
          } label: {
            configRow(title: "Tools", value: model.toolsSummary)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          if !model.documents.isEmpty {
            NavigationLink {
              GroupAgentDocumentsView(documents: model.documents)
            } label: {
              configRow(title: "Documents", value: "\(model.documents.count)")
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
          }
        } header: {
          Text("Configuration")
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(palette.secondaryText)
        }

        if model.isExisting {
          Section {
            Button("Remove Agent", role: .destructive) {
              showDeleteConfirm = true
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Text(errorMessage)
              .font(.system(size: 13))
              .foregroundStyle(.red)
              .listRowBackground(rowFill)
          }
        }
      }
      .listStyle(.insetGrouped)
      // Glass sheet body like chat progress/ask sheets — no solid fill.
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .navigationTitle("Vibe AI")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .tint(accentTint)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(model.isExisting ? "Save" : "Create") {
            guard let config = model.buildConfig() else { return }
            model.onSave?(config)
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .confirmationDialog(
        "Remove AI Agent",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) {
          model.onDelete?()
          dismiss()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes the agent and clears its memory. This cannot be undone.")
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    // Let the system pageSheet Liquid Glass show through (same as ask/progress sheets).
    .presentationBackground(.clear)
  }

  @ViewBuilder
  private func configRow(title: String, value: String) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(palette.text)
      Spacer(minLength: 12)
      Text(value)
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
    }
  }
}

private struct GroupAgentPromptEditor: View {
  @ObservedObject var model: GroupAgentConfigModel
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    Form {
      Section {
        TextField("e.g. Helpful PM for sprint planning", text: $model.generateInput)
          .listRowBackground(rowFill)
        Button {
          model.generatePrompt { _ in }
        } label: {
          HStack {
            if model.isGenerating {
              ProgressView().controlSize(.small)
            }
            Text(model.isGenerating ? "Generating…" : "Generate from input")
          }
        }
        .disabled(model.isGenerating)
        .listRowBackground(rowFill)
      } header: {
        Text("Generate")
      } footer: {
        Text("Optional: describe the agent, then generate a system prompt.")
      }

      Section {
        TextEditor(text: $model.systemPrompt)
          .frame(minHeight: 220)
          .listRowBackground(rowFill)
      } header: {
        Text("System Prompt")
      } footer: {
        Text("Describe how this agent should behave in the group.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("System Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}

private struct GroupAgentToolsEditor: View {
  @ObservedObject var model: GroupAgentConfigModel
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    List {
      Section {
        ForEach(GroupAgentConfigModel.toolOptions, id: \.id) { option in
          Toggle(isOn: Binding(
            get: { model.enabledTools.contains(option.id) },
            set: { on in
              if on {
                model.enabledTools.insert(option.id)
              } else {
                model.enabledTools.remove(option.id)
              }
            }
          )) {
            VStack(alignment: .leading, spacing: 2) {
              Text(option.title)
              Text(option.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
          }
          .listRowBackground(rowFill)
        }
      } header: {
        Text("Enabled Tools")
      } footer: {
        Text("At least one tool is required.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Tools")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}

private struct GroupAgentDocumentsView: View {
  let documents: [(id: String, name: String, url: String)]
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    List {
      Section {
        ForEach(documents, id: \.id) { doc in
          Button {
            let cleaned = doc.url.replacingOccurrences(of: "vibe://", with: "https://")
            if let url = URL(string: cleaned) {
              UIApplication.shared.open(url)
            }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "doc.text.fill")
                .foregroundStyle(.tint)
              Text(doc.name)
                .foregroundStyle(.primary)
              Spacer()
              Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
          }
          .listRowBackground(rowFill)
        }
      } header: {
        Text("Agent Documents")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Documents")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}

// MARK: - New standalone agent (Grok-Bot role presets)

/// A ready-made role for a new agent: fills the system prompt (the role) and a
/// sensible control mode. Owner can edit every field before creating.
enum ChatAgentRolePreset: String, CaseIterable, Identifiable {
  case marketing, social, coder, publisher, monitor, sales, manager, boss, custom
  var id: String { rawValue }

  var title: String {
    switch self {
    case .marketing: return "Marketing"
    case .social: return "Social"
    case .coder: return "Coder"
    case .publisher: return "Publisher"
    case .monitor: return "Monitor"
    case .sales: return "Sales"
    case .manager: return "Manager"
    case .boss: return "Boss"
    case .custom: return "Custom"
    }
  }

  var symbol: String {
    switch self {
    case .marketing: return "megaphone.fill"
    case .social: return "bubble.left.and.bubble.right.fill"
    case .coder: return "chevron.left.forwardslash.chevron.right"
    case .publisher: return "arrow.up.circle.fill"
    case .monitor: return "waveform.path.ecg"
    case .sales: return "chart.line.uptrend.xyaxis"
    case .manager: return "checklist"
    case .boss: return "crown.fill"
    case .custom: return "square.and.pencil"
    }
  }

  var defaultName: String {
    switch self {
    case .marketing: return "Marketing Lead"
    case .social: return "Social Manager"
    case .coder: return "Coder"
    case .publisher: return "Publisher"
    case .monitor: return "Monitor"
    case .sales: return "Sales Rep"
    case .manager: return "Team Manager"
    case .boss: return "Boss"
    case .custom: return "New Agent"
    }
  }

  var persona: String? {
    switch self {
    case .marketing: return "Marketing Lead"
    case .social: return "Social Manager"
    case .coder: return "Coder"
    case .publisher: return "Publisher"
    case .monitor: return "Monitor"
    case .sales: return "Sales Rep"
    case .manager: return "Manager"
    case .boss: return "Boss"
    case .custom: return nil
    }
  }

  var systemPrompt: String {
    switch self {
    case .marketing:
      return "You are the Marketing Lead for this team. You own positioning, messaging, campaigns, and copy. Research the market and competitors before you write, keep everything specific and on-brand, and turn briefs into ready-to-ship deliverables. When you have a computer, save your work to files."
    case .social:
      return "You are the Social Manager for this team. You own the accounts on X, Instagram and anywhere else the team posts. Sign in through the browser on your computer, read the timeline, draft and publish posts, reply to mentions, and watch what competitors ship. When you find something the product should copy or beat, hand it to the Coder with the exact link, a screenshot path and one sentence on why it matters. Never post anything that names a customer without approval."
    case .coder:
      return "You are the Coder for this team. You work in a real repository on your own computer. Read before you write: `agix context` and `agix grep` to find the code, `agix body` to read a symbol, then computer_edit_file for a surgical change -- never rewrite a file you have not read. Run the build and the tests yourself and paste the real output. When the change is green, hand it to the Publisher with the branch, the files touched and how to verify it. If a request is vague, ask one sharp question rather than guessing."
    case .publisher:
      return "You are the Publisher for this team. You take finished, tested work and ship it. Check the build and the tests are green before anything leaves your machine, deploy, then verify the live thing actually responds. Deploying and publishing are irreversible: ask for approval before every one, and say exactly what you are about to run. If a deploy fails, roll back first and report second."
    case .monitor:
      return "You are the Monitor for this team. You watch: uptime, errors, logs, usage, cost, and anything the team asked you to keep an eye on. Check on a schedule, keep a running file of what you saw so you can say what CHANGED rather than what is, and stay quiet when nothing did. When something breaks, say what broke, when it started, what you already checked, and hand it to the Coder with the exact error."
    case .sales:
      return "You are a Sales Rep for this team. You qualify leads, write outreach, and handle objections to keep the pipeline moving. Personalize every message, stay concise and human, and never over-promise. Any message that reaches a real customer needs approval first."
    case .manager:
      return "You are a Manager for this team. You turn goals into plans, break work into tasks, delegate, track progress, and summarize status. Be organized and decisive, surface risks early, and keep everyone unblocked."
    case .boss:
      return "You are the Boss. You set strategy, make the final call on big decisions, and hold the team to outcomes. Think in priorities and trade-offs, ask for the numbers, and sign off before anything significant ships."
    case .custom:
      return ""
    }
  }

  var autonomyMode: String {
    switch self {
    case .marketing, .manager, .monitor, .coder: return "safe_auto"
    case .sales, .boss, .publisher, .social: return "approval_required"
    case .custom: return "safe_auto"
    }
  }

  /// Capabilities this role starts with. Owner can add or remove any of them before creating.
  var capabilities: Set<ChatAgentCapability> {
    switch self {
    case .marketing: return [.computer, .research, .team]
    case .social: return [.browser, .research, .team]
    case .coder: return [.computer, .research, .team]
    case .publisher: return [.computer, .team]
    case .monitor: return [.computer, .research, .team]
    case .sales, .manager, .boss: return [.research, .team]
    case .custom: return []
    }
  }

  /// Registry model id this role starts on; nil follows the registry default.
  /// Step-heavy roles start cheaper, decision roles start on a frontier model.
  var defaultModelId: String? {
    switch self {
    case .marketing: return "claude-sonnet-5"
    case .social: return "claude-sonnet-5"
    case .coder: return "claude-sonnet-5"
    case .publisher: return "claude-haiku-4-5-20251001"
    case .monitor: return "claude-haiku-4-5-20251001"
    case .sales: return "claude-haiku-4-5-20251001"
    case .manager: return "claude-sonnet-5"
    case .boss: return "claude-opus-4-8"
    case .custom: return nil
    }
  }

  var baseTools: [String] {
    switch self {
    case .custom: return []
    default: return ["create_document"]
    }
  }
}

/// One composable thing an agent can be given. The raw ids are what the server stores; it
/// expands the coarse ones into whole tool families (VibeContracts.ToolBundles).
enum ChatAgentCapability: String, CaseIterable, Identifiable {
  case computer, browser, research, team
  var id: String { rawValue }

  var toolIds: [String] {
    switch self {
    case .computer: return ["computer_run"]
    case .browser: return ["browser_open"]
    case .research: return ["search_google", "read_url"]
    case .team: return ["handoff_to_agent"]
    }
  }

  /// Needs the isolated runtime: the embedded loop has no sandbox.
  var needsSandbox: Bool { self == .computer || self == .browser }

  var title: String {
    switch self {
    case .computer: return "Its own computer"
    case .browser: return "Browser only"
    case .research: return "Web research"
    case .team: return "Works with other agents"
    }
  }

  var detail: String {
    switch self {
    case .computer: return "Linux shell, files, code editing and a real Chromium it stays signed into."
    case .browser: return "A real Chromium with saved logins, but no shell and no files."
    case .research: return "Web search and reading pages, without a machine of its own."
    case .team: return "Can hand a finished piece of work to another agent in this chat."
    }
  }

  var symbol: String {
    switch self {
    case .computer: return "desktopcomputer"
    case .browser: return "safari"
    case .research: return "magnifyingglass"
    case .team: return "person.2.fill"
    }
  }
}

func chatAgentAutonomyLabel(_ mode: String) -> String {
  switch mode {
  case "draft_first": return "Draft first"
  case "manual": return "Manual"
  case "safe_auto": return "Safe auto"
  case "approval_required": return "Approval required"
  case "full_auto": return "Full auto"
  default: return mode
  }
}

func chatAgentAutonomyDetail(_ mode: String) -> String {
  switch mode {
  case "draft_first": return "Prepares work but never sends until you review."
  case "manual": return "Acts only when you explicitly ask."
  case "safe_auto": return "Acts on low-risk steps, asks before risky ones."
  case "approval_required": return "Asks for your approval before every action."
  case "full_auto": return "Acts on its own without asking."
  default: return ""
  }
}

/// Owner-editable → server create body. `enabled_tools`/`persona` omitted when
/// empty so the server keeps its defaults; computer roles run isolated.
func chatAgentCreateAttributes(
  name: String, persona: String?, systemPrompt: String,
  autonomyMode: String, baseTools: [String], capabilities: Set<ChatAgentCapability>,
  modelProvider: String? = nil, modelId: String? = nil
) -> [String: Any] {
  var enabled = baseTools
  for id in capabilities.flatMap(\.toolIds) where !enabled.contains(id) { enabled.append(id) }
  let needsSandbox = capabilities.contains { $0.needsSandbox }
  var attrs: [String: Any] = [
    "display_name": name,
    "system_prompt": systemPrompt,
    "autonomy_mode": autonomyMode,
    "output_modes": ["text"],
    "execution_mode": needsSandbox ? "isolated" : "embedded",
  ]
  if let persona, !persona.isEmpty { attrs["persona"] = persona }
  if !enabled.isEmpty { attrs["enabled_tools"] = enabled }
  // Server validates the pair on create; omitted, it keeps the schema default.
  if let modelProvider, !modelProvider.isEmpty { attrs["model_provider"] = modelProvider }
  if let modelId, !modelId.isEmpty { attrs["model_id"] = modelId }
  return attrs
}

/// Native create sheet: pick a role, tune the role text + control, create.
/// `onCreate` runs the POST; its callback carries an error string, nil = done.
struct ChatNewAgentView: View {
  var onCancel: () -> Void
  var onCreate: ([String: Any], @escaping (String?) -> Void) -> Void
  var onLoadModelRegistry: ((@escaping (ChatAgentModelRegistry) -> Void) -> Void)? = nil

  @Environment(\.colorScheme) private var colorScheme
  @State private var preset: ChatAgentRolePreset = .marketing
  @State private var name: String = ChatAgentRolePreset.marketing.defaultName
  @State private var systemPrompt: String = ChatAgentRolePreset.marketing.systemPrompt
  @State private var autonomy: String = ChatAgentRolePreset.marketing.autonomyMode
  @State private var capabilities: Set<ChatAgentCapability> = ChatAgentRolePreset.marketing.capabilities
  @State private var registry: ChatAgentModelRegistry = .fallback
  @State private var didLoadRegistry = false
  @State private var didPickModel = false
  @State private var modelProviderId = ChatAgentModelRegistry.fallback.defaultProvider
  @State private var modelId =
    ChatAgentRolePreset.marketing.defaultModelId
    ?? ChatAgentModelRegistry.fallback.defaultModelId
  @State private var isCreating = false
  @State private var errorMessage: String?

  private let autonomyOptions = ["draft_first", "manual", "safe_auto", "approval_required", "full_auto"]
  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }
  private var selectedFill: Color {
    palette.text.opacity(colorScheme == .dark ? 0.20 : 0.12)
  }
  private var canCreate: Bool {
    !isCreating
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      List {
        roleSection
        nameSection
        instructionsSection
        modelSection
        controlSection
        capabilitySection
        if let errorMessage { errorSection(errorMessage) }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .onAppear { loadRegistryIfNeeded() }
      .navigationTitle("New Agent")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .tint(palette.text)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { onCancel() } label: {
            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
          }
          .disabled(isCreating)
        }
        ToolbarItem(placement: .topBarTrailing) {
          if isCreating {
            ProgressView()
          } else {
            Button("Create") { create() }
              .fontWeight(.semibold)
              .disabled(!canCreate)
          }
        }
      }
    }
    .presentationBackground(.clear)
  }

  private func applyPreset(_ p: ChatAgentRolePreset) {
    guard p != preset else { return }
    preset = p
    name = p.defaultName
    systemPrompt = p.systemPrompt
    autonomy = p.autonomyMode
    capabilities = p.capabilities
    didPickModel = false
    applyPresetModel(p)
  }

  /// Resolves a preset model id against the live registry; unknown or
  /// unavailable ids fall back to the registry default.
  private func applyPresetModel(_ p: ChatAgentRolePreset) {
    if let wanted = p.defaultModelId,
      let hit = registry.selection(modelId: wanted),
      hit.provider.available
    {
      modelProviderId = hit.provider.id
      modelId = hit.model.id
      return
    }
    if let fallback = registry.selection(modelId: registry.defaultModelId),
      fallback.provider.available
    {
      modelProviderId = fallback.provider.id
      modelId = fallback.model.id
      return
    }
    if let provider = registry.providers.first(where: \.available),
      let model = provider.models.first(where: \.recommended) ?? provider.models.first
    {
      modelProviderId = provider.id
      modelId = model.id
      return
    }
    modelProviderId = registry.defaultProvider
    modelId = registry.defaultModelId
  }

  private func loadRegistryIfNeeded() {
    guard !didLoadRegistry else { return }
    didLoadRegistry = true
    guard let onLoadModelRegistry else {
      applyPresetModel(preset)
      return
    }
    onLoadModelRegistry { loaded in
      registry = loaded
      if !didPickModel { applyPresetModel(preset) }
    }
  }

  private var selectedModel: ChatAgentModelInfo? {
    registry.model(providerId: modelProviderId, modelId: modelId)
  }

  private var modelFooter: String {
    let detail = selectedModel?.description ?? "Picks which model runs this agent."
    guard registry.isFallback else { return detail }
    return "\(detail) Showing the built-in catalog while the live registry is unavailable."
  }

  private func create() {
    errorMessage = nil
    isCreating = true
    let attrs = chatAgentCreateAttributes(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      persona: preset.persona,
      systemPrompt: systemPrompt,
      autonomyMode: autonomy,
      baseTools: preset.baseTools,
      capabilities: capabilities,
      modelProvider: modelProviderId,
      modelId: modelId)
    onCreate(attrs) { error in
      isCreating = false
      if let error { errorMessage = error }
    }
  }

  private var roleSection: some View {
    Section {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(ChatAgentRolePreset.allCases) { roleCard($0) }
        }
        .padding(.vertical, 4)
      }
      .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
      .listRowBackground(Color.clear)
    } header: {
      sectionHeader("Role")
    }
  }

  private func roleCard(_ p: ChatAgentRolePreset) -> some View {
    let selected = p == preset
    return Button {
      withAnimation(.easeInOut(duration: 0.15)) { applyPreset(p) }
    } label: {
      VStack(spacing: 6) {
        Image(systemName: p.symbol)
          .font(.system(size: 20, weight: .semibold))
        Text(p.title)
          .font(.system(size: 13, weight: .semibold))
      }
      .foregroundStyle(selected ? palette.text : palette.secondaryText)
      .frame(width: 96, height: 78)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(selected ? selectedFill : rowFill)
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(palette.text, lineWidth: selected ? 1.5 : 0)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private var nameSection: some View {
    Section {
      HStack {
        Text("Name").font(.system(size: 16)).foregroundStyle(palette.text)
        Spacer(minLength: 12)
        TextField(preset.defaultName, text: $name)
          .multilineTextAlignment(.trailing)
          .foregroundStyle(palette.secondaryText)
      }
      .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
      .listRowBackground(rowFill)
    } header: {
      sectionHeader("Name")
    }
  }

  private var instructionsSection: some View {
    Section {
      ZStack(alignment: .topLeading) {
        if systemPrompt.isEmpty {
          Text("Describe the role and the job…")
            .font(.system(size: 15))
            .foregroundStyle(palette.secondaryText.opacity(0.7))
            .padding(.top, 8).padding(.leading, 5)
        }
        TextEditor(text: $systemPrompt)
          .font(.system(size: 15))
          .foregroundStyle(palette.text)
          .frame(minHeight: 150)
          .scrollContentBackground(.hidden)
      }
      .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
      .listRowBackground(rowFill)
    } header: {
      sectionHeader("Instructions")
    } footer: {
      Text("This is the agent's role — what it is and the job it does.")
        .foregroundStyle(palette.secondaryText)
    }
  }

  private var modelSection: some View {
    Section {
      Menu {
        ForEach(registry.providers) { provider in
          Section {
            ForEach(provider.models) { model in
              Button {
                modelProviderId = provider.id
                modelId = model.id
                didPickModel = true
              } label: {
                if provider.id == modelProviderId && model.id == modelId {
                  Label(model.name, systemImage: "checkmark")
                } else {
                  Text(model.name)
                }
              }
              .disabled(!provider.available)
            }
          } header: {
            Text(provider.available ? provider.name : "\(provider.name) (unavailable)")
          }
        }
      } label: {
        HStack {
          Text("Model").font(.system(size: 16)).foregroundStyle(palette.text)
          Spacer(minLength: 12)
          Text(selectedModel?.name ?? modelId)
            .font(.system(size: 15)).foregroundStyle(palette.secondaryText)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondaryText)
        }
      }
      .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
      .listRowBackground(rowFill)
    } header: {
      sectionHeader("Model")
    } footer: {
      Text(modelFooter).foregroundStyle(palette.secondaryText)
    }
  }

  private var controlSection: some View {
    Section {
      Menu {
        ForEach(autonomyOptions, id: \.self) { mode in
          Button {
            autonomy = mode
          } label: {
            if mode == autonomy {
              Label(chatAgentAutonomyLabel(mode), systemImage: "checkmark")
            } else {
              Text(chatAgentAutonomyLabel(mode))
            }
          }
        }
      } label: {
        HStack {
          Text("Control").font(.system(size: 16)).foregroundStyle(palette.text)
          Spacer(minLength: 12)
          Text(chatAgentAutonomyLabel(autonomy))
            .font(.system(size: 15)).foregroundStyle(palette.secondaryText)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondaryText)
        }
      }
      .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
      .listRowBackground(rowFill)

    } header: {
      sectionHeader("Control")
    } footer: {
      Text(chatAgentAutonomyDetail(autonomy)).foregroundStyle(palette.secondaryText)
    }
  }

  private var capabilitySection: some View {
    Section {
      ForEach(ChatAgentCapability.allCases) { capability in
        Toggle(isOn: binding(for: capability)) {
          HStack(spacing: 12) {
            Image(systemName: capability.symbol)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(palette.secondaryText)
              .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text(capability.title).font(.system(size: 16)).foregroundStyle(palette.text)
              Text(capability.detail).font(.system(size: 12)).foregroundStyle(palette.secondaryText)
            }
          }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
        .listRowBackground(rowFill)
      }
    } header: {
      sectionHeader("What it can do")
    } footer: {
      Text("A computer or a browser runs the agent in its own sandbox. Everything else runs inline.")
        .foregroundStyle(palette.secondaryText)
    }
  }

  private func binding(for capability: ChatAgentCapability) -> Binding<Bool> {
    Binding(
      get: { capabilities.contains(capability) },
      set: { on in
        if on { capabilities.insert(capability) } else { capabilities.remove(capability) }
      }
    )
  }

  private func errorSection(_ msg: String) -> some View {
    Section {
      Text(msg).font(.system(size: 13)).foregroundStyle(.red).listRowBackground(rowFill)
    }
  }

  private func sectionHeader(_ t: String) -> some View {
    Text(t)
      .font(.system(size: 13, weight: .semibold))
      .textCase(.uppercase)
      .foregroundStyle(palette.secondaryText)
  }
}
