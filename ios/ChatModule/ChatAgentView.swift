import Foundation
import Security
import SwiftUI
import UIKit

final class ChatNativeAgentRegistry {
  static let shared = ChatNativeAgentRegistry()

  private final class WeakRef {
    weak var value: ChatNativeAgentView?

    init(_ value: ChatNativeAgentView) {
      self.value = value
    }
  }

  private var map: [String: WeakRef] = [:]

  func register(surfaceId: String, view: ChatNativeAgentView) {
    map[surfaceId] = WeakRef(view)
  }

  func view(for surfaceId: String) -> ChatNativeAgentView? {
    if let value = map[surfaceId]?.value {
      return value
    }
    map.removeValue(forKey: surfaceId)
    return nil
  }

  func unregister(surfaceId: String) {
    map.removeValue(forKey: surfaceId)
  }
}

/// Process-lifetime home for the agent socket.
///
/// `ChatNativeAgentView` is a stored property of `ChatAgentConversationController`, which
/// is created on push and released on pop — and `didMoveToWindow` used to `disconnect()`
/// the client and nil it on every detach. So opening an agent chat paid a fresh
/// DNS + TLS + WebSocket handshake plus a Phoenix join EVERY time: measured on device at
/// 25.827 `connecting` → 26.862 `socket open` → 27.179 `join OK`, a flat 1.35s per open,
/// while the app already held an open socket to that very host.
///
/// Nothing about the socket is per-view — its topic is `agent:<userId>` — so it has no
/// business dying with the view. One client lives here for the process; views ATTACH as
/// its owner and frames are forwarded to whoever is attached now. A view that finds an
/// already-joined socket skips the dial AND the join and is usable immediately.
///
/// It is not kept alive forever: with no owner attached the socket is torn down after a
/// grace period, so leaving agent chats does not leave a second socket heartbeating.
final class ChatNativeAgentSocketHolder {
  static let shared = ChatNativeAgentSocketHolder()

  /// Long enough that navigating out and back in reuses the socket, short enough that
  /// walking away from agent chats doesn't leave one running.
  private static let idleTeardownDelay: TimeInterval = 90.0

  private(set) var client: ChatPhoenixClient?
  private(set) var topic: String = ""
  private(set) var isJoined = false
  private weak var owner: ChatNativeAgentView?
  private var idleTeardown: DispatchWorkItem?

  func attach(_ view: ChatNativeAgentView) {
    idleTeardown?.cancel()
    idleTeardown = nil
    owner = view
  }

  func detach(_ view: ChatNativeAgentView) {
    guard owner === view else { return }
    owner = nil
    idleTeardown?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.owner == nil else { return }
      NSLog("[ChatNativeAgent] idle teardown — no agent surface for %.0fs", Self.idleTeardownDelay)
      self.invalidate()
    }
    idleTeardown = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTeardownDelay, execute: work)
  }

  /// The live client for `topic`, dialling one only when there isn't one already.
  func client(for topic: String, socketURL: URL, token: String) -> ChatPhoenixClient {
    if let existing = client, self.topic == topic { return existing }
    // A different user (or a stale topic): that socket is worthless here.
    invalidate()
    self.topic = topic
    NSLog(
      "[ChatNativeAgent] connecting socketURL=%@ topic=%@ hasToken=%@",
      socketURL.absoluteString, topic, token.isEmpty ? "false" : "true")
    let callbacks = ChatPhoenixClient.Callbacks(
      onOpen: { [weak self] in
        DispatchQueue.main.async { self?.owner?.agentSocketDidOpen() }
      },
      onClose: { [weak self] _, _ in
        DispatchQueue.main.async { self?.handleDrop() }
      },
      onError: { [weak self] error in
        DispatchQueue.main.async {
          NSLog("[ChatNativeAgent] socket error %@", error)
          self?.handleDrop()
        }
      },
      onEvent: { [weak self] frame in
        DispatchQueue.main.async { self?.owner?.agentSocketDidReceive(frame) }
      }
    )
    let next = ChatPhoenixClient(
      baseURL: socketURL, params: [:], authToken: token, callbacks: callbacks)
    client = next
    next.connect()
    return next
  }

  func markJoined() { isJoined = true }

  /// Drop the socket outright (stream abort, auth change, idle teardown).
  func invalidate() {
    client?.disconnect()
    client = nil
    isJoined = false
    topic = ""
  }

  private func handleDrop() {
    client = nil
    isJoined = false
    owner?.agentSocketDidClose()
  }
}

private enum ChatNativeAgentPage: Int {
  case chat = 0
  case history = 1
}

private enum ChatNativeAgentRole: String, Codable {
  case user
  case assistant
}

private enum ChatNativeAgentStreamSegment: Codable, Equatable {
  case text(String)
  case progress(id: String, label: String, tool: String?, status: String)
  case cards(groupId: String, cards: [ChatListRow.AgentCard])

  var isRunningProgress: Bool {
    if case .progress(_, _, _, let status) = self { return status == "running" }
    return false
  }

  var progressTool: String? {
    if case .progress(_, _, let tool, _) = self { return tool }
    return nil
  }

  var progressId: String? {
    if case .progress(let id, _, _, _) = self { return id }
    return nil
  }

  var cardGroupId: String? {
    if case .cards(let groupId, _) = self { return groupId }
    return nil
  }
}

private struct ChatNativeAgentMessage: Codable, Equatable {
  let id: String
  let role: ChatNativeAgentRole
  var content: String
  var timestampMs: Int64
  var isStreaming: Bool
  var streamSegments: [ChatNativeAgentStreamSegment]
  // Set on a user message when its turn fails to get a response (agent error or
  // the user stops generation). Drives the "not sent" indicator. Optional so
  // older persisted state without the key still decodes.
  var deliveryFailed: Bool?
  // Set on an assistant message whose turn errored out. Drives the side
  // "regenerate" button, which now only appears on failed responses. Optional
  // so older persisted state without the key still decodes.
  var isError: Bool?
  /// Full ordered `buildTurnNodes` output sealed at settle (JSON array of node dicts).
  /// Cold-open + server rehydrate prefer this over a thin summary-only rebuild.
  /// Absent / version < 2 → legacy thin path (summary). Optional for older state.
  var settledProgressNodesJSON: Data?
  /// Frozen contract: `2` means settledProgressNodesJSON carries the full ordered structure.
  var agentTurnStructureVersion: Int?
  /// The server's own ordered node container for this turn (JSON array of node dicts), as
  /// sent on every stream frame. When present it is AUTHORITATIVE: it already interleaves
  /// narration text ↔ tool steps ↔ thinking in stream order, and it carries fields the local
  /// segment enum cannot express (kind, tokens, durationMs, thinkingText). Absent only on an
  /// older server, where the client-side `buildTurnNodes` heuristics still apply.
  var serverProgressNodesJSON: Data?

  init(
    id: String,
    role: ChatNativeAgentRole,
    content: String,
    timestampMs: Int64,
    isStreaming: Bool,
    streamSegments: [ChatNativeAgentStreamSegment] = [],
    deliveryFailed: Bool? = nil,
    isError: Bool? = nil,
    settledProgressNodesJSON: Data? = nil,
    agentTurnStructureVersion: Int? = nil,
    serverProgressNodesJSON: Data? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestampMs = timestampMs
    self.isStreaming = isStreaming
    self.streamSegments = streamSegments
    self.deliveryFailed = deliveryFailed
    self.isError = isError
    self.settledProgressNodesJSON = settledProgressNodesJSON
    self.agentTurnStructureVersion = agentTurnStructureVersion
    self.serverProgressNodesJSON = serverProgressNodesJSON
  }
}

/// Finalized non-text agent artifact (music, question, file, …) delivered after
/// the streaming text row settles. Stored separately so rich rows never mutate
/// the assistant text bubble.
private struct ChatNativeAgentRichOutput: Codable, Equatable {
  var id: String
  var agentPartIndex: Int
  var kind: String
  var mediaUrl: String?
  var text: String
  var fileName: String?
  var durationSeconds: Double?
  var timestampMs: Int64
  var assistantMessageId: String?
  /// JSON-encoded metadata dictionary (batch fields, music track fields, …).
  var metadataJSON: Data

  var metadata: [String: Any] {
    guard !metadataJSON.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: metadataJSON),
      let dict = object as? [String: Any]
    else {
      return [:]
    }
    return dict
  }

  init(
    id: String,
    agentPartIndex: Int,
    kind: String,
    mediaUrl: String? = nil,
    text: String = "",
    fileName: String? = nil,
    durationSeconds: Double? = nil,
    timestampMs: Int64,
    assistantMessageId: String? = nil,
    metadata: [String: Any] = [:]
  ) {
    self.id = id
    self.agentPartIndex = agentPartIndex
    self.kind = kind
    self.mediaUrl = mediaUrl
    self.text = text
    self.fileName = fileName
    self.durationSeconds = durationSeconds
    self.timestampMs = timestampMs
    self.assistantMessageId = assistantMessageId
    self.metadataJSON =
      (try? JSONSerialization.data(withJSONObject: metadata, options: [])) ?? Data()
  }
}

private struct ChatNativeAgentConversation: Codable, Equatable {
  var id: String
  var title: String
  var createdAt: Int64
  var updatedAt: Int64
  var messages: [ChatNativeAgentMessage]
  /// Finalized rich rows for this conversation, keyed/deduped by part/message id.
  var richOutputs: [ChatNativeAgentRichOutput]

  init(
    id: String,
    title: String,
    createdAt: Int64,
    updatedAt: Int64,
    messages: [ChatNativeAgentMessage],
    richOutputs: [ChatNativeAgentRichOutput] = []
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messages = messages
    self.richOutputs = richOutputs
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, createdAt, updatedAt, messages, richOutputs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    createdAt = try container.decode(Int64.self, forKey: .createdAt)
    updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
    messages = try container.decode([ChatNativeAgentMessage].self, forKey: .messages)
    richOutputs =
      (try? container.decode([ChatNativeAgentRichOutput].self, forKey: .richOutputs)) ?? []
  }
}

private struct ChatNativeAgentPersistedState: Codable {
  let activeConversationId: String?
  let conversations: [ChatNativeAgentConversation]
}

private enum ChatNativeAgentPendingSend {
  case message(
    conversationId: String,
    text: String,
    truncateAtId: String?,
    modelProvider: String,
    modelId: String,
    thinkingLevel: String
  )
  case builderUiResponse(conversationId: String, uiResponse: [String: Any], summary: String?)

  var conversationId: String {
    switch self {
    case .message(let conversationId, _, _, _, _, _):
      return conversationId
    case .builderUiResponse(let conversationId, _, _):
      return conversationId
    }
  }

  func withConversationId(_ updatedConversationId: String) -> ChatNativeAgentPendingSend {
    switch self {
    case .message(
      _,
      let text,
      let truncateAtId,
      let modelProvider,
      let modelId,
      let thinkingLevel
    ):
      return .message(
        conversationId: updatedConversationId,
        text: text,
        truncateAtId: truncateAtId,
        modelProvider: modelProvider,
        modelId: modelId,
        thinkingLevel: thinkingLevel
      )
    case .builderUiResponse(_, let uiResponse, let summary):
      return .builderUiResponse(
        conversationId: updatedConversationId,
        uiResponse: uiResponse,
        summary: summary
      )
    }
  }
}

private struct ChatNativeAgentRenderEntry {
  let id: String
  let messageId: String
  let role: ChatNativeAgentRole
  let text: String
  let timestampMs: Int64
  let messageType: String
  let isStreaming: Bool
  let isAgentMessage: Bool
  let showTail: Bool
  let progressNodes: [[String: Any]]?
  let agentCard: ChatListRow.AgentCard?
  let actionSourceMessageId: String?
  let actionSourceText: String?
  var deliveryFailed: Bool = false
  var isError: Bool = false
  var mediaUrl: String? = nil
  var fileName: String? = nil
  var duration: Double? = nil
  var metadata: [String: Any]? = nil
  /// Frozen: 2 when progressNodes is the full settled ordered structure.
  var agentTurnStructureVersion: Int? = nil
}

private final class ChatNativeAgentHistoryCell: UITableViewCell {
  static let reuseIdentifier = "ChatNativeAgentHistoryCell"

  private let titleLabel = UILabel()
  private let previewLabel = UILabel()
  private let dateLabel = UILabel()
  private let separatorView = UIView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)

    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1

    previewLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    previewLabel.numberOfLines = 1

    dateLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    dateLabel.textAlignment = .right

    separatorView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

    [titleLabel, previewLabel, dateLabel, separatorView].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview($0)
    }

    NSLayoutConstraint.activate([
      dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      dateLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      dateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),

      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -12),
      titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),

      previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      previewLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
      previewLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

      separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      separatorView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
    ])
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    conversation: ChatNativeAgentConversation,
    activeConversationId: String?,
    appearance: ChatListAppearance
  ) {
    let isActive = conversation.id == activeConversationId
    let previewText = conversation.messages.last?.content.trimmingCharacters(
      in: .whitespacesAndNewlines)
    titleLabel.text = conversation.title.isEmpty ? "New Chat" : conversation.title
    previewLabel.text =
      (previewText?.isEmpty == false ? previewText : "No messages") ?? "No messages"
    dateLabel.text = Self.formatDateLabel(conversation.createdAt)

    titleLabel.textColor = appearance.textColorThem.withAlphaComponent(isActive ? 1.0 : 0.72)
    previewLabel.textColor = appearance.timeColorThem.withAlphaComponent(isActive ? 0.9 : 0.72)
    dateLabel.textColor = appearance.timeColorThem.withAlphaComponent(isActive ? 0.9 : 0.64)
    contentView.alpha = isActive ? 1.0 : 0.86
    separatorView.backgroundColor = appearance.dayBorderColor.withAlphaComponent(0.36)
  }

  private static func formatDateLabel(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return "Today"
    }
    if calendar.isDateInYesterday(date) {
      return "Yesterday"
    }
    let now = Date()
    let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
    if days > 1 && days < 7 {
      return "\(days)d ago"
    }
    return Self.dateFormatter.string(from: date)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()
}

public final class ChatNativeAgentView: UIView, UITableViewDataSource, UITableViewDelegate,
  UIScrollViewDelegate
{
  static let conversationsDidChangeNotification = Notification.Name(
    "ChatNativeAgentView.conversationsDidChange"
  )

  public var onNativeEvent = NativeEventDispatcher()

  /// Invoked when the header back button is tapped on the chat page. Set by a
  /// native UIKit host (e.g. `ChatAgentConversationController`) to pop the
  /// navigation stack, since the Expo `onNativeEvent` bridge is not wired when
  /// the view is hosted natively.
  public var onHeaderBack: (() -> Void)?

  /// Fired whenever the active conversation's rows change (sends, streaming
  /// chunks, completion). Lets a host render the agent conversation in the real
  /// chat surface (`ChatMainView`/`ChatListView`) while this view runs headless
  /// as the transport + row source. Rows use the same `kind`/`message` envelope
  /// `ChatListView` consumes.
  public var onRowsChanged: (([[String: Any]]) -> Void)?

  /// Fired when streaming starts/stops, so a host can toggle the composer's
  /// send/stop button.
  public var onStreamingStateChanged: ((Bool) -> Void)?

  /// The visible built-in chat header is owned by the host, while this headless
  /// transport owns the selected model and turn lifecycle.
  public var onHeaderStateChanged: ((String, String) -> Void)? {
    didSet { notifyHeaderStateChanged() }
  }

  /// When true, this view is only the agent socket + row source for a host
  /// (`ChatMainView`). Skip local message rendering, full-screen layout work,
  /// and expensive blur effects so opening Vibe AI does not double the memory
  /// footprint of two full chat UIs (observed as SIGKILL / jetsam).
  private var isTransportOnly = false

  @objc public var surfaceId: String = "" {
    didSet {
      let trimmed = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !registeredSurfaceId.isEmpty, registeredSurfaceId != trimmed {
        ChatNativeAgentRegistry.shared.unregister(surfaceId: registeredSurfaceId)
      }
      registeredSurfaceId = trimmed
      if !trimmed.isEmpty {
        ChatNativeAgentRegistry.shared.register(surfaceId: trimmed, view: self)
      }
    }
  }

  private let headerContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContentView = UIView()

  private let footerMaskView = UIView()
  private let footerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let footerMaskOverlayView = UIView()
  private let footerMaskGradientLayer = CAGradientLayer()
  private let backGlassView = UIVisualEffectView(effect: nil)
  private let titleGlassView = UIVisualEffectView(effect: nil)
  private let actionGlassView = UIVisualEffectView(effect: nil)
  private let backButton = UIButton(type: .system)
  private let titleButton = UIButton(type: .custom)
  private let titleLabel = UILabel()
  private let actionButton = UIButton(type: .system)

  private let pageScrollView = UIScrollView()
  private let chatPage = UIView()
  private let historyPage = UIView()
  private let messagesView = ChatNativeAgentMessagesView()
  private let historyTableView = UITableView(frame: .zero, style: .plain)
  private let historyEmptyLabel = UILabel()

  private var appearance = ChatListAppearance.current
  private var currentPage: ChatNativeAgentPage = .chat
  private var conversations: [ChatNativeAgentConversation] = []
  private var activeConversationId: String?
  private var streamingConversationId: String?

  private var currentSpacerHeight: CGFloat = 0

  private var topic: String = ""
  private var joinedTopic = false
  private var transportEnabled = false
  private var phoenixClient: ChatPhoenixClient?
  private var pendingReplies: [String: (String, [String: Any]) -> Void] = [:]
  private var reconnectWorkItem: DispatchWorkItem?
  private var streamingTimeoutWorkItem: DispatchWorkItem?
  private var pendingSends: [ChatNativeAgentPendingSend] = []
  private var lastReportedStreamingState = false
  private var isStoppingStreamManually = false
  private var builderQuestionNavigationController: UINavigationController?
  private var queuedBuilderQuestionRequest: ChatBuilderUiRequest?
  private var builderSetupState: ChatBuilderSetupState?
  private var builderActivity: [ChatBuilderActivityItem] = []
  private var builderActiveAgentId: String?
  private var builderLatestSecret: String?
  private var cachedAgentSecrets: [String: String] = [:]
  private var registeredSurfaceId: String = ""
  private var modelRegistry: ChatAgentModelRegistry = .fallback
  private var selectedModelProvider = ChatAgentModelRegistry.fallback.defaultProvider
  private var selectedModelId = ChatAgentModelRegistry.fallback.defaultModelId
  private var selectedThinkingLevel =
    ChatAgentModelRegistry.fallback.model(
      providerId: ChatAgentModelRegistry.fallback.defaultProvider,
      modelId: ChatAgentModelRegistry.fallback.defaultModelId
    )?.defaultThinkingLevel ?? "medium"
  private var hasExplicitModelSelection = false
  private var modelRegistryLoadInFlight = false
  private var modelRegistryLoadCompleted = false
  private var modelRegistryLoadWaiters: [() -> Void] = []
  private var headerActivityState = "ready"
  /// `rich_outputs` payloads buffered until the streamed text turn settles (`done`).
  private var pendingRichOutputsByConversation: [String: [[String: Any]]] = [:]

  private static let fallbackApiBaseURL = "https://api.vibegram.io"
  private static let persistenceKey = "vibe.native.agent.screen.v1"
  private static let modelProviderPersistenceKey = "vibe.native.agent.model-provider.v1"
  private static let modelIdPersistenceKey = "vibe.native.agent.model-id.v1"
  private static let thinkingLevelPersistenceKey = "vibe.native.agent.thinking-level.v1"
  private static let modelSelectionExplicitPersistenceKey =
    "vibe.native.agent.model-selection-explicit.v1"

  override init(frame: CGRect) {
    super.init(frame: frame)
    commonInit()
  }

  /// Transport-only construction. `prepareForTransportOnly()` can only hide the local
  /// UI *after* `init` has already built it; knowing at init time lets the expensive
  /// half be skipped instead of built-then-thrown-away — that was ~most of the felt
  /// delay when opening Vibe AI (see `[AgentOpen] view-init`).
  public init(frame: CGRect, transportOnly: Bool) {
    super.init(frame: frame)
    isTransportOnly = transportOnly
    commonInit()
  }

  private func commonInit() {
    let startedAt = ProcessInfo.processInfo.systemUptime
    func stageMs(_ since: TimeInterval) -> Int {
      Int((ProcessInfo.processInfo.systemUptime - since) * 1000)
    }
    var stageStartedAt = startedAt

    backgroundColor = .clear
    clipsToBounds = true

    setupHeader()
    setupPages()
    let setupMs = stageMs(stageStartedAt)
    stageStartedAt = ProcessInfo.processInfo.systemUptime
    applyPersistedState()
    let persistedMs = stageMs(stageStartedAt)
    stageStartedAt = ProcessInfo.processInfo.systemUptime
    applyPersistedModelSelection()
    applyAppearance([:])
    refreshHeader(animated: false)
    let chromeMs = stageMs(stageStartedAt)
    stageStartedAt = ProcessInfo.processInfo.systemUptime
    // Both of these only feed this view's OWN UI, which a transport instance never
    // shows: `refreshHistoryList` reloads a table `prepareForTransportOnly` hides, and
    // `rebuildChatRows` builds the entire transcript into the local
    // `ChatNativeAgentMessagesView` that the same call then clears. Worse, `onRowsChanged`
    // is still nil here, so the rows go nowhere — the host gets its copy from
    // `synchronizeHostState()` at the end of the controller's `viewDidLoad`, which runs
    // `rebuildChatRows` again. Skipping this is a pure deletion of duplicated work.
    if !isTransportOnly {
      refreshHistoryList()
      rebuildChatRows(scrollToBottom: false, animated: false)
    }
    NSLog(
      "[AgentOpen] view-init transportOnly=%@ setupMs=%d persistedStateMs=%d chromeMs=%d rowsMs=%d totalMs=%d",
      isTransportOnly ? "Y" : "N", setupMs, persistedMs, chromeMs, stageMs(stageStartedAt),
      stageMs(startedAt))
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    transportEnabled = false
    reconnectWorkItem?.cancel()
    streamingTimeoutWorkItem?.cancel()
    // Release the shared socket rather than closing it: this view dies on every pop and
    // closing here would put back the per-open handshake the holder exists to remove.
    ChatNativeAgentSocketHolder.shared.detach(self)
    if !registeredSurfaceId.isEmpty {
      ChatNativeAgentRegistry.shared.unregister(surfaceId: registeredSurfaceId)
    }
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      transportEnabled = true
      connectIfNeeded()
      loadModelRegistryIfNeeded()
      if let activeConversationId, conversation(for: activeConversationId)?.messages.isEmpty == true
      {
        loadConversation(id: activeConversationId)
      }
      return
    }
    // Detach only — the socket belongs to the holder and outlives this view, which is
    // what makes reopening an agent chat instant. The holder tears it down itself once
    // no agent surface has claimed it for a while.
    transportEnabled = false
    reconnectWorkItem?.cancel()
    ChatNativeAgentSocketHolder.shared.detach(self)
    phoenixClient = nil
    joinedTopic = false
  }

  /// Configure this instance as a hidden transport for a host chat surface.
  /// Call before attaching to a window when `onRowsChanged` drives `ChatMainView`.
  public func prepareForTransportOnly() {
    isTransportOnly = true
    isHidden = true
    isUserInteractionEnabled = false
    clipsToBounds = true
    // Tiny frame: no full-screen layer trees / cell dequeues for the hidden UI.
    frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    autoresizingMask = []
    // Drop blur backing stores — costly even when the view is hidden.
    headerMaskBlurView.effect = nil
    footerMaskBlurView.effect = nil
    backGlassView.effect = nil
    titleGlassView.effect = nil
    actionGlassView.effect = nil
    messagesView.isHidden = true
    historyTableView.isHidden = true
    pageScrollView.isHidden = true
    headerContainer.isHidden = true
    footerMaskView.isHidden = true
    // Clear any rows the init path may have built into the local list.
    messagesView.setRows(
      [],
      topPadding: 0,
      spacerHeight: 0,
      bottomPadding: 0,
      scrollToBottom: false,
      animated: false
    )
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    if isTransportOnly {
      // Host owns all visible layout; skip header/pages/message geometry.
      return
    }

    let safeTop = safeAreaInsets.top
    let bounds = self.bounds
    let headerHeight = safeTop + 72.0

    headerContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    headerMaskView.frame = headerContainer.bounds
    headerMaskBlurView.frame = headerMaskView.bounds
    headerMaskOverlayView.frame = headerMaskBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds
    bringSubviewToFront(headerContainer)
    headerContainer.bringSubviewToFront(headerContentView)

    let contentY = safeTop + 8.0
    headerContentView.frame = CGRect(
      x: 12.0,
      y: contentY,
      width: max(0.0, bounds.width - 24.0),
      height: 44.0
    )

    backGlassView.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    actionGlassView.frame = CGRect(
      x: max(0.0, headerContentView.bounds.width - 44.0),
      y: 0.0,
      width: 44.0,
      height: 44.0
    )
    let maxCenterWidth = max(0.0, headerContentView.bounds.width * 0.65)
    let requiredTitleWidth = max(160.0, titleLabel.intrinsicContentSize.width + 36.0)
    let centerWidth = min(maxCenterWidth, requiredTitleWidth)
    titleGlassView.frame = CGRect(
      x: (headerContentView.bounds.width - centerWidth) * 0.5,
      y: 0.0,
      width: centerWidth,
      height: 44.0
    )

    backButton.frame = backGlassView.bounds
    titleButton.frame = titleGlassView.bounds
    actionButton.frame = actionGlassView.bounds
    [backButton, titleButton, actionButton].forEach { control in
      control.layer.cornerRadius = control.bounds.height * 0.5
    }
    [backGlassView, titleGlassView, actionGlassView].forEach { glassView in
      glassView.layer.cornerRadius = glassView.bounds.height * 0.5
    }
    titleLabel.frame = titleButton.bounds.insetBy(dx: 12.0, dy: 4.0)

    pageScrollView.frame = bounds
    pageScrollView.contentSize = CGSize(width: bounds.width * 2.0, height: bounds.height)
    chatPage.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: bounds.height)
    historyPage.frame = CGRect(
      x: bounds.width,
      y: 0,
      width: bounds.width,
      height: bounds.height
    )

    messagesView.frame = chatPage.bounds
    let activeRows: [[String: Any]]
    if let activeConversationId, let conversation = conversation(for: activeConversationId) {
      activeRows = makeRawRows(for: conversation)
    } else {
      activeRows = []
    }
    messagesView.setRows(
      activeRows,
      topPadding: safeTop + 80.0,
      spacerHeight: currentSpacerHeight,
      bottomPadding: 140.0,
      scrollToBottom: false,
      animated: false
    )

    // Footer fade mask at bottom of chat page
    let footerMaskHeight: CGFloat = 100.0
    footerMaskView.frame = CGRect(
      x: 0.0,
      y: bounds.height - footerMaskHeight,
      width: bounds.width,
      height: footerMaskHeight
    )
    footerMaskBlurView.frame = footerMaskView.bounds
    footerMaskOverlayView.frame = footerMaskBlurView.bounds
    footerMaskGradientLayer.frame = footerMaskView.bounds

    historyTableView.frame = historyPage.bounds
    historyTableView.contentInset = UIEdgeInsets(
      top: safeTop + 80.0,
      left: 0.0,
      bottom: 100.0,
      right: 0.0
    )
    historyTableView.scrollIndicatorInsets = historyTableView.contentInset
    historyEmptyLabel.frame = CGRect(
      x: 28.0,
      y: safeTop + 132.0,
      width: max(0.0, historyPage.bounds.width - 56.0),
      height: 120.0
    )

    let targetOffset = CGPoint(x: CGFloat(currentPage.rawValue) * bounds.width, y: 0)
    if abs(pageScrollView.contentOffset.x - targetOffset.x) > 0.5 {
      pageScrollView.setContentOffset(targetOffset, animated: false)
    }
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    applyAppearance(rawAppearance)
  }

  /// Current persisted transcript for a host that wants to stage it authoritatively at
  /// final bounds before navigation. Data-only: it does not touch either message list.
  func currentHostRows() -> [[String: Any]] {
    guard let activeConversation = activeConversationId.flatMap({ conversation(for: $0) }) else {
      return []
    }
    return makeRawRows(for: activeConversation)
  }

  func synchronizeHostState(emitRows: Bool = true) {
    if emitRows {
      rebuildChatRows(scrollToBottom: false, animated: false)
    }
    onStreamingStateChanged?(streamingConversationId != nil)
    notifyHeaderStateChanged()
  }

  func handleHostEvent(_ event: [String: Any]) {
    handleMessagesEvent(event)
  }

  func setBuilderActiveAgentId(_ activeAgentId: String?) {
    builderActiveAgentId = Self.normalizedString(activeAgentId)
    cacheBuilderSecretIfPossible()
  }

  func setBuilderLatestSecret(_ latestSecret: String?) {
    builderLatestSecret = Self.normalizedString(latestSecret)
    cacheBuilderSecretIfPossible()
  }

  func presentModelPicker(from presenter: UIViewController) {
    loadModelRegistryIfNeeded { [weak self, weak presenter] in
      guard let self, let presenter else { return }
      let picker = ChatProviderModelPickerView(
        registry: self.modelRegistry,
        currentProviderId: self.selectedModelProvider,
        currentModelId: self.selectedModelId,
        currentThinkingLevel: self.selectedThinkingLevel
      ) { [weak self] providerId, modelId, thinkingLevel, completion in
        guard let self else {
          completion(false)
          return
        }
        self.applyModelSelection(
          providerId: providerId,
          modelId: modelId,
          thinkingLevel: thinkingLevel,
          persist: true)
        completion(true)
      }
      let host = UIHostingController(
        rootView: NavigationStack {
          picker
        }
      )
      host.view.backgroundColor = .clear
      host.view.isOpaque = false
      host.modalPresentationStyle = .pageSheet
      if let sheet = host.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        sheet.preferredCornerRadius = 30
      }
      presenter.present(host, animated: true)
    }
  }

  func submitText(_ rawText: String, userMessageId: String? = nil) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    connectIfNeeded()

    // Edit / resend of an existing message: if this id is already in the active
    // conversation, the turn it started (and everything after it) is stale. We
    // truncate it locally in `beginStreamingTurn` and ask the server to drop the
    // same tail so the list doesn't accumulate duplicate / orphaned bubbles.
    let trimmedId = userMessageId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var serverTruncateAtId: String? = nil
    if !trimmedId.isEmpty,
      let activeId = activeConversationId,
      let conversation = conversation(for: activeId),
      conversation.messages.contains(where: { $0.id == trimmedId })
    {
      serverTruncateAtId = trimmedId
    }

    guard let conversationId = beginStreamingTurn(
      userText: text,
      fallbackTitle: String(text.prefix(20)),
      userMessageId: userMessageId
    ) else { return }

    if joinedTopic {
      pushMessage(text: text, conversationId: conversationId, truncateAtId: serverTruncateAtId)
    } else {
      pendingSends.append(
        .message(
          conversationId: conversationId,
          text: text,
          truncateAtId: serverTruncateAtId,
          modelProvider: selectedModelProvider,
          modelId: selectedModelId,
          thinkingLevel: selectedThinkingLevel
        ))
    }
  }

  private func beginStreamingTurn(
    userText: String,
    fallbackTitle: String,
    userMessageId: String? = nil
  ) -> String? {
    let trimmedText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return nil }

    var conversationId = activeConversationId
    if conversationId == nil {
      conversationId = createConversation(title: fallbackTitle)
    }
    guard let conversationId else { return nil }

    let timestampMs = Self.nowMs()
    let resolvedUserMessageId: String = {
      let trimmed = userMessageId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? UUID().uuidString : trimmed
    }()
    let userMessage = ChatNativeAgentMessage(
      id: resolvedUserMessageId,
      role: .user,
      content: trimmedText,
      timestampMs: timestampMs,
      isStreaming: false,
      streamSegments: []
    )
    // No placeholder seed. The assistant turn starts with EMPTY segments so it emits
    // NO row until the first real chunk/tool step arrives (see makeRenderEntries — an
    // empty streaming turn is skipped). The header carries the "Thinking…" state during
    // the gap, so there is no in-list feedback to lose. A seeded "Working…" progress node
    // painted an empty full-width box that re-measured and SHIFTED the layout the moment
    // the first chunk landed — exactly the jump the user reported. The cell is now born
    // with real content (streaming text OR the first tool step) and grows in place.
    let assistantMessage = ChatNativeAgentMessage(
      id: UUID().uuidString,
      role: .assistant,
      content: "",
      timestampMs: timestampMs,
      isStreaming: true,
      streamSegments: []
    )

    updateConversation(conversationId) { conversation in
      // Edit / resend: drop the prior copy of this message and every bubble that
      // followed it before re-appending the fresh turn, so the list shows a
      // single clean exchange instead of stacking duplicates.
      if let existingIndex = conversation.messages.firstIndex(where: {
        $0.id == resolvedUserMessageId
      }) {
        conversation.messages = Array(conversation.messages.prefix(existingIndex))
      }
      conversation.messages.append(userMessage)
      conversation.messages.append(assistantMessage)
      conversation.updatedAt = timestampMs
      if conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        conversation.title = fallbackTitle
      }
    }

    streamingConversationId = conversationId
    notifyStreamingStateChanged()
    setHeaderActivityState(fallback: "thinking")
    currentSpacerHeight = 0.0
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: true, animated: true)
    scheduleStreamingTimeout()

    return conversationId
  }

  private func submitBuilderUiResponse(
    requestId: String,
    answers: [String: Any],
    summary: String?
  ) {
    let trimmedRequestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRequestId.isEmpty else { return }

    let normalizedSummary: String
    if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      normalizedSummary = "Updated the setup"
    }

    connectIfNeeded()
    guard
      let conversationId = beginStreamingTurn(
        userText: normalizedSummary,
        fallbackTitle: "Agent setup"
      )
    else { return }

    let uiResponse: [String: Any] = [
      "requestId": trimmedRequestId,
      "answers": answers,
    ]

    if joinedTopic {
      pushBuilderUiResponse(
        conversationId: conversationId,
        uiResponse: uiResponse,
        summary: normalizedSummary
      )
    } else {
      pendingSends.append(
        .builderUiResponse(
          conversationId: conversationId,
          uiResponse: uiResponse,
          summary: normalizedSummary
        ))
    }
  }

  private func pushBuilderUiResponse(
    conversationId: String,
    uiResponse: [String: Any],
    summary: String?
  ) {
    var payload: [String: Any] = [
      "conversation_id": conversationId,
      "ui_response": uiResponse,
    ]
    if let summary, !summary.isEmpty {
      payload["summary"] = summary
    }
    sendChannelEvent(event: "builder_ui_response", payload: payload) { _, _ in }
  }

  private func setupHeader() {
    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
    headerContainer.layer.zPosition = 50.0
    headerContainer.isUserInteractionEnabled = true

    headerMaskView.isUserInteractionEnabled = false
    headerContainer.addSubview(headerMaskView)
    headerMaskView.addSubview(headerMaskBlurView)
    headerMaskBlurView.contentView.addSubview(headerMaskOverlayView)
    headerMaskGradientLayer.colors = [
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.85).cgColor,
      UIColor.black.withAlphaComponent(0.45).cgColor,
      UIColor.clear.cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.42, 0.72, 1.0]
    headerMaskView.layer.mask = headerMaskGradientLayer

    headerContainer.addSubview(headerContentView)
    headerContentView.layer.zPosition = 1.0
    headerContentView.isUserInteractionEnabled = true
    headerContentView.addSubview(backGlassView)
    headerContentView.addSubview(titleGlassView)
    headerContentView.addSubview(actionGlassView)
    backGlassView.contentView.addSubview(backButton)
    titleGlassView.contentView.addSubview(titleButton)
    actionGlassView.contentView.addSubview(actionButton)
    titleButton.addSubview(titleLabel)

    [backGlassView, titleGlassView, actionGlassView].forEach { glassView in
      glassView.clipsToBounds = true
      glassView.layer.cornerCurve = .continuous
      glassView.contentView.backgroundColor = .clear
      glassView.isUserInteractionEnabled = true
    }

    [backButton, titleButton, actionButton].forEach {
      $0.tintColor = .white
      $0.backgroundColor = .clear
      $0.contentHorizontalAlignment = .center
      $0.contentVerticalAlignment = .center
      $0.clipsToBounds = true
    }
    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    actionButton.addTarget(self, action: #selector(handleActionPressed), for: .touchUpInside)

    titleButton.isUserInteractionEnabled = false
    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail

    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
    actionButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
  }

  private func setupPages() {
    pageScrollView.isPagingEnabled = true
    pageScrollView.showsHorizontalScrollIndicator = false
    pageScrollView.alwaysBounceHorizontal = true
    pageScrollView.bounces = false
    pageScrollView.keyboardDismissMode = .interactive
    pageScrollView.delegate = self
    if #available(iOS 11.0, *) {
      pageScrollView.contentInsetAdjustmentBehavior = .never
    }
    if headerContainer.superview === self {
      insertSubview(pageScrollView, belowSubview: headerContainer)
    } else {
      addSubview(pageScrollView)
    }

    pageScrollView.addSubview(chatPage)
    pageScrollView.addSubview(historyPage)

    chatPage.clipsToBounds = true
    historyPage.clipsToBounds = true

    chatPage.addSubview(messagesView)
    messagesView.onTap = { [weak self] in
      self?.window?.endEditing(true)
    }
    messagesView.onNativeEvent = { [weak self] event in
      self?.handleMessagesEvent(event)
    }

    let historyTap = UITapGestureRecognizer(target: self, action: #selector(handlePageTap))
    historyTap.cancelsTouchesInView = false
    historyPage.addGestureRecognizer(historyTap)

    historyTableView.backgroundColor = .clear
    historyTableView.separatorStyle = .none
    historyTableView.dataSource = self
    historyTableView.delegate = self
    historyTableView.keyboardDismissMode = .interactive
    historyTableView.register(
      ChatNativeAgentHistoryCell.self,
      forCellReuseIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier
    )
    if #available(iOS 11.0, *) {
      historyTableView.contentInsetAdjustmentBehavior = .never
    }
    historyPage.addSubview(historyTableView)

    historyEmptyLabel.text = "No conversations yet.\nStart chatting with Vibe AI."
    historyEmptyLabel.numberOfLines = 0
    historyEmptyLabel.textAlignment = .center
    historyPage.addSubview(historyEmptyLabel)

    // Footer fade mask
    footerMaskView.isUserInteractionEnabled = false
    footerMaskView.clipsToBounds = true
    chatPage.addSubview(footerMaskView)
    footerMaskView.addSubview(footerMaskBlurView)
    footerMaskBlurView.contentView.addSubview(footerMaskOverlayView)
    footerMaskGradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.55).cgColor,
      UIColor.black.cgColor,
    ]
    footerMaskGradientLayer.locations = [0.0, 0.38, 1.0]
    footerMaskView.layer.mask = footerMaskGradientLayer

    bringSubviewToFront(headerContainer)
  }

  private func applyAppearance(_ rawAppearance: [String: Any]) {
    appearance = ChatListAppearance.from(raw: rawAppearance)
    messagesView.applyAppearance(appearance)

    let headerTint = appearance.textColorThem
    let baseBackground = appearance.wallpaperGradient.first ?? UIColor.black
    let isDarkTheme = appearance.isDark

    backgroundColor = baseBackground
    titleLabel.textColor = headerTint
    backButton.tintColor = appearance.textColorThem
    actionButton.tintColor = appearance.textColorThem
    historyEmptyLabel.textColor = appearance.timeColorThem
    chatPage.backgroundColor = baseBackground
    historyPage.backgroundColor = baseBackground
    historyTableView.backgroundColor = .clear

    var white: CGFloat = 0.0
    if #available(iOS 26.0, *) {
      // On iOS 26, headerMask is hidden; glass handles everything.
    } else if appearance.textColorThem.getWhite(&white, alpha: nil) {
      headerMaskBlurView.effect = UIBlurEffect(style: white > 0.5 ? .dark : .light)
    } else {
      headerMaskBlurView.effect = UIBlurEffect(style: .regular)
    }
    headerMaskOverlayView.backgroundColor = baseBackground.withAlphaComponent(0.72)
    backGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    titleGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    actionGlassView.contentView.backgroundColor = baseBackground.withAlphaComponent(0.10)
    refreshHeaderGlass(isDarkTheme: isDarkTheme)

    // Footer mask theme
    var footerWhite: CGFloat = 0.0
    if appearance.textColorThem.getWhite(&footerWhite, alpha: nil) {
      footerMaskBlurView.effect = UIBlurEffect(style: footerWhite > 0.5 ? .dark : .light)
    } else {
      footerMaskBlurView.effect = UIBlurEffect(style: .regular)
    }
    footerMaskOverlayView.backgroundColor = baseBackground.withAlphaComponent(0.72)

    refreshHeader(animated: false)
    refreshHistoryList()
    setNeedsLayout()
  }

  private func currentBuilderPanelTheme() -> ChatBuilderPanelTheme {
    let isDarkTheme = appearance.isDark
    return ChatBuilderPanelTheme(
      isDark: isDarkTheme,
      backgroundColor: builderThemeColor(isDarkTheme ? "#121212" : "#F5F4F1"),
      cardColor: builderThemeColor(isDarkTheme ? "#242424" : "#FFFFFF"),
      inputColor: builderThemeColor(isDarkTheme ? "#222222" : "#F2F2F2"),
      textColor: builderThemeColor(isDarkTheme ? "#E8E6F0" : "#1A1A1F"),
      secondaryTextColor: builderThemeColor(isDarkTheme ? "#9896A8" : "#5A5A66"),
      accentColor: builderThemeColor(isDarkTheme ? "#7CB8B8" : "#4A8D8E")
    )
  }

  private func builderThemeColor(_ hex: String) -> UIColor {
    let sanitized =
      hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
        of: "#", with: "")
    guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
      return .systemBackground
    }
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }

  @objc private func handleBackPressed() {
    if currentPage == .history {
      setPage(.chat, animated: true)
      return
    }
    if let onHeaderBack {
      onHeaderBack()
      return
    }
    onNativeEvent(["type": "headerBack"])
  }

  @objc private func handleActionPressed() {
    if currentPage == .history {
      _ = createConversation(title: "New Chat")
      setPage(.chat, animated: true)
      return
    }

    setPage(.history, animated: true)
  }

  @objc private func handlePageTap() {
    window?.endEditing(true)
  }

  private func handleMessagesEvent(_ event: [String: Any]) {
    let type = Self.normalizedString(event["type"]) ?? ""

    if type == "agentCardPressed",
      let rawCard = event["card"] as? [String: Any],
      let card = ChatListRow.AgentCard.parse(rawCard)
    {
      presentAgentCardPanel(card)
      return
    }

    guard type == "agentMessageAction" else {
      onNativeEvent(event)
      return
    }

    let action = Self.normalizedString(event["action"]) ?? ""
    let sourceMessageId = Self.normalizedString(event["sourceMessageId"]) ?? ""
    let sourceText = (event["sourceText"] as? String) ?? ""

    switch action {
    case "copy":
      guard !sourceText.isEmpty else { return }
      UIPasteboard.general.string = sourceText
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onNativeEvent(["type": "agentToast", "message": "Copied to clipboard"])

    case "thumbUp":
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onNativeEvent([
        "type": "agentFeedback",
        "messageId": sourceMessageId,
        "value": "up",
      ])
      onNativeEvent(["type": "agentToast", "message": "Thanks for the feedback"])

    case "thumbDown":
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onNativeEvent([
        "type": "agentFeedback",
        "messageId": sourceMessageId,
        "value": "down",
      ])
      onNativeEvent(["type": "agentToast", "message": "Feedback noted"])

    case "regenerate":
      regenerateAssistantResponse(sourceMessageId: sourceMessageId)

    default:
      onNativeEvent(event)
    }
  }

  private func presentAgentCardPanel(_ card: ChatListRow.AgentCard) {
    guard let presenter = topMostViewController() else { return }
    let apiContext = resolveAPIConfig().map {
      ChatNativeAgentConfigAPIContext(apiBaseURL: $0.apiBaseURL, token: $0.token)
    }
    let controller = ChatNativeAgentConfigPanelController(
      card: resolvedAgentCard(card),
      appearance: appearance,
      apiContext: apiContext
    )
    controller.onToast = { [weak self] message in
      self?.onNativeEvent(["type": "agentToast", "message": message])
    }
    controller.onDeleteAgent = { [weak self] card, dismiss in
      self?.deleteAgent(card, dismiss: dismiss)
    }
    controller.onOpenAgentChat = { [weak self] card in
      self?.emitOpenAgentChat(card)
    }

    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .fullScreen
    presenter.present(navigation, animated: true)
  }

  func presentAgentControlPanel(from presenter: UIViewController) {
    guard let config = resolveAPIConfig() else {
      onNativeEvent(["type": "agentToast", "message": "Missing API session"])
      return
    }
    let apiContext = ChatNativeAgentConfigAPIContext(
      apiBaseURL: config.apiBaseURL,
      token: config.token
    )
    let controller = ChatAgentsMainViewController(
      apiContext: apiContext,
      appearance: appearance
    )
    controller.onToast = { [weak self] message in
      self?.onNativeEvent(["type": "agentToast", "message": message])
    }
    controller.onCreateAgent = { [weak self] in
      self?.onNativeEvent(["type": "agentCreateRequested"])
    }
    controller.onOpenAgentChat = { [weak self] card in
      self?.emitOpenAgentChat(card)
    }
    controller.onDeleteAgent = { [weak self] card, completion in
      self?.deleteAgent(card, dismiss: completion)
    }

    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .fullScreen
    presenter.present(navigation, animated: true)
  }

  private func emitOpenAgentChat(_ card: ChatListRow.AgentCard) {
    guard let agentUserId = card.agentUserId, !agentUserId.isEmpty else {
      onNativeEvent(["type": "agentToast", "message": "Agent chat is not available yet"])
      return
    }
    var payload: [String: Any] = [
      "type": "agentChatPressed",
      "agentUserId": agentUserId,
      "agentId": card.agentId,
      "agentName": card.displayName,
    ]
    if let username = card.username, !username.isEmpty {
      payload["agentUsername"] = username
      payload["agentHandle"] = "@\(username)"
    }
    onNativeEvent(payload)
  }

  private func refreshHeaderGlass(isDarkTheme: Bool) {
    if #available(iOS 26.0, *) {
      headerMaskView.isHidden = true
      footerMaskView.isHidden = true

      let backEffect = UIGlassEffect()
      backEffect.isInteractive = true
      backGlassView.effect = backEffect

      let titleEffect = UIGlassEffect()
      titleEffect.isInteractive = true
      titleGlassView.effect = titleEffect

      let actionEffect = UIGlassEffect()
      actionEffect.isInteractive = true
      actionGlassView.effect = actionEffect
      return
    }

    let blurStyle: UIBlurEffect.Style = isDarkTheme ? .systemMaterialDark : .systemMaterialLight
    backGlassView.effect = UIBlurEffect(style: blurStyle)
    titleGlassView.effect = UIBlurEffect(style: blurStyle)
    actionGlassView.effect = UIBlurEffect(style: blurStyle)
  }

  private func refreshHeader(animated: Bool) {
    let title = currentPage == .chat ? selectedModelDisplayTitle : "History"
    let backSymbol = "chevron.left"
    let actionSymbol = currentPage == .chat ? "clock" : "plus"
    let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setImage(UIImage(systemName: backSymbol, withConfiguration: config), for: .normal)
    actionButton.setImage(
      UIImage(systemName: actionSymbol, withConfiguration: config), for: .normal)

    if animated {
      UIView.transition(
        with: titleLabel,
        duration: 0.2,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) {
        self.titleLabel.text = title
      }
      return
    }
    titleLabel.text = title
  }

  private func setPage(_ page: ChatNativeAgentPage, animated: Bool) {
    guard
      currentPage != page
        || abs(pageScrollView.contentOffset.x - CGFloat(page.rawValue) * bounds.width) > 0.5
    else {
      return
    }
    window?.endEditing(true)
    currentPage = page
    refreshHeader(animated: animated)
    bringSubviewToFront(headerContainer)
    let target = CGPoint(x: CGFloat(page.rawValue) * bounds.width, y: 0)
    pageScrollView.setContentOffset(target, animated: animated)
  }

  // MARK: - Socket bridge (owned by ChatNativeAgentSocketHolder)

  func agentSocketDidOpen() { handleSocketOpen() }

  func agentSocketDidReceive(_ frame: ChatPhoenixClient.EventFrame) { handlePhoenixFrame(frame) }

  func agentSocketDidClose() {
    handleSocketClose(
      streamFailureMessage: "Connection lost. Tap regenerate to retry.",
      toastMessage: "Connection lost"
    )
  }

  private func connectIfNeeded() {
    guard transportEnabled else { return }
    guard let config = resolveConnectionConfig() else { return }

    let nextTopic = "agent:\(config.userId)"
    topic = nextTopic
    let holder = ChatNativeAgentSocketHolder.shared
    holder.attach(self)

    // Already dialled for this process: adopt it. This is the whole point — the socket
    // outlives the view, so the second and every later open of an agent chat costs
    // nothing instead of a 1.35s handshake.
    if let live = holder.client, holder.topic == nextTopic {
      phoenixClient = live
      guard holder.isJoined, !joinedTopic else { return }
      NSLog("[ChatNativeAgent] adopted live socket topic=%@ — no dial, no join", nextTopic)
      joinedTopic = true
      syncConversations()
      flushPendingSends()
      return
    }

    phoenixClient = holder.client(
      for: nextTopic, socketURL: config.socketURL, token: config.token)
  }

  private func handleSocketOpen() {
    reconnectWorkItem?.cancel()
    guard let client = phoenixClient, !topic.isEmpty else { return }
    NSLog("[ChatNativeAgent] socket open — joining topic=%@", topic)
    let joinRef = client.join(topic: topic, payload: [:])
    pendingReplies[joinRef] = { [weak self] status, response in
      guard let self else { return }
      if status == "ok" {
        NSLog("[ChatNativeAgent] join OK topic=%@ pendingSends=%d", self.topic, self.pendingSends.count)
        self.joinedTopic = true
        // Record it on the holder: the NEXT view to open this chat adopts a joined
        // socket and skips both the dial and the join.
        ChatNativeAgentSocketHolder.shared.markJoined()
        self.syncConversations()
        self.flushPendingSends()
        return
      }
      NSLog("[ChatNativeAgent] join FAILED topic=%@ status=%@ response=%@", self.topic, status, "\(response)")
      if self.streamingConversationId != nil {
        self.finishStreaming(
          fallbackText: "Couldn’t connect. Tap retry to try again.",
          forceErrorText: true
        )
      }
      self.scheduleReconnect()
    }
  }

  private func handleSocketClose(
    streamFailureMessage: String? = nil,
    toastMessage: String? = nil
  ) {
    let hadActiveStream = streamingConversationId != nil
    let stoppedManually = isStoppingStreamManually
    isStoppingStreamManually = false
    joinedTopic = false
    pendingReplies.removeAll()
    phoenixClient = nil

    if hadActiveStream && !stoppedManually {
      if let toastMessage, !toastMessage.isEmpty {
        onNativeEvent(["type": "agentToast", "message": toastMessage])
      }
      finishStreaming(
        fallbackText: streamFailureMessage ?? "Connection lost. Tap regenerate to retry.",
        forceErrorText: true
      )
    }

    scheduleReconnect()
  }

  private func scheduleReconnect() {
    reconnectWorkItem?.cancel()
    guard transportEnabled else { return }
    let workItem = DispatchWorkItem { [weak self] in
      self?.connectIfNeeded()
    }
    reconnectWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
  }

  private func resolveConnectionConfig() -> (socketURL: URL, token: String, userId: String)? {
    // Primary source is the live chat engine config (same store the working chat
    // socket uses); fall back to the native-call config and keychain session.
    let engineConfig = ChatEngineStore.shared.getConfig()
    let nativeCallConfig = VibeNativeCallStore.shared.getNativeEngineConfig()
    let session = Self.loadNativeAuthSessionFromKeychain()

    guard
      let userId = Self.normalizedString(
        engineConfig["userId"] ?? nativeCallConfig["userId"] ?? session?["userId"])
    else {
      NSLog("[ChatNativeAgent] missing native user id")
      return nil
    }

    let apiBase =
      Self.normalizedString(
        engineConfig["apiBaseUrl"] ?? engineConfig["baseUrl"]
          ?? nativeCallConfig["baseUrl"] ?? nativeCallConfig["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let socketString =
      Self.normalizedString(
        engineConfig["socketUrl"] ?? engineConfig["url"] ?? nativeCallConfig["socketUrl"])
      ?? (apiBase.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
        + "/socket")
    let token = [
      Self.normalizedString(session?["loginToken"]),
      Self.normalizedString(nativeCallConfig["authToken"]),
      Self.normalizedString(engineConfig["authToken"] ?? engineConfig["token"]),
    ].compactMap { $0 }.first { $0 != userId && $0.lowercased() != "undefined" }
    guard let token else {
      NSLog("[ChatNativeAgent] missing valid login token (user id is not socket auth)")
      return nil
    }

    guard let socketURL = URL(string: socketString) else {
      NSLog("[ChatNativeAgent] invalid socket url %@", socketString)
      return nil
    }

    return (socketURL, token, userId)
  }

  private func resolveAPIConfig() -> (apiBaseURL: URL, token: String, userId: String)? {
    let engineConfig = ChatEngineStore.shared.getConfig()
    let nativeCallConfig = VibeNativeCallStore.shared.getNativeEngineConfig()
    let session = Self.loadNativeAuthSessionFromKeychain()

    guard
      let userId = Self.normalizedString(
        engineConfig["userId"] ?? nativeCallConfig["userId"] ?? session?["userId"])
    else {
      return nil
    }

    let apiBase =
      Self.normalizedString(
        engineConfig["apiBaseUrl"] ?? engineConfig["baseUrl"]
          ?? nativeCallConfig["baseUrl"] ?? nativeCallConfig["apiBaseUrl"])
      ?? Self.fallbackApiBaseURL
    let token =
      Self.normalizedString(
        engineConfig["authToken"] ?? engineConfig["token"]
          ?? nativeCallConfig["authToken"] ?? session?["loginToken"])
      ?? userId

    guard let apiBaseURL = URL(string: apiBase) else { return nil }
    return (apiBaseURL, token, userId)
  }

  private func loadModelRegistryIfNeeded(completion: (() -> Void)? = nil) {
    if let completion {
      modelRegistryLoadWaiters.append(completion)
    }
    if modelRegistryLoadCompleted {
      flushModelRegistryLoadWaiters()
      return
    }
    guard !modelRegistryLoadInFlight, let config = resolveAPIConfig() else {
      if !modelRegistryLoadInFlight {
        flushModelRegistryLoadWaiters()
      }
      return
    }

    modelRegistryLoadInFlight = true
    ChatAgentModelRegistryService.load(
      apiBaseURL: config.apiBaseURL,
      token: config.token
    ) { [weak self] registry in
      guard let self else { return }
      self.modelRegistryLoadInFlight = false
      self.modelRegistryLoadCompleted = true
      self.modelRegistry = registry
      self.resolveModelSelectionAgainstRegistry()
      self.flushModelRegistryLoadWaiters()
    }
  }

  private func flushModelRegistryLoadWaiters() {
    let waiters = modelRegistryLoadWaiters
    modelRegistryLoadWaiters.removeAll()
    waiters.forEach { $0() }
  }

  private func applyPersistedModelSelection() {
    guard
      let provider = Self.normalizedString(
        UserDefaults.standard.string(forKey: Self.modelProviderPersistenceKey)),
      let modelId = Self.normalizedString(
        UserDefaults.standard.string(forKey: Self.modelIdPersistenceKey))
    else {
      UserDefaults.standard.set(
        selectedModelProvider,
        forKey: Self.modelProviderPersistenceKey)
      UserDefaults.standard.set(selectedModelId, forKey: Self.modelIdPersistenceKey)
      UserDefaults.standard.set(
        selectedThinkingLevel,
        forKey: Self.thinkingLevelPersistenceKey)
      UserDefaults.standard.set(
        false,
        forKey: Self.modelSelectionExplicitPersistenceKey)
      return
    }
    selectedModelProvider = provider
    selectedModelId = modelId
    if let persistedThinkingLevel = Self.normalizedString(
      UserDefaults.standard.string(forKey: Self.thinkingLevelPersistenceKey))
    {
      selectedThinkingLevel = persistedThinkingLevel.lowercased()
    } else if let fallbackModel = ChatAgentModelRegistry.fallback.model(
      providerId: provider,
      modelId: modelId)
    {
      selectedThinkingLevel = fallbackModel.defaultThinkingLevel
      UserDefaults.standard.set(
        selectedThinkingLevel,
        forKey: Self.thinkingLevelPersistenceKey)
    } else {
      UserDefaults.standard.set(
        selectedThinkingLevel,
        forKey: Self.thinkingLevelPersistenceKey)
    }
    hasExplicitModelSelection = UserDefaults.standard.bool(
      forKey: Self.modelSelectionExplicitPersistenceKey)
  }

  private func resolveModelSelectionAgainstRegistry() {
    if hasExplicitModelSelection,
      let provider = modelRegistry.provider(id: selectedModelProvider),
      provider.available,
      let model = modelRegistry.model(providerId: provider.id, modelId: selectedModelId)
    {
      applyModelSelection(
        providerId: provider.id,
        modelId: model.id,
        thinkingLevel: selectedThinkingLevel,
        persist: true)
      return
    }

    let defaultProvider =
      modelRegistry.provider(id: modelRegistry.defaultProvider).flatMap {
        $0.available ? $0 : nil
      }
      ?? modelRegistry.providers.first(where: \.available)
      ?? modelRegistry.providers.first
    guard let defaultProvider else { return }
    let defaultModel =
      modelRegistry.model(
        providerId: defaultProvider.id,
        modelId: modelRegistry.defaultModelId)
      ?? defaultProvider.models.first(where: \.recommended)
      ?? defaultProvider.models.first
    guard let defaultModel else { return }
    applyModelSelection(
      providerId: defaultProvider.id,
      modelId: defaultModel.id,
      thinkingLevel: defaultModel.defaultThinkingLevel,
      persist: true,
      explicit: false
    )
  }

  private func applyModelSelection(
    providerId: String,
    modelId: String,
    thinkingLevel: String,
    persist: Bool,
    explicit: Bool = true
  ) {
    guard
      let provider = modelRegistry.provider(id: providerId),
      provider.available,
      let model = modelRegistry.model(providerId: provider.id, modelId: modelId)
    else {
      return
    }
    let resolvedThinkingLevel =
      model.thinkingLevels.first(where: {
        $0.caseInsensitiveCompare(thinkingLevel) == .orderedSame
      })
      ?? model.defaultThinkingLevel
    selectedModelProvider = provider.id
    selectedModelId = model.id
    selectedThinkingLevel = resolvedThinkingLevel
    if persist {
      hasExplicitModelSelection = explicit
      UserDefaults.standard.set(provider.id, forKey: Self.modelProviderPersistenceKey)
      UserDefaults.standard.set(model.id, forKey: Self.modelIdPersistenceKey)
      UserDefaults.standard.set(
        resolvedThinkingLevel,
        forKey: Self.thinkingLevelPersistenceKey)
      UserDefaults.standard.set(
        explicit,
        forKey: Self.modelSelectionExplicitPersistenceKey)
    }
    refreshHeader(animated: true)
    notifyHeaderStateChanged()
  }

  private var selectedModelDisplayTitle: String {
    modelRegistry.model(providerId: selectedModelProvider, modelId: selectedModelId)?.name
      ?? ChatAgentModelRegistry.fallback.model(
        providerId: selectedModelProvider,
        modelId: selectedModelId
      )?.name
      ?? selectedModelId
  }

  private func setHeaderActivityState(
    from payload: [String: Any]? = nil,
    fallback: String
  ) {
    let serverState = Self.normalizedString(
      payload?["activityState"] ?? payload?["activity_state"]
    )?.lowercased()
    let nextState: String
    switch serverState {
    case "thinking", "working", "typing", "ready":
      nextState = serverState ?? fallback
    default:
      nextState = fallback
    }
    guard headerActivityState != nextState else { return }
    headerActivityState = nextState
    notifyHeaderStateChanged()
  }

  private func notifyHeaderStateChanged() {
    let subtitle: String
    switch headerActivityState {
    case "thinking": subtitle = "Thinking…"
    case "working": subtitle = "Working…"
    case "typing": subtitle = "Typing…"
    default: subtitle = "Ready"
    }
    onHeaderStateChanged?(selectedModelDisplayTitle, subtitle)
  }

  private func handlePhoenixFrame(_ frame: ChatPhoenixClient.EventFrame) {
    if frame.event == "phx_reply", let ref = frame.ref {
      let status = (frame.payload["status"] as? String) ?? "error"
      let response = (frame.payload["response"] as? [String: Any]) ?? [:]
      let handler = pendingReplies.removeValue(forKey: ref)
      handler?(status, response)
      return
    }

    guard frame.topic == topic else { return }

    if frame.payload["activityState"] != nil || frame.payload["activity_state"] != nil {
      setHeaderActivityState(from: frame.payload, fallback: headerActivityState)
    }

    // The server now ships the WHOLE ordered node list on every stream frame, so the feed no
    // longer has to be re-derived here from independent labels (which is why two identical
    // requests used to produce different note lists, and why kind/tokens/thinkingText had
    // nowhere to live). Capture it first; the per-event handlers below stay as the fallback
    // path for a server that does not send it.
    captureServerProgressNodes(from: frame.payload)

    switch frame.event {
    case "chunk":
      let text = (frame.payload["text"] as? String) ?? ""
      NSLog("[ChatNativeAgent] chunk received len=%d total_segments=%d", text.count, conversation(for: streamingConversationId ?? activeConversationId ?? "")?.messages.last?.streamSegments.count ?? 0)
      scheduleStreamingTimeout()
      setHeaderActivityState(from: frame.payload, fallback: "typing")
      appendChunk(text)
    case "progress":
      let label =
        (frame.payload["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let tool = frame.payload["tool"] as? String
      let status = (frame.payload["status"] as? String) ?? "running"
      let toolCallId =
        ((frame.payload["tool_call_id"] as? String)
          ?? (frame.payload["toolCallId"] as? String)
          ?? (frame.payload["call_id"] as? String)
          ?? (frame.payload["callId"] as? String))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      NSLog(
        "[ChatNativeAgent] progress tool=%@ status=%@ label=%@ callId=%@",
        tool ?? "nil", status, label, toolCallId ?? "nil")
      scheduleStreamingTimeout()
      setHeaderActivityState(from: frame.payload, fallback: "working")

      guard let conversationId = streamingConversationId ?? activeConversationId else { break }
      updateConversation(conversationId) { conversation in
        guard !conversation.messages.isEmpty else { return }
        let lastIndex = conversation.messages.count - 1
        guard conversation.messages[lastIndex].role == .assistant else { return }

        // Keep completed steps in the turn (Codex-style item list). Never delete
        // them — replacing/clearing the segment list is what blanked the cell when
        // a later chunk arrived. Prefer stable tool_call_id, then tool key.
        let toolKey = tool
        let resolvedLabel = label.isEmpty ? "Working…" : label
        let stableId =
          (toolCallId?.isEmpty == false ? toolCallId! : nil)
          ?? toolKey
          ?? UUID().uuidString
        let existingIdx = conversation.messages[lastIndex].streamSegments.firstIndex(where: {
          segment in
          if let toolCallId, !toolCallId.isEmpty, segment.progressId == toolCallId {
            return true
          }
          // Distinct agentic beats (e.g. search_music_send) must not overwrite the prior step.
          if let toolKey, toolKey.contains("_send") {
            return segment.progressId == stableId || segment.progressTool == toolKey
          }
          if let toolKey {
            // Only match a still-running step for this tool so "Looking up" is kept
            // when "Found · …" arrives (GPT-style step history, not label replace).
            return segment.progressTool == toolKey && segment.isRunningProgress
          }
          return segment.isRunningProgress
            && (segment.progressTool == nil || segment.progressTool == "thread_start")
        })
        if let existingIdx {
          let existingId = conversation.messages[lastIndex].streamSegments[existingIdx].progressId
            ?? stableId
          let previousLabel: String = {
            if case .progress(_, let lab, _, _) =
              conversation.messages[lastIndex].streamSegments[existingIdx]
            {
              return lab
            }
            return resolvedLabel
          }()
          let doneStatuses: Set<String> = ["done", "complete", "completed", "error", "failed"]
          let isDone = doneStatuses.contains(status.lowercased())
          let wasRunning = conversation.messages[lastIndex].streamSegments[existingIdx]
            .isRunningProgress
          // Seal the running label, then append the done label as a new beat so the
          // feed reads Looking up → Found → Sending (not a single overwritten line).
          if isDone, wasRunning,
            previousLabel != resolvedLabel,
            !previousLabel.isEmpty
          {
            conversation.messages[lastIndex].streamSegments[existingIdx] = .progress(
              id: existingId,
              label: previousLabel,
              tool: toolKey
                ?? conversation.messages[lastIndex].streamSegments[existingIdx].progressTool,
              status: "complete"
            )
            conversation.messages[lastIndex].streamSegments.append(
              .progress(
                id: "\(stableId)-done",
                label: resolvedLabel,
                tool: toolKey,
                status: status
              )
            )
          } else {
            conversation.messages[lastIndex].streamSegments[existingIdx] = .progress(
              id: existingId,
              label: resolvedLabel,
              tool: toolKey
                ?? conversation.messages[lastIndex].streamSegments[existingIdx].progressTool,
              status: status
            )
          }
        } else {
          conversation.messages[lastIndex].streamSegments.append(
            .progress(
              id: stableId,
              label: resolvedLabel,
              tool: toolKey,
              status: status
            )
          )
        }
        // Thread-start placeholder is done once real tool/work progress arrives.
        if toolKey != nil, toolKey != "thread_start" {
          if let startIdx = conversation.messages[lastIndex].streamSegments.firstIndex(where: {
            $0.progressTool == "thread_start" && $0.isRunningProgress
          }) {
            conversation.messages[lastIndex].streamSegments[startIdx] = .progress(
              id: "thread-start",
              label: "Working…",
              tool: "thread_start",
              status: "complete"
            )
          }
        }
      }
      rebuildChatRows(scrollToBottom: false, animated: false)
    case "thinking":
      // Reasoning stream. The node itself already arrived via captureServerProgressNodes
      // (kind "thinking" + tokens + durationMs), so this only keeps the turn alive and moves
      // the header to "Thinking…".
      scheduleStreamingTimeout()
      setHeaderActivityState(from: frame.payload, fallback: "thinking")
      rebuildChatRows(scrollToBottom: false, animated: false)
    case "subagent":
      NSLog("[ChatNativeAgent] subagent event=%@", (frame.payload["event"] as? String) ?? "unknown")
      scheduleStreamingTimeout()
      setHeaderActivityState(from: frame.payload, fallback: "working")
      handleSubagentEvent(frame.payload)
    case "agent_cards":
      scheduleStreamingTimeout()
      handleAgentCardsEvent(frame.payload)
    case "builder_state":
      scheduleStreamingTimeout()
      handleBuilderStateEvent(frame.payload)
    case "ui_request":
      scheduleStreamingTimeout()
      handleBuilderUiRequestEvent(frame.payload)
    case "review_ready":
      scheduleStreamingTimeout()
      handleBuilderReviewReadyEvent(frame.payload)
    case "ack":
      NSLog("[ChatNativeAgent] ack received conv=%@", (frame.payload["conversation_id"] as? String) ?? "nil")
      if let conversationId = frame.payload["conversation_id"] as? String {
        applyAcknowledgedConversationId(conversationId)
      }
    case "rich_outputs":
      handleRichOutputsEvent(frame.payload)
    case "done":
      setHeaderActivityState(from: frame.payload, fallback: "ready")
      finishStreaming(
        fallbackText: nil,
        forceErrorText: false
      )
    case "error":
      setHeaderActivityState(from: frame.payload, fallback: "ready")
      let message = (frame.payload["message"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      finishStreaming(
        fallbackText:
          (message?.isEmpty == false ? message : "Something went wrong. Tap regenerate to retry."),
        forceErrorText: true
      )
    case "title_updated":
      let conversationId = (frame.payload["conversation_id"] as? String) ?? ""
      let title = (frame.payload["title"] as? String) ?? ""
      guard !conversationId.isEmpty else { return }
      updateConversation(conversationId) { conversation in
        conversation.title = title
      }
      persistState()
      refreshHistoryList()
    default:
      break
    }
  }

  /// Server pushes finalized non-text artifacts after text completion and before
  /// (or around) `done`. Never interleave into the streaming text row — buffer
  /// while the turn is still open, then persist and render as separate rows.
  private func handleRichOutputsEvent(_ payload: [String: Any]) {
    let conversationId =
      Self.normalizedString(payload["conversation_id"] ?? payload["conversationId"])
      ?? streamingConversationId
      ?? activeConversationId
    guard let conversationId, !conversationId.isEmpty else {
      NSLog("[ChatNativeAgent] rich_outputs dropped: no conversation id")
      return
    }

    if streamingConversationId == conversationId {
      var pending = pendingRichOutputsByConversation[conversationId] ?? []
      pending.append(payload)
      pendingRichOutputsByConversation[conversationId] = pending
      NSLog(
        "[ChatNativeAgent] rich_outputs buffered until settle conv=%@",
        String(conversationId.prefix(8))
      )
      return
    }

    applyRichOutputsPayload(payload, conversationId: conversationId)
  }

  private func flushPendingRichOutputs(for conversationId: String) {
    let pending = pendingRichOutputsByConversation.removeValue(forKey: conversationId) ?? []
    for payload in pending {
      applyRichOutputsPayload(payload, conversationId: conversationId)
    }
  }

  private func applyRichOutputsPayload(_ payload: [String: Any], conversationId: String) {
    let parsed = Self.parseRichOutputs(from: payload)
    guard !parsed.isEmpty else {
      NSLog("[ChatNativeAgent] rich_outputs empty after parse")
      return
    }

    let assistantMessageId =
      conversation(for: conversationId)?.messages.last(where: { $0.role == .assistant })?.id

    updateConversation(conversationId) { conversation in
      var existingById = Dictionary(
        uniqueKeysWithValues: conversation.richOutputs.map { ($0.id, $0) })
      for var output in parsed {
        if output.assistantMessageId == nil {
          output.assistantMessageId = assistantMessageId
        }
        existingById[output.id] = output
      }
      conversation.richOutputs = existingById.values.sorted {
        if $0.agentPartIndex != $1.agentPartIndex {
          return $0.agentPartIndex < $1.agentPartIndex
        }
        return $0.timestampMs < $1.timestampMs
      }
      conversation.updatedAt = Self.nowMs()
    }

    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: true, animated: false)
  }

  private static func parseRichOutputs(from payload: [String: Any]) -> [ChatNativeAgentRichOutput] {
    let rawItems: [[String: Any]] = {
      if let outputs = payload["outputs"] as? [[String: Any]] { return outputs }
      if let outputs = payload["rich_outputs"] as? [[String: Any]] { return outputs }
      if let outputs = payload["richOutputs"] as? [[String: Any]] { return outputs }
      if let items = payload["items"] as? [[String: Any]] { return items }
      if let parts = payload["parts"] as? [[String: Any]] { return parts }
      return []
    }()

    let baseTimestamp =
      parseTimestampMs(payload["timestamp"] ?? payload["timestampMs"] ?? payload["timestamp_ms"])
      ?? nowMs()

    var results: [ChatNativeAgentRichOutput] = []
    results.reserveCapacity(rawItems.count)

    for (fallbackIndex, item) in rawItems.enumerated() {
      guard let output = parseRichOutputItem(item, fallbackIndex: fallbackIndex, baseTimestamp: baseTimestamp)
      else { continue }
      // Text is already streamed as the assistant row — never re-emit as rich.
      if output.kind == "text" { continue }
      results.append(output)
    }

    return results.sorted {
      if $0.agentPartIndex != $1.agentPartIndex {
        return $0.agentPartIndex < $1.agentPartIndex
      }
      return $0.timestampMs < $1.timestampMs
    }
  }

  private static func parseRichOutputItem(
    _ item: [String: Any],
    fallbackIndex: Int,
    baseTimestamp: Int64
  ) -> ChatNativeAgentRichOutput? {
    let metadataRaw =
      (item["metadata"] as? [String: Any])
      ?? (item["meta"] as? [String: Any])
      ?? [:]

    func anyValue(_ keys: [String]) -> Any? {
      for key in keys {
        if let value = item[key] { return value }
        if let value = metadataRaw[key] { return value }
      }
      return nil
    }

    let kind =
      (normalizedString(anyValue(["type", "kind", "agentPartKind", "agent_part_kind"])) ?? "file")
      .lowercased()

    let partIndex =
      parseInt(anyValue(["agentPartIndex", "agent_part_index", "partIndex", "part_index", "index"]))
      ?? fallbackIndex

    let partId =
      normalizedString(
        anyValue([
          "agentPartId", "agent_part_id", "id", "messageId", "message_id", "trackId", "track_id",
        ]))
      ?? "rich-\(partIndex)-\(fallbackIndex)"

    let mediaUrl = normalizedString(
      anyValue([
        "mediaUrl", "media_url", "previewUrl", "preview_url", "streamUrl", "stream_url", "uri",
        "audioUrl", "audio_url", "url",
      ]))

    let title =
      normalizedString(anyValue(["title", "name", "fileName", "file_name"]))
      ?? normalizedString(anyValue(["text", "content", "fallbackText", "fallback_text"]))
      ?? (kind == "music" ? "Music" : kind.capitalized)

    let artist = normalizedString(anyValue(["artist", "subtitle", "channel"]))
    let album = normalizedString(anyValue(["album"]))
    let cover = normalizedString(anyValue(["cover", "thumbnail", "artwork", "image"]))
    let source = normalizedString(anyValue(["source"]))
    let videoId = normalizedString(anyValue(["videoId", "video_id"]))
    let trackId =
      normalizedString(anyValue(["trackId", "track_id", "id"]))
      ?? partId

    let durationSeconds = parseFlexibleDurationSeconds(
      anyValue(["durationSeconds", "duration_seconds", "duration"]))
    let durationLabel =
      normalizedString(anyValue(["duration"]))
      ?? durationSeconds.map { formatDurationLabel(seconds: $0) }

    let text =
      normalizedString(anyValue(["text", "content", "fallbackText", "fallback_text"]))
      ?? title

    let timestampMs =
      parseTimestampMs(anyValue(["timestamp", "timestampMs", "timestamp_ms"]))
      ?? (baseTimestamp + Int64(partIndex))

    var metadata: [String: Any] = metadataRaw
    // Normalize music + batch keys into both cases so ChatListViewModels / store
    // parsers can read either shape.
    metadata["trackId"] = trackId
    metadata["track_id"] = trackId
    if let videoId {
      metadata["videoId"] = videoId
      metadata["video_id"] = videoId
    }
    metadata["title"] = title
    if let artist {
      metadata["artist"] = artist
    }
    if let album {
      metadata["album"] = album
    }
    if let durationLabel {
      metadata["duration"] = durationLabel
    }
    if let durationSeconds {
      metadata["durationSeconds"] = durationSeconds
      metadata["duration_seconds"] = durationSeconds
    }
    if let cover {
      metadata["cover"] = cover
    }
    if let source {
      metadata["source"] = source
    }
    if let mediaUrl {
      metadata["previewUrl"] = mediaUrl
      metadata["preview_url"] = mediaUrl
      metadata["streamUrl"] = mediaUrl
      metadata["stream_url"] = mediaUrl
      metadata["mediaUrl"] = mediaUrl
      metadata["media_url"] = mediaUrl
    }
    if let links = item["links"] as? [String: Any] ?? metadataRaw["links"] as? [String: Any] {
      metadata["links"] = links
    }

    // Batch / turn identity (frozen contract).
    if let value = normalizedString(anyValue(["agentTurnId", "agent_turn_id"])) {
      metadata["agentTurnId"] = value
      metadata["agent_turn_id"] = value
    }
    if let value = normalizedString(anyValue(["agentBatchId", "agent_batch_id"])) {
      metadata["agentBatchId"] = value
      metadata["agent_batch_id"] = value
    }
    metadata["agentPartId"] = partId
    metadata["agent_part_id"] = partId
    metadata["agentPartIndex"] = partIndex
    metadata["agent_part_index"] = partIndex
    if let count = parseInt(anyValue(["agentPartCount", "agent_part_count"])) {
      metadata["agentPartCount"] = count
      metadata["agent_part_count"] = count
    }
    metadata["agentPartKind"] = kind
    metadata["agent_part_kind"] = kind
    metadata["agentFinalized"] = true
    metadata["agent_finalized"] = true

    if let assistantId = normalizedString(
      anyValue(["assistantMessageId", "assistant_message_id", "parentMessageId", "parent_message_id"])
    ) {
      metadata["assistantMessageId"] = assistantId
    }

    let messageType: String
    switch kind {
    case "music", "audio", "mp3":
      messageType = "music"
    case "question", "ask_user", "ask-user":
      messageType = "question"
    default:
      messageType = kind
    }

    // Music rows require a playable URL for the audio cell + queue registry.
    if messageType == "music", mediaUrl == nil {
      if let videoId, !videoId.isEmpty {
        let fallback = "https://api.vibegram.io/api/music/stream/\(videoId)"
        return ChatNativeAgentRichOutput(
          id: partId,
          agentPartIndex: partIndex,
          kind: messageType,
          mediaUrl: fallback,
          text: text,
          fileName: title,
          durationSeconds: durationSeconds,
          timestampMs: timestampMs,
          assistantMessageId: normalizedString(
            anyValue([
              "assistantMessageId", "assistant_message_id", "parentMessageId", "parent_message_id",
            ])),
          metadata: {
            var m = metadata
            m["previewUrl"] = fallback
            m["preview_url"] = fallback
            m["streamUrl"] = fallback
            m["stream_url"] = fallback
            m["mediaUrl"] = fallback
            m["media_url"] = fallback
            return m
          }()
        )
      }
      NSLog("[ChatNativeAgent] skip music rich output without mediaUrl id=%@", partId)
      return nil
    }

    return ChatNativeAgentRichOutput(
      id: partId,
      agentPartIndex: partIndex,
      kind: messageType,
      mediaUrl: mediaUrl,
      text: text,
      fileName: title,
      durationSeconds: durationSeconds,
      timestampMs: timestampMs,
      assistantMessageId: normalizedString(
        anyValue([
          "assistantMessageId", "assistant_message_id", "parentMessageId", "parent_message_id",
        ])),
      metadata: metadata
    )
  }

  private static func parseInt(_ raw: Any?) -> Int? {
    if let value = raw as? Int { return value }
    if let value = raw as? NSNumber { return value.intValue }
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return Int(trimmed)
    }
    return nil
  }

  private static func parseFlexibleDurationSeconds(_ raw: Any?) -> Double? {
    if let value = raw as? Double, value.isFinite {
      return value > 10_000 ? value / 1000.0 : value
    }
    if let value = raw as? NSNumber {
      let doubleValue = value.doubleValue
      guard doubleValue.isFinite else { return nil }
      // Heuristic: values that look like milliseconds.
      return doubleValue > 10_000 ? doubleValue / 1000.0 : doubleValue
    }
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if let number = Double(trimmed) {
        return number > 10_000 ? number / 1000.0 : number
      }
      // mm:ss or h:mm:ss
      let parts = trimmed.split(separator: ":").compactMap { Double($0) }
      if parts.count == 2 {
        return parts[0] * 60.0 + parts[1]
      }
      if parts.count == 3 {
        return parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
      }
    }
    return nil
  }

  private static func formatDurationLabel(seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }

  private func handleSubagentEvent(_ payload: [String: Any]) {
    let label = Self.normalizedString(payload["label"]) ?? "Specialist"
    let event = Self.normalizedString(payload["event"]) ?? ""
    let detail = Self.normalizedString(payload["detail"])
    let status = Self.normalizedString(payload["status"]) ?? ""

    let nextLabel: String
    let segmentStatus: String
    switch event {
    case "started":
      nextLabel = "Starting \(label)..."
      segmentStatus = "running"
    case "progress":
      nextLabel = detail ?? "\(label) is working..."
      segmentStatus = "running"
    case "finished":
      nextLabel = status == "error" ? "\(label) failed." : "\(label) completed."
      segmentStatus = status == "error" ? "error" : "complete"
    default:
      nextLabel = detail ?? "Working..."
      segmentStatus = "running"
    }

    guard let conversationId = streamingConversationId ?? activeConversationId else { return }
    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }

      let toolKey = "subagent_\(label)"
      if let existingIdx = conversation.messages[lastIndex].streamSegments.firstIndex(where: {
        $0.progressTool == toolKey
      }) {
        let existingId = conversation.messages[lastIndex].streamSegments[existingIdx].progressId
          ?? UUID().uuidString
        conversation.messages[lastIndex].streamSegments[existingIdx] = .progress(
          id: existingId,
          label: nextLabel,
          tool: toolKey,
          status: segmentStatus
        )
      } else {
        conversation.messages[lastIndex].streamSegments.append(
          .progress(
            id: UUID().uuidString,
            label: nextLabel,
            tool: toolKey,
            status: segmentStatus
          )
        )
      }
    }
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func handleAgentCardsEvent(_ payload: [String: Any]) {
    let groupId =
      Self.normalizedString(payload["group_id"])
      ?? Self.normalizedString(payload["groupId"])
      ?? "builder:cards"
    let rawCards = (payload["cards"] as? [[String: Any]]) ?? []
    let cards = rawCards.compactMap(ChatListRow.AgentCard.parse).map(resolvedAgentCard)
    guard !cards.isEmpty else { return }
    guard let conversationId = streamingConversationId ?? activeConversationId else { return }

    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }

      conversation.messages[lastIndex].streamSegments.removeAll {
        if case .cards(let existingGroupId, _) = $0 {
          return existingGroupId == groupId
        }
        return false
      }
      conversation.messages[lastIndex].streamSegments.append(
        .cards(groupId: groupId, cards: cards)
      )
      conversation.updatedAt = Self.nowMs()
    }
    persistState()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func handleBuilderStateEvent(_ payload: [String: Any]) {
    if let activeAgentId = Self.normalizedString(payload["activeAgentId"] ?? payload["active_agent_id"])
    {
      builderActiveAgentId = activeAgentId
    }
    if let latestSecret = Self.normalizedString(payload["latestSecret"] ?? payload["latest_secret"])
    {
      builderLatestSecret = latestSecret
    }
    cacheBuilderSecretIfPossible()

    if let setupState = ChatBuilderSetupState(raw: payload["setupState"] as? [String: Any]) {
      builderSetupState = setupState
    }
    builderActivity =
      ((payload["activity"] as? [[String: Any]]) ?? [])
      .compactMap(ChatBuilderActivityItem.init(raw:))
  }

  private func cacheBuilderSecretIfPossible() {
    guard
      let agentId = builderActiveAgentId,
      let latestSecret = builderLatestSecret,
      !latestSecret.isEmpty
    else { return }

    cachedAgentSecrets[agentId] = latestSecret
  }

  private func resolvedAgentCard(_ card: ChatListRow.AgentCard) -> ChatListRow.AgentCard {
    if let latestSecret = Self.normalizedString(card.latestSecret), !latestSecret.isEmpty {
      cachedAgentSecrets[card.agentId] = latestSecret
      return card
    }

    if let cachedSecret = cachedAgentSecrets[card.agentId], !cachedSecret.isEmpty {
      return ChatListRow.AgentCard(
        id: card.id,
        style: card.style,
        agentId: card.agentId,
        agentUserId: card.agentUserId,
        displayName: card.displayName,
        username: card.username,
        identifier: card.identifier,
        avatarUrl: card.avatarUrl,
        status: card.status,
        promptStatus: card.promptStatus,
        promptPreview: card.promptPreview,
        systemPrompt: card.systemPrompt,
        modelProvider: card.modelProvider,
        modelId: card.modelId,
        enabledTools: card.enabledTools,
        outputModes: card.outputModes,
        voiceProfile: card.voiceProfile,
        voiceProvider: card.voiceProvider,
        callbackURL: card.callbackURL,
        apiBaseURL: card.apiBaseURL,
        invokeURL: card.invokeURL,
        eventsURL: card.eventsURL,
        builderLink: card.builderLink,
        agentDMURL: card.agentDMURL,
        secretHint: card.secretHint,
        latestSecret: cachedSecret,
        defaultDestinationChat: card.defaultDestinationChat,
        attachedChats: card.attachedChats,
        eventInboxMode: card.eventInboxMode,
        summaryWindowHours: card.summaryWindowHours,
        summarySchedule: card.summarySchedule,
        summaryTimes: card.summaryTimes,
        incomingChatEnabled: card.incomingChatEnabled,
        canDelete: card.canDelete
      )
    }

    guard
      card.latestSecret == nil,
      let activeAgentId = builderActiveAgentId,
      let latestSecret = builderLatestSecret,
      card.agentId == activeAgentId
    else {
      return card
    }

    cachedAgentSecrets[activeAgentId] = latestSecret

    return ChatListRow.AgentCard(
      id: card.id,
      style: card.style,
      agentId: card.agentId,
      agentUserId: card.agentUserId,
      displayName: card.displayName,
      username: card.username,
      identifier: card.identifier,
      avatarUrl: card.avatarUrl,
      status: card.status,
      promptStatus: card.promptStatus,
      promptPreview: card.promptPreview,
      systemPrompt: card.systemPrompt,
      modelProvider: card.modelProvider,
      modelId: card.modelId,
      enabledTools: card.enabledTools,
      outputModes: card.outputModes,
      voiceProfile: card.voiceProfile,
      voiceProvider: card.voiceProvider,
      callbackURL: card.callbackURL,
      apiBaseURL: card.apiBaseURL,
      invokeURL: card.invokeURL,
      eventsURL: card.eventsURL,
      builderLink: card.builderLink,
      agentDMURL: card.agentDMURL,
      secretHint: card.secretHint,
      latestSecret: latestSecret,
      defaultDestinationChat: card.defaultDestinationChat,
      attachedChats: card.attachedChats,
      eventInboxMode: card.eventInboxMode,
      summaryWindowHours: card.summaryWindowHours,
      summarySchedule: card.summarySchedule,
      summaryTimes: card.summaryTimes,
      incomingChatEnabled: card.incomingChatEnabled,
      canDelete: card.canDelete
    )
  }

  private func handleBuilderUiRequestEvent(_ payload: [String: Any]) {
    handleBuilderStateEvent(payload)

    guard let request = ChatBuilderUiRequest(raw: payload["pendingUiRequest"] as? [String: Any])
    else { return }

    if let navigationController = builderQuestionNavigationController,
      navigationController.presentingViewController != nil
    {
      queuedBuilderQuestionRequest = request
      return
    }
    presentBuilderQuestionPanel(request)
  }

  private func handleBuilderReviewReadyEvent(_ payload: [String: Any]) {
    handleBuilderStateEvent(payload)
  }

  private func presentBuilderQuestionPanel(_ request: ChatBuilderUiRequest) {
    if let navigationController = builderQuestionNavigationController,
      navigationController.presentingViewController != nil
    {
      return
    }

    guard let presenter = topMostViewController() else { return }

    let controller = ChatBuilderPanelController(
      mode: .request(request),
      theme: currentBuilderPanelTheme(),
      setupState: builderSetupState,
      activity: builderActivity,
      agentEnabled: nil
    )
    controller.onSubmitRequest = { [weak self] requestId, answers, summary in
      self?.submitBuilderUiResponse(requestId: requestId, answers: answers, summary: summary)
    }
    controller.onControllerDismissed = { [weak self] in
      guard let self else { return }
      self.builderQuestionNavigationController = nil
      guard let queuedRequest = self.queuedBuilderQuestionRequest else { return }
      self.queuedBuilderQuestionRequest = nil
      DispatchQueue.main.async { [weak self] in
        self?.presentBuilderQuestionPanel(queuedRequest)
      }
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.selectedDetentIdentifier = .medium
      sheet.prefersGrabberVisible = false
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.prefersEdgeAttachedInCompactHeight = true
      sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      sheet.preferredCornerRadius = 28.0
    }

    builderQuestionNavigationController = navigationController
    presenter.present(navigationController, animated: true)
  }

  private func syncConversations() {
    sendChannelEvent(event: "list_conversations", payload: [:]) { [weak self] status, response in
      guard let self, status == "ok" else { return }
      let remoteItems = (response["conversations"] as? [[String: Any]]) ?? []
      let localConversations = self.conversations

      var merged: [ChatNativeAgentConversation] = remoteItems.compactMap { item in
        guard let id = Self.normalizedString(item["id"]) else { return nil }
        let title = Self.normalizedString(item["title"]) ?? "New Chat"
        let existing = localConversations.first(where: { $0.id == id })
        return ChatNativeAgentConversation(
          id: id,
          title: title,
          createdAt: Self.parseTimestampMs(item["inserted_at"]) ?? Self.nowMs(),
          updatedAt: Self.parseTimestampMs(item["updated_at"]) ?? Self.nowMs(),
          messages: existing?.messages ?? [],
          richOutputs: existing?.richOutputs ?? []
        )
      }

      if let activeConversationId,
        !merged.contains(where: { $0.id == activeConversationId }),
        let localActive = localConversations.first(where: { $0.id == activeConversationId })
      {
        merged.insert(localActive, at: 0)
      }

      merged.sort { $0.createdAt > $1.createdAt }
      self.conversations = merged
      // Keep the current session in view. Only fall back to the newest remote
      // conversation when we have no active id (first open). New Chat sets a
      // local active id so we never wipe the open list unless the user asked.
      if self.activeConversationId == nil {
        self.activeConversationId = merged.first?.id
      } else if let activeId = self.activeConversationId,
        !merged.contains(where: { $0.id == activeId }),
        let localActive = localConversations.first(where: { $0.id == activeId })
      {
        // Local-only active (e.g. brand-new chat not on server yet) — keep it.
        self.conversations.insert(localActive, at: 0)
      }

      self.persistState()
      self.refreshHistoryList()
      self.rebuildChatRows(scrollToBottom: false, animated: false)

      if let activeConversationId,
        self.conversation(for: activeConversationId)?.messages.isEmpty == true
      {
        self.loadConversation(id: activeConversationId)
      }
    }
  }

  private func regenerateAssistantResponse(sourceMessageId: String) {
    let assistantMessageId = sourceMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !assistantMessageId.isEmpty else { return }

    connectIfNeeded()

    guard let conversationId = activeConversationId else { return }
    guard let conversation = conversation(for: conversationId) else { return }
    guard let assistantIndex = conversation.messages.firstIndex(where: { $0.id == assistantMessageId })
    else { return }
    guard conversation.messages[assistantIndex].role == .assistant else { return }
    guard assistantIndex > 0 else { return }

    var userText = ""
    for index in stride(from: assistantIndex - 1, through: 0, by: -1) {
      let candidate = conversation.messages[index]
      guard candidate.role == .user else { continue }
      userText = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !userText.isEmpty {
        break
      }
    }
    guard !userText.isEmpty else { return }

    let timestampMs = Self.nowMs()
    let assistantMessage = ChatNativeAgentMessage(
      id: UUID().uuidString,
      role: .assistant,
      content: "",
      timestampMs: timestampMs,
      isStreaming: true,
      streamSegments: []
    )

    updateConversation(conversationId) { conversation in
      let keptMessageIds = Set(
        conversation.messages.prefix(assistantIndex).map(\.id)
      )
      conversation.messages = Array(conversation.messages.prefix(assistantIndex))
      conversation.messages.append(assistantMessage)
      // Drop rich rows that belonged to the regenerated turn (or later).
      conversation.richOutputs.removeAll { output in
        guard let parentId = output.assistantMessageId else {
          // Unlinked artifacts after the truncation point are removed by id collision
          // only when they shared the regenerated assistant id as their own id prefix.
          return output.id == assistantMessageId
            || output.id.hasPrefix("\(assistantMessageId)-")
        }
        return !keptMessageIds.contains(parentId)
      }
      conversation.updatedAt = timestampMs
    }
    pendingRichOutputsByConversation.removeValue(forKey: conversationId)

    streamingConversationId = conversationId
    notifyStreamingStateChanged()
    setHeaderActivityState(fallback: "thinking")
    currentSpacerHeight = 0.0
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: true, animated: true)
    scheduleStreamingTimeout()
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

    if joinedTopic {
      pushMessage(text: userText, conversationId: conversationId, truncateAtId: assistantMessageId)
    } else {
      pendingSends.append(
        .message(
          conversationId: conversationId,
          text: userText,
          truncateAtId: assistantMessageId,
          modelProvider: selectedModelProvider,
          modelId: selectedModelId,
          thinkingLevel: selectedThinkingLevel
        ))
    }
  }

  private func loadConversation(id: String) {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    sendChannelEvent(event: "get_conversation", payload: ["id": id]) {
      [weak self] status, response in
      guard let self, status == "ok" else { return }

      let conversationPayload: [String: Any]
      if let nested = response["conversation"] as? [String: Any] {
        conversationPayload = nested
      } else {
        conversationPayload = response
      }

      let rawMessages = (conversationPayload["messages"] as? [[String: Any]]) ?? []
      var messages = rawMessages.compactMap(Self.parseServerMessage)
      // Preserve local v2 turn structure across server rehydrate (server only has thin text).
      let localById: [String: ChatNativeAgentMessage] = {
        guard let existing = self.conversation(for: id) else { return [:] }
        return Dictionary(uniqueKeysWithValues: existing.messages.map { ($0.id, $0) })
      }()
      messages = messages.map { serverMessage in
        var merged = serverMessage
        if let local = localById[serverMessage.id],
          let version = local.agentTurnStructureVersion, version >= 2,
          let nodesJSON = local.settledProgressNodesJSON, !nodesJSON.isEmpty
        {
          merged.settledProgressNodesJSON = nodesJSON
          merged.agentTurnStructureVersion = version
          // Keep richer local streamSegments when the server only sent final content.
          if local.streamSegments.count > serverMessage.streamSegments.count {
            merged.streamSegments = local.streamSegments
          }
        } else if let nodesJSON = Self.loadLocalTurnStructureData(messageId: serverMessage.id) {
          merged.settledProgressNodesJSON = nodesJSON
          merged.agentTurnStructureVersion = 2
        }
        return merged
      }
      // History may already include finalized music/question rows as normal messages.
      let historyRich = rawMessages.compactMap(Self.parseServerRichOutputMessage)
        + rawMessages.flatMap(Self.parseNestedServerRichOutputs)
      let payloadRich = Self.parseRichOutputs(from: conversationPayload)

      self.updateConversation(id) { conversation in
        conversation.messages = messages.sorted { $0.timestampMs < $1.timestampMs }
        var mergedById = Dictionary(
          uniqueKeysWithValues: conversation.richOutputs.map { ($0.id, $0) })
        for output in historyRich + payloadRich {
          mergedById[output.id] = output
        }
        // Drop rich rows that duplicate a text message id still present in messages.
        let messageIds = Set(conversation.messages.map(\.id))
        conversation.richOutputs = mergedById.values
          .filter { !messageIds.contains($0.id) || $0.kind != "text" }
          .sorted {
            if $0.agentPartIndex != $1.agentPartIndex {
              return $0.agentPartIndex < $1.agentPartIndex
            }
            return $0.timestampMs < $1.timestampMs
          }
        conversation.updatedAt = Self.nowMs()
      }
      self.persistState()
      self.refreshHistoryList()
      self.rebuildChatRows(scrollToBottom: false, animated: false)
    }
  }

  private func pushMessage(
    text: String,
    conversationId: String,
    truncateAtId: String?,
    modelProvider: String? = nil,
    modelId: String? = nil,
    thinkingLevel: String? = nil
  ) {
    var payload: [String: Any] = [
      "text": text,
      "images": [],
      "conversation_id": conversationId,
      "model_provider": modelProvider ?? selectedModelProvider,
      "model_id": modelId ?? selectedModelId,
      "thinking_level": thinkingLevel ?? selectedThinkingLevel,
    ]
    if let truncateAtId, !truncateAtId.isEmpty {
      payload["truncate_at_id"] = truncateAtId
    }
    NSLog("[ChatNativeAgent] pushing message conv=%@ joined=%@ len=%d",
      conversationId, joinedTopic ? "true" : "false", text.count)
    sendChannelEvent(event: "message", payload: payload) { status, response in
      NSLog("[ChatNativeAgent] message push reply status=%@ response=%@", status, "\(response)")
    }
  }

  private func flushPendingSends() {
    guard joinedTopic else { return }
    let queued = pendingSends
    pendingSends.removeAll()
    for pending in queued {
      switch pending {
      case .message(
        let conversationId,
        let text,
        let truncateAtId,
        let modelProvider,
        let modelId,
        let thinkingLevel
      ):
        pushMessage(
          text: text,
          conversationId: conversationId,
          truncateAtId: truncateAtId,
          modelProvider: modelProvider,
          modelId: modelId,
          thinkingLevel: thinkingLevel
        )

      case .builderUiResponse(let conversationId, let uiResponse, let summary):
        pushBuilderUiResponse(
          conversationId: conversationId,
          uiResponse: uiResponse,
          summary: summary
        )
      }
    }
  }

  private func sendChannelEvent(
    event: String,
    payload: [String: Any],
    reply: @escaping (String, [String: Any]) -> Void
  ) {
    guard let client = phoenixClient, !topic.isEmpty else { return }
    let ref = client.push(topic: topic, event: event, payload: payload)
    pendingReplies[ref] = reply
  }

  /// Store the server's ordered node container on the streaming assistant message.
  /// Authoritative when present — see `ChatNativeAgentMessage.serverProgressNodesJSON`.
  private func captureServerProgressNodes(from payload: [String: Any]) {
    let raw =
      (payload["progressNodes"] as? [[String: Any]])
      ?? (payload["progress_nodes"] as? [[String: Any]])
    guard let raw, !raw.isEmpty else { return }
    guard JSONSerialization.isValidJSONObject(raw),
      let data = try? JSONSerialization.data(withJSONObject: raw, options: [])
    else { return }
    guard let conversationId = streamingConversationId ?? activeConversationId else { return }

    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }
      conversation.messages[lastIndex].serverProgressNodesJSON = data
    }
  }

  /// Nodes the server sent for this turn, if any.
  private static func serverProgressNodes(
    from message: ChatNativeAgentMessage
  ) -> [[String: Any]]? {
    guard let data = message.serverProgressNodesJSON, !data.isEmpty,
      let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      !nodes.isEmpty
    else { return nil }
    return nodes
  }

  private static func isTextNode(_ node: [String: Any]) -> Bool {
    let kind = (node["kind"] as? String) ?? (node["itemType"] as? String) ?? ""
    return kind == "text"
  }

  private func appendChunk(_ chunk: String) {
    guard let conversationId = streamingConversationId ?? activeConversationId else {
      NSLog("[ChatNativeAgent] appendChunk: no active conversation, dropping chunk len=%d", chunk.count)
      return
    }
    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else {
        NSLog("[ChatNativeAgent] appendChunk: no messages in conversation")
        return
      }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else {
        NSLog("[ChatNativeAgent] appendChunk: last message is not assistant")
        return
      }
      conversation.messages[lastIndex].content += chunk
      conversation.messages[lastIndex].isStreaming = true
      conversation.updatedAt = Self.nowMs()

      // Append to the last .text segment (skip over any trailing card segments),
      // or create a new one. This preserves ordering: if the last non-card segment
      // was a progress, a new text block starts AFTER it.
      let lastTextOrProgressIndex = conversation.messages[lastIndex].streamSegments.lastIndex(where: {
        switch $0 {
        case .text: return true
        case .progress: return true
        case .cards: return false
        }
      })
      if let lastIdx = lastTextOrProgressIndex,
         case .text(let existing) = conversation.messages[lastIndex].streamSegments[lastIdx] {
        conversation.messages[lastIndex].streamSegments[lastIdx] = .text(existing + chunk)
      } else {
        // Insert before any trailing card segments
        let insertIndex = lastTextOrProgressIndex.map { $0 + 1 } ?? conversation.messages[lastIndex].streamSegments.count
        conversation.messages[lastIndex].streamSegments.insert(.text(chunk), at: min(insertIndex, conversation.messages[lastIndex].streamSegments.count))
      }

      NSLog("[ChatNativeAgent] appendChunk: content_len=%d segments=%d chunk_len=%d",
            conversation.messages[lastIndex].content.count,
            conversation.messages[lastIndex].streamSegments.count,
            chunk.count)
    }
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func applyAcknowledgedConversationId(_ serverConversationId: String) {
    guard let currentId = activeConversationId, currentId != serverConversationId else {
      if streamingConversationId != nil {
        streamingConversationId = serverConversationId
      }
      return
    }

    guard let index = conversations.firstIndex(where: { $0.id == currentId }) else {
      activeConversationId = serverConversationId
      streamingConversationId = serverConversationId
      return
    }

    conversations[index].id = serverConversationId
    activeConversationId = serverConversationId
    streamingConversationId = serverConversationId
    pendingSends = pendingSends.map {
      $0.conversationId == currentId ? $0.withConversationId(serverConversationId) : $0
    }
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func finishStreaming(
    fallbackText: String?,
    forceErrorText: Bool,
    markUserMessageFailed: Bool? = nil
  ) {
    streamingTimeoutWorkItem?.cancel()
    setHeaderActivityState(fallback: "ready")

    guard let conversationId = streamingConversationId ?? activeConversationId else {
      NSLog("[ChatNativeAgent] finishStreaming: no active conversation")
      return
    }
    // A failed/stopped turn marks the user's message as "not sent". Default to the
    // error flag so connection-loss / error / join-failure paths all light it up.
    let markFailed = markUserMessageFailed ?? forceErrorText
    NSLog("[ChatNativeAgent] finishStreaming conversationId=%@ fallback=%@ forceError=%d",
          String(conversationId.prefix(8)), fallbackText ?? "nil", forceErrorText ? 1 : 0)
    pendingSends.removeAll { $0.conversationId == conversationId }

    updateConversation(conversationId) { conversation in
      guard !conversation.messages.isEmpty else { return }
      let lastIndex = conversation.messages.count - 1
      guard conversation.messages[lastIndex].role == .assistant else { return }

      if forceErrorText, let fallbackText, conversation.messages[lastIndex].content.isEmpty {
        conversation.messages[lastIndex].content = fallbackText
      } else if conversation.messages[lastIndex].content.isEmpty, let fallbackText {
        conversation.messages[lastIndex].content = fallbackText
      }
      conversation.messages[lastIndex].isStreaming = false
      // Only an errored turn keeps the regenerate affordance; a clean/stopped
      // finish clears it.
      conversation.messages[lastIndex].isError = forceErrorText ? true : nil
      // Seal running progress as complete — do NOT wipe the step list (that is
      // what made the cell appear to clear when the answer settled).
      for (idx, segment) in conversation.messages[lastIndex].streamSegments.enumerated() {
        guard case .progress(let id, let label, let tool, let status) = segment,
          status == "running"
        else { continue }
        conversation.messages[lastIndex].streamSegments[idx] = .progress(
          id: id,
          label: label,
          tool: tool,
          status: forceErrorText ? "error" : "complete"
        )
      }

      // Tag (or clear) the nearest preceding user message's delivered state.
      if let userIndex = conversation.messages[..<lastIndex].lastIndex(where: {
        $0.role == .user
      }) {
        conversation.messages[userIndex].deliveryFailed = markFailed ? true : nil
      }

      // Seal the full ordered turn structure (intro→note→summary) into the local
      // message so cold-open / server rehydrate keep the same feed the live turn had.
      // FROZEN: metadata["agentTurnStructureVersion"] = 2 + full progressNodes array.
      let sealed = Self.settledTurnStructure(from: conversation.messages[lastIndex])
      if let sealed {
        conversation.messages[lastIndex].settledProgressNodesJSON = sealed.nodesJSON
        conversation.messages[lastIndex].agentTurnStructureVersion = 2
        Self.persistLocalTurnStructure(
          messageId: conversation.messages[lastIndex].id,
          nodesJSON: sealed.nodesJSON
        )
      }

      conversation.updatedAt = Self.nowMs()
    }

    streamingConversationId = nil
    notifyStreamingStateChanged()
    // Rich artifacts are only committed after the text turn settles.
    flushPendingRichOutputs(for: conversationId)
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  func stopStreaming() {
    guard let conversationId = streamingConversationId else { return }

    isStoppingStreamManually = true
    pendingReplies.removeAll()
    pendingSends.removeAll { $0.conversationId == conversationId }

    finishStreaming(fallbackText: "Stopped.", forceErrorText: false, markUserMessageFailed: true)
    onNativeEvent(["type": "agentToast", "message": "Stopped response"])

    // Aborting a stream still means dropping the socket — that IS the abort mechanism.
    // Route it through the holder so its cached state can't outlive the connection.
    joinedTopic = false
    reconnectWorkItem?.cancel()
    ChatNativeAgentSocketHolder.shared.invalidate()
    phoenixClient = nil
    scheduleReconnect()
  }

  private func deleteAgent(_ card: ChatListRow.AgentCard, dismiss: @escaping () -> Void) {
    guard let config = resolveAPIConfig() else {
      onNativeEvent(["type": "agentToast", "message": "Missing API session"])
      return
    }

    let trimmedId = card.agentId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedId.isEmpty else { return }

    let path = "/api/agents/\(trimmedId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedId)"
    let url = URL(string: path, relativeTo: config.apiBaseURL) ?? config.apiBaseURL.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let cardTitle = card.displayName

    VibeHTTP.shared.dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgent] delete agent failed %@", error.localizedDescription)
          self.onNativeEvent(["type": "agentToast", "message": "Could not delete agent"])
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
          let body =
            data.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          NSLog(
            "[ChatNativeAgent] delete agent rejected status=%d body=%@",
            statusCode,
            body ?? "-"
          )
          self.onNativeEvent(["type": "agentToast", "message": "Delete failed"])
          return
        }

        self.removeAgentCards(agentId: trimmedId)
        dismiss()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.onNativeEvent(["type": "agentToast", "message": "Deleted \(cardTitle)"])
      }
    }.resume()
  }

  private func removeAgentCards(agentId: String) {
    let trimmedId = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedId.isEmpty else { return }

    for index in conversations.indices {
      var conversation = conversations[index]
      for messageIndex in conversation.messages.indices {
        var segments = conversation.messages[messageIndex].streamSegments
        var changed = false

        segments = segments.compactMap { segment in
          switch segment {
          case .cards(let groupId, let cards):
            let filtered = cards.filter { $0.agentId != trimmedId }
            if filtered.count != cards.count {
              changed = true
            }
            return filtered.isEmpty ? nil : .cards(groupId: groupId, cards: filtered)

          default:
            return segment
          }
        }

        if changed {
          conversation.messages[messageIndex].streamSegments = segments
        }
      }
      conversations[index] = conversation
    }

    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func scheduleStreamingTimeout() {
    streamingTimeoutWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      NSLog("[ChatNativeAgent] streaming timeout fired after 45s")
      self?.finishStreaming(
        fallbackText: "Response timed out. Tap retry to try again.",
        forceErrorText: true
      )
    }
    streamingTimeoutWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 45.0, execute: workItem)
  }

  private func createConversation(title: String) -> String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let conversation = ChatNativeAgentConversation(
      id: UUID().uuidString,
      title: trimmedTitle.isEmpty ? "New Chat" : trimmedTitle,
      createdAt: Self.nowMs(),
      updatedAt: Self.nowMs(),
      messages: []
    )
    conversations.insert(conversation, at: 0)
    activeConversationId = conversation.id
    currentSpacerHeight = 0
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)

    if joinedTopic {
      sendChannelEvent(event: "create_conversation", payload: ["title": conversation.title]) {
        [weak self] status, response in
        guard let self, status == "ok" else { return }
        guard let newId = Self.normalizedString(response["id"]) else { return }
        self.replaceConversationId(localId: conversation.id, serverId: newId)
      }
    }
    return conversation.id
  }

  private func replaceConversationId(localId: String, serverId: String) {
    guard let index = conversations.firstIndex(where: { $0.id == localId }) else { return }
    conversations[index].id = serverId
    if activeConversationId == localId {
      activeConversationId = serverId
    }
    if streamingConversationId == localId {
      streamingConversationId = serverId
    }
    pendingSends = pendingSends.map {
      $0.conversationId == localId ? $0.withConversationId(serverId) : $0
    }
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
  }

  private func deleteConversation(id: String) {
    conversations.removeAll(where: { $0.id == id })
    pendingRichOutputsByConversation.removeValue(forKey: id)
    if activeConversationId == id {
      activeConversationId = conversations.sorted { $0.createdAt > $1.createdAt }.first?.id
      currentSpacerHeight = 0

      if let activeConversationId,
        conversation(for: activeConversationId)?.messages.isEmpty == true
      {
        loadConversation(id: activeConversationId)
      }
    }
    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
    if joinedTopic {
      sendChannelEvent(event: "delete_conversation", payload: ["id": id]) { _, _ in }
    }
  }

  private func selectConversation(id: String) {
    guard activeConversationId != id else {
      setPage(.chat, animated: true)
      return
    }
    activeConversationId = id
    currentSpacerHeight = 0

    persistState()
    refreshHistoryList()
    rebuildChatRows(scrollToBottom: false, animated: false)
    if conversation(for: id)?.messages.isEmpty == true {
      loadConversation(id: id)
    }
    setPage(.chat, animated: true)
  }

  private func refreshHistoryList() {
    historyEmptyLabel.isHidden = !conversations.isEmpty
    historyTableView.reloadData()
  }

  private func rebuildChatRows(scrollToBottom: Bool, animated: Bool) {
    let topPadding = safeAreaInsets.top + 80.0
    let bottomPadding: CGFloat = 140.0

    guard let activeConversation = activeConversationId.flatMap({ conversation(for: $0) }) else {
      if !isTransportOnly {
        messagesView.setRows(
          [],
          topPadding: topPadding,
          spacerHeight: currentSpacerHeight,
          bottomPadding: bottomPadding,
          scrollToBottom: false,
          animated: false
        )
      }
      onRowsChanged?([])
      return
    }

    let rows = makeRawRows(for: activeConversation)
    // Hosted transport path: only push rows to ChatMainView — do not also
    // materialize a second full message list in this hidden view.
    if !isTransportOnly {
      messagesView.setRows(
        rows,
        topPadding: topPadding,
        spacerHeight: currentSpacerHeight,
        bottomPadding: bottomPadding,
        scrollToBottom: false,
        animated: animated
      )
    }
    onRowsChanged?(rows)

    guard scrollToBottom, !isTransportOnly else { return }
    DispatchQueue.main.async { [weak self] in
      self?.messagesView.scrollToBottom(animated: animated)
    }
  }

  private func makeRawRows(for conversation: ChatNativeAgentConversation) -> [[String: Any]] {
    let renderEntries = makeRenderEntries(for: conversation)
    let regeneratePromptByAssistantId = regeneratePromptMap(for: conversation)
    var rows: [[String: Any]] = []
    var lastDayKey: String?

    for index in renderEntries.indices {
      let entry = renderEntries[index]
      let dayKey = Self.dayKey(entry.timestampMs)
      if lastDayKey != dayKey {
        rows.append([
          "kind": "day",
          "key": "d-\(dayKey)",
          "label": Self.formatDayLabel(entry.timestampMs),
          "timestampMs": entry.timestampMs,
        ])
        lastDayKey = dayKey
      }

      let previous = index > 0 ? renderEntries[index - 1] : nil
      let next = index + 1 < renderEntries.count ? renderEntries[index + 1] : nil
      let isSequenceStart = previous?.role != entry.role
      let isSequenceEnd = next?.role != entry.role
      let shape = Self.makeBubbleShape(
        isMe: entry.role == .user,
        isSequenceStart: isSequenceStart,
        isSequenceEnd: isSequenceEnd,
        showTail: entry.showTail
      )

      var message: [String: Any] = [
        "id": entry.id,
        "text": entry.text,
        "timestamp": Self.formatTimeLabel(entry.timestampMs),
        "isMe": entry.role == .user,
        "type": entry.messageType,
        "bubbleShape": shape,
      ]

      if entry.deliveryFailed {
        message["deliveryFailed"] = true
      }

      if let mediaUrl = entry.mediaUrl, !mediaUrl.isEmpty {
        message["mediaUrl"] = mediaUrl
      }
      if let fileName = entry.fileName, !fileName.isEmpty {
        message["fileName"] = fileName
      }
      if let duration = entry.duration, duration.isFinite, duration > 0 {
        message["duration"] = duration
      }

      if entry.isAgentMessage {
        message["isAgentMessage"] = true
        message["agentName"] = "Vibe AI"
        message["plainContent"] = entry.text
        var metadata: [String: Any] = entry.metadata ?? [:]
        if let progressNodes = entry.progressNodes, !progressNodes.isEmpty {
          metadata["progressNodes"] = progressNodes
        }
        // FROZEN key+value: cold-open / merge prefer local v2 full structure over thin server.
        if let version = entry.agentTurnStructureVersion, version >= 2 {
          metadata["agentTurnStructureVersion"] = version
        }
        if let agentCard = entry.agentCard {
          metadata["agentCard"] = agentCard.rawValue
        }
        if entry.isError {
          message["isError"] = true
        }
        if entry.messageType == "text", let actionSourceMessageId = entry.actionSourceMessageId {
          metadata["sourceMessageId"] = actionSourceMessageId
          if let regeneratePrompt = regeneratePromptByAssistantId[actionSourceMessageId],
            !regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            metadata["regeneratePrompt"] = regeneratePrompt
          }
        }
        if entry.messageType == "text", let actionSourceText = entry.actionSourceText {
          metadata["sourceText"] = actionSourceText
        }
        if !metadata.isEmpty {
          message["metadata"] = metadata
        }
        if entry.isStreaming {
          message["isStreaming"] = true
        }
      } else if let metadata = entry.metadata, !metadata.isEmpty {
        message["metadata"] = metadata
      }

      rows.append([
        "kind": "message",
        "key": "m-\(entry.id)",
        "message": message,
      ])

      if entry.isAgentMessage, entry.isStreaming {
        NSLog(
          "[AgentGap] emit id=%@ type=%@ nodes=%d textLen=%d streaming=1",
          String(entry.id.suffix(12)), entry.messageType,
          entry.progressNodes?.count ?? 0,
          entry.text.trimmingCharacters(in: .whitespacesAndNewlines).count)
      }

      // The standalone bottom "agent_actions" row (copy/thumb/regenerate tab bar)
      // is intentionally not emitted anymore. Regenerate now lives on the agent
      // bubble itself — a side button + long-press menu — carried via the agent
      // message's `regeneratePrompt`/`sourceMessageId` metadata above.
    }

    return rows
  }

  private func makeRenderEntries(for conversation: ChatNativeAgentConversation)
    -> [ChatNativeAgentRenderEntry]
  {
    let messages = conversation.messages.sorted { $0.timestampMs < $1.timestampMs }
    var entries: [ChatNativeAgentRenderEntry] = []
    var emittedRichIds = Set<String>()
    // A still-streaming turn's OWN rich artifacts are buffered in
    // pendingRichOutputsByConversation (handleRichOutputsEvent) and only committed to
    // conversation.richOutputs on finish (flushPendingRichOutputs), so they can never
    // reach appendRichOutputEntries — which reads only committed outputs — mid-stream.
    // The per-message `!isActiveStreaming` guards below keep them off the live turn.
    // We must NOT suppress rich rows conversation-WIDE while streaming: that made every
    // already-rendered older track/card vanish on each send and reappear on finish (the
    // "media disappears from list / gap shift" churn). Older committed outputs stay.

    for message in messages {
      let isActiveStreaming =
        message.isStreaming
        && conversation.id == (streamingConversationId ?? activeConversationId)

      let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasRenderableSegments = message.streamSegments.contains { segment in
        switch segment {
        case .text(let text):
          return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .progress:
          // Keep completed steps on the same turn cell after settle (not only running).
          return true
        case .cards(_, let cards):
          return !cards.isEmpty
        }
      }

      if message.role == .assistant && hasRenderableSegments {
        let entryCountBeforeAppend = entries.count
        appendSegmentedEntries(
          from: message,
          isStreaming: isActiveStreaming,
          into: &entries
        )
        if entries.count > entryCountBeforeAppend {
          if !isActiveStreaming {
            appendRichOutputEntries(
              for: conversation,
              assistantMessageId: message.id,
              afterTimestamp: message.timestampMs,
              emittedIds: &emittedRichIds,
              into: &entries
            )
          }
          continue
        }
      }

      // No placeholder "Thinking…" bubble. A streaming assistant turn with nothing
      // renderable yet (no text, no running tool step, no cards) emits NO row — the cell
      // is born only when real content arrives, and then it grows with the stream. The
      // old full-width "Thinking…" shell was large and empty, and the moment the first
      // chunk landed it re-measured and shifted the layout. Tool activity is unaffected:
      // a running-progress segment makes `hasRenderableSegments` true above, so it still
      // renders through appendSegmentedEntries. The guard below drops the empty turn.
      if isActiveStreaming && trimmedContent.isEmpty { continue }

      guard !trimmedContent.isEmpty || message.role == .user else { continue }

      entries.append(
        ChatNativeAgentRenderEntry(
          id: message.id,
          messageId: message.id,
          role: message.role,
          text: message.content,
          timestampMs: message.timestampMs,
          messageType: "text",
          isStreaming: false,
          isAgentMessage: message.role == .assistant,
          showTail: true,
          progressNodes: nil,
          agentCard: nil,
          actionSourceMessageId: message.role == .assistant ? message.id : nil,
          actionSourceText: message.role == .assistant ? message.content : nil,
          deliveryFailed: message.role == .user && (message.deliveryFailed ?? false),
          isError: message.role == .assistant && (message.isError ?? false)
        ))

      if !isActiveStreaming, message.role == .assistant {
        appendRichOutputEntries(
          for: conversation,
          assistantMessageId: message.id,
          afterTimestamp: message.timestampMs,
          emittedIds: &emittedRichIds,
          into: &entries
        )
      }
    }

    // Orphans are always prior-turn committed outputs (the live turn's are still
    // buffered as pending), so they are safe to surface even while streaming.
    do {
      // Orphan rich rows (no parent assistant id) still render, in part-index order.
      appendRichOutputEntries(
        for: conversation,
        assistantMessageId: nil,
        afterTimestamp: nil,
        emittedIds: &emittedRichIds,
        into: &entries,
        includeOrphans: true
      )
    }

    return entries
  }

  private func appendRichOutputEntries(
    for conversation: ChatNativeAgentConversation,
    assistantMessageId: String?,
    afterTimestamp: Int64?,
    emittedIds: inout Set<String>,
    into entries: inout [ChatNativeAgentRenderEntry],
    includeOrphans: Bool = false
  ) {
    let candidates = conversation.richOutputs
      .filter { output in
        if emittedIds.contains(output.id) { return false }
        if let assistantMessageId {
          return output.assistantMessageId == assistantMessageId
            || output.assistantMessageId == nil
        }
        if includeOrphans {
          return output.assistantMessageId == nil
            || !conversation.messages.contains(where: { $0.id == output.assistantMessageId })
        }
        return false
      }
      .sorted {
        if $0.agentPartIndex != $1.agentPartIndex {
          return $0.agentPartIndex < $1.agentPartIndex
        }
        return $0.timestampMs < $1.timestampMs
      }

    for output in candidates {
      // When attached to a specific assistant message, only claim unlinked outputs once.
      if let assistantMessageId,
        output.assistantMessageId == nil,
        conversation.messages.last(where: { $0.role == .assistant })?.id != assistantMessageId
      {
        continue
      }
      emittedIds.insert(output.id)
      let baseTimestamp = afterTimestamp ?? output.timestampMs
      let timestampMs = max(output.timestampMs, baseTimestamp + Int64(output.agentPartIndex))
      entries.append(
        ChatNativeAgentRenderEntry(
          id: output.id,
          messageId: output.id,
          role: .assistant,
          text: output.text,
          timestampMs: timestampMs,
          messageType: output.kind,
          isStreaming: false,
          isAgentMessage: true,
          showTail: false,
          progressNodes: nil,
          agentCard: nil,
          actionSourceMessageId: nil,
          actionSourceText: nil,
          mediaUrl: output.mediaUrl,
          fileName: output.fileName,
          duration: output.durationSeconds,
          metadata: output.metadata
        ))
    }
  }

  private func appendSegmentedEntries(
    from message: ChatNativeAgentMessage,
    isStreaming: Bool,
    into entries: inout [ChatNativeAgentRenderEntry]
  ) {
    let lastRenderableSegmentIndex = message.streamSegments.lastIndex(where: {
      switch $0 {
      case .text(let text):
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case .cards(_, let cards):
        return !cards.isEmpty
      case .progress:
        return false
      }
    })

    // Cards are rendered after the response body (deferred).
    var deferredCardEntries: [ChatNativeAgentRenderEntry] = []
    for (index, segment) in message.streamSegments.enumerated() {
      guard case .cards(let groupId, let cards) = segment, !cards.isEmpty else { continue }
      let shouldAttachActions = !isStreaming && index == lastRenderableSegmentIndex
      for (cardIndex, card) in cards.enumerated() {
        deferredCardEntries.append(
          ChatNativeAgentRenderEntry(
            id: "\(message.id)-card-\(groupId)-\(cardIndex)",
            messageId: message.id,
            role: .assistant,
            text: card.displayName,
            timestampMs: message.timestampMs,
            messageType: "agent_card",
            isStreaming: false,
            isAgentMessage: true,
            showTail: false,
            progressNodes: nil,
            agentCard: card,
            actionSourceMessageId:
              shouldAttachActions && cardIndex == cards.count - 1 ? message.id : nil,
            actionSourceText:
              shouldAttachActions && cardIndex == cards.count - 1 ? message.content : nil
          ))
      }
    }

    // ONE stable turn cell for the whole assistant message. Never swap ids from
    // "-progress" → "-text" (that remounted the cell and looked like clear+replace).
    // Progress steps (thread start, tool fetches, done) live as progressNodes on
    // the same entry as the streaming answer text.
    let renderableTextIndices: [Int] = message.streamSegments.enumerated().compactMap {
      index, segment in
      if case .text(let text) = segment,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return index
      }
      return nil
    }
    let hasToolSteps = message.streamSegments.contains {
      if case .progress = $0 { return true }
      return false
    }
    // With tools, prose rides as "text" nodes. While STREAMING every text segment (incl.
    // the in-flight answer) is a node so it shows + grows live; once SETTLED the final text
    // segment graduates to the answer body so the bubble reads like a normal reply.
    let answerTextIndex: Int? = (hasToolSteps && !isStreaming) ? renderableTextIndices.last : nil
    // Prefer durable v2 structure (sealed at finishStreaming) over a thin rebuild when
    // streamSegments were clobbered by a server rehydrate. Live turns always rebuild.
    // Side store is authoritative even when the in-message version field is missing.
    let settledVersion = message.agentTurnStructureVersion ?? 0
    let settledNodes: [[String: Any]]? = {
      guard !isStreaming else { return nil }
      if let data = message.settledProgressNodesJSON,
        let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        !nodes.isEmpty
      {
        return nodes
      }
      // Side store keyed by message id (survives conversation message replacement).
      return Self.loadLocalTurnStructure(messageId: message.id)
    }()
    // Server container wins when present: it is already ordered and carries kind/tokens/
    // thinkingText. Settled (sealed) structure still wins over it so a finished turn never
    // re-renders differently than it did live.
    let serverNodes = Self.serverProgressNodes(from: message)
    // Settled turns hand their final text to the answer body, so the last text node must not
    // also appear in the feed.
    let serverFeedNodes: [[String: Any]]? = serverNodes.map { nodes in
      guard !isStreaming, let lastTextIndex = nodes.lastIndex(where: Self.isTextNode)
      else { return nodes }
      var trimmed = nodes
      trimmed.remove(at: lastTextIndex)
      return trimmed
    }
    let progressNodes: [[String: Any]] =
      settledNodes
      ?? serverFeedNodes
      ?? buildTurnNodes(
        from: message.streamSegments,
        emitTextNodes: hasToolSteps,
        answerTextIndex: answerTextIndex
      )
    let structureVersion: Int? = settledNodes != nil ? max(settledVersion, 2) : nil
    let hasProgress = !progressNodes.isEmpty
    let hasTextNodes = progressNodes.contains {
      ($0["itemType"] as? String) == "text" || ($0["kind"] as? String) == "text"
    }

    // Answer body: pure-prose turns stream it live; with-tools turns show it only once
    // settled (live prose rides in the "text" nodes above and the body is suppressed).
    let bodyText: String = {
      // Server-authoritative: the last text node IS the answer once the turn settles, and
      // while it streams the prose rides in the feed. Derived from the same list the feed
      // renders, so body and feed can never disagree.
      if let serverNodes, settledNodes == nil {
        let hasServerToolSteps = serverNodes.contains { !Self.isTextNode($0) }
        if !hasServerToolSteps { return message.content }
        guard !isStreaming,
          let last = serverNodes.last(where: Self.isTextNode),
          let text = last["label"] as? String
        else { return isStreaming ? "" : message.content }
        return text
      }
      if !hasToolSteps { return message.content }  // pure prose (Case A): body streams
      guard !isStreaming, let answerTextIndex,
        case .text(let text) = message.streamSegments[answerTextIndex]
      else {
        // Server rehydrate may leave only content + sealed nodes (no streamSegments text).
        if !isStreaming, settledNodes != nil {
          return message.content
        }
        return ""  // with-tools + live: body suppressed, prose is in the feed
      }
      return text
    }()
    let hasText = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    if hasText || hasProgress {
      let attachActions = !isStreaming && hasText
      // Prefer "text" once answer prose exists so the bubble uses the normal agent
      // text path + progress nodes; until then use agent_progress_tree for the
      // step-only shell.
      let messageType = hasText ? "text" : "agent_progress_tree"
      let displayText: String = {
        if hasText { return bodyText }
        // No answer body yet. If the feed already carries prose (text nodes), let the
        // loader carry the status — don't fabricate a body. Only a truly text-less turn
        // surfaces the running/last step label so the shell isn't blank.
        if hasTextNodes { return "" }
        if let running = progressNodes.last(where: {
          ($0["status"] as? String)?.lowercased() == "running"
        }), let label = running["label"] as? String, !label.isEmpty {
          return label
        }
        return (progressNodes.last?["label"] as? String) ?? "Working…"
      }()
      entries.append(
        ChatNativeAgentRenderEntry(
          id: "\(message.id)-turn",
          messageId: message.id,
          role: .assistant,
          text: displayText,
          timestampMs: message.timestampMs,
          messageType: messageType,
          isStreaming: isStreaming,
          isAgentMessage: true,
          showTail: hasText,
          progressNodes: progressNodes,
          agentCard: nil,
          actionSourceMessageId: attachActions ? message.id : nil,
          actionSourceText: attachActions ? message.content : nil,
          isError: message.isError ?? false,
          agentTurnStructureVersion: structureVersion
        ))
    }

    if !deferredCardEntries.isEmpty, !isStreaming || hasText {
      entries.append(contentsOf: deferredCardEntries)
    }
  }

  /// Build progress-node metadata for the turn cell. Includes running AND completed
  /// steps so "Resolving SoundCloud…" stays visible under the answer.
  /// Ordered interleaved node feed for the turn cell. `.progress` steps become tool nodes
  /// and (when `emitTextNodes`) narration `.text` segments become `kind:"text"` nodes, IN
  /// STREAM ORDER, so the body renders intro → notes → summary continuously — the same
  /// "prose rides as text progressItems" contract the bridge agents already use. Without
  /// this, a built-in-agent turn WITH tool steps is not `isPlainProseLiveTurn`, so the
  /// interleaved path suppresses the body and the whole answer hides behind the loader
  /// until settle. `answerTextIndex` (when non-nil) is the one text segment NOT emitted
  /// here because it graduates to the settled answer body (displayText). Node ids are
  /// stable (progress id, or position for text) so the feed updates in place, never remounts.
  private func buildTurnNodes(
    from segments: [ChatNativeAgentStreamSegment],
    emitTextNodes: Bool,
    answerTextIndex: Int?
  ) -> [[String: Any]] {
    Self.buildTurnNodes(
      from: segments, emitTextNodes: emitTextNodes, answerTextIndex: answerTextIndex)
  }

  private static func buildTurnNodes(
    from segments: [ChatNativeAgentStreamSegment],
    emitTextNodes: Bool,
    answerTextIndex: Int?
  ) -> [[String: Any]] {
    var nodes: [[String: Any]] = []
    var hasSubagentNode = false

    for (index, segment) in segments.enumerated() {
      switch segment {
      case .text(let text):
        guard emitTextNodes, index != answerTextIndex else { continue }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        // Narration node: `label` carries the prose, `kind`/`itemType` "text" → the
        // interleaved feed renders it as streaming text between the tool steps.
        nodes.append([
          "id": "text-\(index)",
          "label": text,
          "kind": "text",
          "itemType": "text",
          "status": "complete",
          "depth": 0,
        ])

      case .progress(let id, let label, let tool, let status):
        // thread_start is a placeholder sentinel ("Working…"), NEVER a real step — never
        // render it as a node. New turns no longer seed it, but OLD persisted turns baked a
        // COMPLETED thread_start in (finishStreaming seals every running step to "complete"
        // at done), and a lone one rendered as an empty transparent progress shell under the
        // answer — the gap the user reported ("skeleton still there"). Dropping it here cleans
        // old + new + any server-sent thread_start at render time, so a settled pure-prose
        // turn falls back to a clean text bubble instead of a text bubble + phantom shell.
        if tool == "thread_start" { continue }

        // depth must stay 0 for top-level tools (search_music, etc.).
        // VibeAgentKitMap.chatMessage only surfaces depth==0 as feed items;
        // depth>=1 is treated as nested under a subagent and was dropping every
        // Vibe AI tool step — feed showed only "text" nodes (AgentFeed order=[text]).
        let depth: Int
        if tool == "delegate_to_subagent" || tool == nil || tool == "thread_start" {
          depth = 0
        } else if let tool, tool.hasPrefix("subagent_") {
          depth = 1
          hasSubagentNode = true
        } else if hasSubagentNode {
          depth = 2
        } else {
          depth = 0
        }

        var node: [String: Any] = [
          "id": id,
          "label": label,
          "status": status,
          "depth": depth,
          // itemType/kind "tool" so hasToolProgressItems is true (not all "text").
          "kind": "tool",
          "itemType": "tool",
        ]
        if let tool {
          node["tool"] = tool
          // Keep a stable kind that still counts as a non-text tool step.
          node["kind"] = tool
          node["itemType"] = tool
        }
        nodes.append(node)

      case .cards:
        continue
      }
    }

    return nodes
  }

  // MARK: - Settled turn structure (v2) — local durable store

  /// FROZEN contract key for the side store (UserDefaults). Values are JSON arrays of
  /// progress node dicts, keyed by assistant message id.
  private static let turnStructureStoreKey = "ChatNativeAgentView.agentTurnStructure.v2"

  /// Seal the same ordered node list the live turn rendered, for cold-open rebuild.
  private static func settledTurnStructure(
    from message: ChatNativeAgentMessage
  ) -> (nodesJSON: Data, nodes: [[String: Any]])? {
    // Prefer the server's own container so the sealed (cold-open) structure is byte-identical
    // to what the live turn rendered — that mismatch is what made a relaunched chat show a
    // different set of notes than the one the user watched.
    if let serverNodes = serverProgressNodes(from: message) {
      var nodes = serverNodes
      if let lastTextIndex = nodes.lastIndex(where: isTextNode) {
        nodes.remove(at: lastTextIndex)  // graduates to the answer body
      }
      if !nodes.isEmpty, JSONSerialization.isValidJSONObject(nodes),
        let data = try? JSONSerialization.data(withJSONObject: nodes, options: [])
      {
        return (data, nodes)
      }
    }
    let renderableTextIndices: [Int] = message.streamSegments.enumerated().compactMap {
      index, segment in
      if case .text(let text) = segment,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return index
      }
      return nil
    }
    let hasToolSteps = message.streamSegments.contains {
      if case .progress = $0 { return true }
      return false
    }
    // Settled mode: last text graduates to body; earlier text + all progress stay as nodes.
    let answerTextIndex: Int? = hasToolSteps ? renderableTextIndices.last : nil
    let nodes = buildTurnNodes(
      from: message.streamSegments,
      emitTextNodes: hasToolSteps,
      answerTextIndex: answerTextIndex
    )
    guard !nodes.isEmpty,
      JSONSerialization.isValidJSONObject(nodes),
      let data = try? JSONSerialization.data(withJSONObject: nodes, options: [])
    else { return nil }
    return (data, nodes)
  }

  private static func persistLocalTurnStructure(messageId: String, nodesJSON: Data) {
    let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // UserDefaults property-list store: base64 strings keyed by message id.
    var stringStore =
      UserDefaults.standard.dictionary(forKey: turnStructureStoreKey) as? [String: String] ?? [:]
    stringStore[trimmed] = nodesJSON.base64EncodedString()
    // Cap growth: keep newest ~200 sealed turns.
    if stringStore.count > 200 {
      let sortedKeys = stringStore.keys.sorted()
      for key in sortedKeys.prefix(stringStore.count - 200) {
        stringStore.removeValue(forKey: key)
      }
    }
    UserDefaults.standard.set(stringStore, forKey: turnStructureStoreKey)
  }

  private static func loadLocalTurnStructureData(messageId: String) -> Data? {
    let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let stringStore =
      UserDefaults.standard.dictionary(forKey: turnStructureStoreKey) as? [String: String] ?? [:]
    guard let b64 = stringStore[trimmed], let data = Data(base64Encoded: b64), !data.isEmpty
    else { return nil }
    return data
  }

  private static func loadLocalTurnStructure(messageId: String) -> [[String: Any]]? {
    guard let data = loadLocalTurnStructureData(messageId: messageId),
      let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      !nodes.isEmpty
    else { return nil }
    return nodes
  }

  private func regeneratePromptMap(for conversation: ChatNativeAgentConversation) -> [String: String]
  {
    let messages = conversation.messages.sorted { $0.timestampMs < $1.timestampMs }
    var prompts: [String: String] = [:]
    var lastUserText: String?

    for message in messages {
      let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      switch message.role {
      case .user:
        lastUserText = trimmed.isEmpty ? nil : message.content

      case .assistant:
        if let lastUserText, !trimmed.isEmpty {
          prompts[message.id] = lastUserText
        }
      }
    }

    return prompts
  }

  private func conversation(for id: String) -> ChatNativeAgentConversation? {
    conversations.first(where: { $0.id == id })
  }

  private func updateConversation(_ id: String, mutate: (inout ChatNativeAgentConversation) -> Void)
  {
    guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
    var conversation = conversations[index]
    mutate(&conversation)
    conversations[index] = conversation
  }

  private func notifyStreamingStateChanged() {
    let isStreaming = streamingConversationId != nil
    guard isStreaming != lastReportedStreamingState else { return }
    lastReportedStreamingState = isStreaming
    onStreamingStateChanged?(isStreaming)
    onNativeEvent([
      "type": "agentStreamingState",
      "isStreaming": isStreaming,
    ])
  }


  private func applyPersistedState() {
    guard
      let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
      let state = try? JSONDecoder().decode(ChatNativeAgentPersistedState.self, from: data)
    else {
      return
    }
    conversations = state.conversations.map { conversation in
      var normalizedConversation = conversation
      normalizedConversation.messages = conversation.messages.map { message in
        guard message.role == .assistant, message.isStreaming else { return message }
        var normalizedMessage = message
        normalizedMessage.isStreaming = false
        normalizedMessage.streamSegments.removeAll { $0.isRunningProgress }
        if normalizedMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let fallbackText = "Previous response was interrupted. Tap regenerate to retry."
          normalizedMessage.content = fallbackText
          normalizedMessage.streamSegments = [.text(fallbackText)]
        }
        return normalizedMessage
      }
      return normalizedConversation
    }
    // Keep the active session across app restarts until the user taps New Chat.
    activeConversationId = state.activeConversationId
    if activeConversationId == nil,
      let newest = conversations.max(by: { $0.updatedAt < $1.updatedAt })
    {
      activeConversationId = newest.id
    }
  }

  /// Start a blank conversation (header +). Prior chats stay in History; the open
  /// list only clears when the user explicitly starts a new chat.
  func startNewChatSession() {
    _ = createConversation(title: "New Chat")
    setHeaderActivityState(fallback: "ready")
    NSLog("[ChatNativeAgent] startNewChatSession id=%@", activeConversationId ?? "nil")
  }

  /// Present the conversation History sheet (id + title per past chat).
  func presentConversationHistory(from presenter: UIViewController) {
    // Refresh from server when possible so History includes every chat id the user has.
    if joinedTopic {
      syncConversations()
    }
    let sheet = ChatNativeAgentHistorySheetController(
      conversations: conversations.sorted { $0.updatedAt > $1.updatedAt },
      activeConversationId: activeConversationId,
      appearance: appearance,
      onSelect: { [weak self] id in
        self?.selectConversation(id: id)
      },
      onDelete: { [weak self] id in
        self?.deleteConversation(id: id)
      },
      onNewChat: { [weak self] in
        self?.startNewChatSession()
      }
    )
    let navigation = UINavigationController(rootViewController: sheet)
    navigation.modalPresentationStyle = .pageSheet
    if let sheetPresentation = navigation.sheetPresentationController {
      if #available(iOS 16.0, *) {
        sheetPresentation.detents = [.medium(), .large()]
        sheetPresentation.selectedDetentIdentifier = .medium
      } else {
        sheetPresentation.detents = [.medium(), .large()]
      }
      sheetPresentation.prefersGrabberVisible = true
      sheetPresentation.preferredCornerRadius = 28
    }
    var host: UIViewController = presenter
    while let presented = host.presentedViewController {
      host = presented
    }
    host.present(navigation, animated: true)
  }

  private func persistState() {
    let state = ChatNativeAgentPersistedState(
      activeConversationId: activeConversationId,
      conversations: conversations
    )
    guard let data = try? JSONEncoder().encode(state) else { return }
    UserDefaults.standard.set(data, forKey: Self.persistenceKey)
    NotificationCenter.default.post(name: Self.conversationsDidChangeNotification, object: nil)
  }

  static func homeListSummary() -> (preview: String, timestampMs: Int64)? {
    guard
      let data = UserDefaults.standard.data(forKey: persistenceKey),
      let state = try? JSONDecoder().decode(ChatNativeAgentPersistedState.self, from: data),
      let conversation =
        state.activeConversationId.flatMap({ activeId in
          state.conversations.first(where: { $0.id == activeId })
        })
        ?? state.conversations.max(by: { $0.updatedAt < $1.updatedAt })
    else {
      return nil
    }

    let latestMessage = conversation.messages.max(by: { $0.timestampMs < $1.timestampMs })
    let trimmedContent = latestMessage?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let preview =
      trimmedContent.isEmpty && latestMessage?.isStreaming == true
      ? "Thinking…"
      : (trimmedContent.isEmpty ? "Ask Vibe AI anything" : trimmedContent)
    return (preview, latestMessage?.timestampMs ?? conversation.updatedAt)
  }

  private func topMostViewController() -> UIViewController? {
    guard
      let root =
        window?.rootViewController
        ?? UIApplication.shared.connectedScenes
        .compactMap({ scene -> UIViewController? in
          guard let windowScene = scene as? UIWindowScene else { return nil }
          return windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        })
        .first
    else { return nil }

    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  private static func parseServerMessage(_ raw: [String: Any]) -> ChatNativeAgentMessage? {
    let type =
      (normalizedString(raw["type"] ?? raw["kind"] ?? raw["message_type"] ?? raw["messageType"])
        ?? "text")
      .lowercased()
    // Non-text finalized artifacts are handled as rich outputs, not text bubbles.
    if type != "text" && type != "assistant" && type != "user" {
      return nil
    }

    let id = normalizedString(raw["id"]) ?? UUID().uuidString
    let role = ChatNativeAgentRole(rawValue: (raw["role"] as? String) ?? "assistant") ?? .assistant
    let content = normalizedString(raw["content"] ?? raw["text"]) ?? ""
    let timestampMs = parseTimestampMs(raw["timestamp"] ?? raw["timestampMs"]) ?? nowMs()
    return ChatNativeAgentMessage(
      id: id,
      role: role,
      content: content,
      timestampMs: timestampMs,
      isStreaming: false,
      streamSegments: content.isEmpty ? [] : [.text(content)]
    )
  }

  /// Rebuilds a rich row from a persisted/history message that already used the
  /// normal music/question message shape (deduped by id on merge).
  private static func parseServerRichOutputMessage(_ raw: [String: Any]) -> ChatNativeAgentRichOutput?
  {
    let type =
      (normalizedString(raw["type"] ?? raw["kind"] ?? raw["message_type"] ?? raw["messageType"])
        ?? "")
      .lowercased()
    guard !type.isEmpty, type != "text", type != "assistant", type != "user" else { return nil }
    return parseRichOutputItem(raw, fallbackIndex: 0, baseTimestamp: nowMs())
  }

  /// Agent history stores the finalized batch on its assistant message. Rehydrate those
  /// nested outputs so reconnect/reinstall follows the same separate-cell contract as live
  /// `rich_outputs` delivery instead of depending on a one-shot socket event.
  private static func parseNestedServerRichOutputs(_ raw: [String: Any])
    -> [ChatNativeAgentRichOutput]
  {
    let nested =
      (raw["richOutputs"] as? [[String: Any]])
      ?? (raw["rich_outputs"] as? [[String: Any]])
      ?? []
    guard !nested.isEmpty else { return [] }

    var envelope: [String: Any] = ["outputs": nested]
    if let timestamp = raw["timestamp"] ?? raw["timestampMs"] ?? raw["timestamp_ms"] {
      envelope["timestamp"] = timestamp
    }
    let assistantMessageId = normalizedString(raw["id"])
    return parseRichOutputs(from: envelope).map { output in
      var linked = output
      if linked.assistantMessageId == nil {
        linked.assistantMessageId = assistantMessageId
      }
      return linked
    }
  }

  // MARK: - Legacy decode helper
  // When loading persisted messages that don't have streamSegments,
  // the Codable default will give an empty array which is correct.

  private static func parseTimestampMs(_ raw: Any?) -> Int64? {
    if let value = raw as? NSNumber {
      let number = value.int64Value
      return number < 2_000_000_000 ? number * 1000 : number
    }
    if let value = raw as? String {
      if let number = Int64(value) {
        return number < 2_000_000_000 ? number * 1000 : number
      }
      if let date = isoDateFormatter.date(from: value) {
        return Int64(date.timeIntervalSince1970 * 1000.0)
      }
      if let date = fallbackDateFormatter.date(from: value) {
        return Int64(date.timeIntervalSince1970 * 1000.0)
      }
    }
    return nil
  }

  private static func normalizedString(_ raw: Any?) -> String? {
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func loadNativeAuthSessionFromKeychain() -> [String: Any]? {
    let keyData = Data("user_session_v2".utf8)

    for service in ["app:no-auth", "app:auth", "app"] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keyData,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess,
        let data = result as? Data,
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        return json
      }
    }

    let legacyQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrAccount as String: "user_session_v2",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    return nil
  }

  private static func makeBubbleShape(
    isMe: Bool,
    isSequenceStart: Bool,
    isSequenceEnd: Bool,
    showTail: Bool
  ) -> [String: Any] {
    // Match ChatEngine bubbleShapePayload — full 18 / merged 12 (Telegram-like).
    let full: CGFloat = 18
    let merged: CGFloat = 12
    var shape: [String: Any] = [
      "isMe": isMe,
      "showTail": showTail && isSequenceEnd,
      "borderTopLeftRadius": full,
      "borderTopRightRadius": full,
      "borderBottomLeftRadius": full,
      "borderBottomRightRadius": full,
    ]

    if isMe {
      // Outgoing top-right remains full in every sequence position; only the
      // bottom-right corner tightens when another outgoing bubble follows.
      shape["borderTopRightRadius"] = full
      shape["borderBottomRightRadius"] = isSequenceEnd ? full : merged
    } else {
      shape["borderTopLeftRadius"] = isSequenceStart ? full : merged
      shape["borderBottomLeftRadius"] = isSequenceEnd ? full : merged
    }

    return shape
  }

  private static func formatTimeLabel(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return timeFormatter.string(from: date)
  }

  private static func formatDayLabel(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return dayFormatter.string(from: date)
  }

  private static func dayKey(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
  }

  private static func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000.0)
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static let isoDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let fallbackDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return formatter
  }()

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    conversations.sorted { $0.createdAt > $1.createdAt }.count
  }

  public func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let sorted = conversations.sorted { $0.createdAt > $1.createdAt }
    let conversation = sorted[indexPath.row]
    let cell =
      tableView.dequeueReusableCell(
        withIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier,
        for: indexPath
      ) as? ChatNativeAgentHistoryCell
      ?? ChatNativeAgentHistoryCell(
        style: .default, reuseIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier)
    cell.configure(
      conversation: conversation,
      activeConversationId: activeConversationId,
      appearance: appearance
    )
    return cell
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    window?.endEditing(true)
    let sorted = conversations.sorted { $0.createdAt > $1.createdAt }
    guard indexPath.row < sorted.count else { return }
    selectConversation(id: sorted[indexPath.row].id)
  }

  public func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let sorted = conversations.sorted { $0.createdAt > $1.createdAt }
    guard indexPath.row < sorted.count else { return nil }
    let conversationId = sorted[indexPath.row].id
    let deleteAction = UIContextualAction(style: .destructive, title: "Delete") {
      [weak self] _, _, completion in
      self?.deleteConversation(id: conversationId)
      completion(true)
    }
    return UISwipeActionsConfiguration(actions: [deleteAction])
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard scrollView === pageScrollView else { return }
    syncCurrentPageFromOffset()
  }

  public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    guard scrollView === pageScrollView else { return }
    syncCurrentPageFromOffset()
  }

  private func syncCurrentPageFromOffset() {
    let width = max(1.0, pageScrollView.bounds.width)
    let pageIndex = Int(round(pageScrollView.contentOffset.x / width))
    let nextPage: ChatNativeAgentPage = pageIndex <= 0 ? .chat : .history
    guard currentPage != nextPage else { return }
    currentPage = nextPage
    refreshHeader(animated: true)
  }
}

// MARK: - History sheet (built-in Vibe AI)

/// Modal History list for the hosted Vibe AI surface (transport-only `ChatNativeAgentView`
/// cannot page-swipe into its internal history table).
private final class ChatNativeAgentHistorySheetController: UITableViewController {
  private var conversations: [ChatNativeAgentConversation]
  private let activeConversationId: String?
  private let appearance: ChatListAppearance
  private let onSelect: (String) -> Void
  private let onDelete: (String) -> Void
  private let onNewChat: () -> Void

  init(
    conversations: [ChatNativeAgentConversation],
    activeConversationId: String?,
    appearance: ChatListAppearance,
    onSelect: @escaping (String) -> Void,
    onDelete: @escaping (String) -> Void,
    onNewChat: @escaping () -> Void
  ) {
    self.conversations = conversations
    self.activeConversationId = activeConversationId
    self.appearance = appearance
    self.onSelect = onSelect
    self.onDelete = onDelete
    self.onNewChat = onNewChat
    super.init(style: .plain)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "History"
    view.backgroundColor = appearance.isDark ? UIColor(white: 0.07, alpha: 1) : .systemBackground
    tableView.backgroundColor = view.backgroundColor
    tableView.separatorStyle = .none
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 72
    tableView.register(
      ChatNativeAgentHistoryCell.self,
      forCellReuseIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier
    )
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(handleClose)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .add,
      target: self,
      action: #selector(handleNew)
    )
    if conversations.isEmpty {
      let empty = UILabel()
      empty.text = "No conversations yet.\nStart chatting with Vibe AI."
      empty.numberOfLines = 0
      empty.textAlignment = .center
      empty.textColor = appearance.timeColorThem
      empty.font = .systemFont(ofSize: 15, weight: .regular)
      tableView.backgroundView = empty
    }
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  @objc private func handleNew() {
    dismiss(animated: true) { [onNewChat] in
      onNewChat()
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    conversations.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let cell =
      tableView.dequeueReusableCell(
        withIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier,
        for: indexPath
      ) as? ChatNativeAgentHistoryCell
      ?? ChatNativeAgentHistoryCell(
        style: .default,
        reuseIdentifier: ChatNativeAgentHistoryCell.reuseIdentifier
      )
    let conversation = conversations[indexPath.row]
    cell.configure(
      conversation: conversation,
      activeConversationId: activeConversationId,
      appearance: appearance
    )
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let id = conversations[indexPath.row].id
    dismiss(animated: true) { [onSelect] in
      onSelect(id)
    }
  }

  override func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    let id = conversations[indexPath.row].id
    let delete = UIContextualAction(style: .destructive, title: "Delete") {
      [weak self] _, _, completion in
      guard let self else {
        completion(false)
        return
      }
      self.onDelete(id)
      self.conversations.removeAll { $0.id == id }
      tableView.deleteRows(at: [indexPath], with: .automatic)
      completion(true)
    }
    return UISwipeActionsConfiguration(actions: [delete])
  }
}
