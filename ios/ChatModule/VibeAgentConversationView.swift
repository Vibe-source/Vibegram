//
//  VibeAgentConversationView.swift
//  Vibe
//
//  The full-page agent surface. This is the screen pushed from a default-chat
//  agent bubble's "view agent" affordance: it shows the full conversation for a
//  single agent task (the user's prompt + the agent's reply) rendered with the
//  ported VibeAgentKit components — streaming text, the agent loader/orb, the
//  compact tool-progress feed, and the tappable progress sheet.
//
//  Design intent (per product direction):
//   - The page is NEVER empty: it is seeded with that task's prior messages
//     (the user prompt that started the task + the agent message), so opening
//     "view agent" lands you in the middle of the conversation, not a blank feed.
//   - The default chat list stays the multiplexing surface (one bubble per
//     prompt/task in groups); THIS view is single-task.
//
//  The Resolo `ChatView`/`ChatStore` (its networking + state layer) is NOT ported
//  — only the rendering primitives. Vibe owns the data and maps it in via
//  `VibeAgentKitMap` below, so we don't drag Resolo's backend into Vibe core.
//

import AVFoundation
import Speech
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Mapping: Vibe data -> VibeAgentKit render models

enum VibeAgentKitMap {

  /// Appearance matched to the app's warm-dark palette (the ported fallbacks were
  /// authored against the same palette, so they line up without retuning).
  static func appearance(for traitCollection: UITraitCollection) -> VibeAgentKitChatAppearance {
    traitCollection.userInterfaceStyle == .light ? .lightFallback : .fallback
  }

  /// One enriched tool node -> a progress item. The compact label
  /// (`chatAgentNodeCompactLabel`, shared with the chat-cell formatter) gives the
  /// Claude-Code-style "Read ChatEngine.swift", "Edit chat.ex  +12 −3" reading.
  /// `detail` is the decrypted per-action blob (command OUTPUT, todo contents);
  /// it becomes the row's expandable body in the tool sheet.
  static func progressItem(
    from node: ChatListRow.AgentProgressNode,
    detail: [String: Any]? = nil
  ) -> VibeAgentKitProgressItem {
    let kind = node.kind ?? (detail?["kind"] as? String)
    // bash carries its full (un-clipped) command; read carries the file slice it read;
    // edits carry a unified-diff patch. All ride the decrypted blob → the expand layers.
    let fullCommand = (detail?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let patch = (detail?["patch"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawOutput = (detail?["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = node.target ?? (detail?["name"] as? String)

    var parsedTodos: [VibeAgentKitTodoItem]? = nil
    if let rawTodos = detail?["todos"] as? [[String: Any]] {
      parsedTodos = rawTodos.map { t in
        VibeAgentKitTodoItem(
          content: (t["content"] as? String) ?? "",
          status: (t["status"] as? String) ?? "",
          activeForm: t["activeForm"] as? String
        )
      }
    }

    // Prefer encrypted action blob; fall back to plaintext node.detail (Grok CoT live).
    // Thinking keeps a larger body so the sheet can show the full CoT (not a 1.4k clip).
    let bodyFromEnc = actionDetailBody(kind: kind, detail: detail)
    let bodyFromNode: String? = {
      guard let d = node.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else {
        return nil
      }
      let limit = (kind == "thinking") ? 12000 : 1400
      if d.count > limit { return String(d.prefix(limit)) + "\n… (truncated)" }
      return d
    }()
    let messageContent = bodyFromEnc ?? bodyFromNode

    return VibeAgentKitProgressItem(
      label: chatAgentNodeCompactLabel(node),
      badges: [],
      eventType: "progress",
      recipient: nil,
      platform: nil,
      format: nil,
      messageContent: messageContent,
      messagePreview: nil,
      voiceUrl: nil,
      voiceDuration: nil,
      status: node.status,
      isRecording: false,
      recordingStartTime: nil,
      tool: kind,
      image: nil,
      itemType: kind,
      sourceUrl: nil,
      nodeId: node.id,
      command: (fullCommand?.isEmpty == false) ? fullCommand : nil,
      patch: (patch?.isEmpty == false) ? patch : nil,
      fileName: fileName,
      fileContent: (kind == "read" && rawOutput?.isEmpty == false) ? rawOutput : nil,
      lineStart: node.start,
      lineEnd: node.end,
      parentId: node.parentId,
      subagentType: node.subagentType,
      tokens: node.tokens,
      durationMs: node.durationMs,
      todos: parsedTodos
    )
  }

  /// Decrypt a turn's sealed action array into `nodeId -> detail`. Server-opaque:
  /// without the phone-held key this is empty and rows show labels only.
  private static func actionDetailMap(for row: ChatListRow) -> [String: [String: Any]] {
    guard let enc = row.agentActionsEnc,
      let obj = AgentRuntimeCrypto.decrypt(enc),
      let actions = obj["actions"] as? [[String: Any]]
    else { return [:] }
    var map: [String: [String: Any]] = [:]
    for action in actions {
      if let id = action["id"] as? String, !id.isEmpty { map[id] = action }
    }
    return map
  }

  private static func imageAttachments(from row: ChatListRow) -> [VibeAgentKitImageAttachment] {
    var attachments: [VibeAgentKitImageAttachment] = []
    let rowId = row.messageId ?? row.key
    // The sealed bridge blobs are the canonical attachment set — exactly the images the
    // agent received, in order. A picker send also carries the first image in the row's
    // media fields, so when any blob decrypts we render blobs ONLY (the media entry
    // would duplicate blob #0). The media/thumb fallback below still covers rows whose
    // blobs can't be decrypted here (no pairing key on this device) or plain media rows.
    for (index, blob) in row.agentBridgeAttachmentsEnc.enumerated() {
      guard let object = AgentRuntimeCrypto.decrypt(blob) else { continue }
      let mime =
        normalizedString(object["mime"])
        ?? normalizedString(object["type"])
        ?? normalizedString(object["contentType"])
        ?? normalizedString(object["content_type"])
      let dataBase64 =
        normalizedString(object["dataB64"])
        ?? normalizedString(object["data_b64"])
        ?? normalizedString(object["base64"])
      let uri =
        normalizedString(object["uri"])
        ?? normalizedString(object["url"])
        ?? normalizedString(object["path"])
      let name =
        normalizedString(object["name"])
        ?? normalizedString(object["fileName"])
        ?? normalizedString(object["file_name"])
      let looksImage =
        (mime?.lowercased().hasPrefix("image/") == true)
        || dataBase64 != nil
        || isImageReference(uri: uri, fileName: name)
      guard looksImage else { continue }
      attachments.append(
        VibeAgentKitImageAttachment(
          id: "\(rowId)#bridge-image-\(index)",
          name: name,
          mime: mime ?? mimeType(for: name ?? uri ?? ""),
          sourceURI: uri,
          dataBase64: dataBase64
        )
      )
    }
    if !attachments.isEmpty { return attachments }

    let sourceURI = (row.localMediaUrl?.isEmpty == false ? row.localMediaUrl : row.mediaUrl)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let isImageMessage =
      row.visualKind == .media
      && (row.messageType == "image"
        || row.messageType == "gif"
        || isImageReference(uri: sourceURI, fileName: row.fileName))
    if isImageMessage, let sourceURI, !sourceURI.isEmpty {
      attachments.append(
        VibeAgentKitImageAttachment(
          id: "\(rowId)#media",
          name: row.fileName,
          mime: mimeType(for: row.fileName ?? sourceURI),
          sourceURI: sourceURI,
          dataBase64: row.thumbnailBase64
        )
      )
    } else if isImageMessage, let thumb = row.thumbnailBase64, !thumb.isEmpty {
      attachments.append(
        VibeAgentKitImageAttachment(
          id: "\(rowId)#thumb",
          name: row.fileName,
          mime: "image/jpeg",
          sourceURI: nil,
          dataBase64: thumb
        )
      )
    }

    return attachments
  }

  private static func normalizedString(_ raw: Any?) -> String? {
    guard let raw else { return nil }
    let value: String
    if let string = raw as? String {
      value = string
    } else if let number = raw as? NSNumber {
      value = number.stringValue
    } else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isImageReference(uri: String?, fileName: String?) -> Bool {
    let extensions = [uri, fileName].compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      if let url = URL(string: value), !url.pathExtension.isEmpty {
        return url.pathExtension.lowercased()
      }
      let ext = (value as NSString).pathExtension.lowercased()
      return ext.isEmpty ? nil : ext
    }
    return extensions.contains { ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"].contains($0) }
  }

  private static func mimeType(for value: String) -> String? {
    let ext: String
    if let url = URL(string: value), !url.pathExtension.isEmpty {
      ext = url.pathExtension.lowercased()
    } else {
      ext = (value as NSString).pathExtension.lowercased()
    }
    switch ext {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic", "heif": return "image/heic"
    case "bmp": return "image/bmp"
    default: return nil
    }
  }

  /// The decrypted detail rendered as the tool sheet row's expandable body: a
  /// command's OUTPUT, a todo checklist, search hits. Returns nil to leave the
  /// row as just its label (edits/reads need no body).
  private static func actionDetailBody(kind: String?, detail: [String: Any]?) -> String? {
    guard let detail else { return nil }
    let output = ((detail["output"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let clipped = output.count > 1400 ? String(output.prefix(1400)) + "\n… (truncated)" : output
    switch kind ?? (detail["kind"] as? String) ?? "" {
    case "todo":
      let todos = detail["todos"] as? [[String: Any]] ?? []
      guard !todos.isEmpty else { return nil }
      return todos.map { todo -> String in
        let content = (todo["content"] as? String) ?? ""
        switch (todo["status"] as? String) ?? "" {
        case "completed": return "✓ \(content)"
        case "in_progress": return "→ \(content)"
        default: return "• \(content)"
        }
      }.joined(separator: "\n")
    case "bash", "search", "web", "task", "tool", "mcp", "thinking":
      return clipped.isEmpty ? nil : clipped
    default:
      return nil
    }
  }

  /// A chat row -> a render message. User rows render as right-side bubbles; agent
  /// rows render as the assistant body (streaming text + progress).
  static func chatMessage(from row: ChatListRow) -> VibeAgentKitChatMessage {
    let isUser = row.isMe && !row.isAgentMessage
    let isCompaction = row.isAgentMessage && row.agentMsgKind == "summary"
    let defaultBody = row.isAgentMessage ? (row.plainContent ?? row.text) : row.text
    // A /compact summary renders as a centered, collapsible divider — keep its RAW
    // summary text (the divider reveals it on tap); ordinary turns use their body.
    let body = isCompaction
      ? (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)
      : defaultBody
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let isInterrupted = trimmedBody == "[Request interrupted by user]"
      || trimmedBody.localizedCaseInsensitiveContains("request interrupted by user")
    let hasBodyText = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // A turn's tool actions render natively: each depth-0 node becomes a progress
    // item (compact shimmer line + tap-to-open tool sheet). The decrypted detail
    // (command OUTPUT, todo contents) becomes each row's expandable body.
    let detailMap: [String: [String: Any]] = row.isAgentMessage ? actionDetailMap(for: row) : [:]
    let items = row.isAgentMessage
      ? row.agentProgressNodes.filter { $0.depth == 0 }.map { progressItem(from: $0, detail: detailMap[$0.id]) }
      : []
    // Subagent (Claude Task tool) children: depth>=1 nodes grouped by their parent
    // Task node id. Kept out of the main feed; the read-only subagent view reads them.
    var subagentChildren: [String: [VibeAgentKitProgressItem]] = [:]
    if row.isAgentMessage {
      for node in row.agentProgressNodes where node.depth >= 1 {
        guard let parentId = node.parentId, !parentId.isEmpty else { continue }
        subagentChildren[parentId, default: []].append(progressItem(from: node, detail: detailMap[node.id]))
      }
    }
    let attachments = row.isAgentMessage ? [] : imageAttachments(from: row)
    // A turn delivered via the bridge-history path ("agentBridgeHistory") carries its
    // live state ONLY as a progress node whose status the bridge flipped to "running"
    // (markMessageRunning in vibe-bridge.js): the relayed metadata has no `isStreaming`
    // flag, and the runtime card is sealed/encrypted BEFORE the turn is marked live so
    // it still reads status:"done". Without keying off the node, a still-running history
    // turn arrives looking identical to a finished one — so the cell collapses it into a
    // "Worked · N steps" card instead of showing the live feed (the "still live but it
    // collapses, no live progress" bug). Every finished node gets an explicit
    // "done"/"error" status from foldTurnIntoHost, so a lone "running" node unambiguously
    // means the turn is in flight.
    let hasRunningNode = row.agentProgressNodes.contains { $0.status.lowercased() == "running" }
    let isLiveTurn = row.isAgentMessage && !isCompaction && !isInterrupted
      && (row.isStreamingText || hasRunningNode)
    // Tools-only finished turns (common for Grok mid-recovery) still count as "final"
    // so the Worked · N steps card renders instead of a blank bubble.
    let hasToolSteps = !items.isEmpty && items.contains { $0.itemType != "text" }
    let hasFinal =
      row.isAgentMessage && !isLiveTurn && !isCompaction && !isInterrupted
      && (hasBodyText || hasToolSteps)
    return VibeAgentKitChatMessage(
      id: row.messageId ?? row.key,
      role: (isUser && !isInterrupted) ? .user : .assistant,
      text: body,
      timestamp: row.timestamp,
      timestampMs: 0,
      isStreaming: isLiveTurn,
      isError: row.status == "failed",
      hasFinalResponseText: hasFinal,
      progress: [],
      progressItems: (isCompaction || isInterrupted) ? [] : items,
      subagentChildren: (isCompaction || isInterrupted) ? [:] : subagentChildren,
      sourceMessageId: (isCompaction || isInterrupted) ? nil : row.agentActionSourceId,
      runtime: (isCompaction || isInterrupted) ? nil : (row.isAgentMessage ? row.agentRuntime : nil),
      attachments: attachments,
      isCompactionSummary: isCompaction,
      systemDividerText: isInterrupted ? "[Request interrupted by user]" : nil
    )
  }

  /// Build the seed message list for a task. `rows` should already be the slice of
  /// chat rows that belong to this task (the prompt + the agent reply, and any
  /// prior turns when resumed).
  /// Max rows mapped at once. Each `chatMessage(from:)` performs per-row E2E decryption
  /// (actions + attachments) which, over hundreds of rows, blocks the main thread for
  /// seconds and overheats the device. Only the latest window is ever needed to continue.
  static let transcriptWindow = 40

  static func messages(from rows: [ChatListRow], limit: Int = transcriptWindow) -> [VibeAgentKitChatMessage] {
    // Decrypt/map only the most recent `limit` rows (the visible tail). Older turns load
    // on demand via History; mapping all of them is what froze the agent view.
    let windowed = rows.count > limit ? Array(rows.suffix(limit)) : rows
    // The same outgoing prompt can surface twice — once as the optimistic/native row and
    // again as a server- or session-history re-ingest under a DIFFERENT message id, which
    // slips past the id-based merge upstream and renders as a duplicate user bubble (one
    // pinned at the top, one down in the feed). Collapse a user bubble that exactly repeats
    // the previous kept user turn (only assistant/agent turns in between) — the real-world
    // signature of that double-ingest. A genuinely repeated identical prompt is the rare,
    // low-harm cost.
    var lastUserText: String?
    var result: [VibeAgentKitChatMessage] = []
    for row in windowed {
      guard case .message = row.kind else { continue }
      // Skip empty system/placeholder rows. A freshly-started streaming row with no
      // renderable text/tool/runtime is represented by the header/STOP state instead;
      // keeping it here draws an empty rounded assistant bubble until the first real
      // chunk lands.
      let m = chatMessage(from: row)
      // A runtime with only metadata (status, provider, model) but no diff is not
      // renderable — the cell's assistant body view hides everything, producing an
      // empty cell that creates a large scrollable gap in the history view. Only
      // treat the runtime as "real content" when it carries an actual file diff.
      let hasRenderableRuntime: Bool = {
        guard let rt = m.runtime, let diff = rt.diff else { return false }
        let hasPatch = diff.patch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return diff.filesChanged > 0 || diff.additions > 0 || diff.deletions > 0
          || !diff.files.isEmpty || hasPatch
      }()
      let hasRenderableProgress = m.progressItems.contains { item in
        if item.itemType == "text" {
          return !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !isPlaceholderThinkingProgressItem(item)
      }
      let emptyStreamingPlaceholder =
        m.isStreaming && m.text.isEmpty && !hasRenderableProgress && !hasRenderableRuntime
          && m.attachments.isEmpty
      if m.text.isEmpty && !hasRenderableProgress && !hasRenderableRuntime && m.attachments.isEmpty
        && (!m.isStreaming || emptyStreamingPlaceholder)
      {
        continue
      }
      if m.role == .user, m.attachments.isEmpty {
        let trimmed = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          if trimmed == lastUserText { continue }  // duplicate of the previous user turn
          lastUserText = trimmed
        }
      }
      result.append(m)
    }
    return result
  }
}

// MARK: - Full-page agent conversation surface

enum VibeAgentConversationSurfaceMode: String {
  case transcript
  case visual
}

final class VibeAgentConversationViewController: UIViewController, UITableViewDataSource,
  UITableViewDelegate, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate
{

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let workspaceView = VibeAgentWorkspaceView()
  private let progressSheet = VibeAgentKitAgentProgressSheetView()
  private let composerView = VibeComposerView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let liveDotView = UIView()
  private let liveLabel = UILabel()
  // Connection status indicator on the device subline (in-view header): solid green
  // pip when the computer is connected, red pip + spinner while reconnecting.
  private let connectionDotView = UIView()
  private let connectionSpinner = UIActivityIndicatorView(style: .medium)
  private var messages: [VibeAgentKitChatMessage]
  /// Bridge info-command results (executable == "vibe-bridge") are stored in `messages`
  /// for banner/catalog computations but suppressed from the table — they render in the
  /// glass overlay instead.
  private var tableMessages: [VibeAgentKitChatMessage] {
    messages.filter { msg in
      // Bridge info-command results render in the glass overlay, not the table.
      if msg.runtime?.command?.executable?.lowercased() == "vibe-bridge" { return false }
      // Skip agent messages that carry no renderable content: no text, no progress
      // items, no attachments, not streaming, and no runtime diff. Such messages
      // produce empty cells that create a scrollable gap (the "huge empty state" bug
      // when opening history).
      if msg.role == .assistant,
        !msg.isStreaming,
        !msg.isCompactionSummary,
        msg.systemDividerText == nil,
        msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        msg.progressItems.isEmpty,
        msg.attachments.isEmpty
      {
        let hasDiff: Bool = {
          guard let diff = msg.runtime?.diff else { return false }
          let hasPatch = diff.patch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
          return diff.filesChanged > 0 || diff.additions > 0 || diff.deletions > 0
            || !diff.files.isEmpty || hasPatch
        }()
        if !hasDiff { return false }
      }
      return true
    }
  }
  private var appearance: VibeAgentKitChatAppearance
  private let runtimeTitle: String
  private let runtimeSubtitle: String
  private let inputPlaceholder: String
  private let regeneratePrompt: String
  let surfaceMode: VibeAgentConversationSurfaceMode
  private let messagesProvider: (() -> [VibeAgentKitChatMessage])?
  private let onSend: ((String, AgentBridgeRunOptions, [String]) -> Void)?
  private var tableBottomConstraint: NSLayoutConstraint?
  private var composerBottomConstraint: NSLayoutConstraint?
  private var composerHeightConstraint: NSLayoutConstraint?
  private var toggleScrollLockDepth = 0
  private var changeObserver: NSObjectProtocol?
  private var keyboardObservers: [NSObjectProtocol] = []
  private let bottomEdgeFadeView = UIView()
  private let editToastBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let editToastIcon = UIImageView()
  private let editToastLabel = UILabel()
  private let usageBannerView = ChatPinnedBannerView()
  private var usageBannerVisible = false
  private var usageBannerKey: String?
  private let commandOverlayView = VibeAgentCommandOverlayView()

  // A short confirmation toast for composer actions that used to pop the (oversized,
  // unbounded-height) command overlay — `/usage` now just refreshes the pinned banner
  // above and confirms here instead; `/plan` confirms here instead of a local panel.
  private let infoToastBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let infoToastIcon = UIImageView()
  private let infoToastLabel = UILabel()
  private var infoToastHideWork: DispatchWorkItem?

  // Subagent (Claude Task tool) surfacing: a top toast announces a subagent starting,
  // and tapping it (or its feed row) opens a read-only detail view of its steps.
  private let subagentToastBlur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let subagentToastLabel = UILabel()
  private var subagentToastTarget: (messageId: String, nodeId: String)?
  private var subagentToastHideWork: DispatchWorkItem?
  private var toastedSubagentIds: Set<String> = []
  private weak var openSubagentDetail: VibeAgentSubagentDetailViewController?
  private var openSubagentRef: (messageId: String, nodeId: String)?

  // In-view header (the app hides the system nav bar, so this VC carries its own):
  // model name centered (tappable → model/thinking/speed), connected device beneath,
  // plus back / new-chat / overflow. Shown only when NOT embedded in a SwiftUI nav.
  private let headerContentView = UIView()
  private let backGlassView = UIVisualEffectView(effect: nil)
  private let headerBackButton = UIButton(type: .system)
  private let avatarGlassView = UIVisualEffectView(effect: nil)
  private let titleGlassView = UIVisualEffectView(effect: nil)
  private let titleButton = UIButton(type: .custom)
  private let customTitleStack = UIStackView()
  private let headerModelButton = UIButton(type: .system)
  private let rightActionsGlassView = UIVisualEffectView(effect: nil)
  private let rightActionsStack = UIStackView()
  private var usesInViewHeader: Bool { !isEmbeddedInSwiftUI && !embeddedInChatHost }

  /// The header profile avatar — the SAME avatar as the main chat view (gradient +
  /// optional fetched picture), not a generic SF person glyph. The host seeds these so
  /// it can resolve the conversation's real avatar.
  private let headerAvatarView = VibeAgentHeaderAvatarView()
  var avatarTitle: String?
  var avatarPeerUserId: String?
  var avatarChatId: String?
  var avatarURI: String? { didSet { if isViewLoaded { refreshHeaderAvatar() } } }

  /// History button — its own standalone trailing element, immediately to the left of
  /// the profile avatar. Stays put when the new-chat button animates in/out.
  private lazy var headerHistoryButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "clock.arrow.circlepath"), for: .normal)
    btn.addTarget(self, action: #selector(historyTapped), for: .touchUpInside)
    btn.accessibilityLabel = "History"
    btn.setContentHuggingPriority(.required, for: .horizontal)
    btn.setContentCompressionResistancePriority(.required, for: .horizontal)
    return btn
  }()

  /// New-chat button — only present once a history/turn is loaded. It animates IN next
  /// to the history button (and out again) without disturbing history/profile.
  private lazy var headerNewChatActionButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
    btn.addTarget(self, action: #selector(newChatTapped), for: .touchUpInside)
    btn.accessibilityLabel = "New Chat"
    btn.setContentHuggingPriority(.required, for: .horizontal)
    btn.setContentCompressionResistancePriority(.required, for: .horizontal)
    return btn
  }()

  /// "Computer" button — visible once this chat has a preview frame or live computer
  /// state. Presents the live sheet, falling back to the last frame.
  private lazy var headerComputerButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "display"), for: .normal)
    btn.addTarget(self, action: #selector(computerPreviewTapped), for: .touchUpInside)
    btn.accessibilityLabel = "Computer"
    btn.setContentHuggingPriority(.required, for: .horizontal)
    btn.setContentCompressionResistancePriority(.required, for: .horizontal)
    btn.isHidden = true
    return btn
  }()

  /// Container for ONLY history + new chat — the cloud (profile) is deliberately NOT in
  /// here; it stays its own standalone bar-button item. Arranged left→right as
  /// new chat, history, so new chat animates in hugging the history button while the
  /// cloud (a separate item further trailing) never shares a wrapper with them.
  private lazy var headerHistoryActionsStack: UIStackView = {
    let stack = UIStackView(arrangedSubviews: [
      headerComputerButton, headerNewChatActionButton, headerHistoryButton,
    ])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 16
    return stack
  }()

  /// Floating 96pt live "computer" thumbnail above the composer; tap opens the full sheet.
  /// Hidden until the first `agent-preview` frame for this chat.
  private lazy var computerThumbnailView: UIImageView = {
    let iv = UIImageView()
    iv.contentMode = .scaleAspectFill
    iv.clipsToBounds = true
    iv.layer.cornerRadius = 14
    iv.backgroundColor = UIColor.black.withAlphaComponent(0.85)
    iv.isUserInteractionEnabled = true
    iv.isHidden = true
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.accessibilityLabel = "Computer preview"
    iv.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(computerPreviewTapped)))
    return iv
  }()

  /// Floating "jump to latest" control above the composer; appears when the feed is
  /// scrolled away from the bottom and snaps it back on tap.
  private let jumpToBottomButton = UIButton(type: .system)
  private var jumpToBottomBottomConstraint: NSLayoutConstraint?
  private var jumpButtonVisible = false
  /// One-shot guard so the feed lands pinned to the bottom on first appearance without a
  /// visible settle/shift as content size and insets resolve.
  private var hasPerformedInitialScroll = false
  /// Notified when the model/intelligence/speed selection changes so the header label
  /// stays in sync with the menu.
  private var selectionObserver: NSObjectProtocol?

  /// The model a loaded run reports (history list / live task). The header shows this
  /// when the user hasn't explicitly overridden the model, so a resumed/opened session
  /// reflects its real model instead of the local default.
  var runModel: String? {
    didSet {
      guard isViewLoaded else { return }
      updateWorkspace()
      updateHeaderTexts()
    }
  }
  /// Bridge-reported thinking/reasoning effort for the loaded run/session (if known).
  var runReasoningEffort: String? {
    didSet {
      guard isViewLoaded else { return }
      updateWorkspace()
      updateHeaderTexts()
    }
  }
  /// Connected computer name shown beneath the model (e.g. "MacBook-Pro.local").
  var deviceLabel: String?
  /// Whether that computer is currently online (drives the "· reconnecting" hint).
  var deviceConnected: Bool = true

  /// True if a chat history was explicitly picked or a new message was sent.
  /// When false, the view hides messages and shows the "History" button instead of
  /// the standard "New Chat" / "Menu" actions.
  var isHistoryPicked: Bool = false {
    didSet {
      guard isViewLoaded else { return }
      updateNavigationButtons()
      updateRepoPickerStyle()
      updateEmptyState()
      updateWorkspace()
      tableView.reloadData()
      updateUsageBanner()
    }
  }

  /// Closure called when the user taps "History"
  var onPresentHistory: (() -> Void)?
  /// Closure called when the user taps the agent profile button.
  var onPresentProfile: (() -> Void)?

  /// A chat-shaped skeleton (alternating agent/user placeholder bubbles with a soft
  /// low-contrast shimmer) shown while a session's transcript is loading, instead of a
  /// bare spinner or a fake "Loading conversation…" bubble. It COVERS the feed until the
  /// real rows are materialized underneath and then cross-fades away, so the transition
  /// reads skeleton → chat with no blank flash in between.
  private let loadingSkeleton = VibeAgentTranscriptSkeletonView()
  private var skeletonVisible = false
  /// Safety fallback: if a transcript never lands, fade the skeleton out to the empty
  /// state rather than covering the feed forever.
  private var skeletonSafetyTimeout: DispatchWorkItem?
  private let repoPickerButton = UIButton(type: .system)

  /// Menu assigned by the host (ChatListView) to display Repo/Permission/Report/History options.
  var repoPickerMenu: UIMenu? {
    didSet {
      repoPickerButton.menu = repoPickerMenu
      updateRepoPickerStyle()
    }
  }
  /// Centered welcome shown when the conversation is empty (and not loading): the agent
  /// chat surface lands here directly — a fresh chat with a clear "start typing" cue —
  /// rather than a separate history screen. Past sessions stay reachable via the nav
  /// buttons (new chat / menu); this just keeps the blank state from looking broken.
  private let emptyStateView = UIStackView()
  private let emptyStateIcon = UIImageView()
  private let emptyStateTitle = UILabel()
  private let emptyStateSubtitle = UILabel()
  private let emptyStateVisibleGuide = UILayoutGuide()
  var isLoadingTranscript = false {
    didSet {
      updateLoadingOverlay()
      updateUsageBanner()
    }
  }

  /// Tapping a message's progress row opens the full tool sheet for that message.
  /// Stashed so we know which message's items to present.
  private var progressItemsByMessageId: [String: [VibeAgentKitProgressItem]] = [:]

  /// Message ids whose "Worked · N steps" line is currently expanded inline.
  /// Persists across reloads so a live update doesn't collapse what the user opened.
  private var expandedProgressMessageIds: Set<String> = []
  private var expandedRuntimeMessageIds: Set<String> = []

  /// User message ids whose long prompt bubble is expanded. Long prompts collapse by
  /// default so the table does not inherit huge row heights or blank lower padding.
  private var expandedTextMessageIds: Set<String> = []

  /// Per-message set of step node-ids whose detail layer is open (the command/result
  /// box, the edit patch, the read file slice). Keyed by message id → node ids; persists
  /// across reloads so a live tick doesn't re-collapse a step the user drilled into.
  private var expandedStepIdsByMessage: [String: Set<String>] = [:]

  /// When each still-streaming turn was first seen as live. The "Working · M:SS" clock
  /// reads from this so it counts up steadily and NEVER restarts as new chunks arrive
  /// (a fresh `Date()` per chunk was what made the timer appear to reset).
  private var streamStartByMessageId: [String: Date] = [:]
  /// Optimistic rows inserted locally immediately after send. The real transport rows
  /// replace them once ChatEngine/bridge state catches up.
  private var localMessageOrder: [String] = []
  private var localMessagesById: [String: VibeAgentKitChatMessage] = [:]
  private var localWorkingMessageIdBySourceId: [String: String] = [:]
  private var lastLiveHeaderStatusText: String?
  private var lastLiveHeaderStatusAt: TimeInterval = 0
  private static let liveHeaderStatusGrace: TimeInterval = 12.0

  /// Start a fresh conversation with the agent (clears the on-screen transcript and
  /// begins a new, non-resumed task). When nil the trailing "new chat" button is
  /// hidden — set by hosts where a new chat is meaningful (the bridge runtime view).
  var onNewChat: (() -> Void)?

  /// Back/close hook. When set (the isolated full-screen DM agent surface hosted as a
  /// child of ChatConversationController), the header back button calls this instead of
  /// pop/dismiss so the host can return to the chat surface. Nil for pushed/modal use.
  var onClose: (() -> Void)?

  /// True when this surface is the DM's PRIMARY entry — opened because the agent's Default
  /// view is "Agent", not a "See progress" drill-down from the chat surface. The host wires
  /// Back to exit the whole DM straight to Home in this case (rather than peeling back to the
  /// chat view underneath), so the agent reads as its own page, not a layer over chat.
  var isPrimaryAgentSurface = false

  /// Host hook invoked when the user picks "Edit" on a message — after the VC has
  /// reverted the turn's file changes and before it refills the composer. Hosts use
  /// it to reset into a fresh task so the revised prompt re-runs cleanly (rather than
  /// resuming the old turn). The Edit action itself is gated on `agentBridgeChatId`.
  var onEditMessage: ((VibeAgentKitChatMessage) -> Void)?

  /// If true, this controller is embedded in a SwiftUI view (like AgentBridgeRuntimeView)
  /// and the SwiftUI NavigationStack will manage the navigation bar and header.
  var isEmbeddedInSwiftUI = false

  /// True when hosted in-place inside ChatMainView's bridge DM surface. The shared chat
  /// header (the model + device glass pills) provides the chrome, so this VC suppresses
  /// its own in-view header and just fills the body with the runtime feed + composer —
  /// switching chat⇄agent then has no present/dismiss shift.
  var embeddedInChatHost = false

  /// Chat + provider context (history surface) so a runtime card can route a
  /// full-file-open request to the user's bridge. Nil in the live agent view.
  var agentBridgeChatId: String? {
    didSet {
      composerView.bridgeChatId = agentBridgeChatId
      if isViewLoaded { updateComputerPreviewAffordances() }
    }
  }
  /// Set by a host that already knows the agent; otherwise the session resolves it from
  /// this chat's peer. Skips one lookup on the way into the Computer sheet.
  var agentComputerAgentId: String?
  private var computerSheetOpening = false

  var agentBridgeProvider: String? {
    didSet {
      composerView.provider = agentBridgeProvider ?? "codex"
      composerView.bridgeChatId = agentBridgeChatId
      if isViewLoaded {
        updateHeaderTexts()
        updateWorkspace()
      }
    }
  }

  /// The session ids identifying the CONVERSATION this page shows (History-picked and/or
  /// adopted-from-turns), supplied live by the hosting ChatListView. Used to scope
  /// ask/command sheets: every session shares one DM chatId, so without this an ask from
  /// a different conversation would pop over this page. Empty/nil ⇒ no session identity
  /// yet ⇒ present (fail-open, matching the bubble surface's fallback).
  var agentBridgeAskSessionScope: ((Set<String>) -> (owns: Bool, hasIdentity: Bool))?

  init(
    title: String,
    subtitle: String = "",
    messages: [VibeAgentKitChatMessage],
    regeneratePrompt: String = "",
    inputPlaceholder: String? = nil,
    surfaceMode: VibeAgentConversationSurfaceMode = .transcript,
    messagesProvider: (() -> [VibeAgentKitChatMessage])? = nil,
    onSend: ((String, AgentBridgeRunOptions, [String]) -> Void)? = nil
  ) {
    self.messages = messages
    self.runtimeTitle = title
    self.runtimeSubtitle = subtitle
    self.inputPlaceholder = inputPlaceholder ?? "Ask \(title)"
    self.regeneratePrompt = regeneratePrompt
    self.surfaceMode = surfaceMode
    self.messagesProvider = messagesProvider
    self.onSend = onSend
    self.appearance = .fallback
    super.init(nibName: nil, bundle: nil)
    self.title = title
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if let changeObserver {
      NotificationCenter.default.removeObserver(changeObserver)
    }
    if let selectionObserver {
      NotificationCenter.default.removeObserver(selectionObserver)
    }
    keyboardObservers.forEach(NotificationCenter.default.removeObserver)
  }

  @objc func closeTapped() {
    if let onClose {
      onClose()
      return
    }
    if let nav = navigationController, nav.viewControllers.first !== self {
      nav.popViewController(animated: true)
    } else {
      dismiss(animated: true)
    }
  }

  private func configureNewChatButton(animated: Bool = false) {
    guard !isEmbeddedInSwiftUI, !embeddedInChatHost else { return }
    installHeaderActionsItem()
    updateHeaderActionButtons(animated: animated)
  }

  /// Install TWO separate trailing items: the cloud (profile) as its own standalone
  /// element at the trailing edge, and — to its left, after a gap — the history + new
  /// chat group. Keeping the cloud out of the group is what makes it read as a single
  /// independent element instead of being warped together with the action buttons.
  private func installHeaderActionsItem() {
    headerAvatarView.removeTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    headerAvatarView.addTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    refreshHeaderAvatar()
    
    guard !usesInViewHeader else { return }
    
    // Already installed? The history/new-chat group is the trailing-most custom stack.
    if navigationItem.rightBarButtonItems?.last?.customView === headerHistoryActionsStack {
      return
    }
    let profileItem = UIBarButtonItem(customView: headerAvatarView)
    profileItem.accessibilityLabel = "Profile"
    let gap = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
    gap.width = 12
    let actionsItem = UIBarButtonItem(customView: headerHistoryActionsStack)
    actionsItem.accessibilityLabel = "Agent actions"
    // Index 0 = trailing edge: cloud sits alone at the edge, gap, then history group.
    navigationItem.rightBarButtonItems = [profileItem, gap, actionsItem]
  }

  /// Show/hide the new-chat button next to history. Animating only this arranged
  /// subview keeps the profile + history anchored to the trailing edge while new chat
  /// slides/fades in beside the history button.
  private func updateHeaderActionButtons(animated: Bool) {
    let targetHidden = !isHistoryPicked
    guard headerNewChatActionButton.isHidden != targetHidden else {
      headerNewChatActionButton.alpha = targetHidden ? 0 : 1
      return
    }
    if animated {
      if !targetHidden { headerNewChatActionButton.alpha = 0 }
      view.setNeedsLayout()
      UIView.animate(
        withDuration: 0.28, delay: 0,
        usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4,
        options: [.curveEaseInOut, .allowUserInteraction]
      ) {
        self.headerNewChatActionButton.isHidden = targetHidden
        self.headerNewChatActionButton.alpha = targetHidden ? 0 : 1
        if self.usesInViewHeader {
          self.layoutCustomHeaderViews()
        } else {
          self.headerHistoryActionsStack.layoutIfNeeded()
          self.navigationController?.navigationBar.layoutIfNeeded()
        }
      }
    } else {
      headerNewChatActionButton.isHidden = targetHidden
      headerNewChatActionButton.alpha = targetHidden ? 0 : 1
      view.setNeedsLayout()
    }
  }

  /// Feed the header avatar the conversation's real identity so it renders the same
  /// gradient/picture as the main chat view (falls back to the runtime title).
  private func refreshHeaderAvatar() {
    headerAvatarView.configure(
      title: avatarTitle ?? runtimeTitle,
      peerUserId: avatarPeerUserId,
      chatId: avatarChatId,
      avatarURI: avatarURI,
      isDark: appearance.isDark
    )
  }

  private func updateNavigationButtons() {
    if !isEmbeddedInSwiftUI && !embeddedInChatHost {
      // Only animate if the view is already on screen (window != nil) so it doesn't
      // animate on initial load.
      let animated = viewIfLoaded?.window != nil
      configureNewChatButton(animated: animated)
    } else {
      buildInViewHeader()
    }
  }


  @objc private func historyTapped() {
    onPresentHistory?()
  }

  @objc private func profileTapped() {
    onPresentProfile?()
  }

  /// Opens the LIVE computer sheet when a session can be created; the still-frame sheet
  /// stays the fallback for no gateway / 429 capacity (agent-computer-v1 §2).
  @objc private func computerPreviewTapped() {
    guard let chatId = agentBridgeChatId, !chatId.isEmpty else { return }
    guard !computerSheetOpening else { return }
    computerSheetOpening = true
    setComputerAffordancesBusy(true)
    VibeAgentComputerSession.create(agentId: agentComputerAgentId, chatId: chatId) {
      [weak self] result in
      guard let self else { return }
      self.computerSheetOpening = false
      self.setComputerAffordancesBusy(false)
      let canPresent = self.viewIfLoaded?.window != nil && self.presentedViewController == nil
      guard canPresent else {
        if case .success(let session) = result { session.stop() }
        return
      }
      switch result {
      case .success(let session):
        self.present(
          VibeAgentComputerViewController(
            session: session, agentTitle: self.runtimeTitle, appearance: self.appearance),
          animated: true)
      case .failure:
        self.present(
          VibeAgentComputerPreviewViewController(
            chatId: chatId, appearance: self.appearance,
            fallbackNote: "Live view unavailable — showing the latest frame."),
          animated: true)
      }
    }
  }

  private func setComputerAffordancesBusy(_ busy: Bool) {
    headerComputerButton.isEnabled = !busy
    computerThumbnailView.isUserInteractionEnabled = !busy
    UIView.animate(withDuration: 0.15) {
      self.headerComputerButton.alpha = busy ? 0.45 : 1.0
      self.computerThumbnailView.alpha = busy ? 0.6 : 1.0
    }
  }

  /// Show/hide the header button + floating thumbnail once a "computer" preview frame
  /// has arrived for this chat (agent-platform-v1 §3.4).
  private func updateComputerPreviewAffordances() {
    let preview = agentBridgeChatId.flatMap { ChatEngine.shared.latestAgentPreview(chatId: $0) }
    let computer = agentBridgeChatId.flatMap { ChatEngine.shared.latestAgentComputer(chatId: $0) }
    // The button rides either signal; the thumbnail needs an actual frame.
    headerComputerButton.isHidden = preview == nil && computer == nil
    computerThumbnailView.isHidden = preview == nil
    if let preview {
      computerThumbnailView.image = preview.image
    }
  }

  @objc private func handleTranscriptTap() {
    view.endEditing(true)
  }

  // The dismiss tap lives on the root view; let it coexist with the table's own
  // gestures and ignore touches that land inside the composer (so typing / its buttons
  // keep working while a tap anywhere else dismisses the keyboard).
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    guard let touched = touch.view else { return true }
    return !touched.isDescendant(of: composerView)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }

  @objc private func jumpToBottomTapped() {
    scrollToBottom(animated: true)
    setJumpButtonVisible(false)
  }

  @objc private func newChatTapped() {
    startNewChat()
  }

  private func startNewChat() {
    expandedProgressMessageIds.removeAll()
    expandedRuntimeMessageIds.removeAll()
    expandedTextMessageIds.removeAll()
    expandedStepIdsByMessage.removeAll()
    progressItemsByMessageId.removeAll()
    streamStartByMessageId.removeAll()
    localMessageOrder.removeAll()
    localMessagesById.removeAll()
    localWorkingMessageIdBySourceId.removeAll()
    messages = []
    isLoadingTranscript = false
    isHistoryPicked = false
    updateWorkspace()
    tableView.reloadData()
    updateNavigationLiveState()
    updateLoadingOverlay()
    updateEditToast()
    updateUsageBanner(force: true)
    hideCommandOverlay()
    onNewChat?()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "agent.ask.sheet"
    // Let the feed extend under the (now translucent) nav bar and the bottom edge so
    // content flows edge-to-edge and the bars read as seamless blur — no opaque block.
    edgesForExtendedLayout = .all
    extendedLayoutIncludesOpaqueBars = true
    appearance = VibeAgentKitMap.appearance(for: traitCollection)
    view.backgroundColor = appearance.background
    configureNavigationTitle()
    configureNewChatButton()

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = appearance.background
    tableView.separatorStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 96.0
    tableView.keyboardDismissMode = .interactive
    if #available(iOS 26.0, *) {
      tableView.topEdgeEffect.style = .soft
      tableView.bottomEdgeEffect.style = .soft
    }
    // Bottom is driven by `updateScrollInsets()` (tracks the composer + keyboard); top
    // keeps a little breathing room under the translucent nav bar.
    tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
    tableView.register(VibeAgentKitMessageCell.self, forCellReuseIdentifier: VibeAgentKitMessageCell.reuseIdentifier)
    tableView.register(
      VibeAgentKitCompactionCell.self,
      forCellReuseIdentifier: VibeAgentKitCompactionCell.reuseIdentifier)
    view.addSubview(tableView)

    workspaceView.translatesAutoresizingMaskIntoConstraints = false
    workspaceView.isHidden = surfaceMode != .visual
    workspaceView.applyAppearance(appearance)
    view.addSubview(workspaceView)
    tableView.isHidden = surfaceMode == .visual

    // Tap anywhere outside the composer to dismiss the keyboard. Installed on the ROOT
    // view (not just the table) so a tap in the empty feed area or under the composer's
    // own glass row still dismisses; the delegate excludes touches inside the composer so
    // the text view / its buttons keep working. `cancelsTouchesInView = false` keeps cell
    // taps and links alive.
    let dismissTap = UITapGestureRecognizer(target: self, action: #selector(handleTranscriptTap))
    dismissTap.cancelsTouchesInView = false
    dismissTap.delegate = self
    view.addGestureRecognizer(dismissTap)

    composerView.translatesAutoresizingMaskIntoConstraints = false
    composerView.applyAppearance(appearance)
    composerView.placeholder = inputPlaceholder
    composerView.provider = agentBridgeProvider ?? "codex"
    composerView.bridgeChatId = agentBridgeChatId
    composerView.onSend = { [weak self] text, options in
      guard let self else { return }
      self.isHistoryPicked = true
      self.onSend?(text, options, self.composerView.consumePendingAttachments())
    }
    composerView.onCommand = { [weak self] command in
      guard let self else { return }
      let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      self.handleComposerCommand(trimmed)
    }
    composerView.onAttach = { [weak self] in
      self?.presentImageAttachmentPicker()
    }
    composerView.onCamera = { [weak self] in
      self?.presentCameraPicker()
    }
    composerView.onFile = { [weak self] in
      self?.presentFilePicker()
    }
    composerView.onOpenToolsSheet = { [weak self] vc in
      self?.present(vc, animated: true)
    }
    composerView.onStop = { [weak self] in
      self?.stopActiveTask()
    }
    composerView.onHeightChanged = { [weak self] height in
      self?.updateComposerHeight(height, animated: true)
    }
    view.addSubview(composerView)

    setupEditToast()

    repoPickerButton.translatesAutoresizingMaskIntoConstraints = false
    repoPickerButton.showsMenuAsPrimaryAction = true
    updateRepoPickerStyle()
    view.addSubview(repoPickerButton)
    view.addSubview(computerThumbnailView)

    progressSheet.translatesAutoresizingMaskIntoConstraints = false
    progressSheet.applyAppearance(appearance)
    progressSheet.isHidden = true
    view.addSubview(progressSheet)

    loadingSkeleton.applyAppearance(appearance)
    loadingSkeleton.isHidden = true
    // The skeleton is the table's OWN backgroundView — inside the list, behind its rows —
    // so any row that does render sits on top of it instead of being covered by an
    // absolute overlay; the composer/chrome stay live above the table as before.
    tableView.backgroundView = loadingSkeleton

    setupEmptyState()
    setupUsageBanner()
    setupCommandOverlay()
    setupSubagentToast()
    setupInfoToast()

    // Pin the feed to the TRUE bottom so messages scroll UNDER the floating composer
    // (Resolo-style, no hard footer line). `updateScrollInsets()` keeps a bottom
    // content inset equal to the composer's covered height so the last bubble clears
    // the pill, and grows it with the keyboard.
    let tableBottomConstraint = tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    // Pin the composer's bottom to the KEYBOARD LAYOUT GUIDE, not the view bottom. The
    // guide tracks the keyboard natively — including the interactive swipe-to-dismiss drag
    // — so the composer rides with the keyboard frame-for-frame instead of being animated
    // separately by notifications (which left it "stuck in the middle" on a swipe-down).
    // `usesBottomSafeArea = false` collapses the guide to the view's true bottom when the
    // keyboard is offscreen, so the composer still owns its home-indicator inset there.
    view.keyboardLayoutGuide.usesBottomSafeArea = false
    let composerBottomConstraint = composerView.bottomAnchor.constraint(
      equalTo: view.keyboardLayoutGuide.topAnchor)
    let composerHeightConstraint = composerView.heightAnchor.constraint(equalToConstant: composerView.preferredHeight)
    self.tableBottomConstraint = tableBottomConstraint
    self.composerBottomConstraint = composerBottomConstraint
    self.composerHeightConstraint = composerHeightConstraint

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableBottomConstraint,
      workspaceView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      workspaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      workspaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      workspaceView.bottomAnchor.constraint(equalTo: composerView.topAnchor),
      composerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      composerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      composerBottomConstraint,
      composerHeightConstraint,
      editToastBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      editToastBlur.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor, constant: 16.0),
      editToastBlur.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor, constant: -16.0),
      editToastBlur.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8.0),
      repoPickerButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      repoPickerButton.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8.0),
      computerThumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      computerThumbnailView.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8.0),
      computerThumbnailView.widthAnchor.constraint(equalToConstant: 96),
      computerThumbnailView.heightAnchor.constraint(equalToConstant: 96),
      progressSheet.topAnchor.constraint(equalTo: view.topAnchor),
      progressSheet.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      progressSheet.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      progressSheet.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      usageBannerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18.0),
      usageBannerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18.0),
      usageBannerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8.0),
      usageBannerView.heightAnchor.constraint(equalToConstant: ChatPinnedBannerView.preferredHeight),
      commandOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18.0),
      commandOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18.0),
      commandOverlayView.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -10.0),
    ])

    view.addLayoutGuide(emptyStateVisibleGuide)
    NSLayoutConstraint.activate([
      emptyStateVisibleGuide.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      emptyStateVisibleGuide.bottomAnchor.constraint(equalTo: composerView.topAnchor),
      emptyStateVisibleGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateVisibleGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      emptyStateView.centerXAnchor.constraint(equalTo: emptyStateVisibleGuide.centerXAnchor),
      emptyStateView.centerYAnchor.constraint(
        equalTo: emptyStateVisibleGuide.centerYAnchor, constant: -16.0),
      emptyStateView.leadingAnchor.constraint(
        greaterThanOrEqualTo: emptyStateVisibleGuide.leadingAnchor, constant: 40.0),
      emptyStateView.trailingAnchor.constraint(
        lessThanOrEqualTo: emptyStateVisibleGuide.trailingAnchor, constant: -40.0),
    ])

    updateEmptyState()

    bottomEdgeFadeView.translatesAutoresizingMaskIntoConstraints = false
    bottomEdgeFadeView.isUserInteractionEnabled = false
    view.insertSubview(bottomEdgeFadeView, belowSubview: composerView)
    NSLayoutConstraint.activate([
      bottomEdgeFadeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomEdgeFadeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomEdgeFadeView.bottomAnchor.constraint(equalTo: composerView.bottomAnchor),
      bottomEdgeFadeView.topAnchor.constraint(equalTo: composerView.topAnchor, constant: -48),
    ])
    updateBottomEdgeFade()
    setupJumpToBottomButton()

    // Configure model popup on load
    DispatchQueue.main.async { [weak self] in
      self?.refreshModelMenu()
    }

    trackStreamStarts(messages)
    indexProgress()
    updateWorkspace()
    updateComputerPreviewAffordances()
    observeKeyboard()
    observeLiveMessages()
    // First landing is handled in viewDidLayoutSubviews (once content + insets resolve)
    // so the feed opens pinned to the bottom with no visible settle/shift.
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if usesInViewHeader {
      navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    applyNavigationAppearance()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    view.endEditing(true)
    if usesInViewHeader {
      navigationController?.setNavigationBarHidden(false, animated: animated)
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    // SwiftUI host nav stack restores its own appearance AFTER viewWillAppear (during
    // the UIKit appearance sequence, not before). viewIsAppearing fires later — after
    // SwiftUI has committed its layout pass — so our transparent bar wins.
    applyNavigationAppearance()
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if traitCollection.userInterfaceStyle != previous?.userInterfaceStyle {
      appearance = VibeAgentKitMap.appearance(for: traitCollection)
      view.backgroundColor = appearance.background
      tableView.backgroundColor = appearance.background
      workspaceView.applyAppearance(appearance)
      progressSheet.applyAppearance(appearance)
      composerView.applyAppearance(appearance)
      commandOverlayView.applyAppearance(appearance)
      loadingSkeleton.applyAppearance(appearance)
      updateEditToastAppearance()
      updateInfoToastAppearance()
      if !isEmbeddedInSwiftUI {
        applyNavigationAppearance()
      }
      refreshHeaderAvatar()
      updateJumpButtonAppearance()
      updateBottomEdgeFade()
      updateEmptyState()
      updateUsageBanner(force: true)
      updateWorkspace()
      tableView.reloadData()
    }
  }

  // MARK: Live updates

  func appendLocalPendingTurn(messageId: String, body: String) {
    let id = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { return }
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayBody = trimmedBody.isEmpty ? "Please take a look at the attached image." : trimmedBody
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    upsertLocalMessage(
      VibeAgentKitChatMessage(
        id: id,
        role: .user,
        text: displayBody,
        timestamp: "",
        timestampMs: nowMs
      )
    )
    let workingId = "local-working-\(id)"
    localWorkingMessageIdBySourceId[id] = workingId
    upsertLocalMessage(
      VibeAgentKitChatMessage(
        id: workingId,
        role: .assistant,
        text: "",
        timestamp: "",
        timestampMs: nowMs + 1,
        isStreaming: true
      )
    )
    setMessages(messages)
  }

  private func upsertLocalMessage(_ message: VibeAgentKitChatMessage) {
    localMessagesById[message.id] = message
    if !localMessageOrder.contains(message.id) {
      localMessageOrder.append(message.id)
    }
  }

  private func removeLocalMessage(_ id: String) {
    localMessagesById.removeValue(forKey: id)
    localMessageOrder.removeAll { $0 == id }
  }

  private func mergeLocalMessages(into incoming: [VibeAgentKitChatMessage]) -> [VibeAgentKitChatMessage] {
    let incomingIds = Set(incoming.map(\.id))
    for id in incomingIds where localMessagesById[id] != nil {
      removeLocalMessage(id)
    }

    var resolvedWorkingSources: [(sourceId: String, workingId: String)] = []
    for (sourceId, workingId) in localWorkingMessageIdBySourceId {
      let hasSourceLinkedReply = incoming.contains { message in
        !message.role.isUser
          && !message.id.hasPrefix("local-working-")
          && message.sourceMessageId == sourceId
      }
      let hasAdjacentReply: Bool = {
        guard let sourceIndex = incoming.firstIndex(where: { $0.id == sourceId }) else { return false }
        let replyStart = incoming.index(after: sourceIndex)
        return replyStart < incoming.endIndex
          && incoming[replyStart...].contains { message in
            !message.role.isUser && !message.id.hasPrefix("local-working-")
          }
      }()
      let hasRealReply = hasSourceLinkedReply || hasAdjacentReply
      guard hasRealReply else { continue }
      resolvedWorkingSources.append((sourceId, workingId))
    }
    for resolved in resolvedWorkingSources {
      let sourceId = resolved.sourceId
      let workingId = resolved.workingId
      removeLocalMessage(workingId)
      localWorkingMessageIdBySourceId.removeValue(forKey: sourceId)
    }

    let local = localMessageOrder.compactMap { id -> VibeAgentKitChatMessage? in
      guard !incomingIds.contains(id) else { return nil }
      return localMessagesById[id]
    }
    return incoming + local
  }

  /// Replace the rendered messages (e.g. when the agent stream advances). Cheap
  /// reload is fine here — the surface is single-task and short.
  func setMessages(_ incomingMessages: [VibeAgentKitChatMessage]) {
    let newMessages = mergeLocalMessages(into: incomingMessages)
    guard newMessages != messages else { return }
    if !isHistoryPicked,
      newMessages.contains(where: { $0.isStreaming || $0.runtime?.status == "running" })
    {
      isHistoryPicked = true
    }

    // Intercept newly arrived bridge info-command results. `/usage` gets a toast (the
    // pinned usage banner, refreshed below by `updateUsageBanner()`, already carries the
    // detail) instead of the old unbounded-height overlay, which could grow to cover the
    // whole screen for a long result; everything else still uses the overlay.
    let previousIds = Set(messages.map(\.id))
    for msg in newMessages where msg.runtime?.command?.executable?.lowercased() == "vibe-bridge"
      && !previousIds.contains(msg.id)
    {
      if bridgeCommandName(msg) == "usage" {
        showInfoToast(title: "Usage updated", systemImage: "gauge.with.dots.needle.bottom.50percent")
      } else {
        showBridgeCommandResult(msg)
      }
    }

    let wasNearBottom = isNearBottom()
    // Capture the pre-update rendered rows (bridge commands excluded) for the pure-append
    // check and to diff per-row content on the in-place streaming path.
    let oldTableMessages = tableMessages
    let oldTableIds = oldTableMessages.map(\.id)
    messages = newMessages
    updateWorkspace()
    let liveIds = Set(newMessages.map(\.id))
    expandedTextMessageIds = expandedTextMessageIds.filter { liveIds.contains($0) }
    expandedProgressMessageIds = expandedProgressMessageIds.filter { liveIds.contains($0) }
    expandedStepIdsByMessage = expandedStepIdsByMessage.filter { liveIds.contains($0.key) }
    // Real rows arrived → drop the centered loading spinner.
    if !newMessages.isEmpty { isLoadingTranscript = false }
    trackStreamStarts(newMessages)
    indexProgress()
    updateEditToast()
    updateSubagentState(newMessages)
    updateNavigationLiveState()
    updateLoadingOverlay()
    updateUsageBanner()
    updateComposerCommandCatalog()

    // A pure append (new turns pushed onto the end — the typical "send") animates the
    // new rows in and scrolls up, matching Resolo's push-in feel. Anything else
    // (streaming edits to existing rows, replacements, reorders) falls back to a plain
    // reload so the streaming label and bubble geometry stay correct.
    let newTableIds = tableMessages.map(\.id)
    let isPureAppend =
      newTableIds.count > oldTableIds.count && Array(newTableIds.prefix(oldTableIds.count)) == oldTableIds
    // A fresh user send = the last rendered row is a user message whose id is new. Pin it
    // to the top with room reserved below for the streaming answer (ChatGPT-style) instead
    // of scrolling to the bottom.
    let newUserSendId = tableMessages.last { $0.role.isUser && !oldTableIds.contains($0.id) }?.id
    if let newUserSendId { pushToTopUserId = newUserSendId }
    // The pinned turn has finished once its answer is no longer streaming.
    let turnStillLive = tableMessages.contains { $0.isStreaming || $0.runtime?.status == "running" }
    if pushToTopUserId != nil, !turnStillLive, newUserSendId == nil {
      pushToTopUserId = nil
      pushToTopReserve = 0
      pushToTopDetached = false
      pinAnimationDeadline = nil
    }
    // A streaming delta to the SAME rows (ids unchanged) is the common live case.
    let isContentOnlyUpdate = !newTableIds.isEmpty && newTableIds == oldTableIds
    if isHistoryPicked, isPureAppend, tableView.window != nil, tableView.numberOfRows(inSection: 0) == oldTableIds.count {
      let inserted = (oldTableIds.count..<newTableIds.count).map { IndexPath(row: $0, section: 0) }
      tableView.performBatchUpdates {
        // `.none` — we drive the appearance ourselves so the new bubble springs up from
        // below as the previous messages slide up (Resolo's on-send morph), instead of a
        // flat fade.
        tableView.insertRows(at: inserted, with: .none)
      } completion: { [weak self] _ in
        guard let self else { return }
        self.animateSentRows(inserted)
        if let id = newUserSendId {
          self.pinUserMessageToTop(id: id, animated: true)
        } else if self.pushToTopUserId != nil {
          // Pinned turn growing: the reserve shrinks passively in updateScrollInsets as the
          // answer streams in; just refresh the inset (no scroll move — the question holds).
          self.updateScrollInsets()
          self.reassertPinnedOffsetIfNeeded()
        } else if wasNearBottom {
          self.scrollToBottom(animated: true)
        }
      }
    } else if isContentOnlyUpdate, isHistoryPicked, tableView.window != nil,
      tableView.numberOfRows(inSection: 0) == newTableIds.count
    {
      // Content-only update (streaming deltas to existing rows): reconfigure the on-screen
      // cells IN PLACE instead of reloadData(). A full reload dequeues fresh cells every
      // frame, which remounts the whole turn and — because prepareForReuse wipes the
      // streaming label's incremental-reveal state — re-fades the ENTIRE answer on each
      // delta (the "flicker / extra fade" bug). Reusing the live cell instance lets the
      // label fade in only the newly-arrived characters.
      for indexPath in tableView.indexPathsForVisibleRows ?? [] {
        let row = indexPath.row
        guard row < tableMessages.count else { continue }
        // Only touch rows whose content actually changed (the streaming turn). Leaving
        // finished rows untouched stops them from rebuilding (and re-fading) every frame.
        if row < oldTableMessages.count, oldTableMessages[row] == tableMessages[row] { continue }
        reconfigureVisibleCell(at: indexPath)
      }
      // Pick up the new self-sized heights without a reload or a competing animation, so
      // the answer grows smoothly under the pinned question (top stays anchored).
      UIView.performWithoutAnimation {
        tableView.beginUpdates()
        tableView.endUpdates()
      }
      // Always recompute the bottom inset. While the question is pinned this shrinks the
      // reserve as the answer grows; once the turn finishes (pin cleared above) it lets the
      // reserve collapse back to the base inset — otherwise a short final answer leaves the
      // full-screen reserve behind as a big empty stretch you can scroll into (the "double
      // gap" bug: the send reserves a screen, the finished agent answer never fills it).
      updateScrollInsets()
      if pushToTopUserId == nil, wasNearBottom {
        scrollToBottom(animated: false)
      } else {
        reassertPinnedOffsetIfNeeded()
      }
    } else {
      tableView.reloadData()
      // Materialize real self-sized heights BEFORE any reserve/offset math below.
      // Right after reloadData the table only has ESTIMATED heights (96pt/row), which
      // undercount the content below the pinned question — computedPushToTopReserve
      // then re-inflates the bottom inset into a big scrollable dead gap on every
      // update that lands on this branch (it collapsed again as soon as any inline
      // toggle forced a real layout, which is exactly the reported flicker cycle).
      if tableView.window != nil {
        UIView.performWithoutAnimation { tableView.layoutIfNeeded() }
      }
      if let id = newUserSendId {
        pinUserMessageToTop(id: id, animated: true)
      } else {
        // Pinned turn growing: the reserve shrinks passively here. Finished turn: the
        // reserve collapses back to the base inset (same anti-"double gap" reset as above).
        updateScrollInsets()
        if pushToTopUserId == nil, wasNearBottom {
          scrollToBottom(animated: true)
        } else {
          reassertPinnedOffsetIfNeeded()
        }
      }
    }

    // Rows are now materialized and laid out underneath (every branch above commits its
    // cells before returning). If the loading skeleton is still covering the feed, cross-
    // fade it away NOW — revealing real content, never an empty gap.
    if skeletonVisible, !messages.isEmpty {
      revealTranscriptFromSkeleton()
    }
  }

  /// Resolo-style send morph: the freshly inserted bubble(s) spring up from a small
  /// downward offset (with a quick fade) while `scrollToBottom` slides the earlier
  /// messages up — so a send reads as the previous message being pushed up by the new one.
  private func animateSentRows(_ inserted: [IndexPath]) {
    let cells = inserted.compactMap { indexPath -> UITableViewCell? in
      guard indexPath.row < tableMessages.count, tableMessages[indexPath.row].role.isUser else {
        return nil
      }
      return tableView.cellForRow(at: indexPath)
    }
    guard !cells.isEmpty else { return }
    for cell in cells {
      cell.transform = CGAffineTransform(translationX: 0, y: 22)
      cell.alpha = 0
    }
    UIView.animate(
      withDuration: 0.42,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.4,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      for cell in cells {
        cell.transform = .identity
        cell.alpha = 1
      }
    }
  }

  func setTranscriptLoading(_ loading: Bool) {
    if loading {
      isHistoryPicked = true
      // A fresh session is loading — re-arm the one-shot so its first laid-out rows land
      // pinned to the bottom (no settle), just like the initial open.
      hasPerformedInitialScroll = false
    }
    isLoadingTranscript = loading
    updateRepoPickerStyle()
    updateEmptyState()
    updateWorkspace()
    updateUsageBanner()
  }

  private func observeLiveMessages() {
    selectionObserver = NotificationCenter.default.addObserver(
      forName: AgentBridgeSelectionStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.updateRepoPickerStyle()
    }

    guard messagesProvider != nil else { return }
    changeObserver = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      self.refreshFromProvider()
      if (note.userInfo?["reason"] as? String) == "agentBridgeAsk" {
        self.handleAgentBridgeAsk(note.userInfo ?? [:])
      }
      let reason = note.userInfo?["reason"] as? String
      if reason == "agentPreview" || reason == "agentComputer",
        (note.userInfo?["chatId"] as? String) == self.agentBridgeChatId
      {
        self.updateComputerPreviewAffordances()
      }
    }
  }

  /// A plan-approval / question request arrived from the bridge for this chat.
  /// Decrypt the sealed body and present the approval/ask sheet (once per request).
  private func handleAgentBridgeAsk(_ info: [AnyHashable: Any]) {
    let infoChatId = (info["chatId"] as? String) ?? ""
    let infoRequestId = (info["requestId"] as? String) ?? ""
    NSLog(
      "[AgentView][ask] handle ENTER vcChat=%@ infoChat=%@ requestId=%@ kind=%@",
      agentBridgeChatId ?? "nil", infoChatId, infoRequestId, (info["kind"] as? String) ?? "nil"
    )
    guard let chatId = agentBridgeChatId, !chatId.isEmpty else {
      NSLog("[AgentView][ask] DROP — vc has no agentBridgeChatId")
      return
    }
    guard infoChatId == chatId else {
      NSLog("[AgentView][ask] DROP — chatId mismatch vc=%@ info=%@", chatId, infoChatId)
      return
    }
    // Every agent session — Claude AND Codex, every run — ingests into the SAME DM
    // chatId (sessions are isolated only by a `bridge-<sessionId>-` message prefix).
    // So a chatId match alone lets the OTHER provider's ask surface on this page.
    // Scope to this page's provider too, so a Codex ask can't pop up on the Claude
    // page (and vice-versa). Only drop when both sides name a provider and disagree.
    let infoProvider =
      (info["provider"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let vcProvider =
      (agentBridgeProvider ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !infoProvider.isEmpty, !vcProvider.isEmpty, infoProvider != vcProvider {
      NSLog(
        "[AgentView][ask] DROP — provider mismatch vc=%@ info=%@ requestId=%@",
        vcProvider, infoProvider, infoRequestId)
      return
    }
    guard !infoRequestId.isEmpty else {
      NSLog("[AgentView][ask] DROP — empty requestId")
      return
    }
    // CONVERSATION scoping: chatId+provider still match every session in this shared DM.
    // When the ask names its session (or the one it resumed from) and this page has a
    // session identity, drop on no intersection — the ask belongs to a different
    // conversation and surfaces on its own page (mirrors ChatListView's guard).
    let askSessionIds = Set(
      [
        (info["sessionId"] as? String) ?? "",
        (info["resumedFromSessionId"] as? String) ?? "",
      ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    )
    if !askSessionIds.isEmpty, let scope = agentBridgeAskSessionScope?(askSessionIds),
      !scope.owns, scope.hasIdentity
    {
      NSLog(
        "[AgentView][ask] DROP — session mismatch ask=%@ (this page shows a different conversation) requestId=%@",
        askSessionIds.joined(separator: ","), infoRequestId)
      return
    }
    let requestId = infoRequestId
    guard let payload = ChatEngine.shared.latestAgentBridgeAsk(requestId: requestId) else {
      NSLog("[AgentView][ask] DROP — no stored payload for requestId=%@", requestId)
      return
    }

    // The body is E2E-sealed (`askEnc`); an isolated-runtime run (agent-platform-v1) sends
    // `ask` plaintext instead. Fall back to plaintext `request` for a keyless pairing.
    var body: [String: Any]
    if let dec = AgentRuntimeCrypto.decrypt(payload["askEnc"]) {
      body = dec
    } else if payload["askEnc"] == nil, let ask = payload["ask"] as? [String: Any] {
      body = ["request": ask]
    } else if let raw = payload["request"] as? [String: Any] {
      body = ["request": raw]
    } else {
      NSLog(
        "[AgentView][ask] DROP — decrypt failed AND no plaintext request (sealed=%@) requestId=%@",
        payload["askEnc"] != nil ? "Y" : "N", requestId
      )
      return
    }
    let kind = (body["kind"] as? String) ?? (info["kind"] as? String) ?? "ask"
    let request = (body["request"] as? [String: Any]) ?? body
    // Cross-surface dedup: claim once so the bubble surface (or another agent view)
    // doesn't also present this same ask.
    guard ChatEngine.shared.claimAgentBridgeAskPresentation(requestId: requestId) else {
      NSLog("[AgentView][ask] DROP — already claimed by another surface requestId=%@", requestId)
      return
    }
    NSLog("[AgentView][ask] PRESENT sheet kind=%@ requestId=%@ reqKeys=%@", kind, requestId, request.keys.joined(separator: ","))
    presentAskSheet(
      requestId: requestId,
      kind: kind,
      provider: info["provider"] as? String,
      request: request
    )
  }

  private func presentAskSheet(requestId: String, kind: String, provider: String?, request: [String: Any]) {
    let sheet = VibeAgentAskSheetViewController(
      kind: kind, request: request, appearance: appearance, requestId: requestId)
    sheet.onResolve = { [weak self] decision, answer in
      self?.resolveAgentBridgeAsk(
        requestId: requestId,
        kind: kind,
        provider: provider,
        request: request,
        decision: decision,
        answer: answer
      )
    }
    sheet.onDismissWithoutResolve = {
      ChatEngine.shared.releaseAgentBridgeAskPresentation(requestId: requestId)
    }
    let nav = UINavigationController(rootViewController: sheet)
    nav.modalPresentationStyle = .pageSheet
    nav.view.backgroundColor = .clear
    if let presentation = nav.sheetPresentationController {
      presentation.detents = [.medium(), .large()]
      presentation.prefersGrabberVisible = true
      presentation.preferredCornerRadius = 22
    }
    // If this VC is already presenting (e.g. an attachment picker or a prior sheet) the
    // new present() is dropped silently — surface that so we can see it in the logs.
    if let existing = presentedViewController {
      NSLog(
        "[VibeAgentConversationView][ask] DROP present — already presenting: %@",
        String(describing: type(of: existing))
      )
      sheet.onDismissWithoutResolve?()
      return
    }
    present(nav, animated: true) {
      NSLog("[AgentView][ask] present() completed requestId=%@", requestId)
    }
  }

  /// Send the answer back to the bridge and, for an approved plan, kick off the
  /// implementation run on the proven send path (edits enabled, resuming the
  /// plan's session). A rejection with feedback asks the agent to revise the plan.
  private func resolveAgentBridgeAsk(
    requestId: String,
    kind: String,
    provider: String?,
    request: [String: Any],
    decision: String,
    answer: [String: Any]?
  ) {
    var payload: [String: Any] = [
      "chatId": agentBridgeChatId ?? "",
      "requestId": requestId,
      "decision": decision,
    ]
    if let provider, !provider.isEmpty { payload["provider"] = provider }
    if let answer, !answer.isEmpty { payload["answer"] = answer }
    _ = ChatEngine.shared.sendAgentBridgeAskResponse(payload)

    guard kind == "plan" else { return }
    let resolvedProvider = agentBridgeProvider ?? "codex"
    let feedback = (answer?["feedback"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    if decision == "approve" {
      // Approving means the user is OK with edits → switch out of plan mode so the
      // implementation turn can actually change files.
      AgentBridgeSelectionStore.setWorkMode(.allowEdits)
      let options = AgentBridgeSelectionStore.selectedRunOptions(provider: resolvedProvider)
      var prompt = "The plan above is approved. Implement it now, end to end."
      if let feedback, !feedback.isEmpty { prompt += "\n\nAdditional guidance:\n\(feedback)" }
      if let plan = (request["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !plan.isEmpty
      {
        prompt += "\n\nApproved plan:\n\(plan)"
      }
      onSend?(prompt, options, [])
      reloadLiveMessages()
    } else if decision == "reject", let feedback, !feedback.isEmpty {
      // Stay in plan mode and revise — the new plan re-triggers approval.
      let options = AgentBridgeSelectionStore.selectedRunOptions(provider: resolvedProvider)
      onSend?("Please revise the plan based on this feedback, then present the updated plan:\n\(feedback)", options, [])
      reloadLiveMessages()
    }
  }

  private func refreshFromProvider() {
    guard let messagesProvider else { return }
    let next = messagesProvider()
    guard !next.isEmpty else { return }
    setMessages(next)
  }

  /// Pull the latest rows into the feed on demand. Used right after a send from this
  /// surface: the chat list appends the outgoing bubble synchronously (no engine
  /// `didChange` fires for the optimistic native row), so without an explicit poke
  /// the user's message would only appear in the chat view, not here.
  func reloadLiveMessages() {
    refreshFromProvider()
  }

  private func configureNavigationTitle() {
    // The embedded (profile) path gets its header from the SwiftUI NavigationStack
    // toolbar; only the standalone/chat presentations build the in-view header.
    guard usesInViewHeader else { return }
    buildInViewHeader()
  }

  private func buildInViewHeader() {
    navigationController?.setNavigationBarHidden(true, animated: false)
    if headerContentView.superview == nil {
      setupCustomHeaderViews()
    }
    updateHeaderActionButtons(animated: false)
    updateHeaderTexts()
  }

  private func setupCustomHeaderViews() {
    headerContentView.backgroundColor = .clear
    view.addSubview(headerContentView)
    
    headerContentView.addSubview(backGlassView)
    headerContentView.addSubview(avatarGlassView)
    headerContentView.addSubview(titleGlassView)
    headerContentView.addSubview(rightActionsGlassView)
    
    let backEffect = UIGlassEffect()
    backEffect.isInteractive = true
    backEffect.tintColor = .clear
    backGlassView.effect = backEffect
    
    headerBackButton.setTitle(nil, for: .normal)
    headerBackButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    let backSymbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    headerBackButton.setPreferredSymbolConfiguration(backSymbolConfig, forImageIn: .normal)
    headerBackButton.tintColor = appearance.text
    headerBackButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    backGlassView.contentView.addSubview(headerBackButton)
    
    let avatarEffect = UIGlassEffect()
    avatarEffect.isInteractive = true
    avatarEffect.tintColor = .clear
    avatarGlassView.effect = avatarEffect
    
    headerAvatarView.translatesAutoresizingMaskIntoConstraints = true
    headerAvatarView.constraints.forEach { constraint in
      if constraint.firstAttribute == .width || constraint.firstAttribute == .height {
        constraint.isActive = false
      }
    }
    headerAvatarView.removeTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    headerAvatarView.addTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    avatarGlassView.contentView.addSubview(headerAvatarView)

    titleGlassView.effect = nil

    titleButton.addTarget(self, action: #selector(profileTapped), for: .touchUpInside)
    titleGlassView.contentView.addSubview(titleButton)

    customTitleStack.axis = .vertical
    customTitleStack.alignment = .leading
    customTitleStack.spacing = -1
    customTitleStack.isUserInteractionEnabled = false

    headerModelButton.configuration = nil
    headerModelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    headerModelButton.titleLabel?.numberOfLines = 1
    headerModelButton.titleLabel?.lineBreakMode = .byTruncatingTail
    headerModelButton.titleLabel?.adjustsFontSizeToFitWidth = true
    headerModelButton.titleLabel?.minimumScaleFactor = 0.85
    headerModelButton.isUserInteractionEnabled = false
    headerModelButton.tintColor = appearance.text

    connectionDotView.layer.cornerRadius = 3
    connectionDotView.layer.cornerCurve = .continuous
    connectionDotView.translatesAutoresizingMaskIntoConstraints = false
    connectionSpinner.translatesAutoresizingMaskIntoConstraints = false
    connectionSpinner.hidesWhenStopped = true
    connectionSpinner.transform = CGAffineTransform(scaleX: 0.62, y: 0.62)
    subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    subtitleLabel.textColor = appearance.textSecondary
    subtitleLabel.textAlignment = .left
    subtitleLabel.lineBreakMode = .byTruncatingTail

    let subtitleStack = UIStackView(arrangedSubviews: [connectionDotView, connectionSpinner, subtitleLabel])
    subtitleStack.spacing = 4
    subtitleStack.alignment = .center
    subtitleStack.isUserInteractionEnabled = false

    customTitleStack.addArrangedSubview(headerModelButton)
    customTitleStack.addArrangedSubview(subtitleStack)
    titleButton.addSubview(customTitleStack)

    let actionsEffect = UIGlassEffect()
    actionsEffect.isInteractive = true
    actionsEffect.tintColor = .clear
    rightActionsGlassView.effect = actionsEffect

    rightActionsStack.axis = .horizontal
    rightActionsStack.alignment = .fill
    rightActionsStack.distribution = .fillEqually
    rightActionsStack.spacing = 0
    rightActionsGlassView.contentView.addSubview(rightActionsStack)

    let actionSymbolConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    headerNewChatActionButton.setTitle(nil, for: .normal)
    headerNewChatActionButton.setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
    headerNewChatActionButton.setPreferredSymbolConfiguration(actionSymbolConfig, forImageIn: .normal)
    headerNewChatActionButton.tintColor = appearance.text

    headerHistoryButton.setTitle(nil, for: .normal)
    headerHistoryButton.setImage(createHistoryIcon(), for: .normal)
    headerHistoryButton.tintColor = appearance.text

    rightActionsStack.addArrangedSubview(headerNewChatActionButton)
    rightActionsStack.addArrangedSubview(headerHistoryButton)

    [headerBackButton, headerModelButton, headerNewChatActionButton, headerHistoryButton].forEach { button in
      button.backgroundColor = .clear
      button.contentHorizontalAlignment = .center
      button.contentVerticalAlignment = .center
      button.clipsToBounds = true
    }
  }

  private func layoutCustomHeaderViews() {
    guard usesInViewHeader else { return }
    // The header is added in configureNavigationTitle (viewDidLoad) BEFORE tableView,
    // composerView, etc. are added — so it ends up buried beneath them. Bring it to
    // the front on every layout pass so the glass pills are always visible.
    view.bringSubviewToFront(headerContentView)
    let safeTop = view.safeAreaInsets.top
    headerContentView.frame = CGRect(x: 12.0, y: safeTop + 8.0, width: view.bounds.width - 24.0, height: 44.0)

    backGlassView.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    avatarGlassView.frame = CGRect(x: backGlassView.frame.maxX + 8.0, y: 0.0, width: 44.0, height: 44.0)

    var visibleActionCount = 0
    if !headerNewChatActionButton.isHidden { visibleActionCount += 1 }
    if !headerHistoryButton.isHidden { visibleActionCount += 1 }

    let actionWidth: CGFloat = 44.0
    let totalActionsWidth = CGFloat(visibleActionCount) * actionWidth

    rightActionsGlassView.frame = CGRect(
      x: headerContentView.bounds.width - totalActionsWidth,
      y: 0.0,
      width: totalActionsWidth,
      height: 44.0
    )

    rightActionsStack.frame = rightActionsGlassView.bounds

    let titleMinX = avatarGlassView.frame.maxX + 12.0
    let titleMaxX = rightActionsGlassView.frame.minX > 0 ? rightActionsGlassView.frame.minX - 8.0 : headerContentView.bounds.width - 8.0
    let availableWidth = max(0, titleMaxX - titleMinX)

    titleGlassView.frame = CGRect(
      x: titleMinX,
      y: 0.0,
      width: availableWidth,
      height: 44.0
    )

    headerBackButton.frame = backGlassView.bounds
    titleButton.frame = titleGlassView.bounds
    headerAvatarView.frame = avatarGlassView.bounds.insetBy(dx: 4.0, dy: 4.0)
    headerAvatarView.layer.cornerRadius = headerAvatarView.bounds.height / 2.0
    headerAvatarView.clipsToBounds = true
    
    [headerBackButton, headerNewChatActionButton, headerHistoryButton].forEach { button in
      button.layer.cornerRadius = button.bounds.height / 2.0
    }
    [backGlassView, avatarGlassView, titleGlassView, rightActionsGlassView].forEach { glass in
      glass.layer.cornerRadius = glass.bounds.height / 2.0
    }
    
    let horizontalInset: CGFloat = 4.0 // matches main header inset when not inside glass
    let stackSize = customTitleStack.systemLayoutSizeFitting(
      CGSize(width: titleButton.bounds.width - (horizontalInset * 2.0), height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    customTitleStack.frame = CGRect(
      x: horizontalInset,
      y: (titleButton.bounds.height - stackSize.height) * 0.5,
      width: titleButton.bounds.width - (horizontalInset * 2.0),
      height: stackSize.height
    )
  }

  private func createHistoryIcon(strokeWidth: CGFloat = 1.8) -> UIImage {
    let size = CGSize(width: 24, height: 24)
    let scale = 24.0 / 64.0
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      let cgContext = context.cgContext
      cgContext.setLineWidth(strokeWidth)
      cgContext.setLineCap(.round)
      cgContext.setLineJoin(.round)
      UIColor.black.setStroke()
      
      let center = CGPoint(x: 35.6 * scale, y: 30.73 * scale)
      let radius: CGFloat = 21.91 * scale
      
      let path = UIBezierPath()
      path.addArc(withCenter: center, radius: radius, startAngle: CGFloat.pi / 2.0, endAngle: CGFloat.pi, clockwise: false)
      cgContext.addPath(path.cgPath)
      cgContext.strokePath()
      
      let arrow = UIBezierPath()
      arrow.move(to: CGPoint(x: 5.79 * scale, y: 21.06 * scale))
      arrow.addLine(to: CGPoint(x: 13.67 * scale, y: 31.35 * scale))
      arrow.addLine(to: CGPoint(x: 23.96 * scale, y: 23.48 * scale))
      cgContext.addPath(arrow.cgPath)
      cgContext.strokePath()
      
      let hands = UIBezierPath()
      hands.move(to: CGPoint(x: 34.95 * scale, y: 14.04 * scale))
      hands.addLine(to: CGPoint(x: 34.95 * scale, y: 32.35 * scale))
      hands.addLine(to: CGPoint(x: 43.26 * scale, y: 38.72 * scale))
      cgContext.addPath(hands.cgPath)
      cgContext.strokePath()
    }.withRenderingMode(.alwaysTemplate)
  }

  /// Latest model a run in this conversation reported (the bridge sends
  /// `metadata.model`). Used so the header shows the real model (Opus / GPT-5.5 …) even
  /// when the user hasn't explicitly picked one — instead of the bare provider name.
  private var latestRuntimeModel: String? {
    for message in messages.reversed() {
      if let model = message.runtime?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
        !model.isEmpty
      {
        return model
      }
    }
    return nil
  }

  /// Latest reasoning effort a run reported (live runtime metadata).
  private var latestRuntimeReasoningEffort: String? {
    for message in messages.reversed() {
      if let effort = message.runtime?.reasoningEffort?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !effort.isEmpty
      {
        return effort
      }
    }
    return nil
  }

  private var latestRuntimeAdvisor: String? {
    for message in messages.reversed() {
      if let advisor = message.runtime?.advisor?.trimmingCharacters(in: .whitespacesAndNewlines),
        !advisor.isEmpty
      {
        return advisor
      }
    }
    return nil
  }

  /// Model id to display for the open session. Prefer run/session-reported values so
  /// history and live tasks show what actually ran; fall back to the store selection
  /// only when nothing was reported (empty/new chat). Explicit overrides still drive
  /// the next spawn via `selectedRunOptions`.
  private func displayedSessionModelId(provider: String) -> String? {
    if let runtime = latestRuntimeModel { return runtime }
    if let run = runModel?.trimmingCharacters(in: .whitespacesAndNewlines), !run.isEmpty {
      return run
    }
    if let explicit = AgentBridgeSelectionStore.selectedModel(provider: provider) {
      return explicit
    }
    return AgentBridgeSelectionStore.selectedRunOptions(provider: provider).model
  }

  /// Effort to display as the session's reported configuration. Prefer run/session
  /// values; do not invent archived effort from the mobile default picker.
  private func displayedSessionReasoningEffort() -> String? {
    if let runtime = latestRuntimeReasoningEffort { return runtime }
    if let run = runReasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
      !run.isEmpty
    {
      return run
    }
    return nil
  }

  /// Compact configuration string for workspace/header, e.g. `Opus 4.6 · Thinking High`.
  private func sessionConfigurationLabel(provider: String) -> String? {
    AgentBridgeSessionConfiguration.compactLabel(
      provider: provider,
      model: displayedSessionModelId(provider: provider),
      reasoningEffort: displayedSessionReasoningEffort()
    )
  }

  private func sessionThinkingLabel() -> String? {
    guard
      let effort = displayedSessionReasoningEffort(),
      let level = AgentBridgeIntelligenceLevel.fromProviderEffort(effort)
    else { return nil }
    return "\(level.title) Thinking"
  }

  private func headerModelTitle(provider: String) -> String {
    let title = AgentBridgeSelectionStore.modelTitle(
      provider: provider,
      model: displayedSessionModelId(provider: provider)
    )
    if provider.lowercased() == "claude", title.lowercased().hasPrefix("claude ") {
      return String(title.dropFirst("Claude ".count))
    }
    return title
  }

  /// Refresh the header's model title + run-options menu and the device subline.
  /// The current "what's happening now" line for the header subtitle while a turn is live:
  /// the latest running progress step ("Reading …", "bash …") or the thinking token count.
  private func messageLiveHeaderStatusText() -> String? {
    guard let live = messages.last(where: { $0.isStreaming || $0.runtime?.status == "running" })
    else { return nil }
    let items = live.progressItems
    if let running = items.last(where: {
      vibeAgentKitRunningStepStatuses.contains(($0.status ?? "").lowercased())
    }) {
      return vibeAgentKitProgressDisplayLabel(running)
    }
    if let last = items.last {
      return vibeAgentKitProgressDisplayLabel(last)
    }
    return "Thinking"
  }

  private func engineLiveHeaderStatusText() -> String? {
    let chatId = agentBridgeChatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !chatId.isEmpty, let progress = ChatEngine.shared.agentProgress(chatId: chatId) else {
      return nil
    }
    let label = (progress["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return label.isEmpty ? "Thinking" : label
  }

  private func liveHeaderStatusText() -> String? {
    if let current = messageLiveHeaderStatusText() ?? engineLiveHeaderStatusText() {
      lastLiveHeaderStatusText = current
      lastLiveHeaderStatusAt = ProcessInfo.processInfo.systemUptime
      return current
    }

    let chatId = agentBridgeChatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hasLiveSession = !chatId.isEmpty && ChatEngine.shared.liveBridgeSessionId(chatId: chatId) != nil
    let canUseCachedLiveText = !messages.isEmpty || hasLiveSession
    if canUseCachedLiveText,
      let cached = lastLiveHeaderStatusText,
      ProcessInfo.processInfo.systemUptime - lastLiveHeaderStatusAt <= Self.liveHeaderStatusGrace
    {
      return cached
    }
    return nil
  }

  private func isLiveTurnActive() -> Bool {
    if messages.contains(where: { $0.isStreaming || $0.runtime?.status == "running" }) {
      return true
    }
    let chatId = agentBridgeChatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !chatId.isEmpty, ChatEngine.shared.agentProgress(chatId: chatId) != nil {
      return true
    }
    return false
  }

  /// Header subtitle contents: live status while a turn is running, the chat/history title
  /// when a transcript is open and idle, otherwise a "start a session" prompt. The header
  /// title itself always stays the agent's name (Claude / Codex).
  private func headerSubtitleText() -> String {
    if isLiveTurnActive(), let thinking = sessionThinkingLabel() { return thinking }
    if let live = liveHeaderStatusText() { return live }
    let title = runtimeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty && (isHistoryPicked || !tableMessages.isEmpty) { return title }
    // No topic yet — surface reported model·thinking so an open/running session still
    // shows its configuration in the header strip.
    if let config = sessionConfigurationLabel(provider: agentBridgeProvider ?? "codex") {
      return config
    }
    if !tableMessages.isEmpty { return "Session" }
    return "Start a session"
  }

  private func updateHeaderTexts() {
    guard usesInViewHeader else { return }

    let provider = agentBridgeProvider ?? "codex"
    // The running session's actual model is the primary header title. The second line
    // carries its reported effort (for example "Max Thinking").
    headerModelButton.setTitle(headerModelTitle(provider: provider), for: .normal)
    let color = vibeAgentKitColorWithAlpha(appearance.text, 0.8)
    headerModelButton.setTitleColor(color, for: .normal)
    headerModelButton.tintColor = color

    // Subtitle carries the live state: current thinking/tool step while running, the
    // history/chat name when a transcript is open and idle, else session config or
    // "Start a session". Reported model·thinking also lives on the workspace strip.
    subtitleLabel.text = headerSubtitleText()
    subtitleLabel.textColor = appearance.textSecondary
    if let config = sessionConfigurationLabel(provider: provider) {
      headerModelButton.accessibilityValue = config
      headerModelButton.accessibilityHint = "Session configuration: \(config)"
    } else {
      headerModelButton.accessibilityValue = nil
      headerModelButton.accessibilityHint = nil
    }

    // Connection is shown by the pip/spinner regardless of what the subtitle text says.
    let device = (deviceLabel?.isEmpty == false) ? deviceLabel : AgentPairingService.lastDeviceLabel
    let connected = (deviceLabel != nil) ? deviceConnected : AgentPairingService.lastConnected
    let hasDevice = (device ?? "").isEmpty == false
    let isReconnecting = !connected && hasDevice

    if isReconnecting {
      connectionDotView.isHidden = true
      connectionSpinner.color = appearance.textSecondary
      connectionSpinner.startAnimating()
    } else {
      connectionSpinner.stopAnimating()
      connectionDotView.isHidden = !hasDevice
      connectionDotView.backgroundColor = UIColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1)
    }
    
    if isViewLoaded {
      view.setNeedsLayout()
    }
  }

  private func updateWorkspace() {
    guard isViewLoaded else { return }
    let provider = agentBridgeProvider ?? "codex"
    // Prefer reported run/session model+effort for the open conversation; fall back to
    // the explicit user selection (or store default) only when nothing was reported.
    let modelId = displayedSessionModelId(provider: provider)
    let modelOnlyTitle = AgentBridgeSelectionStore.modelTitle(provider: provider, model: modelId)
    let modelTitle =
      sessionConfigurationLabel(provider: provider)
      ?? modelOnlyTitle
    let device = (deviceLabel?.isEmpty == false) ? deviceLabel : AgentPairingService.lastDeviceLabel
    let connected = (deviceLabel != nil) ? deviceConnected : AgentPairingService.lastConnected
    workspaceView.configure(
      messages: messages,
      provider: provider,
      displayTitle: runtimeTitle,
      modelTitle: modelTitle,
      deviceLabel: device,
      deviceConnected: connected,
      isHistoryPicked: isHistoryPicked,
      isLoading: isLoadingTranscript
    )
  }


  private func refreshModelMenu() {
    // Menu removed: tapping title now pushes to profile
  }

  private func applyNavigationAppearance() {
    connectionSpinner.color = appearance.textSecondary
    subtitleLabel.textColor = appearance.textSecondary

    headerModelButton.tintColor = appearance.text
    headerModelButton.setTitleColor(appearance.text, for: .normal)

    headerBackButton.tintColor = appearance.text
    headerNewChatActionButton.tintColor = appearance.text
    headerHistoryButton.tintColor = appearance.text

    // Embedded (SwiftUI nav) path — keep the bar fully transparent so the feed flows
    // under it edge-to-edge.
    titleLabel.textColor = appearance.text
    let transparent = UINavigationBarAppearance()
    transparent.configureWithTransparentBackground()
    transparent.backgroundColor = .clear
    transparent.shadowColor = .clear
    transparent.titleTextAttributes = [.foregroundColor: appearance.text]
    navigationController?.navigationBar.standardAppearance = transparent
    navigationController?.navigationBar.scrollEdgeAppearance = transparent
    navigationController?.navigationBar.compactAppearance = transparent
    navigationController?.navigationBar.compactScrollEdgeAppearance = transparent
    navigationController?.navigationBar.isTranslucent = true
    navigationController?.navigationBar.tintColor = appearance.text
  }

  private func updateNavigationLiveState() {
    let isLive = isLiveTurnActive()
    // The composer's trailing control becomes STOP while a task is live (cancel the
    // running bridge run) and reverts to send/mic once it finishes — so an active turn
    // can never be sent over, and the user can always interrupt it.
    composerView.setTaskActive(isLive)
    // In-view header: the model can change as runs report it, so refresh the header
    // (model title + connection pip) whenever the message set advances.
    if usesInViewHeader {
      updateHeaderTexts()
      return
    }
    liveDotView.isHidden = !isLive
    liveLabel.isHidden = !isLive
    subtitleLabel.isHidden = runtimeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func updateComposerHeight(_ height: CGFloat, animated: Bool) {
    composerHeightConstraint?.constant = height
    guard animated else {
      view.layoutIfNeeded()
      return
    }
    // `onHeightChanged` now fires from inside `VibeComposerView`'s own expand/collapse
    // animation closure, so most of the time we're already inside an active transaction
    // here — just ride it. Wrapping our OWN `UIView.animate` on top of that (a second,
    // differently-timed spring) is what used to make the pill and the keyboard visibly
    // fall out of sync ("jumping"). Only start a fresh spring when nothing is animating
    // yet (e.g. a safe-area-only change that didn't go through that closure).
    guard UIView.inheritedAnimationDuration <= 0 else {
      view.layoutIfNeeded()
      return
    }
    UIView.animate(
      withDuration: 0.38,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) { self.view.layoutIfNeeded() }
  }

  // MARK: Image attachments

  private func presentImageAttachmentPicker() {
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 4
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  private func presentCameraPicker() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = ["public.image"]
    picker.delegate = self
    present(picker, animated: true)
  }

  private func presentFilePicker() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    for result in results {
      let provider = result.itemProvider
      guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
      provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let self, let image = object as? UIImage,
          let blob = Self.sealedImageBlob(from: image)
        else { return }
        DispatchQueue.main.async { self.composerView.addAttachment(blob: blob) }
      }
    }
  }

  /// Downscale + JPEG-encode so the encrypted blob is small enough to ride inside a
  /// chat message, then seal it with the pairing key so the server only relays an
  /// opaque payload. The daemon decrypts it and writes the file for the agent to read.
  static func sealedImageBlob(from image: UIImage) -> String? {
    let scaled = scaledImage(image, maxDimension: 1024)
    guard let data = scaled.jpegData(compressionQuality: 0.55) else { return nil }
    let object: [String: Any] = [
      "name": "image-\(Int(Date().timeIntervalSince1970 * 1000)).jpg",
      "mime": "image/jpeg",
      "dataB64": data.base64EncodedString(),
    ]
    return AgentRuntimeCrypto.encrypt(object)
  }

  private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxDimension, longest > 0 else { return image }
    let scale = maxDimension / longest
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
  }

  private func observeKeyboard() {
    // The composer is pinned to `view.keyboardLayoutGuide.topAnchor`, so UIKit moves it
    // with the keyboard natively (including the interactive swipe-to-dismiss drag) and
    // `viewDidLayoutSubviews` → `updateScrollInsets()` keeps the feed pinned to the bottom
    // in lockstep. We only listen for the keyboard's appearance to keep the last bubble in
    // view when it first rises (the guide animation does the rest).
    let center = NotificationCenter.default
    keyboardObservers.append(center.addObserver(
      forName: UIResponder.keyboardWillShowNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, self.isNearBottom() else { return }
      DispatchQueue.main.async { self.scrollToBottom(animated: true) }
    })
  }

  private func indexProgress() {
    progressItemsByMessageId = [:]
    for message in messages where !message.progressItems.isEmpty {
      progressItemsByMessageId[message.id] = message.progressItems
    }
  }

  /// Stamp the moment each turn first appears as live so its "Working · M:SS" clock
  /// counts up from a fixed instant (not a fresh now-time on every re-push), and forget
  /// turns that finished or scrolled out of the transcript.
  private func trackStreamStarts(_ next: [VibeAgentKitChatMessage]) {
    let liveIds = Set(next.filter { $0.isStreaming }.map(\.id))
    for id in liveIds where streamStartByMessageId[id] == nil {
      streamStartByMessageId[id] = Date()
    }
    streamStartByMessageId = streamStartByMessageId.filter { liveIds.contains($0.key) }
  }

  // MARK: Table

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    isHistoryPicked ? tableMessages.count : 0
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let message = tableMessages[indexPath.row]
    // System dividers and /compact summaries are centered muted rows, not bubbles.
    // Compact summaries can expand; interruption/status dividers are static.
    if message.isCompactionSummary || message.systemDividerText != nil {
      let cell = tableView.dequeueReusableCell(
        withIdentifier: VibeAgentKitCompactionCell.reuseIdentifier,
        for: indexPath
      ) as! VibeAgentKitCompactionCell
      cell.backgroundColor = .clear
      cell.onToggle = message.isCompactionSummary ? { [weak self] in self?.toggleCompaction(for: message.id) } : nil
      cell.configure(
        text: message.text,
        title: message.systemDividerText ?? "Context compacted",
        expanded: expandedProgressMessageIds.contains(message.id),
        canExpand: message.isCompactionSummary,
        appearance: appearance
      )
      return cell
    }
    let cell = tableView.dequeueReusableCell(
      withIdentifier: VibeAgentKitMessageCell.reuseIdentifier,
      for: indexPath
    ) as! VibeAgentKitMessageCell
    cell.backgroundColor = .clear
    cell.selectionStyle = .none
    cell.onProgressTap = { [weak self] in self?.toggleProgress(for: message.id) }
    cell.onStepTap = { [weak self] nodeId in self?.toggleStepDetail(messageId: message.id, nodeId: nodeId) }
    cell.onOpenSubagent = { [weak self] nodeId in
      self?.presentSubagentView(messageId: message.id, parentNodeId: nodeId)
    }
    cell.onTextExpansionTap = { [weak self] in self?.toggleTextExpansion(for: message.id) }
    cell.onAttachmentTap = { [weak self] attachment in self?.presentImageAttachment(attachment) }
    cell.onToggleRuntimeExpand = { [weak self] in self?.toggleRuntimeExpand(for: message.id) }
    cell.onReviewTapped = { [weak self] in self?.presentRuntimeReview(message) }
    cell.onFileTapped = { [weak self] file in self?.presentRuntimeFile(file, message: message) }
    cell.configure(
      message: message,
      appearance: appearance,
      regeneratePrompt: regeneratePrompt,
      showsActions: false,
      isProgressExpanded: expandedProgressMessageIds.contains(message.id),
      expandedStepIds: expandedStepIdsByMessage[message.id] ?? [],
      isTextExpanded: expandedTextMessageIds.contains(message.id),
      isRuntimeExpanded: expandedRuntimeMessageIds.contains(message.id),
      streamingStartDate: message.isStreaming ? streamStartByMessageId[message.id] : nil,
      availableWidth: tableView.bounds.width
    )
    return cell
  }

  /// Reconfigure an already-visible cell in place for the content-only streaming path —
  /// reuses the live cell instance (and, crucially, its streaming-text reveal state)
  /// instead of a reloadData() remount that would re-fade the whole answer each delta.
  /// The tap closures wired when the cell was dequeued still target this row's (unchanged)
  /// message id, so they don't need re-binding here.
  private func reconfigureVisibleCell(at indexPath: IndexPath) {
    guard indexPath.row < tableMessages.count else { return }
    let message = tableMessages[indexPath.row]
    if message.isCompactionSummary || message.systemDividerText != nil {
      guard let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitCompactionCell else { return }
      cell.configure(
        text: message.text,
        title: message.systemDividerText ?? "Context compacted",
        expanded: expandedProgressMessageIds.contains(message.id),
        canExpand: message.isCompactionSummary,
        appearance: appearance
      )
      return
    }
    guard let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell else { return }
    cell.configure(
      message: message,
      appearance: appearance,
      regeneratePrompt: regeneratePrompt,
      showsActions: false,
      isProgressExpanded: expandedProgressMessageIds.contains(message.id),
      expandedStepIds: expandedStepIdsByMessage[message.id] ?? [],
      isTextExpanded: expandedTextMessageIds.contains(message.id),
      isRuntimeExpanded: expandedRuntimeMessageIds.contains(message.id),
      streamingStartDate: message.isStreaming ? streamStartByMessageId[message.id] : nil,
      availableWidth: tableView.bounds.width
    )
  }

  // MARK: Hold menu (Copy / Edit)

  // The system context menu provides the "mold" lift/blur (matching Resolo's
  // `.contextMenu`); a rounded targeted preview makes just the bubble lift, not the
  // whole row. Copy is always offered for text; Edit only for user messages in a
  // bridge-backed conversation (where a revert + fresh re-run is possible).
  func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard indexPath.row < tableMessages.count else { return nil }
    let message = tableMessages[indexPath.row]
    let cellText = (tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell)?.currentMessageText
    let text = (cellText?.isEmpty == false) ? cellText! : message.text
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let isUser = message.role.isUser
    let canEdit = isUser && agentBridgeChatId != nil && !trimmed.isEmpty
    guard !trimmed.isEmpty || canEdit else { return nil }

    return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) {
      [weak self] _ in
      guard let self else { return nil }
      var actions: [UIMenuElement] = []
      if !trimmed.isEmpty {
        actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
          UIPasteboard.general.string = text
        })
      }
      if canEdit {
        actions.append(UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
          // Defer so the menu finishes dismissing before we mutate the table / focus
          // the composer.
          DispatchQueue.main.async { self.beginEdit(message) }
        })
      }
      return actions.isEmpty ? nil : UIMenu(children: actions)
    }
  }

  /// "Edit" a user message: revert any file changes the turn it produced made (the
  /// bridge's file-aware revert), have the host reset to a fresh task, then refill the
  /// composer so the revised prompt re-runs cleanly from the reverted state.
  private func beginEdit(_ message: VibeAgentKitChatMessage) {
    revertTurn(after: message)
    onEditMessage?(message)
    composerView.beginEditing(with: message.text)
  }

  /// Find the agent turn this user message produced (the next assistant message with
  /// a revertible runtime) and ask the bridge to restore the files it changed. No-op
  /// when the turn changed nothing revertible (e.g. the repo was dirty beforehand).
  private func revertTurn(after message: VibeAgentKitChatMessage) {
    guard
      let chatId = agentBridgeChatId,
      let idx = messages.firstIndex(where: { $0.id == message.id })
    else { return }
    let turn = messages[messages.index(after: idx)...].first {
      !$0.role.isUser && $0.runtime != nil
    }
    guard
      let runtime = turn?.runtime,
      runtime.controls?.canRevert == true,
      let taskId = runtime.taskId, !taskId.isEmpty
    else { return }
    let provider = runtime.provider ?? agentBridgeProvider ?? "codex"
    _ = ChatEngine.shared.sendAgentBridgeControl([
      "chatId": chatId,
      "provider": provider,
      "action": "revert",
      "taskId": taskId,
    ])
  }

  /// Cancel the in-flight bridge run for this chat (SIGTERM → SIGKILL on the connected
  /// computer). Wired to the composer's STOP button, which only appears while a task is
  /// live. Prefers the live turn's taskId when present; the bridge also falls back to
  /// the single running task for this chat+provider when taskId is absent.
  private func stopActiveTask() {
    guard let chatId = agentBridgeChatId, !chatId.isEmpty else { return }
    if let runId = ChatEngine.shared.activeIsolatedRunId(chatId: chatId) {
      NSLog("[AgentView] stopActiveTask isolated chat=%@ runId=%@", chatId, runId)
      _ = ChatEngine.shared.cancelAgentRun(chatId: chatId, runId: runId)
    }
    let provider = agentBridgeProvider ?? "codex"
    let taskId = messages.first {
      $0.isStreaming || $0.runtime?.status == "running"
    }?.runtime?.taskId
    var payload: [String: Any] = [
      "chatId": chatId,
      "provider": provider,
      "action": "cancel",
    ]
    if let taskId, !taskId.isEmpty { payload["taskId"] = taskId }
    NSLog("[AgentView] stopActiveTask chat=%@ provider=%@ taskId=%@", chatId, provider, taskId ?? "nil")
    _ = ChatEngine.shared.sendAgentBridgeControl(payload)
  }

  func tableView(
    _ tableView: UITableView,
    previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    bubblePreview(for: configuration)
  }

  func tableView(
    _ tableView: UITableView,
    previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    bubblePreview(for: configuration)
  }

  private func bubblePreview(for configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
    guard
      let indexPath = configuration.identifier as? NSIndexPath,
      let cell = tableView.cellForRow(at: IndexPath(row: indexPath.row, section: indexPath.section))
        as? VibeAgentKitMessageCell
    else { return nil }
    return cell.bubblePreview()
  }

  private func toggleTextExpansion(for messageId: String) {
    if expandedTextMessageIds.contains(messageId) {
      expandedTextMessageIds.remove(messageId)
    } else {
      expandedTextMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: expandedProgressMessageIds.contains(messageId),
          expandedStepIds: expandedStepIdsByMessage[messageId] ?? [],
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }

  private func presentImageAttachment(_ attachment: VibeAgentKitImageAttachment) {
    if let image = VibeAgentKitAttachmentGridView.decodedImage(from: attachment) {
      presentImagePreview(image)
      return
    }
    guard let source = attachment.sourceURI?.trimmingCharacters(in: .whitespacesAndNewlines),
      !source.isEmpty
    else { return }
    Task { [weak self] in
      let image = await ChatAvatarImageStore.load(from: source)
      await MainActor.run {
        guard let self, let image else { return }
        self.presentImagePreview(image)
      }
    }
  }

  private func presentImagePreview(_ image: UIImage) {
    let host = UIHostingController(rootView: VibeAgentImagePreview(image: image))
    host.modalPresentationStyle = .fullScreen
    present(host, animated: true)
  }

  // MARK: Progress (inline expand)

  // Tapping "Worked · N steps" reveals/hides that turn's step list inline, in the
  // bubble (Claude-Code style). The expanded set persists across reloads, and the
  // table update keeps the tapped row anchored so the list does not jump.
  private func toggleProgress(for messageId: String) {
    if expandedProgressMessageIds.contains(messageId) {
      expandedProgressMessageIds.remove(messageId)
    } else {
      expandedProgressMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    // Reconfigure the visible cell in place (cheap, idempotent), then let the
    // table remeasure its new height. If the cell isn't on screen the set is
    // already updated, so cellForRowAt renders it expanded when it scrolls in.
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: expandedProgressMessageIds.contains(messageId),
          expandedStepIds: expandedStepIdsByMessage[messageId] ?? [],
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }

  /// Apply an inline expand/collapse without letting UITableView "helpfully" scroll.
  /// The cell owns the visible y-translate; the table only remeasures the tapped row.
  private func applyAnchoredRowChange(at _: IndexPath, _ change: () -> Void) {
    let offset = tableView.contentOffset
    toggleScrollLockDepth += 1
    UIView.performWithoutAnimation {
      change()
      tableView.beginUpdates()
      tableView.endUpdates()
      tableView.layoutIfNeeded()
      tableView.setContentOffset(clampedContentOffset(offset), animated: false)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      UIView.performWithoutAnimation {
        self.tableView.setContentOffset(self.clampedContentOffset(offset), animated: false)
      }
      self.toggleScrollLockDepth = max(0, self.toggleScrollLockDepth - 1)
    }
  }

  private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
    let minY = -tableView.adjustedContentInset.top
    let maxY = max(
      minY,
      tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
    )
    return CGPoint(x: offset.x, y: min(max(offset.y, minY), maxY))
  }

  // Tapping a /compact divider reveals or hides the kept summary, in place — same
  // anchored unfold as the other toggles, reusing the per-message expand set.
  private func toggleCompaction(for messageId: String) {
    if expandedProgressMessageIds.contains(messageId) {
      expandedProgressMessageIds.remove(messageId)
    } else {
      expandedProgressMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitCompactionCell {
        cell.configure(
          text: tableMessages[row].text,
          title: "Context compacted",
          expanded: expandedProgressMessageIds.contains(messageId),
          canExpand: true,
          appearance: appearance
        )
      }
    }
  }

  // Tapping one completed step row (command, edit, read) opens its detail inline
  // under that row. The parent "Worked" card stays expanded and the tapped row is
  // reconfigured in place, so file diffs do not leave the conversation surface.
  private func toggleStepDetail(messageId: String, nodeId: String) {
    var expanded = expandedStepIdsByMessage[messageId] ?? []
    if expanded.contains(nodeId) {
      expanded.remove(nodeId)
    } else {
      expanded.insert(nodeId)
    }
    if expanded.isEmpty {
      expandedStepIdsByMessage.removeValue(forKey: messageId)
    } else {
      expandedStepIdsByMessage[messageId] = expanded
    }
    expandedProgressMessageIds.insert(messageId)

    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: true,
          expandedStepIds: expanded,
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }
  private func toggleRuntimeExpand(for messageId: String) {
    if expandedRuntimeMessageIds.contains(messageId) {
      expandedRuntimeMessageIds.remove(messageId)
    } else {
      expandedRuntimeMessageIds.insert(messageId)
    }
    guard let row = tableMessages.firstIndex(where: { $0.id == messageId }) else { return }
    let indexPath = IndexPath(row: row, section: 0)
    applyAnchoredRowChange(at: indexPath) {
      if let cell = tableView.cellForRow(at: indexPath) as? VibeAgentKitMessageCell {
        cell.configure(
          message: tableMessages[row],
          appearance: appearance,
          regeneratePrompt: regeneratePrompt,
          showsActions: false,
          isProgressExpanded: expandedProgressMessageIds.contains(messageId),
          expandedStepIds: expandedStepIdsByMessage[messageId] ?? [],
          isTextExpanded: expandedTextMessageIds.contains(messageId),
          isRuntimeExpanded: expandedRuntimeMessageIds.contains(messageId),
          streamingStartDate: tableMessages[row].isStreaming ? streamStartByMessageId[messageId] : nil,
          availableWidth: tableView.bounds.width
        )
      }
    }
  }

  private func presentRuntimeReview(_ message: VibeAgentKitChatMessage) {
    guard let patch = message.runtime?.diff?.patch, !patch.isEmpty else { return }
    let diffView = VibeAgentDiffSheetView(patch: patch, fileName: nil)
    presentDiffSheet(diffView: diffView)
  }

  private func presentRuntimeFile(_ file: ChatListRow.AgentRuntimeFile, message: VibeAgentKitChatMessage) {
    guard let patch = message.runtime?.diff?.patch, !patch.isEmpty else { return }
    // VibeAgentDiffSheetView parses the whole patch but displays it. To show just one file,
    // we extract the file chunk using ChatNativeStreamingTextLabel's diffChunk helper,
    // or we just pass the whole patch and let the sheet handle it.
    // For now, we'll extract the chunk the same way AgentRuntimePatchPreviewController did:
    let chunk = diffChunk(for: file.path, patch: patch)
    let diffView = VibeAgentDiffSheetView(patch: chunk.isEmpty ? patch : chunk, fileName: file.name)
    presentDiffSheet(diffView: diffView)
  }

  private func presentDiffSheet(diffView: VibeAgentDiffSheetView) {
    let hostingController = UIHostingController(rootView: diffView)
    hostingController.modalPresentationStyle = .pageSheet
    if let sheet = hostingController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 20
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    present(hostingController, animated: true)
  }

  private func diffChunk(for path: String, patch: String) -> String {
    let target = "diff --git a/\(path)"
    guard let start = patch.range(of: target)?.lowerBound else { return "" }
    let tail = patch[start...]
    if let next = tail.dropFirst(target.count).range(of: "\ndiff --git a/")?.lowerBound {
      return String(tail[..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func updateLoadingOverlay() {
    if isLoadingTranscript && messages.isEmpty {
      showSkeleton()
    } else if skeletonVisible && messages.isEmpty {
      // Loading ended with nothing to show (a fresh / genuinely empty chat) → fade the
      // skeleton straight to the empty-state placeholder.
      hideSkeleton(animated: true)
    }
    // When messages ARE present the skeleton is dismissed by revealTranscriptFromSkeleton()
    // — only AFTER the table has committed its rows — so we never blink skeleton → empty →
    // chat. (Called at the end of updateMessages.)
    updateEmptyState()
  }

  /// Cover the feed with the shimmer skeleton and (re)start the safety fallback.
  private func showSkeleton() {
    guard loadingSkeleton.superview != nil, !skeletonVisible else { return }
    skeletonVisible = true
    loadingSkeleton.layer.removeAllAnimations()
    loadingSkeleton.contentBottomInset = max(20.0, tableView.contentInset.bottom + 8.0)
    loadingSkeleton.isHidden = false
    loadingSkeleton.alpha = 1.0
    loadingSkeleton.startShimmer()

    skeletonSafetyTimeout?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.skeletonVisible, self.messages.isEmpty else { return }
      // Transcript never arrived — stop covering the feed forever; reveal the empty state.
      self.hideSkeleton(animated: true)
    }
    skeletonSafetyTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: work)
  }

  private func hideSkeleton(animated: Bool) {
    guard skeletonVisible else { return }
    skeletonVisible = false
    skeletonSafetyTimeout?.cancel()
    skeletonSafetyTimeout = nil
    guard animated else {
      loadingSkeleton.isHidden = true
      loadingSkeleton.alpha = 1.0
      loadingSkeleton.stopShimmer()
      return
    }
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      self.loadingSkeleton.alpha = 0.0
    } completion: { _ in
      // A new load may have re-shown the skeleton mid-fade — don't clobber it.
      guard !self.skeletonVisible else { return }
      self.loadingSkeleton.isHidden = true
      self.loadingSkeleton.alpha = 1.0
      self.loadingSkeleton.stopShimmer()
    }
  }

  /// Reveal the freshly-loaded transcript from under the skeleton with no blank flash:
  /// force the table to commit its rows first, then cross-fade the cover away over the
  /// now-laid-out content. Safe to call every update — it no-ops once the skeleton is gone.
  private func revealTranscriptFromSkeleton() {
    guard skeletonVisible, !messages.isEmpty else { return }
    if tableView.window != nil {
      UIView.performWithoutAnimation { tableView.layoutIfNeeded() }
    }
    hideSkeleton(animated: true)
  }

  private var agentDisplayName: String {
    switch (agentBridgeProvider ?? "").lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "grok": return "Grok"
    default: return "your agent"
    }
  }

  private func setupEmptyState() {
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    emptyStateView.axis = .vertical
    emptyStateView.alignment = .center
    emptyStateView.spacing = 10.0
    emptyStateView.isHidden = true

    emptyStateIcon.translatesAutoresizingMaskIntoConstraints = false
    emptyStateIcon.contentMode = .scaleAspectFit
    emptyStateIcon.image = nil
    emptyStateIcon.isHidden = true

    emptyStateTitle.numberOfLines = 0
    emptyStateTitle.textAlignment = .center
    emptyStateTitle.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
    emptyStateTitle.textColor = appearance.text

    emptyStateSubtitle.numberOfLines = 0
    emptyStateSubtitle.textAlignment = .center
    emptyStateSubtitle.font = UIFont.systemFont(ofSize: 14.5, weight: .regular)
    emptyStateSubtitle.textColor = appearance.textSecondary

    emptyStateView.addArrangedSubview(emptyStateIcon)
    emptyStateView.addArrangedSubview(emptyStateTitle)
    emptyStateView.addArrangedSubview(emptyStateSubtitle)
    emptyStateView.setCustomSpacing(20.0, after: emptyStateIcon)
    emptyStateView.setCustomSpacing(8.0, after: emptyStateTitle)

    NSLayoutConstraint.activate([
      emptyStateIcon.widthAnchor.constraint(equalToConstant: 64),
      emptyStateIcon.heightAnchor.constraint(equalToConstant: 64),
    ])

    tableView.insertSubview(emptyStateView, at: 0)
  }

  private func updateEmptyState() {
    let show = surfaceMode == .transcript
      && ((!isHistoryPicked) || (messages.isEmpty && !isLoadingTranscript && !isEmbeddedInSwiftUI))
    emptyStateView.isHidden = !show
    guard show else { return }
    let repoName = AgentBridgeSelectionStore.selectedRepository()?.name
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let claudeOrange = UIColor(red: 0.83, green: 0.46, blue: 0.30, alpha: 1.0)
    switch (agentBridgeProvider ?? "").lowercased() {
    case "claude":
      let img = VibeAgentKitChatVectorIcon.image(.claudeAgent, color: claudeOrange, size: 48)
      emptyStateIcon.image = img
      emptyStateIcon.isHidden = false
      emptyStateTitle.text = "You've come to absolutely the right place."
      emptyStateSubtitle.isHidden = true
    case "codex":
      let img = VibeAgentKitChatVectorIcon.image(.gptAgent, color: .white, size: 48)?
        .withRenderingMode(.alwaysTemplate)
      emptyStateIcon.image = img
      emptyStateIcon.tintColor = UIColor.label
      emptyStateIcon.isHidden = false
      emptyStateSubtitle.isHidden = false
      if let repoName, !repoName.isEmpty {
        emptyStateTitle.text = "What should we build on \(repoName)?"
      } else {
        emptyStateTitle.text = "What should we build?"
      }
      emptyStateSubtitle.text = "Pick a repo, describe the change, and Codex will work from your computer."
    case "grok":
      let grokBlue = UIColor(red: 0.45, green: 0.70, blue: 0.95, alpha: 1.0)
      let img = VibeAgentKitChatVectorIcon.image(.claudeAgent, color: grokBlue, size: 48)
      emptyStateIcon.image = img
      emptyStateIcon.isHidden = false
      emptyStateSubtitle.isHidden = false
      if let repoName, !repoName.isEmpty {
        emptyStateTitle.text = "What should we build on \(repoName)?"
      } else {
        emptyStateTitle.text = "What should we build?"
      }
      emptyStateSubtitle.text = "Pick a repo, describe the change, and Grok will work from your computer."
    default:
      emptyStateIcon.isHidden = true
      emptyStateSubtitle.isHidden = false
      let name = agentDisplayName
      emptyStateTitle.text = "Start a new chat with \(name)"
      emptyStateSubtitle.text = "Ask a question or describe a task and \(name) will run it on your computer."
    }
    emptyStateTitle.textColor = appearance.text
    emptyStateSubtitle.textColor = appearance.textSecondary
  }

  // MARK: Scroll helpers

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if usesInViewHeader {
      layoutCustomHeaderViews()
    }
    updateScrollInsets()
    updateBottomEdgeFadeFrame()
    // Land at the bottom exactly once, after the first layout pass that actually has
    // rows + resolved insets — so the feed opens pinned to the latest message with no
    // visible jump/settle.
    if !hasPerformedInitialScroll, isHistoryPicked, tableView.numberOfRows(inSection: 0) > 0 {
      hasPerformedInitialScroll = true
      // Never yank a freshly-sent question down: when a push-to-top pin is active this
      // one-shot would otherwise scroll the list to the bottom on the agent's first laid-out
      // frame (the "push-to-top sometimes jumps back to bottom on agent start" bug). Consume
      // the one-shot but hold the pin.
      if pushToTopUserId == nil {
        // Double pass: the first scroll positions against ESTIMATED self-sizing heights;
        // materializing the real cells corrects contentSize, so scroll once more in the
        // same (animation-free) pass. Otherwise the feed visibly settles a frame later —
        // the "starts at the wrong place, then flicks to the bottom" open.
        UIView.performWithoutAnimation {
          scrollToBottom(animated: false)
          tableView.layoutIfNeeded()
          scrollToBottom(animated: false)
        }
      }
    }
    // Keep the pinned question rock-steady across self-sizing settles / row inserts.
    reassertPinnedOffsetIfNeeded()
  }

  private func setupJumpToBottomButton() {
    jumpToBottomButton.translatesAutoresizingMaskIntoConstraints = false
    jumpToBottomButton.alpha = 0.0
    jumpToBottomButton.isHidden = true
    jumpToBottomButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
    jumpToBottomButton.accessibilityLabel = "Jump to latest"
    jumpToBottomButton.addTarget(self, action: #selector(jumpToBottomTapped), for: .touchUpInside)
    // Below the composer in z-order so the pill always wins touches near the edge.
    view.insertSubview(jumpToBottomButton, belowSubview: composerView)
    let size: CGFloat = 38.0
    let bottom = jumpToBottomButton.bottomAnchor.constraint(
      equalTo: composerView.topAnchor, constant: -10.0)
    jumpToBottomBottomConstraint = bottom
    NSLayoutConstraint.activate([
      jumpToBottomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      jumpToBottomButton.widthAnchor.constraint(equalToConstant: size),
      jumpToBottomButton.heightAnchor.constraint(equalToConstant: size),
      bottom,
    ])
    updateJumpButtonAppearance()
  }

  private func updateJumpButtonAppearance() {
    jumpToBottomButton.backgroundColor = appearance.surfaceElevated
    jumpToBottomButton.tintColor = appearance.text
    jumpToBottomButton.layer.cornerRadius = 19.0
    jumpToBottomButton.layer.cornerCurve = .continuous
    jumpToBottomButton.layer.borderWidth = 0.5
    jumpToBottomButton.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.22 : 0.16).cgColor
    jumpToBottomButton.layer.shadowColor = UIColor.black.cgColor
    jumpToBottomButton.layer.shadowOpacity = appearance.isDark ? 0.4 : 0.14
    jumpToBottomButton.layer.shadowRadius = 8.0
    jumpToBottomButton.layer.shadowOffset = CGSize(width: 0, height: 3)
    jumpToBottomButton.setImage(
      UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
      for: .normal)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    setJumpButtonVisible(!isNearBottom())
    // The user physically grabbed the list while a question was pinned — they own the
    // scroll for the rest of the turn (stop re-asserting the pinned offset).
    if pushToTopUserId != nil, scrollView.isTracking || scrollView.isDragging {
      pushToTopDetached = true
    }
  }

  private func setJumpButtonVisible(_ visible: Bool) {
    let shouldShow = visible && surfaceMode == .transcript && isHistoryPicked
      && tableView.numberOfRows(inSection: 0) > 0
    guard shouldShow != jumpButtonVisible else { return }
    jumpButtonVisible = shouldShow
    if shouldShow { jumpToBottomButton.isHidden = false }
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.jumpToBottomButton.alpha = shouldShow ? 1.0 : 0.0
      self.jumpToBottomButton.transform =
        shouldShow ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
    } completion: { _ in
      if !shouldShow, self.jumpToBottomButton.alpha <= 0.01 {
        self.jumpToBottomButton.isHidden = true
      }
    }
  }

  private func setupEditToast() {
    editToastBlur.translatesAutoresizingMaskIntoConstraints = false
    editToastBlur.alpha = 0.0
    editToastBlur.isHidden = true
    editToastBlur.clipsToBounds = true
    editToastBlur.layer.cornerRadius = 16.0
    editToastBlur.layer.cornerCurve = .continuous
    editToastBlur.layer.borderWidth = 0.6
    view.addSubview(editToastBlur)

    editToastIcon.translatesAutoresizingMaskIntoConstraints = false
    editToastIcon.contentMode = .scaleAspectFit
    editToastIcon.image = UIImage(systemName: "doc.text.fill")?.withRenderingMode(.alwaysTemplate)
    editToastBlur.contentView.addSubview(editToastIcon)

    editToastLabel.translatesAutoresizingMaskIntoConstraints = false
    editToastLabel.numberOfLines = 1
    editToastLabel.lineBreakMode = .byTruncatingMiddle
    editToastLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    editToastBlur.contentView.addSubview(editToastLabel)

    NSLayoutConstraint.activate([
      editToastIcon.leadingAnchor.constraint(
        equalTo: editToastBlur.contentView.leadingAnchor, constant: 12.0),
      editToastIcon.centerYAnchor.constraint(equalTo: editToastBlur.contentView.centerYAnchor),
      editToastIcon.widthAnchor.constraint(equalToConstant: 14.0),
      editToastIcon.heightAnchor.constraint(equalToConstant: 14.0),
      editToastLabel.leadingAnchor.constraint(equalTo: editToastIcon.trailingAnchor, constant: 7.0),
      editToastLabel.trailingAnchor.constraint(
        equalTo: editToastBlur.contentView.trailingAnchor, constant: -12.0),
      editToastLabel.topAnchor.constraint(equalTo: editToastBlur.contentView.topAnchor, constant: 7.0),
      editToastLabel.bottomAnchor.constraint(
        equalTo: editToastBlur.contentView.bottomAnchor, constant: -7.0),
    ])
    updateEditToastAppearance()
    updateEditToast()
  }

  private func updateEditToastAppearance() {
    editToastIcon.tintColor = vibeAgentKitColorWithAlpha(appearance.text, 0.82)
    editToastLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.88)
    editToastBlur.contentView.backgroundColor =
      (appearance.isDark ? UIColor.white : UIColor.black)
      .withAlphaComponent(appearance.isDark ? 0.055 : 0.045)
    editToastBlur.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.18 : 0.14).cgColor
  }

  /// A short confirmation pill above the composer — replaces the old (unbounded-height,
  /// "covers the screen" on a long result) command overlay for `/usage` and `/plan`.
  private func setupInfoToast() {
    infoToastBlur.translatesAutoresizingMaskIntoConstraints = false
    infoToastBlur.alpha = 0.0
    infoToastBlur.isHidden = true
    infoToastBlur.clipsToBounds = true
    infoToastBlur.layer.cornerRadius = 16.0
    infoToastBlur.layer.cornerCurve = .continuous
    infoToastBlur.layer.borderWidth = 0.6
    view.addSubview(infoToastBlur)

    infoToastIcon.translatesAutoresizingMaskIntoConstraints = false
    infoToastIcon.contentMode = .scaleAspectFit
    infoToastIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)
    infoToastBlur.contentView.addSubview(infoToastIcon)

    infoToastLabel.translatesAutoresizingMaskIntoConstraints = false
    infoToastLabel.numberOfLines = 1
    infoToastLabel.lineBreakMode = .byTruncatingTail
    infoToastLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    infoToastBlur.contentView.addSubview(infoToastLabel)

    NSLayoutConstraint.activate([
      infoToastBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      infoToastBlur.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16.0),
      infoToastBlur.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16.0),
      infoToastBlur.bottomAnchor.constraint(equalTo: composerView.topAnchor, constant: -8.0),
      infoToastIcon.leadingAnchor.constraint(equalTo: infoToastBlur.contentView.leadingAnchor, constant: 12.0),
      infoToastIcon.centerYAnchor.constraint(equalTo: infoToastBlur.contentView.centerYAnchor),
      infoToastIcon.widthAnchor.constraint(equalToConstant: 14.0),
      infoToastIcon.heightAnchor.constraint(equalToConstant: 14.0),
      infoToastLabel.leadingAnchor.constraint(equalTo: infoToastIcon.trailingAnchor, constant: 7.0),
      infoToastLabel.trailingAnchor.constraint(equalTo: infoToastBlur.contentView.trailingAnchor, constant: -12.0),
      infoToastLabel.topAnchor.constraint(equalTo: infoToastBlur.contentView.topAnchor, constant: 7.0),
      infoToastLabel.bottomAnchor.constraint(equalTo: infoToastBlur.contentView.bottomAnchor, constant: -7.0),
    ])
    updateInfoToastAppearance()
  }

  private func updateInfoToastAppearance() {
    infoToastIcon.tintColor = vibeAgentKitColorWithAlpha(appearance.text, 0.82)
    infoToastLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.88)
    infoToastBlur.contentView.backgroundColor =
      (appearance.isDark ? UIColor.white : UIColor.black)
      .withAlphaComponent(appearance.isDark ? 0.055 : 0.045)
    infoToastBlur.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.18 : 0.14).cgColor
  }

  private func showInfoToast(title: String, systemImage: String) {
    infoToastIcon.image = UIImage(systemName: systemImage)
    infoToastLabel.text = title
    infoToastBlur.isHidden = false
    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.infoToastBlur.alpha = 1.0
    }
    infoToastHideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hideInfoToast() }
    infoToastHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
  }

  private func hideInfoToast() {
    infoToastHideWork?.cancel()
    infoToastHideWork = nil
    guard !infoToastBlur.isHidden else { return }
    UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.infoToastBlur.alpha = 0.0
    } completion: { _ in
      if self.infoToastBlur.alpha <= 0.01 { self.infoToastBlur.isHidden = true }
    }
  }

  private func setupUsageBanner() {
    usageBannerView.translatesAutoresizingMaskIntoConstraints = false
    usageBannerView.isHidden = true
    usageBannerView.alpha = 0.0
    usageBannerView.isUserInteractionEnabled = false
    usageBannerView.applyTheme(
      textColor: appearance.text,
      surfaceColor: appearance.surfaceElevated,
      isDark: appearance.isDark
    )
    view.addSubview(usageBannerView)
  }

  private func setupCommandOverlay() {
    commandOverlayView.translatesAutoresizingMaskIntoConstraints = false
    commandOverlayView.isHidden = true
    commandOverlayView.alpha = 0.0
    commandOverlayView.applyAppearance(appearance)
    commandOverlayView.onClose = { [weak self] in self?.hideCommandOverlay() }
    view.addSubview(commandOverlayView)
  }

  /// Show real bridge output (from a `vibe-bridge` result) in the glass overlay
  /// instead of letting it land as a chat bubble.
  /// Extracts the command name from a `vibe-bridge` result's display string, e.g.
  /// "vibe-bridge /usage" → "usage".
  private func bridgeCommandName(_ msg: VibeAgentKitChatMessage) -> String {
    let display = msg.runtime?.command?.display ?? ""
    return display
      .components(separatedBy: " ")
      .first(where: { $0.hasPrefix("/") })
      .map { String($0.dropFirst()).lowercased() }
      ?? ""
  }

  private func showBridgeCommandResult(_ msg: VibeAgentKitChatMessage) {
    guard isViewLoaded, !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let rawName = bridgeCommandName(msg)
    let name = rawName.isEmpty ? "Command" : rawName
    let title = name.prefix(1).uppercased() + String(name.dropFirst())
    commandOverlayView.configure(title: title, body: msg.text)
    showCommandOverlay()
  }

  private func handleComposerCommand(_ command: String) {
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return }
    // Plan mode already has two persistent, always-visible cues (the blue slash icon +
    // the blue permission icon via `refreshModePill`) — a toast confirms the switch
    // without popping a local panel that had nothing but stale "reasoning controls" copy.
    if normalized == "/plan" || normalized == "plan" {
      showInfoToast(title: "Plan mode — proposals only, no edits", systemImage: AgentBridgeWorkMode.plan.icon)
      return
    }
    let content: (title: String, body: String)
    switch normalized {
    case "/usage", "usage":
      // Prefer the payload-backed usage sheet (same glass as progress / tools Usage).
      if let chatId = agentBridgeChatId, !chatId.isEmpty {
        let provider = (agentBridgeProvider ?? composerView.provider)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let appearance = self.appearance
        let root = VibeAgentUsageSheetRoot(
          chatId: chatId,
          provider: provider.isEmpty ? "claude" : provider,
          appearance: appearance
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
          sheet.detents = [.medium(), .large()]
          sheet.prefersGrabberVisible = true
          if #available(iOS 16.0, *) {
            sheet.preferredCornerRadius = 30
          }
        }
        present(host, animated: true)
        return
      }
      content = ("Usage", usageCommandBody())
    case "/status", "status":
      content = ("Status", statusCommandBody())
    case "/commands", "commands":
      content = ("Commands", commandsCommandBody())
    case "/skills", "skills":
      content = ("Skills", skillsCommandBody())
    case "/reasoning", "reasoning", "/thinking", "thinking":
      content = ("Reasoning", reasoningCommandBody())
    case "/compact", "compact":
      content = ("Compact", "Compact is available as a bridge command. It is shown here instead of being inserted into chat; run a compact task from the provider CLI when the bridge reports support.")
    default:
      content = ("Command", "No local panel is available for \(command).")
    }
    commandOverlayView.configure(title: content.title, body: content.body)
    showCommandOverlay()
  }

  private func showCommandOverlay() {
    view.bringSubviewToFront(commandOverlayView)
    if commandOverlayView.isHidden {
      commandOverlayView.isHidden = false
      commandOverlayView.transform = CGAffineTransform(translationX: 0, y: 10)
    }
    UIView.animate(
      withDuration: 0.22,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.commandOverlayView.alpha = 1.0
      self.commandOverlayView.transform = .identity
    }
  }

  private func hideCommandOverlay() {
    UIView.animate(
      withDuration: 0.16,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.commandOverlayView.alpha = 0.0
      self.commandOverlayView.transform = CGAffineTransform(translationX: 0, y: 8)
    } completion: { _ in
      if self.commandOverlayView.alpha <= 0.01 {
        self.commandOverlayView.isHidden = true
      }
    }
  }

  private func latestRuntimeSummary() -> ChatListRow.AgentRuntimeSummary? {
    messages.reversed().compactMap { $0.runtime }.first
  }

  /// Feed the `/` palette the slash + CLI commands the connected provider reports
  /// (from the latest runtime metadata), so it lists everything the real CLI exposes.
  private func updateComposerCommandCatalog() {
    let runtime = latestRuntimeSummary()
    composerView.setProviderCommands(
      slash: runtime?.slashCommands ?? [],
      cli: runtime?.cliCommands ?? []
    )
  }

  private func usageCommandBody() -> String {
    guard let runtime = latestRuntimeSummary(), let usage = runtime.usage else {
      return "No usage has been recorded for this chat yet. Run one agent task first."
    }
    let used = agentUsageTokens(usage)
    let limit = agentUsageLimit(provider: runtime.provider ?? agentBridgeProvider, model: runtime.model)
    var parts: [String] = [
      "\(Self.compactTokenCount(used)) / \(Self.compactTokenCount(limit)) tokens"
    ]
    if let input = usage.inputTokens { parts.append("input \(Self.compactTokenCount(input))") }
    if let output = usage.outputTokens { parts.append("output \(Self.compactTokenCount(output))") }
    if let reasoning = usage.reasoningOutputTokens {
      parts.append("reasoning \(Self.compactTokenCount(reasoning))")
    }
    if let cost = usage.totalCostUsd, cost > 0 {
      parts.append(String(format: "$%.2f", cost))
    }
    if let duration = usage.durationMs, duration > 0 {
      parts.append("runtime \(Self.compactDuration(ms: duration))")
    }
    return parts.joined(separator: "\n")
  }

  private func statusCommandBody() -> String {
    let runtime = latestRuntimeSummary()
    let provider = (runtime?.provider ?? agentBridgeProvider ?? composerView.provider)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let repo = runtime?.repoName
      ?? AgentBridgeSelectionStore.selectedRepository()?.name
      ?? "No repository selected"
    let cwd = runtime?.cwd ?? AgentBridgeSelectionStore.selectedRepository()?.path ?? "-"
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    let reportedModel = displayedSessionModelId(provider: provider)
    let model = reportedModel ?? options.model ?? "Provider default"
    let modelTitle = AgentBridgeSelectionStore.modelTitle(provider: provider, model: model)
    let reportedEffort = displayedSessionReasoningEffort()
    let advisor = runtime?.advisor ?? options.advisor
    let mode = runtime?.workMode ?? AgentBridgeSelectionStore.selectedWorkMode().rawValue
    let status = runtime?.status ?? (messages.contains { $0.isStreaming } ? "running" : "idle")
    let device = deviceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = [
      "\(provider.isEmpty ? agentDisplayName : provider) bridge status: \(status)",
      "repo: \(repo)",
      "cwd: \(cwd)",
      "work mode: \(mode)",
      "model: \(modelTitle)",
    ]
    if let reportedEffort,
      let level = AgentBridgeIntelligenceLevel.fromProviderEffort(reportedEffort)
    {
      lines.append("thinking: \(level.title) (session)")
    }
    if provider.lowercased() == "claude" {
      lines.append("advisor: \(advisor ?? "off")")
    }
    lines.append("device: \(device?.isEmpty == false ? device! : "not reported")")
    lines.append("connection: \(deviceConnected ? "connected" : "reconnecting")")
    return lines.joined(separator: "\n")
  }

  private func commandsCommandBody() -> String {
    let runtime = latestRuntimeSummary()
    var sections: [String] = []
    let bridgeCommands = ["/usage", "/status", "/commands", "/skills", "/model", "/advisor", "/reasoning", "/plan", "/compact"]
    sections.append("Vibe controls\n" + bridgeCommands.joined(separator: "  "))
    if let runtime {
      let providerSlash = runtime.slashCommands.map { $0.hasPrefix("/") ? $0 : "/\($0)" }
      appendCommandSection("Provider slash commands", providerSlash, to: &sections)
      appendCommandSection("Bridge commands", runtime.providerCommands, to: &sections)
      appendCommandSection("CLI commands", runtime.cliCommands, to: &sections)
      appendCommandSection("Tools", runtime.availableTools, to: &sections)
    }
    return sections.joined(separator: "\n\n")
  }

  private func skillsCommandBody() -> String {
    guard let runtime = latestRuntimeSummary() else {
      return "No skills have been reported for this chat yet."
    }
    var sections: [String] = []
    appendCommandSection("Skills", runtime.skills, to: &sections)
    appendCommandSection("Agents", runtime.agents, to: &sections)
    appendCommandSection(
      "MCP servers",
      runtime.mcpServers.map { server in
        if let status = server.status, !status.isEmpty { return "\(server.name) (\(status))" }
        return server.name
      },
      to: &sections
    )
    return sections.isEmpty ? "No skills or MCP servers were reported by the bridge." : sections.joined(separator: "\n\n")
  }

  private func reasoningCommandBody() -> String {
    let provider = agentBridgeProvider ?? composerView.provider
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    let nextEffort = AgentBridgeRunOptions.effectiveEffort(
      provider: provider,
      intelligence: options.intelligence,
      speed: options.speed
    )
    let sessionModelId = displayedSessionModelId(provider: provider)
    let modelTitle = AgentBridgeSelectionStore.modelTitle(
      provider: provider,
      model: sessionModelId ?? options.model
    )
    let sessionEffort = displayedSessionReasoningEffort()
    var lines = [
      "session model: \(modelTitle)",
    ]
    if let sessionEffort {
      if let level = AgentBridgeIntelligenceLevel.fromProviderEffort(sessionEffort) {
        lines.append("session thinking: \(level.title)")
      } else {
        lines.append("session thinking: reported (\(sessionEffort))")
      }
    } else {
      lines.append("session thinking: not reported")
    }
    lines.append(contentsOf: [
      "next-run thinking: \(options.intelligence.title)",
      "next-run speed: \(options.speed.title)",
      "next-run effort: \(nextEffort)",
    ])
    return lines.joined(separator: "\n")
  }

  private func appendCommandSection(
    _ title: String,
    _ values: [String],
    to sections: inout [String]
  ) {
    let cleaned = values
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return }
    sections.append(title + "\n" + cleaned.prefix(18).joined(separator: "  "))
  }

  private func updateUsageBanner(force: Bool = false) {
    guard isViewLoaded else { return }
    usageBannerView.applyTheme(
      textColor: appearance.text,
      surfaceColor: appearance.surfaceElevated,
      isDark: appearance.isDark
    )

    guard let snapshot = latestUsageBannerSnapshot(), isHistoryPicked, !isLoadingTranscript else {
      setUsageBannerVisible(false, key: nil, force: force)
      return
    }

    let key = "\(snapshot.title)|\(snapshot.body)"
    if force || key != usageBannerKey {
      usageBannerView.configure(
        title: snapshot.title,
        body: snapshot.body,
        systemImage: "gauge.with.dots.needle.bottom.50percent",
        animateIcon: usageBannerKey != nil
      )
    }
    setUsageBannerVisible(true, key: key, force: force)
  }

  private func setUsageBannerVisible(_ visible: Bool, key: String?, force: Bool) {
    usageBannerKey = key
    guard force || visible != usageBannerVisible else { return }
    usageBannerVisible = visible
    updateScrollInsets()
    if visible {
      usageBannerView.isHidden = false
      view.bringSubviewToFront(usageBannerView)
      UIView.animate(
        withDuration: 0.18,
        delay: 0.0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.usageBannerView.alpha = 1.0
      }
    } else {
      UIView.animate(
        withDuration: 0.16,
        delay: 0.0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.usageBannerView.alpha = 0.0
      } completion: { _ in
        if self.usageBannerView.alpha <= 0.01 {
          self.usageBannerView.isHidden = true
        }
      }
    }
  }

  private func latestUsageBannerSnapshot() -> (title: String, body: String)? {
    for message in messages.reversed() {
      guard let runtime = message.runtime, let usage = runtime.usage else { continue }
      let used = agentUsageTokens(usage)
      guard used > 0 else { continue }
      let limit = agentUsageLimit(provider: runtime.provider ?? agentBridgeProvider, model: runtime.model)
      let ratio = Double(used) / Double(limit)
      let commandDisplay = runtime.command?.display?.lowercased() ?? ""
      let isExplicitUsageResult = commandDisplay.contains("/usage")
      guard isExplicitUsageResult || ratio >= 0.72 else { continue }

      let provider = (runtime.provider ?? agentBridgeProvider ?? agentDisplayName)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let providerTitle =
        provider.isEmpty
        ? agentDisplayName
        : provider.prefix(1).uppercased() + String(provider.dropFirst())
      let percent = Int(round(ratio * 100.0))
      var body =
        "\(providerTitle) \(percent)% · \(Self.compactTokenCount(used)) / \(Self.compactTokenCount(limit)) tokens"
      if let cost = usage.totalCostUsd, cost > 0 {
        body += String(format: " · $%.2f", cost)
      }
      let title = ratio >= 0.9 ? "Context nearly full" : "Context usage"
      return (title, body)
    }
    return nil
  }

  private func agentUsageTokens(_ usage: ChatListRow.AgentRuntimeUsage) -> Int {
    max(
      0,
      (usage.inputTokens ?? 0)
        + (usage.outputTokens ?? 0)
        + (usage.reasoningOutputTokens ?? 0)
    )
  }

  private func agentUsageLimit(provider: String?, model: String?) -> Int {
    let providerValue = (provider ?? "").lowercased()
    let modelValue = (model ?? "").lowercased()
    if providerValue == "claude" || modelValue.contains("claude") {
      return 200_000
    }
    return 200_000
  }

  private static func compactTokenCount(_ value: Int) -> String {
    if value >= 1_000_000 {
      return String(format: "%.1fM", Double(value) / 1_000_000.0)
    }
    if value >= 1000 {
      return String(format: "%.0fk", Double(value) / 1000.0)
    }
    return "\(value)"
  }

  private static func compactDuration(ms: Int) -> String {
    let seconds = max(0, ms / 1000)
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    let remaining = seconds % 60
    if minutes < 60 { return "\(minutes)m \(remaining)s" }
    return "\(minutes / 60)h \(minutes % 60)m"
  }

  private func updateEditToast() {
    guard isViewLoaded else { return }
    let summary = editDiffSummary()
    let hasLiveTurn = messages.contains { $0.isStreaming || $0.runtime?.status == "running" }
    let shouldShow = summary != nil && isHistoryPicked && !isLoadingTranscript && !hasLiveTurn
    if let summary {
      editToastLabel.attributedText = summary.attributed
      editToastLabel.accessibilityLabel = summary.plain
    }
    guard editToastBlur.isHidden == shouldShow || abs(editToastBlur.alpha - (shouldShow ? 1.0 : 0.0)) > 0.01 else {
      return
    }
    if shouldShow {
      editToastBlur.isHidden = false
      UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.editToastBlur.alpha = 1.0
      }
    } else {
      UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.editToastBlur.alpha = 0.0
      } completion: { _ in
        if self.editToastBlur.alpha <= 0.01 { self.editToastBlur.isHidden = true }
      }
    }
  }

  // MARK: Subagent (Claude Task tool) surfacing

  private func setupSubagentToast() {
    subagentToastBlur.translatesAutoresizingMaskIntoConstraints = false
    subagentToastBlur.alpha = 0.0
    subagentToastBlur.isHidden = true
    subagentToastBlur.clipsToBounds = true
    subagentToastBlur.layer.cornerRadius = 16.0
    subagentToastBlur.layer.cornerCurve = .continuous
    subagentToastBlur.layer.borderWidth = 0.6
    subagentToastBlur.layer.borderColor =
      vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.18 : 0.14).cgColor
    subagentToastBlur.contentView.backgroundColor =
      (appearance.isDark ? UIColor.white : UIColor.black)
      .withAlphaComponent(appearance.isDark ? 0.055 : 0.045)
    view.addSubview(subagentToastBlur)

    subagentToastLabel.translatesAutoresizingMaskIntoConstraints = false
    subagentToastLabel.numberOfLines = 1
    subagentToastLabel.lineBreakMode = .byTruncatingTail
    subagentToastLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    subagentToastLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.9)
    subagentToastBlur.contentView.addSubview(subagentToastLabel)

    NSLayoutConstraint.activate([
      subagentToastBlur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      subagentToastBlur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60.0),
      subagentToastBlur.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor, constant: 24.0),
      subagentToastBlur.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor, constant: -24.0),
      subagentToastLabel.leadingAnchor.constraint(
        equalTo: subagentToastBlur.contentView.leadingAnchor, constant: 14.0),
      subagentToastLabel.trailingAnchor.constraint(
        equalTo: subagentToastBlur.contentView.trailingAnchor, constant: -12.0),
      subagentToastLabel.topAnchor.constraint(equalTo: subagentToastBlur.contentView.topAnchor, constant: 8.0),
      subagentToastLabel.bottomAnchor.constraint(
        equalTo: subagentToastBlur.contentView.bottomAnchor, constant: -8.0),
    ])
    subagentToastBlur.contentView.isUserInteractionEnabled = true
    subagentToastBlur.contentView.addGestureRecognizer(
      UITapGestureRecognizer(target: self, action: #selector(handleSubagentToastTap)))
  }

  @objc private func handleSubagentToastTap() {
    guard let target = subagentToastTarget else { return }
    hideSubagentToast()
    presentSubagentView(messageId: target.messageId, parentNodeId: target.nodeId)
  }

  /// All running subagents in the current transcript, as (messageId, nodeId, type).
  private func runningSubagents(in msgs: [VibeAgentKitChatMessage])
    -> [(messageId: String, nodeId: String, type: String)]
  {
    var out: [(messageId: String, nodeId: String, type: String)] = []
    for message in msgs {
      for item in message.progressItems {
        // Strict: only REAL Task-tool subagents (task-kind + subagentType). The old
        // `task-kind OR has-subagentType` let the bridge's synthetic running-task
        // placeholder (task-kind, no subagentType) fire phantom "Subagent" toasts.
        guard item.isRealSubagent else { continue }
        let nodeId = item.nodeId ?? item.label
        let running = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
        guard running else { continue }
        out.append((messageId: message.id, nodeId: nodeId, type: item.subagentType ?? ""))
      }
    }
    return out
  }

  private func updateSubagentState(_ newMessages: [VibeAgentKitChatMessage]) {
    guard isViewLoaded else { return }
    // Announce any newly-running subagent once (toast auto-fades; the feed row persists).
    for sub in runningSubagents(in: newMessages) where !toastedSubagentIds.contains(sub.nodeId) {
      toastedSubagentIds.insert(sub.nodeId)
      showSubagentToast(messageId: sub.messageId, nodeId: sub.nodeId, type: sub.type)
    }
    // Keep an open detail view streaming: re-feed it the latest children for its parent.
    if let ref = openSubagentRef, let detail = openSubagentDetail,
      let message = newMessages.first(where: { $0.id == ref.messageId })
    {
      let stillRunning = runningSubagents(in: newMessages).contains { $0.nodeId == ref.nodeId }
      detail.update(
        progressItems: message.subagentChildren[ref.nodeId] ?? [],
        running: stillRunning)
    }
  }

  private func showSubagentToast(messageId: String, nodeId: String, type: String) {
    subagentToastTarget = (messageId: messageId, nodeId: nodeId)
    let flavor = type.trimmingCharacters(in: .whitespacesAndNewlines)
    subagentToastLabel.text = flavor.isEmpty ? "Subagent running" : "Subagent running · \(flavor)"
    subagentToastBlur.isHidden = false
    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.subagentToastBlur.alpha = 1.0
    }
    subagentToastHideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hideSubagentToast() }
    subagentToastHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
  }

  private func hideSubagentToast() {
    subagentToastHideWork?.cancel()
    subagentToastHideWork = nil
    guard !subagentToastBlur.isHidden else { return }
    UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.subagentToastBlur.alpha = 0.0
    } completion: { _ in
      if self.subagentToastBlur.alpha <= 0.01 { self.subagentToastBlur.isHidden = true }
    }
  }

  /// Open the read-only subagent view (no composer) for a parent Task node, seeded with
  /// its current children and kept live by `updateSubagentState`.
  private func presentSubagentView(messageId: String, parentNodeId: String) {
    guard let message = messages.first(where: { $0.id == messageId }) else { return }
    let children = message.subagentChildren[parentNodeId] ?? []
    let type = message.progressItems.first {
      (($0.nodeId ?? $0.label) == parentNodeId) && ($0.subagentType?.isEmpty == false)
    }?.subagentType ?? ""
    let running = runningSubagents(in: messages).contains { $0.nodeId == parentNodeId }
    let detail = VibeAgentSubagentDetailViewController(
      subagentType: type,
      progressItems: children,
      running: running,
      appearance: appearance)
    openSubagentDetail = detail
    openSubagentRef = (messageId: messageId, nodeId: parentNodeId)
    detail.onClose = { [weak self] in
      self?.openSubagentDetail = nil
      self?.openSubagentRef = nil
    }
    let nav = UINavigationController(rootViewController: detail)
    nav.modalPresentationStyle = .pageSheet
    // Clear the nav wrapper's opaque backing so the sheet's own UIGlassEffect refracts the
    // chat behind it (real Liquid Glass) instead of frosting a solid nav background — the
    // ask sheet looks glass precisely because it's presented WITHOUT this opaque layer.
    nav.view.backgroundColor = .clear
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  /// The whole-history diff at a glance (not a single edited-file detail): how many files
  /// the session changed and the total lines added (green) / removed (red). This is what
  /// the toast above the composer shows when a history is opened.
  private func editDiffSummary() -> (plain: String, attributed: NSAttributedString)? {
    var files = Set<String>()
    var lastFile: String?
    var added = 0
    var removed = 0
    for message in messages {
      for item in message.progressItems {
        let kind = (item.itemType ?? item.tool ?? "").lowercased()
        guard kind == "edit" || kind == "write" else { continue }
        let file = item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (file?.isEmpty == false) ? file! : item.label
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        if !leaf.isEmpty {
          files.insert(leaf)
          lastFile = leaf
        }
        let counts = editCounts(label: item.label, patch: item.patch)
        added += counts.added
        removed += counts.removed
      }
    }
    guard !files.isEmpty || added > 0 || removed > 0 else { return nil }

    let fileText = (files.count == 1 ? lastFile : "\(files.count) files")
      ?? "\(files.count) files"
    let font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    let attr = NSMutableAttributedString(
      string: fileText,
      attributes: [
        .foregroundColor: vibeAgentKitColorWithAlpha(appearance.text, 0.9),
        .font: font,
      ])
    if added > 0 {
      attr.append(NSAttributedString(
        string: "  +\(added)",
        attributes: [.foregroundColor: UIColor.systemGreen, .font: font]))
    }
    if removed > 0 {
      attr.append(NSAttributedString(
        string: "  −\(removed)",
        attributes: [.foregroundColor: UIColor.systemRed, .font: font]))
    }
    let plain = "\(fileText) · +\(added) −\(removed)"
    return (plain, attr)
  }

  /// Added/removed line counts for one edit. Prefers the actual patch (count of `+`/`-`
  /// body lines) and falls back to the first `+N` / `-N` tokens in the label. The
  /// deletion token uses a non-digit lookbehind so a `Lines 10-20` range isn't misread
  /// as `-20` removed lines.
  private func editCounts(label: String, patch: String?) -> (added: Int, removed: Int) {
    if let patch, patch.contains("\n") {
      var added = 0
      var removed = 0
      for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
          added += 1
        } else if line.hasPrefix("-"), !line.hasPrefix("---") {
          removed += 1
        }
      }
      if added > 0 || removed > 0 { return (added, removed) }
    }
    return (
      firstIntMatch(in: label, pattern: "\\+(\\d[\\d,]*)"),
      firstIntMatch(in: label, pattern: "(?<![0-9])[−-](\\d[\\d,]*)")
    )
  }

  private func firstIntMatch(in text: String, pattern: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
    let ns = text as NSString
    guard
      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
      match.numberOfRanges > 1
    else { return 0 }
    let digits = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
    return Int(digits) ?? 0
  }

  private func updateBottomEdgeFade() {
    bottomEdgeFadeView.isHidden = true
  }

  private func updateRepoPickerStyle() {
    var config = UIButton.Configuration.plain()

    let repoName = AgentBridgeSelectionStore.selectedRepository()?.name ?? "Repository"
    config.title = repoName

    config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    config.imagePlacement = .trailing
    config.imagePadding = 5
    config.baseForegroundColor = appearance.textSecondary
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    repoPickerButton.configuration = config
    repoPickerButton.isHidden = (repoPickerMenu == nil) || isHistoryPicked
  }

  private func updateBottomEdgeFadeFrame() {
    guard let gradient = bottomEdgeFadeView.layer.sublayers?.first as? CAGradientLayer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.frame = bottomEdgeFadeView.bounds
    CATransaction.commit()
  }

  /// Keep the feed's bottom inset matched to however much of the screen the floating
  /// composer (and, when raised, the keyboard) currently covers, so the last bubble
  /// always clears the pill even though the table extends edge-to-edge beneath it.
  private func updateScrollInsets(force: Bool = false) {
    let covered = max(0, view.bounds.maxY - composerView.frame.minY)
    // The table reaches the screen bottom, so its automatic safe-area inset already
    // covers the home indicator; only add the part above it, plus a small gap.
    let baseBottom = max(12, covered - view.safeAreaInsets.bottom + 8)
    // While a send is pinned to the top, reserve room below so the question can hold near
    // the top with the answer streaming beneath it (ChatGPT / Resolo-style). The reserve is
    // recomputed LIVE here every layout pass (Resolo models it as a `minHeight` floor on the
    // current-turn container, not an imperatively-managed inset) so it shrinks to 0 on its
    // own as the answer fills the viewport — no stale "huge gap" left behind by a relax
    // token that measured a not-yet-grown contentSize.
    pushToTopReserve = computedPushToTopReserve()
    let bottom = max(baseBottom, pushToTopReserve)
    var top = usageBannerVisible ? ChatPinnedBannerView.preferredHeight + 24.0 : 12.0
    if usesInViewHeader {
      top += view.safeAreaInsets.top + 44.0 + 8.0
    }
    guard force || abs(tableView.contentInset.bottom - bottom) > 0.5
      || abs(tableView.contentInset.top - top) > 0.5
    else { return }
    let wasNearBottom = isNearBottom()
    tableView.contentInset.bottom = bottom
    tableView.contentInset.top = top
    tableView.verticalScrollIndicatorInsets.bottom = bottom
    tableView.verticalScrollIndicatorInsets.top = top
    if wasNearBottom, pushToTopUserId == nil, pushToTopReserve <= 0, toggleScrollLockDepth == 0 {
      scrollToBottom(animated: false)
    }
  }

  /// The reserve needed RIGHT NOW so the pinned user message can stay at the top with the
  /// answer streaming below it. Sized so the max scroll offset equals the pinned question's
  /// offset (`contentSize + reserve - bounds == userMinY - paddingTop`), matching the
  /// collection-view agent surface. Returns 0 once the answer fills the available space,
  /// so the gap closes itself (Resolo's self-correcting floor, ported to a UITableView).
  private func computedPushToTopReserve() -> CGFloat {
    guard let id = pushToTopUserId,
      let idx = tableMessages.firstIndex(where: { $0.id == id })
    else { return 0 }
    let rect = tableView.rectForRow(at: IndexPath(row: idx, section: 0))
    guard rect.height > 0 else { return 0 }
    let topInset = tableView.adjustedContentInset.top
    let viewport = max(0, tableView.bounds.height - topInset)
    let contentBelow = max(0, tableView.contentSize.height - rect.minY)
    return max(0, viewport - contentBelow)
  }

  // MARK: Push-to-top send (ChatGPT-style)

  /// The user message currently pinned near the top while its answer streams below.
  private var pushToTopUserId: String?
  /// Extra bottom inset reserved so the pinned question can rise to the top; it shrinks
  /// toward zero as the answer fills the space below.
  private var pushToTopReserve: CGFloat = 0
  /// The user grabbed the list after the pin — stop re-asserting the pinned offset so
  /// they can scroll freely for the rest of the turn.
  private var pushToTopDetached = false
  /// While the animated pin scroll is in flight, the per-layout re-assert must not
  /// snap the offset out from under the spring.
  private var pinAnimationDeadline: Date?

  /// Hold the pinned question exactly at its target offset across the passes that used
  /// to nudge it (self-sizing estimates resolving, the answer row inserting below, inset
  /// changes) — the "lands, then hops ~10px" bug. Never fights the user: bails while
  /// they touch/fling the list or once they've detached, and stays quiet during the
  /// pin's own spring animation and inline toggle updates.
  private func reassertPinnedOffsetIfNeeded() {
    guard let id = pushToTopUserId, !pushToTopDetached, toggleScrollLockDepth == 0,
      !tableView.isTracking, !tableView.isDragging, !tableView.isDecelerating,
      let idx = tableMessages.firstIndex(where: { $0.id == id })
    else { return }
    if let deadline = pinAnimationDeadline {
      if Date() < deadline { return }
      pinAnimationDeadline = nil
    }
    let rect = tableView.rectForRow(at: IndexPath(row: idx, section: 0))
    guard rect.height > 0 else { return }
    let topInset = tableView.adjustedContentInset.top
    let targetY = pixelAlignedValue(max(-topInset, rect.minY - topInset))
    if abs(tableView.contentOffset.y - targetY) > 0.5 {
      tableView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
    }
  }

  /// Pin a freshly-sent user message to the top. The room below is reserved passively by
  /// `updateScrollInsets`/`computedPushToTopReserve` (recomputed every layout pass, so it
  /// shrinks to 0 as the answer fills it — Resolo's self-correcting floor). Here we only
  /// force one inset update (so the reserve exists before we move) and scroll the question
  /// to the top; from then on the content above it is fixed, so it simply holds its place.
  private func pinUserMessageToTop(id: String, animated: Bool) {
    guard let idx = tableMessages.firstIndex(where: { $0.id == id }) else { return }
    pushToTopUserId = id
    pushToTopDetached = false
    pinAnimationDeadline = animated ? Date().addingTimeInterval(0.55) : nil
    tableView.layoutIfNeeded()
    updateScrollInsets(force: true)
    tableView.layoutIfNeeded()
    let rect = tableView.rectForRow(at: IndexPath(row: idx, section: 0))
    let topInset = tableView.adjustedContentInset.top
    let targetY = pixelAlignedValue(max(-topInset, rect.minY - topInset))
    setTableContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
  }

  private func setTableContentOffset(_ offset: CGPoint, animated: Bool) {
    guard animated else {
      tableView.setContentOffset(offset, animated: false)
      return
    }
    UIView.animate(
      withDuration: 0.42,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0.4,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.tableView.setContentOffset(offset, animated: false)
    }
  }

  private func pixelAlignedValue(_ value: CGFloat) -> CGFloat {
    let scale =
      view.window?.windowScene?.screen.scale ?? view.window?.screen.scale ?? traitCollection.displayScale
    guard scale > 0 else { return value }
    return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
  }

  private func isNearBottom() -> Bool {
    let offsetY = tableView.contentOffset.y
    let bottom = tableView.contentSize.height - tableView.bounds.height + tableView.contentInset.bottom
    return offsetY >= bottom - 120
  }

  private func scrollToBottom(animated: Bool) {
    let rows = tableView.numberOfRows(inSection: 0)
    guard rows > 0 else { return }
    let last = IndexPath(row: rows - 1, section: 0)
    tableView.scrollToRow(at: last, at: .bottom, animated: animated)
  }
}

/// A small custom progress indicator — a single rotating arc — used as the centered
/// loader while a transcript loads (rather than the system activity indicator or a
/// fake "Loading…" message bubble).
final class VibeAgentCommandOverlayView: UIView {
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  private var appearance: VibeAgentKitChatAppearance = .fallback

  var onClose: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { return nil }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    blurView.contentView.backgroundColor = vibeAgentKitColorWithAlpha(
      appearance.isDark ? UIColor.white : UIColor.black,
      appearance.isDark ? 0.065 : 0.045
    )
    layer.borderColor = vibeAgentKitColorWithAlpha(
      appearance.textSecondary,
      appearance.isDark ? 0.2 : 0.16
    ).cgColor
    titleLabel.textColor = appearance.text
    bodyLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, 0.78)
    closeButton.tintColor = vibeAgentKitColorWithAlpha(appearance.text, 0.78)
  }

  func configure(title: String, body: String) {
    titleLabel.text = title
    bodyLabel.text = body
    setNeedsLayout()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerRadius = 18.0
    layer.cornerCurve = .continuous
    layer.borderWidth = 0.7

    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.numberOfLines = 1
    blurView.contentView.addSubview(titleLabel)

    bodyLabel.translatesAutoresizingMaskIntoConstraints = false
    bodyLabel.font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    bodyLabel.numberOfLines = 0
    blurView.contentView.addSubview(bodyLabel)

    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.setImage(
      UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .semibold)),
      for: .normal
    )
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    blurView.contentView.addSubview(closeButton)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

      titleLabel.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 14.0),
      titleLabel.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 16.0),
      titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8.0),

      closeButton.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 8.0),
      closeButton.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -8.0),
      closeButton.widthAnchor.constraint(equalToConstant: 34.0),
      closeButton.heightAnchor.constraint(equalToConstant: 34.0),

      bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10.0),
      bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      bodyLabel.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -16.0),
      bodyLabel.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor, constant: -14.0),
    ])

    applyAppearance(.fallback)
  }

  @objc private func closeTapped() {
    onClose?()
  }
}

private struct VibeAgentImagePreview: View {
  let image: UIImage
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.black.ignoresSafeArea()
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
      }
      .padding(.top, 18)
      .padding(.trailing, 18)
    }
  }
}

/// A single low-contrast shimmer placeholder. The base is a faint tint of the theme's
/// text color (so the block reads as part of the same warm surface as the real feed, not
/// a generic grey), and the sweep is a wide, feathered highlight — a gentle glow, never a
/// hard-edged bar. Used to assemble the transcript loading skeleton.
private final class VibeAgentSkeletonPillView: UIView {
  private let backgroundGradientLayer = CAGradientLayer()
  private let shimmerGradientLayer = CAGradientLayer()
  private var animating = false
  private var lastAnimatedWidth: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerCurve = .continuous
    clipsToBounds = true
    
    backgroundGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    backgroundGradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    layer.addSublayer(backgroundGradientLayer)
    
    shimmerGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    shimmerGradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
    layer.addSublayer(shimmerGradientLayer)
  }

  required init?(coder: NSCoder) { return nil }

  func apply(base: UIColor, highlight: UIColor, cornerRadius: CGFloat, userGradient: [UIColor]? = nil) {
    layer.cornerRadius = cornerRadius
    
    if let userGradient = userGradient {
      backgroundColor = .clear
      backgroundGradientLayer.colors = userGradient.map { $0.cgColor }
      backgroundGradientLayer.isHidden = false
    } else {
      backgroundColor = base
      backgroundGradientLayer.isHidden = true
    }
    
    // Clear → soft highlight → clear so only a narrow band brightens as it sweeps; the
    // pill's own base color shows through the feathered ends (no visible edge).
    shimmerGradientLayer.colors = [UIColor.clear.cgColor, highlight.cgColor, UIColor.clear.cgColor]
    shimmerGradientLayer.locations = [0.2, 0.5, 0.8]
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    backgroundGradientLayer.frame = bounds
    // Extend well past the bounds so the band enters/exits cleanly off-screen.
    shimmerGradientLayer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3.0, height: bounds.height)
    if animating { addShimmerIfNeeded() }
  }

  func startAnimating() {
    animating = true
    addShimmerIfNeeded()
  }

  func stopAnimating() {
    animating = false
    shimmerGradientLayer.removeAnimation(forKey: "shimmer")
  }

  private func addShimmerIfNeeded() {
    // Very soft, slow sweep — a narrow low-alpha highlight band drifts across each
    // pill; the pill's own fill (them-tone / user gradient) stays the dominant read.
    guard animating, bounds.width > 0 else { return }
    if lastAnimatedWidth == bounds.width, shimmerGradientLayer.animation(forKey: "shimmer") != nil {
      return
    }
    lastAnimatedWidth = bounds.width
    shimmerGradientLayer.removeAnimation(forKey: "shimmer")
    let sweep = CABasicAnimation(keyPath: "transform.translation.x")
    sweep.fromValue = -bounds.width
    sweep.toValue = bounds.width
    sweep.duration = 2.4
    sweep.repeatCount = .infinity
    sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    shimmerGradientLayer.add(sweep, forKey: "shimmer")
  }
}

// MARK: - History load: line spinner (direct + group)

/// Thin rotating line arc for History / chat load in the middle of the feed.
/// Replaces the old orbiting-orb constellation. Channels keep the bubble skeleton.
final class ChatHistoryModernLoadingView: UIView {
  private let spinHost = CALayer()
  private let progressLayer = CAShapeLayer()
  private let spinKey = "chat.history.lineSpin"

  private var lineColor: UIColor = UIColor.secondaryLabel
  private let spinnerSide: CGFloat = 28
  private let lineWidth: CGFloat = 2.0

  var contentTopInset: CGFloat = 0 { didSet { setNeedsLayout() } }
  var contentBottomInset: CGFloat = 20 { didSet { setNeedsLayout() } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    backgroundColor = .clear

    spinHost.contentsScale = UIScreen.main.scale
    layer.addSublayer(spinHost)

    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.lineCap = .round
    progressLayer.lineWidth = lineWidth
    progressLayer.strokeStart = 0.08
    progressLayer.strokeEnd = 0.78
    progressLayer.contentsScale = UIScreen.main.scale
    spinHost.addSublayer(progressLayer)
  }

  required init?(coder: NSCoder) { nil }

  func applyAppearance(isDark: Bool, accent: UIColor, secondaryText: UIColor) {
    _ = accent
    lineColor = secondaryText.withAlphaComponent(isDark ? 0.78 : 0.72)
    progressLayer.strokeColor = lineColor.cgColor
    setNeedsLayout()
  }

  func startAnimating() {
    layoutIfNeeded()
    progressLayer.strokeColor = lineColor.cgColor
    if spinHost.animation(forKey: spinKey) == nil {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0
      spin.toValue = Double.pi * 2
      spin.duration = 0.85
      spin.repeatCount = .infinity
      spin.timingFunction = CAMediaTimingFunction(name: .linear)
      spin.isRemovedOnCompletion = false
      spinHost.add(spin, forKey: spinKey)
    }
  }

  func stopAnimating() {
    spinHost.removeAnimation(forKey: spinKey)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    spinHost.transform = CATransform3DIdentity
    CATransaction.commit()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let usable = bounds.inset(
      by: UIEdgeInsets(
        top: contentTopInset, left: 0, bottom: contentBottomInset, right: 0))
    let center = CGPoint(x: usable.midX, y: usable.midY)

    spinHost.bounds = CGRect(x: 0, y: 0, width: spinnerSide, height: spinnerSide)
    spinHost.position = center

    let ringRect = spinHost.bounds.insetBy(dx: lineWidth / 2.0, dy: lineWidth / 2.0)
    progressLayer.frame = spinHost.bounds
    progressLayer.path = UIBezierPath(ovalIn: ringRect).cgPath
    progressLayer.lineWidth = lineWidth
  }
}

// MARK: - Header line spinner (Home / chat sync)

/// Compact open-arc spinner used in the chat header next to Connecting / Updating.
final class VibeHeaderLineSpinnerView: UIView {
  private let spinHost = CALayer()
  private let progressLayer = CAShapeLayer()
  private let spinKey = "vibe.header.lineSpin"
  private let spinnerSize: CGFloat
  private let strokeWidth: CGFloat
  private var isAnimating = false

  var color: UIColor = .secondaryLabel {
    didSet { progressLayer.strokeColor = color.cgColor }
  }

  init(size: CGFloat = 11, lineWidth: CGFloat = 1.55) {
    self.spinnerSize = size
    self.strokeWidth = lineWidth
    super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = false

    spinHost.contentsScale = UIScreen.main.scale
    layer.addSublayer(spinHost)

    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = color.cgColor
    progressLayer.lineCap = .round
    progressLayer.lineWidth = strokeWidth
    progressLayer.strokeStart = 0.08
    progressLayer.strokeEnd = 0.78
    progressLayer.contentsScale = UIScreen.main.scale
    spinHost.addSublayer(progressLayer)
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: CGSize {
    CGSize(width: spinnerSize, height: spinnerSize)
  }

  func startAnimating() {
    // Never collapse via isHidden — callers reserve this slot so text doesn't shift.
    isHidden = false
    alpha = 1
    isAnimating = true
    layoutIfNeeded()
    progressLayer.strokeColor = color.cgColor
    guard spinHost.animation(forKey: spinKey) == nil else { return }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = Double.pi * 2
    spin.duration = 0.85
    spin.repeatCount = .infinity
    spin.timingFunction = CAMediaTimingFunction(name: .linear)
    spin.isRemovedOnCompletion = false
    spinHost.add(spin, forKey: spinKey)
  }

  func stopAnimating() {
    isAnimating = false
    spinHost.removeAnimation(forKey: spinKey)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    spinHost.transform = CATransform3DIdentity
    CATransaction.commit()
    // Keep layout space; hide only visually so neighboring labels don't jump left.
    isHidden = false
    alpha = 0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    spinHost.bounds = CGRect(x: 0, y: 0, width: spinnerSize, height: spinnerSize)
    spinHost.position = CGPoint(x: bounds.midX, y: bounds.midY)
    let ringRect = spinHost.bounds.insetBy(dx: strokeWidth / 2.0, dy: strokeWidth / 2.0)
    progressLayer.frame = spinHost.bounds
    progressLayer.path = UIBezierPath(ovalIn: ringRect).cgPath
    progressLayer.lineWidth = strokeWidth
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Resume spin if we were animating when the view re-entered a window.
    if isAnimating, window != nil, spinHost.animation(forKey: spinKey) == nil {
      startAnimating()
    }
  }
}

/// Chat-shaped loading skeleton for the agent transcript (Claude / Codex). Renders an
/// alternating cadence of agent (left, multi-line) and user (right, bubble) placeholders
/// on the SAME background as the live feed, so a loading conversation reads as chat rather
/// than a bare spinner. Soft, low-contrast shimmer only.
/// Used for **channels** on History pick; direct + group use `ChatHistoryModernLoadingView`.
final class VibeAgentTranscriptSkeletonView: UIView {
  private struct RowSpec {
    let height: CGFloat
    let widthMultiplier: CGFloat
    let isUser: Bool
  }

  // Four distinct row shapes, cycled bottom-up until the FULL visible height is covered
  // (the topmost row overflows the top edge and is clipped). Layout is manual frame
  // math in layoutSubviews — as a UICollectionView/UITableView backgroundView this view
  // is frame-managed by UIKit, and a constraint stack inside it proved unreliable
  // (rows hugging the top / not filling). Frames recompute on every bounds change.
  private let cycle: [RowSpec] = [
    RowSpec(height: 92.0, widthMultiplier: 0.80, isUser: false),
    RowSpec(height: 44.0, widthMultiplier: 0.46, isUser: true),
    RowSpec(height: 136.0, widthMultiplier: 0.84, isUser: false),
    RowSpec(height: 64.0, widthMultiplier: 0.56, isUser: true),
  ]
  private let rowSpacing: CGFloat = 16.0

  private var pills: [VibeAgentSkeletonPillView] = []
  private var pillIsUser: [Bool] = []
  private var appearance: VibeAgentKitChatAppearance = .fallback
  private var userBubbleGradient: [UIColor]?
  private var agentBubbleColor: UIColor?

  /// Extra bottom clearance (floating composer / keyboard inset) so the lowest
  /// placeholder row sits where the newest real message would. Hosts set this from the
  /// list's own bottom content inset.
  var contentBottomInset: CGFloat = 20.0 {
    didSet { if oldValue != contentBottomInset { setNeedsLayout() } }
  }

  /// Top clearance (header band). Rows stop here instead of running under a transparent
  /// navigation header to the very top of the screen; the topmost row is trimmed to the
  /// line like real content scrolled under the header.
  var contentTopInset: CGFloat = 0.0 {
    didSet { if oldValue != contentTopInset { setNeedsLayout() } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) { return nil }

  func applyAppearance(
    _ appearance: VibeAgentKitChatAppearance,
    userBubbleGradient: [UIColor]? = nil,
    agentBubbleColor: UIColor? = nil
  ) {
    self.appearance = appearance
    self.userBubbleGradient = userBubbleGradient
    self.agentBubbleColor = agentBubbleColor
    restylePills()
    setNeedsLayout()
  }

  func startShimmer() {
    layoutIfNeeded()
    pills.forEach { $0.startAnimating() }
  }

  func stopShimmer() {
    pills.forEach { $0.stopAnimating() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, !isHidden { startShimmer() } else { stopShimmer() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 1.0, bounds.height > 1.0 else { return }
    // Match the real bubble rail: messageHorizontalInset + bubbleSideMargin.
    let sideInset = messageHorizontalInset + bubbleSideMargin
    let contentWidth = max(1.0, bounds.width - sideInset * 2.0)

    // Walk the cycle bottom-up from just above the composer inset until the header
    // band (`contentTopInset`) — full coverage of the visible feed on any screen
    // height. The topmost row is trimmed to the header line so nothing pokes out
    // under a transparent navigation header at the very top of the screen.
    var frames: [(frame: CGRect, isUser: Bool)] = []
    var bottomY = bounds.height - contentBottomInset
    var index = 0
    while bottomY > contentTopInset + 8.0 {
      let spec = cycle[index % cycle.count]
      let width = (contentWidth * spec.widthMultiplier).rounded()
      let x = spec.isUser ? bounds.width - sideInset - width : sideInset
      var frame = CGRect(x: x, y: bottomY - spec.height, width: width, height: spec.height)
      if frame.minY < contentTopInset {
        let trimmed = frame.maxY - contentTopInset
        guard trimmed >= 24.0 else { break }
        frame.origin.y = contentTopInset
        frame.size.height = trimmed
      }
      frames.append((frame, spec.isUser))
      bottomY = frame.minY - rowSpacing
      index += 1
    }

    while pills.count < frames.count {
      let pill = VibeAgentSkeletonPillView()
      pill.translatesAutoresizingMaskIntoConstraints = true
      addSubview(pill)
      pills.append(pill)
      pillIsUser.append(false)
    }
    while pills.count > frames.count {
      pills.removeLast().removeFromSuperview()
      pillIsUser.removeLast()
    }

    for (idx, entry) in frames.enumerated() {
      pillIsUser[idx] = entry.isUser
      pills[idx].frame = entry.frame
    }
    restylePills()
    if window != nil, !isHidden { pills.forEach { $0.startAnimating() } }
  }

  private func restylePills() {
    // When the host hands us its REAL incoming-bubble color, use it solid so the
    // placeholders read as the actual cells of the list (not translucent tint shapes);
    // the shimmer stays a very soft, low-alpha band drifting on top. Hosts that don't
    // pass one (the full-page agent view, whose replies have no bubble) keep the
    // text-tint fallback.
    let agentBase =
      agentBubbleColor
      ?? appearance.text.withAlphaComponent(appearance.isDark ? 0.12 : 0.09)
    let agentHighlight =
      agentBubbleColor != nil
      ? (appearance.isDark
        ? UIColor.white.withAlphaComponent(0.08)
        : UIColor.black.withAlphaComponent(0.05))
      : appearance.text.withAlphaComponent(appearance.isDark ? 0.20 : 0.15)
    let userBase = appearance.userBubbleBackground
    let userHighlight = UIColor.white.withAlphaComponent(appearance.isDark ? 0.12 : 0.16)
    for (idx, pill) in pills.enumerated() {
      guard idx < pillIsUser.count else { break }
      if pillIsUser[idx] {
        pill.apply(
          base: userBase, highlight: userHighlight, cornerRadius: 18.0,
          userGradient: userBubbleGradient)
      } else {
        pill.apply(base: agentBase, highlight: agentHighlight, cornerRadius: 18.0)
      }
    }
  }
}

/// The circular agent avatar shown in the header (profile button). Renders the SAME
/// avatar the main chat view uses: the gradient keyed by the conversation's title /
/// peer / chat id (`ChatProfileAppearanceStore.avatarColors`), an initial glyph on top,
/// and — when the conversation has an uploaded picture — the fetched image resolved
/// through the shared `ChatAvatarURLResolver` + `ChatAvatarImageStore` (so it matches
/// the main view instead of a generic SF person symbol).
final class VibeAgentHeaderAvatarView: UIControl {
  private let avatarNode = ChatAvatarNodeView()
  // Matches the UINavigationBar button wrapper's 36pt min-width slot.
  private let diameter: CGFloat = 36

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatarNode)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: diameter),
      heightAnchor.constraint(equalToConstant: diameter),
    ])
  }

  required init?(coder: NSCoder) { return nil }

  override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

  override func layoutSubviews() {
    super.layoutSubviews()
    avatarNode.frame = bounds
  }

  func configure(
    title: String?,
    peerUserId: String?,
    chatId: String?,
    avatarURI: String?,
    isDark: Bool
  ) {
    avatarNode.configure(
      with: ChatAvatarDescriptor(
        title: title ?? "",
        rawAvatarURI: avatarURI,
        peerUserId: peerUserId,
        chatId: chatId,
        kind: .standard,
        isGroup: false,
        members: [],
        preferPushAvatar: peerUserId?.isEmpty == false,
        gradientColors: nil
      ),
      isDark: isDark,
      renderingSide: diameter
    )
  }
}

/// The agent conversation input: one glass pill that is a single compact line at
/// rest (placeholder + mic/send only) and grows into two rows — the text on top,
/// full width, and a plus/slash/permission row underneath — once it's focused or
/// holds a draft. `self` is a transparent container that extends to the very
/// bottom of the screen (ignoring the safe-area inset) so there is no edge/strip
/// below the input; the pill row is inset above the home indicator.
///
/// Each control in the bottom row is independent: tapping it opens its own native
/// `UIMenu` (or, for "+", delegates to the host's image picker) and never resizes
/// the pill itself — only focus/text/attachment state does that. The public API is
/// unchanged from the previous implementation so both hosts (the standalone agent
/// runtime view and the embedded Claude/Codex DM composer) adopt it with no
/// integration changes.
/// One entry in the composer's `/` command palette. `kind` decides routing when the
/// command is run: `.runOption` is applied locally (it configures the next run);
/// every other kind is SENT to the bridge, which executes it for real — bridge info
/// commands (`/usage`, `/status`, `/doctor`, …) return live data, and provider/CLI
/// slash commands pass through to the actual CLI. No more local mock panels.
struct VibeAgentSlashCommand {
  enum Kind { case bridge, runOption, providerSlash, cli }
  let name: String           // no leading slash
  let subtitle: String
  let kind: Kind
  let takesArgs: Bool
  var display: String { "/\(name)" }
}

public final class VibeComposerView: UIView, UITextViewDelegate {
  var onSend: ((String, AgentBridgeRunOptions) -> Void)? {
    didSet { updateSendState() }
  }
  /// Tapped the trailing control while a task is running — the host cancels the live
  /// bridge run (SIGTERM). Distinct from `onSend` so an active turn can never send.
  var onStop: (() -> Void)?
  var onHeightChanged: ((CGFloat) -> Void)?
  /// Picked "Photo Library / Camera" from the tools sheet — the controller presents an
  /// image picker and stages the result via `addAttachment(blob:)`. The composer can't
  /// present, so it delegates up.
  var onAttach: (() -> Void)?
  var onCamera: (() -> Void)?
  var onFile: (() -> Void)?
  /// Tapped "+" (or selected Permission from the tools sheet) — the composer built the
  /// sheet's content but can't present it itself, so it hands the finished
  /// `UIViewController` up for the host to `present(_:animated:)`.
  var onOpenToolsSheet: ((UIViewController) -> Void)?
  /// Agent bridge command shortcuts (`/usage`, `/compact`, ...). These are local
  /// control panels in the agent surface, not chat messages.
  var onCommand: ((String) -> Void)? {
    didSet { updateCommandMenu() }
  }
  /// Encrypted image blobs staged to ride along with the next send.
  private var pendingAttachmentBlobs: [String] = []
  var placeholder: String = "Ask Codex" {
    didSet { placeholderLabel.text = placeholder }
  }
  /// The agent-bridge chat id for this surface — used by the tools sheet's Usage panel
  /// to request a live usage snapshot from the bridge (round-trip, no chat bubble).
  var bridgeChatId: String?
  /// Drives which run options are read at send time (Claude vs Codex ladders).
  var provider: String = "codex" {
    didSet {
      updateCommandMenu()
      // Seed the `/` palette with this provider's full catalog right away so it's
      // complete from the first `/`; a later runtime summary swaps in the real list.
      if provider != oldValue || providerSlashCommands.isEmpty {
        setProviderCommands(slash: [], cli: [])
      }
    }
  }

  // MARK: Subviews — one glass surface that grows in height on focus.
  private let backgroundMaskView = UIView()
  private let backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let backgroundOverlayView = UIView()
  private let backgroundGradientLayer = CAGradientLayer()
  private let pillGlass = UIVisualEffectView(effect: nil)
  private let pillContainer = UIView()
  private let plusButton = UIButton(type: .system)
  private let slashButton = UIButton(type: .system)
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let sendButton = UIButton(type: .system)
  private let micButton = UIButton(type: .system)

  // `/` command list — a native UIMenu on `slashButton` (same pattern as the
  // permission menu on `permissionButton`): it floats above the composer and never
  // resizes it. Replaces an older in-house drop-up table that used to grow the
  // whole pill upward whenever it was opened.
  private var providerSlashCommands: [VibeAgentSlashCommand] = []
  private var providerCliCommands: [VibeAgentSlashCommand] = []

  /// Bridge + run-option commands always offered, independent of what the CLI reports.
  private static let defaultCommands: [VibeAgentSlashCommand] = [
    .init(name: "usage", subtitle: "Subscription limits + this chat's tokens", kind: .bridge, takesArgs: false),
    .init(name: "status", subtitle: "Account, model, and remaining usage", kind: .bridge, takesArgs: false),
    .init(name: "commands", subtitle: "List every available command", kind: .bridge, takesArgs: false),
    .init(name: "skills", subtitle: "Skills, agents, MCP servers, and tools", kind: .bridge, takesArgs: false),
    .init(name: "doctor", subtitle: "Run the CLI health check", kind: .bridge, takesArgs: false),
    .init(name: "compact", subtitle: "Summarize this conversation to free context", kind: .bridge, takesArgs: false),
    .init(name: "model", subtitle: "Show or set the model for this chat", kind: .bridge, takesArgs: true),
    .init(name: "plan", subtitle: "Plan only — analyze without editing", kind: .runOption, takesArgs: false),
    .init(name: "reasoning", subtitle: "Thinking / speed for this chat", kind: .runOption, takesArgs: false),
  ]

  // One-line descriptions so palette rows show what each command does (not "mock").
  // Mirrors the bridge catalogs; unknown/custom commands fall back to a generic label.
  private static let commandDescriptions: [String: String] = [
    "usage": "Subscription limits + this chat's tokens",
    "status": "Account, model, and remaining usage",
    "commands": "List every available command",
    "skills": "Skills, agents, MCP servers, and tools",
    "help": "List every available command",
    "doctor": "Run the CLI health check",
    "compact": "Free up context / drop resume state",
    "model": "Show or set the model",
    "plan": "Plan only — analyze without editing",
    "reasoning": "Thinking / speed for this chat",
    // Claude skills / workflows / built-ins (run as an agent turn)
    "code-review": "Review the diff for bugs and cleanups",
    "simplify": "Cleanup-only review; apply fixes",
    "security-review": "Scan changes for security issues",
    "review": "Review a GitHub pull request",
    "batch": "Split a large change into parallel units",
    "deep-research": "Web research into a cited report",
    "claude-api": "Load Claude API reference",
    "debug": "Troubleshoot via the debug log",
    "run": "Launch and drive your app",
    "verify": "Build, run, and observe a change",
    "loop": "Run a prompt repeatedly",
    "schedule": "Create or run a cloud routine",
    "team-onboarding": "Generate a team onboarding guide",
    "fewer-permission-prompts": "Add a read-only allowlist",
    "init": "Generate a project guide",
    "insights": "Analyze your recent sessions",
    "goal": "Keep working until a goal is met",
    "context": "Show context-window usage",
    "config": "View or set a setting",
    "clear": "Start a fresh conversation",
    "usage-credits": "Configure extra usage credits",
    // Codex-specific
    "approvals": "Set what Codex can do without asking",
    "diff": "Show the working-tree git diff",
    "new": "Start a new conversation",
    "agent": "Switch the active agent thread",
    "apps": "Browse connectors",
    "plugins": "Browse plugins",
    "mcp": "List configured MCP tools",
    "mention": "Attach a file",
    "fork": "Fork into a new thread",
    "resume": "Resume a saved conversation",
    "memories": "Configure memory",
    "fast": "Toggle the Fast tier",
    "personality": "Choose a response style",
    "logout": "Sign out",
    // CLI subcommands
    "exec": "Run non-interactively",
    "apply": "Apply the latest diff to your tree",
    "login": "Sign in",
    "cloud": "Browse Codex Cloud tasks",
    "sandbox": "Run inside the sandbox",
    "update": "Update the CLI",
    "plugin": "Manage plugins",
    "agents": "Manage subagents",
  ]

  // Codex slash commands are TUI-only (`codex exec` can't run them) — flag them so the
  // palette tells the user, and the bridge answers with a "use the desktop app" note.
  private static let codexDesktopOnly: Set<String> = [
    "review", "approvals", "diff", "new", "clear", "init", "skills", "agent", "apps",
    "plugins", "mcp", "mention", "fork", "resume", "memories", "goal", "personality", "logout",
  ]

  // Seed the palette before the first run delivers the CLI's real catalog. Claude's live
  // list (from each run's init event) replaces this once a turn completes.
  private static let claudeFallbackSlash = [
    "code-review", "simplify", "security-review", "review", "batch", "deep-research",
    "claude-api", "debug", "run", "verify", "loop", "schedule", "team-onboarding",
    "fewer-permission-prompts", "init", "insights", "goal", "context", "config", "skills", "clear",
    "usage-credits",
  ]
  private static let codexFallbackSlash = [
    "review", "approvals", "diff", "new", "init", "skills", "agent", "apps", "plugins",
    "mcp", "mention", "fork", "resume", "memories", "goal", "fast", "personality", "logout",
  ]
  private static let claudeFallbackCli = ["agents", "config", "doctor", "mcp", "plugin", "update", "login", "logout"]
  private static let codexFallbackCli = [
    "exec", "review", "login", "logout", "mcp", "plugin", "doctor", "apply", "resume",
    "fork", "cloud", "sandbox", "update",
  ]

  private var appearance: VibeAgentKitChatAppearance = .fallback

  /// True while a bridge task is running for this chat: the trailing control becomes a
  /// STOP button (always visible, regardless of text) that cancels the run instead of
  /// sending. The host drives this from the live message state.
  private var isTaskActive = false
  private(set) var barHeight: CGFloat = 0
  /// Tracks the last-applied value of `isExpanded` / send-visibility so the bottom row
  /// and trailing control only cross-fade when either actually flips, not on every
  /// keystroke.
  private var lastExpandedState = false
  private var lastSendVisible = false
  private var lastKeyboardPaddingProgress: CGFloat = -1
  /// The most recent keyboard show/hide curve, consumed once by the next expand/collapse
  /// so the pill's own morph rides the SAME timeline as the keyboard instead of a
  /// separately-timed spring — a mismatch there was the visible "jump".
  private var pendingKeyboardAnimation: (duration: TimeInterval, options: UIView.AnimationOptions)?

  // On-device speech dictation for the mic button: tap to start, tap to stop, the
  // recognized text fills the composer so you can edit before sending. The agents
  // are text/code CLIs, so dictation (speech → text) is the useful "record voice"
  // here, not an audio attachment they can't consume.
  private let speechRecognizer = SFSpeechRecognizer()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()
  private var isDictating = false
  private var dictationBaseText = ""

  // MARK: Layout constants
  private let sideSize: CGFloat = 46
  private let topVPad: CGFloat = 6
  // Matches ChatInputBar's idle bottom margin (5pt) so the two composers sit at the
  // same height above the safe area.
  private let bottomVPad: CGFloat = 5
  private let minPillH: CGFloat = 46
  private let maxPillH: CGFloat = 160
  private let textInsetH: CGFloat = 12
  private let textInsetV: CGFloat = 11
  private let sendButtonSize: CGFloat = 30
  // The plus/slash/permission row that appears underneath the text once expanded.
  private let bottomRowHeight: CGFloat = 34
  private let bottomIconSize: CGFloat = 32
  private let bottomRowGap: CGFloat = 8
  private var modeObserver: NSObjectProtocol?

  /// Left/right inset from the composer's own bounds — a touch wider than the chat bar
  /// when idle (30pt) and tightening to 10pt while the keyboard is up. The host drives
  /// this because once the composer is moved above the keyboard, intersecting the
  /// keyboard frame with the composer's own bounds reads as zero and the padding never
  /// changes.
  private var keyboardPaddingProgress: CGFloat = 0
  private func currentPagePadding() -> CGFloat {
    30.0 - (20.0 * keyboardPaddingProgress)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    configure()
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    recognitionTask?.cancel()
    if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
  }

  /// Keeps the slash icon's plan-mode accent in sync whether the mode was set via
  /// /plan, the header permission picker, or the tools sheet's Permission row.
  private func refreshModePill() {
    updateSlashAccent()
    updatePlusButtonMenu()
  }

  private func updatePlusButtonMenu() {
    let cameraAction = UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in
      self?.onCamera?()
    }
    let photoAction = UIAction(title: "Photos", image: UIImage(systemName: "photo")) { [weak self] _ in
      self?.onAttach?()
    }
    let fileAction = UIAction(title: "Files", image: UIImage(systemName: "paperclip")) { [weak self] _ in
      self?.onFile?()
    }

    var menuChildren: [UIMenuElement] = [cameraAction, photoAction, fileAction]

    // Repository choices
    let repos = AgentPairingService.lastStatusSnapshot?.repositories ?? []
    let selectedRepo = AgentBridgeSelectionStore.selectedRepository()
    var repoChildren: [UIMenuElement] = repos.map { repo in
      UIAction(
        title: repo.name,
        subtitle: repo.path,
        image: UIImage(systemName: repo.isGitRepository ? "shippingbox" : "folder"),
        state: (repo.id == selectedRepo?.id || repo.cwd == selectedRepo?.cwd) ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.select(repo)
        self?.updatePlusButtonMenu()
      }
    }
    repoChildren.append(
      UIAction(title: "Pick repository…", image: UIImage(systemName: "folder.badge.plus")) { _ in
        NotificationCenter.default.post(name: NSNotification.Name("OpenAgentPanel"), object: nil)
      })
    let repoMenu = UIMenu(title: "Repository", children: repoChildren)
    menuChildren.append(repoMenu)

    // Permission choices
    let currentMode = AgentBridgeSelectionStore.selectedWorkMode()
    let permissionChildren = AgentBridgeWorkMode.allCases.map { mode in
      UIAction(
        title: mode.title,
        subtitle: mode.subtitle,
        image: UIImage(systemName: mode.icon),
        state: mode == currentMode ? .on : .off
      ) { [weak self] _ in
        AgentBridgeSelectionStore.setWorkMode(mode)
        self?.updatePlusButtonMenu()
      }
    }
    let permissionMenu = UIMenu(
      title: "Permission",
      subtitle: currentMode.title,
      image: UIImage(systemName: "hand.raised"),
      children: permissionChildren)
    menuChildren.append(permissionMenu)

    let menu = UIMenu(title: "", children: menuChildren)
    plusButton.menu = menu
    plusButton.showsMenuAsPrimaryAction = true
  }

  /// Total height the host should give this view.
  var preferredHeight: CGFloat {
    topVPad + pillHeightForText() + bottomVPad + safeAreaInsets.bottom
  }

  /// True whenever the composer shows its full two-row layout — text on top, the
  /// plus/slash/permission row underneath — because it's focused or holds a draft.
  /// False collapses back to a single compact line with just the placeholder and
  /// the mic/send control, hiding the three icons entirely.
  private var isExpanded: Bool {
    textView.isFirstResponder
      || !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !pendingAttachmentBlobs.isEmpty
  }

  /// The plus/slash/permission row reserves this much height below the text, but
  /// only while expanded — collapsing drops the reservation instead of leaving a
  /// gap.
  private var bottomRowReserve: CGFloat { bottomRowHeight + bottomRowGap }

  private func pillHeightForText() -> CGFloat {
    guard isExpanded else { return minPillH }
    let measured = measuredTextHeight()
    let minTextH = minPillH - textInsetV * 2
    let maxTextHeight = max(minTextH, maxPillH - textInsetV * 2 - bottomRowReserve)
    let clampedTextH = max(minTextH, min(maxTextHeight, measured))
    return clampedTextH + textInsetV * 2 + bottomRowReserve
  }

  /// Height the text wants for the full-width row it gets — no side reservations,
  /// since the icon row now lives underneath the text instead of squeezed in
  /// beside it (which used to eat into every wrapped line, not just the last one).
  private func measuredTextHeight() -> CGFloat {
    let w = bounds.width > 0 ? bounds.width : (window?.bounds.width ?? UIScreen.main.bounds.width)
    let pillW = max(1, w - currentPagePadding() * 2)
    let textW = max(1, pillW - textInsetH * 2)
    return textView.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height
  }

  // MARK: - Setup

  private func configure() {
    backgroundColor = .clear
    clipsToBounds = false

    // Keep the permission icon in sync with the work mode chosen anywhere (header
    // picker, /plan, etc.).
    modeObserver = NotificationCenter.default.addObserver(
      forName: AgentBridgeSelectionStore.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshModePill()
    }
    // Capture the system's own keyboard timing so the pill's expand/collapse morph can
    // ride the exact same curve instead of a separately-timed spring (see
    // `pendingKeyboardAnimation`).
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleKeyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

    backgroundMaskView.isUserInteractionEnabled = false
    backgroundGradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.92).cgColor,
    ]
    backgroundGradientLayer.locations = [0.1, 1.0]
    backgroundMaskView.layer.mask = backgroundGradientLayer
    addSubview(backgroundMaskView)
    backgroundMaskView.addSubview(backgroundBlurView)
    backgroundBlurView.contentView.addSubview(backgroundOverlayView)

    // One glass pill hosts everything; only its height changes (focus/text driven).
    configureGlass(pillGlass)
    addSubview(pillGlass)
    pillContainer.backgroundColor = .clear
    pillContainer.clipsToBounds = true
    pillContainer.layer.cornerCurve = .continuous
    pillGlass.contentView.addSubview(pillContainer)

    // The same "+" button stays mounted in both states: closed on the leading side of
    // the pill, expanded in the lower tool row. Keeping one view lets the position
    // animate instead of disappearing and reappearing.
    configureIconButton(plusButton, systemName: "plus")
    plusButton.isHidden = false
    plusButton.alpha = 1
    pillContainer.addSubview(plusButton)
    updatePlusButtonMenu()

    configureIconButton(slashButton, systemName: "slash.circle")
    slashButton.showsMenuAsPrimaryAction = true
    slashButton.isHidden = true
    slashButton.alpha = 0
    pillContainer.addSubview(slashButton)
    updateSlashAccent()

    placeholderLabel.text = placeholder
    placeholderLabel.font = UIFont.systemFont(ofSize: 17)
    placeholderLabel.numberOfLines = 1
    placeholderLabel.isUserInteractionEnabled = false
    pillContainer.addSubview(placeholderLabel)

    textView.backgroundColor = .clear
    textView.font = UIFont.systemFont(ofSize: 17)
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.isScrollEnabled = false
    textView.returnKeyType = .default
    textView.delegate = self
    textView.showsVerticalScrollIndicator = false
    pillContainer.addSubview(textView)

    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    sendButton.clipsToBounds = true
    sendButton.alpha = 0
    sendButton.isHidden = true
    pillContainer.addSubview(sendButton)

    configureIconButton(micButton, systemName: "mic")
    micButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 15, weight: .medium), forImageIn: .normal)
    micButton.addTarget(self, action: #selector(handleMic), for: .touchUpInside)
    pillContainer.addSubview(micButton)

    applyAppearance(.fallback)
    updateCommandMenu()
    refreshModePill()
  }

  private func configureGlass(_ view: UIVisualEffectView) {
    view.clipsToBounds = true
    view.isUserInteractionEnabled = true
    let effect = UIGlassEffect()
    effect.isInteractive = true
    view.effect = effect
    view.contentView.backgroundColor = .clear
  }

  private func configureIconButton(_ button: UIButton, systemName: String) {
    button.setImage(
      UIImage(
        systemName: systemName,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .light)),
      for: .normal)
    button.imageView?.contentMode = .scaleAspectFit
    button.backgroundColor = .clear
    button.tintColor = appearance.text.withAlphaComponent(0.6)
  }

  /// Permission is a single icon (no label) that swaps per the active work mode and
  /// opens its own menu — it never grows or resizes the composer. Its color (not just
  /// its glyph) carries the mode so it reads at a glance without needing a text label.
  private static func color(for mode: AgentBridgeWorkMode) -> UIColor {
    switch mode {
    case .plan: return .systemBlue
    case .readOnly: return .systemGreen
    case .ask: return .systemOrange
    case .askAuto: return .systemTeal
    case .allowEdits: return .systemPurple
    case .fullAccess: return .systemRed
    }
  }


  private func buildToolsSheetViewController() -> UIViewController {
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    host.rootView = AnyView(
      VibeAgentToolsSheet(
        appearance: appearance,
        provider: provider,
        chatId: bridgeChatId,
        // Agent surface is always one provider; detail panel still fetches real payload.
        usageProviders: [provider].filter { !$0.isEmpty },
        allCommands: allCommands,
        onAttach: { [weak self] in self?.onAttach?() },
        onCamera: { /* add camera logic later if needed */ },
        onFile: { /* add file logic later if needed */ },
        onSelectCommand: { [weak self] cmd in self?.applyCommandSelection(cmd) },
        onDismiss: { [weak host] in host?.dismiss(animated: true) }
      )
    )

    // Dark mode: the bare system-sheet material renders too light/gray. Back it with a
    // near-black fill so the sheet reads as a proper dark glass surface (matching the
    // Claude tool sheet). Light mode keeps the native light material.
    host.view.backgroundColor = appearance.isDark
      ? UIColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1.0)
      : nil

    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 30
      sheet.prefersScrollingExpandsWhenScrolledToEdge = false
      // Don't let the sheet resize/expand from a scroll-edge drag — keeps the "tab"
      // bounce off; the sheet only moves via the grabber.
      sheet.prefersEdgeAttachedInCompactHeight = false
    }
    
    return host
  }

  /// The slash icon picks up the plan-mode blue too — a persistent cue that plan mode
  /// is engaged, independent of the momentary "Plan mode" toast shown when `/plan` runs.
  private func updateSlashAccent() {
    slashButton.tintColor =
      AgentBridgeSelectionStore.selectedWorkMode() == .plan
      ? .systemBlue
      : appearance.text.withAlphaComponent(0.6)
  }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    backgroundColor = .clear
    textView.textColor = appearance.text
    textView.tintColor = appearance.text
    placeholderLabel.textColor = appearance.textTertiary
    backgroundBlurView.effect = UIBlurEffect(style: appearance.isDark ? .dark : .light)
    backgroundOverlayView.backgroundColor = appearance.background.withAlphaComponent(0.88)
    plusButton.tintColor = appearance.text.withAlphaComponent(0.6)
    updateSlashAccent()
    micButton.tintColor = isDictating ? .systemRed : appearance.text.withAlphaComponent(0.6)
    applySendButtonGlyph()
    updateAttachmentIndicator()
    updateSendState()
    setNeedsLayout()
  }

  // MARK: - Layout

  public override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    guard w > 0 else { return }

    let expanded = isExpanded
    // Single-line height shared by the text view and the placeholder so the placeholder
    // sits on the exact same baseline as typed text (both top-aligned within one line),
    // rather than being vertically centred in a taller box.
    let lineH = ceil(textView.font?.lineHeight ?? 21)
    // While a task is running, STOP must stay reachable even if the composer is
    // collapsed/unfocused — so its collapsed layout reserves room for it too.
    let stopReserve: CGFloat = (!expanded && isTaskActive) ? sendButtonSize + 10 : 0

    let leftEdge = currentPagePadding()
    let rightEdge = w - currentPagePadding()
    let pillW = max(1, rightEdge - leftEdge)
    backgroundMaskView.frame = bounds
    backgroundBlurView.frame = backgroundMaskView.bounds
    backgroundOverlayView.frame = backgroundBlurView.bounds

    // Closed state reserves the same leading "+" footprint as the native composer
    // reference (44pt), then releases that inset on expansion so the text visibly
    // grows into the freed space.
    let collapsedLeadingTextInset = textInsetH + 44.0
    let leadingTextInset = expanded ? textInsetH : collapsedLeadingTextInset
    let textW = max(1, pillW - leadingTextInset - textInsetH)
    let measured = textView.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height
    let minTextH = minPillH - textInsetV * 2
    let maxTextHeight = max(minTextH, maxPillH - textInsetV * 2 - bottomRowReserve)
    let clampedTextH = expanded ? max(minTextH, min(maxTextHeight, measured)) : minTextH
    textView.isScrollEnabled = expanded && measured > maxTextHeight
    let pillH = expanded ? clampedTextH + textInsetV * 2 + bottomRowReserve : minPillH

    let cornerR = min(pillH / 2, 22)
    pillGlass.frame = CGRect(x: leftEdge, y: topVPad, width: pillW, height: pillH)
    pillContainer.frame = pillGlass.bounds
    pillContainer.layer.cornerRadius = cornerR

    let squareBounds = CGRect(origin: .zero, size: CGSize(width: sideSize, height: sideSize))
    let bottomIconBounds = CGRect(origin: .zero, size: CGSize(width: bottomIconSize, height: bottomIconSize))
    let sendSize = CGSize(width: sendButtonSize, height: sendButtonSize)

    if expanded {
      // Row 1: the text spans the full width, top-aligned.
      textView.frame = CGRect(x: leadingTextInset, y: textInsetV, width: textW, height: clampedTextH)
      placeholderLabel.frame = CGRect(x: leadingTextInset, y: textInsetV, width: textW, height: lineH)

      // Row 2: plus / slash on the left (each padded from the edge and
      // from one another), mic + send together on the right — each its own tap
      // target with its own menu; none of them resize the pill.
      let rowCenterY = pillH - bottomRowHeight / 2
      var x = textInsetH
      for button in [plusButton, slashButton] {
        button.bounds = bottomIconBounds
        button.center = CGPoint(x: x + bottomIconSize / 2, y: rowCenterY)
        x += bottomIconSize + bottomRowGap
      }

      // Send sits statically next to mic once expanded — no separate "entrance" morph
      // when text starts/stops being empty, only an enabled/disabled dim (`updateSendState`).
      let sendReserve = sendButtonSize + 6
      micButton.bounds = bottomIconBounds
      micButton.center = CGPoint(x: pillW - textInsetH - bottomIconSize / 2 - sendReserve, y: rowCenterY)

      sendButton.bounds = CGRect(origin: .zero, size: sendSize)
      sendButton.center = CGPoint(x: pillW - textInsetH - sendButtonSize / 2, y: rowCenterY)
    } else {
      // Collapsed: one line — placeholder on the left, mic (+ STOP, if a task is
      // running) on the right, and the "+" visible at the leading side.
      let centerY = pillH / 2
      let textRight = pillW - sideSize - stopReserve
      plusButton.bounds = bottomIconBounds
      plusButton.center = CGPoint(x: textInsetH + bottomIconSize / 2, y: centerY)

      textView.frame = CGRect(
        x: leadingTextInset,
        y: centerY - lineH / 2,
        width: max(1, textRight - leadingTextInset),
        height: lineH
      )
      placeholderLabel.frame = textView.frame

      micButton.bounds = squareBounds
      micButton.center = CGPoint(x: pillW - sideSize / 2 - stopReserve, y: centerY)

      sendButton.bounds = CGRect(origin: .zero, size: sendSize)
      sendButton.center = CGPoint(x: pillW - 8 - sendButtonSize / 2, y: centerY)
    }
    sendButton.layer.cornerRadius = sendButtonSize / 2

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backgroundGradientLayer.frame = backgroundMaskView.bounds
    pillGlass.cornerConfiguration = .uniformCorners(radius: .fixed(cornerR))
    CATransaction.commit()

    barHeight = topVPad + pillH + bottomVPad + safeAreaInsets.bottom

    pillContainer.bringSubviewToFront(sendButton)
    pillContainer.bringSubviewToFront(plusButton)
    pillContainer.bringSubviewToFront(slashButton)
  }

  public override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    onHeightChanged?(preferredHeight)
    setNeedsLayout()
  }

  func setKeyboardPaddingProgress(
    _ progress: CGFloat,
    animation: (duration: TimeInterval, options: UIView.AnimationOptions)? = nil
  ) {
    let clamped = max(0.0, min(1.0, progress))
    guard abs(clamped - keyboardPaddingProgress) > 0.01 else { return }
    if let animation {
      pendingKeyboardAnimation = animation
    }
    keyboardPaddingProgress = clamped
    updateExpansionState(animated: true)
  }

  // MARK: - Send

  /// Refill the composer with an existing message's text for editing — focus it so
  /// the user can revise and resend (used by the hold menu's "Edit").
  func beginEditing(with text: String) {
    textView.text = text
    placeholderLabel.isHidden = !text.isEmpty
    updateSendState(animated: false)
    updateExpansionState(animated: false)
    textView.becomeFirstResponder()
  }

  @objc private func handleSend() {
    // While a task is running the trailing control is a STOP button — cancel the live
    // run and never send. The button reverts to send/mic when the host clears active.
    if isTaskActive {
      onStop?()
      return
    }
    stopDictation()
    let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasAttachments = !pendingAttachmentBlobs.isEmpty
    guard (!text.isEmpty || hasAttachments), onSend != nil else { return }
    if !hasAttachments, let localCommand = localCommandForComposerText(text) {
      textView.text = ""
      placeholderLabel.isHidden = false
      updateSendState(animated: true)
      updateExpansionState(animated: true)
      if localCommand == "/plan" {
        AgentBridgeSelectionStore.setWorkMode(.plan)
      }
      onCommand?(localCommand)
      return
    }
    let body = text.isEmpty && hasAttachments
      ? "Please take a look at the attached image."
      : text
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: provider)
    textView.text = ""
    placeholderLabel.isHidden = false
    updateSendState(animated: true)
    updateExpansionState(animated: true)
    onSend?(body, options)
  }

  /// Host-driven: flip the trailing control between SEND (idle) and STOP (a bridge task
  /// is running). When active the button is forced visible even while collapsed, swaps
  /// to a stop glyph, and `handleSend` routes to `onStop`.
  func setTaskActive(_ active: Bool) {
    guard isTaskActive != active else { return }
    isTaskActive = active
    applySendButtonGlyph()
    updateSendState(animated: true)
    updateExpansionState(animated: true)
  }

  /// The trailing button shows a stop square while a task runs, otherwise a plain send
  /// arrow. Both ride the same filled circle (background dims via `updateSendState`).
  private func applySendButtonGlyph() {
    let systemName = isTaskActive ? "stop.fill" : "arrow.up.circle.fill"
    let weight: UIImage.SymbolWeight = isTaskActive ? .regular : .regular
    sendButton.setImage(
      UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: weight))?
        .withRenderingMode(.alwaysTemplate),
      for: .normal)
    sendButton.tintColor = appearance.text
    sendButton.backgroundColor = .clear
  }

  /// Send no longer has its own "entrance" animation — it sits statically next to mic
  /// whenever the composer is expanded (or a task is active), per `updateExpansionState`.
  /// This only owns the enabled/disabled dim so typing doesn't need a slide-in morph.
  private func updateSendState(animated: Bool = false) {
    let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasAttachments = !pendingAttachmentBlobs.isEmpty
    let canSend = isTaskActive || ((hasText || hasAttachments) && onSend != nil)
    sendButton.isEnabled = canSend
    let apply = { self.sendButton.alpha = canSend ? 1.0 : 0.35 }
    if animated {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    } else {
      apply()
    }
  }

  // MARK: - Image attachments



  /// Build the leading "/" button's native menu (grouped Info / Options / Commands / CLI),
  /// mirroring the "+"/model/repo pickers. Selecting an item inserts args or runs it.
  private func updateSlashMenu() {
    func actions(_ cmds: [VibeAgentSlashCommand]) -> [UIMenuElement] {
      cmds.map { cmd in
        UIAction(title: cmd.display, subtitle: cmd.subtitle, image: UIImage(systemName: paletteIcon(cmd))) {
          [weak self] _ in
          self?.applyCommandSelection(cmd)
        }
      }
    }
    let all = allCommands
    var sections: [UIMenuElement] = []
    let info = all.filter { $0.kind == .bridge }
    let options = all.filter { $0.kind == .runOption }
    let slash = all.filter { $0.kind == .providerSlash }
    let cli = all.filter { $0.kind == .cli }
    if !info.isEmpty { sections.append(UIMenu(title: "Info", options: .displayInline, children: actions(info))) }
    if !options.isEmpty { sections.append(UIMenu(title: "Options", options: .displayInline, children: actions(options))) }
    if !slash.isEmpty { sections.append(UIMenu(title: "Commands", children: actions(slash))) }
    if !cli.isEmpty { sections.append(UIMenu(title: "Terminal", children: actions(cli))) }
    slashButton.menu = UIMenu(title: "Slash commands", children: sections)
  }

  /// Only RUN-OPTION commands are handled locally (they configure the next run). Info
  /// commands (`/usage`, `/status`, `/commands`, `/compact`, `/doctor`, …) now fall
  /// through to `onSend` so the BRIDGE runs them and returns real CLI/account output —
  /// they used to render local mock panels, which is what felt fake.
  private func localCommandForComposerText(_ text: String) -> String? {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.hasPrefix("/") else { return nil }
    let name = normalized.dropFirst().split(separator: " ").first.map(String.init) ?? ""
    switch name {
    case "plan": return "/plan"
    case "reasoning", "thinking": return "/reasoning"
    default: return nil
    }
  }

  // Slash commands are opened by the outside plain "/" button.
  private func updateCommandMenu() {
    updateSlashMenu()
  }

  /// Stage an encrypted image blob to ride along with the next send. The "+" button
  /// reflects how many are queued so the user knows an image is attached.
  func addAttachment(blob: String) {
    pendingAttachmentBlobs.append(blob)
    updateAttachmentIndicator()
    updateSendState(animated: true)
    updateExpansionState(animated: true)
  }

  /// Hand the staged blobs to the caller and clear them (called at send time).
  func consumePendingAttachments() -> [String] {
    let blobs = pendingAttachmentBlobs
    pendingAttachmentBlobs.removeAll()
    updateAttachmentIndicator()
    updateSendState(animated: true)
    updateExpansionState(animated: true)
    return blobs
  }

  private func updateAttachmentIndicator() {
    let count = pendingAttachmentBlobs.count
    plusButton.setImage(
      UIImage(
        systemName: count > 0 ? "photo.badge.plus.fill" : "plus",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)),
      for: .normal)
    plusButton.tintColor = count > 0 ? .systemBlue : appearance.text.withAlphaComponent(0.6)
    plusButton.accessibilityValue = count > 0 ? "\(count) image(s) attached" : nil
  }

  // MARK: - Voice dictation

  @objc private func handleMic() {
    if isDictating {
      stopDictation()
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self, status == .authorized else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard granted else { return }
            self.startDictation()
          }
        }
      }
    }
  }

  private func startDictation() {
    guard let recognizer = speechRecognizer, recognizer.isAvailable, !isDictating else { return }
    recognitionTask?.cancel()
    recognitionTask = nil

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request
    // Preserve anything already typed; append dictated text after it.
    let existing = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    dictationBaseText = existing.isEmpty ? "" : existing + " "

    let inputNode = audioEngine.inputNode
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      // The recognition handler is called on an arbitrary queue; touch UI/audio on main.
      DispatchQueue.main.async {
        guard let self else { return }
        if let result {
          self.textView.text = self.dictationBaseText + result.bestTranscription.formattedString
          self.textViewDidChange(self.textView)
        }
        if error != nil || (result?.isFinal ?? false) {
          self.stopDictation()
        }
      }
    }

    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.recognitionRequest?.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
      isDictating = true
      updateMicAppearance()
    } catch {
      stopDictation()
    }
  }

  private func stopDictation() {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if isDictating {
      isDictating = false
      updateMicAppearance()
    }
  }

  private func updateMicAppearance() {
    micButton.setImage(
      UIImage(
        systemName: isDictating ? "mic.fill" : "mic",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)),
      for: .normal)
    micButton.tintColor = isDictating ? .systemRed : appearance.text.withAlphaComponent(0.6)
  }

  // MARK: - UITextViewDelegate

  public func textViewDidChange(_ textView: UITextView) {
    placeholderLabel.isHidden = !textView.text.isEmpty
    updateSendState(animated: true)
    updateExpansionState(animated: true)
  }

  public func textViewDidBeginEditing(_ textView: UITextView) {
    // Rely on handleKeyboardWillChangeFrame to trigger updateExpansionState(animated: true)
  }

  public func textViewDidEndEditing(_ textView: UITextView) {
    updateExpansionState(animated: true)
  }

  @objc private func handleKeyboardWillChangeFrame(_ note: Notification) {
    let keyboardVisible: Bool
    if let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
      let window
    {
      let endFrameInWindow = window.convert(endFrame, from: nil)
      keyboardVisible = window.bounds.intersects(endFrameInWindow)
        && endFrameInWindow.minY < window.bounds.maxY
    } else {
      keyboardVisible = false
    }
    if let info = note.userInfo,
      let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue,
      duration > 0,
      let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
    {
      pendingKeyboardAnimation = (duration, UIView.AnimationOptions(rawValue: curveRaw << 16))
    }
    setKeyboardPaddingProgress(keyboardVisible ? 1.0 : 0.0)
  }

  /// Cross-fades the plus/slash/permission row (visible while `isExpanded`) and the
  /// trailing send/stop control (visible while expanded OR a task is running), and
  /// resizes the pill to match — all in ONE animation. `onHeightChanged` fires from
  /// INSIDE that animation's closure (not before it starts) so the host's height
  /// constraint and this view's own icon/frame changes share a single Core Animation
  /// transaction; layering a second, differently-timed animation on top of the first
  /// is what caused the visible "jump" between the pill and the keyboard. When the
  /// change is keyboard-driven, `pendingKeyboardAnimation` supplies the exact system
  /// curve so the morph rides the same timeline as the keyboard itself.
  private func updateExpansionState(animated: Bool) {
    let expanded = isExpanded
    let sendVisible = isTaskActive || expanded
    guard
      expanded != lastExpandedState || sendVisible != lastSendVisible
        || abs(keyboardPaddingProgress - lastKeyboardPaddingProgress) > 0.01
    else { return }
    lastExpandedState = expanded
    lastSendVisible = sendVisible
    lastKeyboardPaddingProgress = keyboardPaddingProgress
    plusButton.isHidden = false
    if expanded {
      slashButton.isHidden = false
    }
    if sendVisible {
      sendButton.isHidden = false
    }
    let newHeight = preferredHeight
    let apply = {
      self.onHeightChanged?(newHeight)
      self.plusButton.alpha = 1
      self.slashButton.alpha = expanded ? 1 : 0
      self.sendButton.alpha = sendVisible ? (self.sendButton.isEnabled ? 1 : 0.35) : 0
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
    let finish: (Bool) -> Void = { _ in
      if !expanded {
        self.slashButton.isHidden = true
      }
      if !sendVisible {
        self.sendButton.isHidden = true
      }
    }
    guard animated else {
      apply()
      finish(true)
      return
    }
    if let kb = pendingKeyboardAnimation {
      pendingKeyboardAnimation = nil
      UIView.animate(
        withDuration: kb.duration, delay: 0,
        options: kb.options.union([.beginFromCurrentState, .allowUserInteraction]),
        animations: apply, completion: finish)
    } else {
      UIView.animate(
        withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction], animations: apply, completion: finish)
    }
  }

  // MARK: - `/` commands

  private var allCommands: [VibeAgentSlashCommand] {
    Self.defaultCommands + providerSlashCommands + providerCliCommands
  }

  /// Inject the provider's reported slash + CLI commands (from the latest runtime
  /// metadata) so the palette lists everything the connected CLI exposes, not just the
  /// built-in bridge commands. Deduped against the defaults.
  func setProviderCommands(slash: [String], cli: [String]) {
    func clean(_ raw: String) -> String {
      raw.trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .lowercased()
    }
    let isCodex = provider.lowercased().contains("codex")
    func subtitle(_ n: String, isCli: Bool) -> String {
      var s = Self.commandDescriptions[n] ?? (isCli ? "Terminal subcommand" : "Slash command")
      if isCodex && Self.codexDesktopOnly.contains(n) { s += " · desktop only" }
      return s
    }
    // Fall back to the provider's full catalog until a run delivers the real one, so the
    // palette is complete from the first `/` in a brand-new chat.
    // Grok headless has no Claude slash catalog; reuse the info-command fallback set.
    let slashSource = slash.isEmpty ? (isCodex ? Self.codexFallbackSlash : Self.claudeFallbackSlash) : slash
    let cliSource = cli.isEmpty ? (isCodex ? Self.codexFallbackCli : Self.claudeFallbackCli) : cli
    var seen = Set(Self.defaultCommands.map { $0.name.lowercased() })
    providerSlashCommands = slashSource.compactMap { item in
      let n = clean(item)
      guard !n.isEmpty, !seen.contains(n) else { return nil }
      seen.insert(n)
      return VibeAgentSlashCommand(name: n, subtitle: subtitle(n, isCli: false), kind: .providerSlash, takesArgs: true)
    }
    providerCliCommands = cliSource.compactMap { item in
      let n = clean(item)
      guard !n.isEmpty, !seen.contains(n) else { return nil }
      seen.insert(n)
      return VibeAgentSlashCommand(name: n, subtitle: subtitle(n, isCli: true), kind: .cli, takesArgs: true)
    }
    updateSlashMenu()
  }

  private func applyCommandSelection(_ cmd: VibeAgentSlashCommand) {
    if cmd.takesArgs {
      // Let the user add arguments — insert and keep editing.
      textView.text = cmd.display + " "
      placeholderLabel.isHidden = true
      updateSendState(animated: true)
      updateExpansionState(animated: true)
      textView.becomeFirstResponder()
    } else {
      // No args → run immediately. handleSend() routes run-options locally and every
      // other command to the bridge for real output.
      textView.text = cmd.display
      handleSend()
    }
  }

  private func paletteIcon(_ cmd: VibeAgentSlashCommand) -> String {
    switch cmd.name {
    case "usage": return "gauge.with.dots.needle.bottom.50percent"
    case "status": return "info.circle"
    case "commands": return "terminal"
    case "doctor": return "stethoscope"
    case "compact": return "rectangle.compress.vertical"
    case "model": return "cpu"
    case "plan": return "checklist"
    case "reasoning": return "brain"
    case "review", "security-review": return "magnifyingglass"
    case "init": return "doc.badge.plus"
    case "context": return "doc.text.magnifyingglass"
    case "mcp": return "server.rack"
    default: return cmd.kind == .cli ? "terminal" : "slash.circle"
    }
  }
}

// MARK: - Composer "+" tools sheet

/// Consolidated bottom sheet for the composer's "+" button, styled after the reference
/// "Add to Chat" sheet: a circular close button + centered title, an optional row of big
/// attachment cards, then grouped rounded sections whose rows carry a leading icon, a
/// title (+ optional subtitle) and a trailing accessory (chevron / value+chevron /
/// checkmark / switch). Reused for the top-level tools list, the resolo-style
/// "Chat Settings" model+thinking picker, and the Permission drill-down.
///
/// Two selection behaviours: a normal row dismisses the sheet then fires its action (so it
/// can hand a second sheet back up through `onOpenToolsSheet` without a presentation
/// conflict); a `keepsOpen` row runs its action and refreshes the sheet in place so its
/// checkmark updates immediately (model / thinking / permission selection).
final class VibeAgentComposerToolsSheet: UIViewController {
  struct Card {
    let title: String
    let systemImage: String
    let action: () -> Void
  }

  enum Trailing {
    case none
    case chevron
    case checkmark
    case value(String)
    case valueChevron(String)
    case toggle(Bool, (Bool) -> Void)
  }

  struct Row {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let tint: UIColor?
    let trailing: Trailing
    /// When true, tapping runs the action and rebuilds the sheet in place (updating this
    /// row's checkmark) instead of dismissing.
    let keepsOpen: Bool
    let action: (() -> Void)?

    init(
      title: String, subtitle: String? = nil, systemImage: String? = nil, tint: UIColor? = nil,
      trailing: Trailing = .chevron, keepsOpen: Bool = false, action: (() -> Void)? = nil
    ) {
      self.title = title
      self.subtitle = subtitle
      self.systemImage = systemImage
      self.tint = tint
      self.trailing = trailing
      self.keepsOpen = keepsOpen
      self.action = action
    }
  }

  struct Section {
    let title: String?
    let rows: [Row]
  }

  private let appearance: VibeAgentKitChatAppearance
  private let sheetTitle: String
  private let detents: [UISheetPresentationController.Detent]
  private let cards: [Card]
  private let sectionsProvider: () -> [Section]

  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()

  init(
    appearance: VibeAgentKitChatAppearance, title: String,
    detents: [UISheetPresentationController.Detent], cards: [Card] = [],
    sectionsProvider: @escaping () -> [Section]
  ) {
    self.appearance = appearance
    self.sheetTitle = title
    self.detents = detents
    self.cards = cards
    self.sectionsProvider = sectionsProvider
    super.init(nibName: nil, bundle: nil)
  }

  /// Convenience for a fixed set of sections.
  convenience init(
    appearance: VibeAgentKitChatAppearance, title: String,
    detents: [UISheetPresentationController.Detent], cards: [Card] = [], sections: [Section]
  ) {
    self.init(
      appearance: appearance, title: title, detents: detents, cards: cards,
      sectionsProvider: { sections })
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = appearance.background

    let header = UIView()
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)

    let closeButton = UIButton(type: .system)
    closeButton.setImage(
      UIImage(
        systemName: "xmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)),
      for: .normal)
    closeButton.tintColor = appearance.text.withAlphaComponent(0.85)
    closeButton.backgroundColor = appearance.surface
    closeButton.layer.cornerRadius = 17
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    header.addSubview(closeButton)

    let titleLabel = UILabel()
    titleLabel.text = sheetTitle
    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.textColor = appearance.text
    titleLabel.textAlignment = .center
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(titleLabel)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)

    contentStack.axis = .vertical
    contentStack.spacing = 22
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentStack)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
      header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 40),

      closeButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
      closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 34),
      closeButton.heightAnchor.constraint(equalToConstant: 34),

      titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
      titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),

      scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
      contentStack.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
      contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
      contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
      contentStack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -36),
    ])

    if let sheet = sheetPresentationController {
      sheet.detents = detents
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 30
      sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    }

    rebuild()
  }

  @objc private func handleClose() { dismiss(animated: true) }

  private func rebuild() {
    contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if !cards.isEmpty {
      contentStack.addArrangedSubview(makeCardRow(cards))
    }
    for section in sectionsProvider() {
      contentStack.addArrangedSubview(makeSectionView(section))
    }
  }

  private func makeCardRow(_ cards: [Card]) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.spacing = 10
    for card in cards {
      let cardView = VibeToolsSheetCardView(card: card, appearance: appearance)
      cardView.onTap = { [weak self] in self?.dismiss(animated: true) { card.action() } }
      row.addArrangedSubview(cardView)
    }
    return row
  }

  private func makeSectionView(_ section: Section) -> UIView {
    let wrapper = UIStackView()
    wrapper.axis = .vertical
    wrapper.spacing = 8

    if let title = section.title, !title.isEmpty {
      let label = UILabel()
      label.text = title.uppercased()
      label.font = .systemFont(ofSize: 12, weight: .semibold)
      label.textColor = appearance.textSecondary.withAlphaComponent(0.7)
      label.translatesAutoresizingMaskIntoConstraints = false
      let inset = UIView()
      inset.addSubview(label)
      NSLayoutConstraint.activate([
        label.topAnchor.constraint(equalTo: inset.topAnchor),
        label.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
        label.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 6),
        label.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
      ])
      wrapper.addArrangedSubview(inset)
    }

    let card = UIView()
    card.backgroundColor = appearance.surface
    card.layer.cornerRadius = 16
    card.clipsToBounds = true

    let rowsStack = UIStackView()
    rowsStack.axis = .vertical
    rowsStack.spacing = 0
    rowsStack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(rowsStack)
    NSLayoutConstraint.activate([
      rowsStack.topAnchor.constraint(equalTo: card.topAnchor),
      rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])

    for (index, row) in section.rows.enumerated() {
      let rowView = VibeToolsSheetRowView(row: row, appearance: appearance)
      rowView.onTap = { [weak self] in self?.handleRowTap(row) }
      rowsStack.addArrangedSubview(rowView)
      if index < section.rows.count - 1 {
        rowsStack.addArrangedSubview(makeSeparator())
      }
    }

    wrapper.addArrangedSubview(card)
    return wrapper
  }

  private func makeSeparator() -> UIView {
    let sep = UIView()
    sep.backgroundColor = appearance.border.withAlphaComponent(0.5)
    sep.translatesAutoresizingMaskIntoConstraints = false
    let wrap = UIView()
    wrap.addSubview(sep)
    NSLayoutConstraint.activate([
      sep.topAnchor.constraint(equalTo: wrap.topAnchor),
      sep.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
      sep.heightAnchor.constraint(equalToConstant: 0.5),
      sep.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
      sep.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
    ])
    return wrap
  }

  private func handleRowTap(_ row: Row) {
    if case .toggle = row.trailing { return }  // driven by the switch
    if row.keepsOpen {
      row.action?()
      rebuild()
    } else {
      dismiss(animated: true) { row.action?() }
    }
  }
}

/// One tappable list row inside `VibeAgentComposerToolsSheet`: leading icon, title (+
/// optional subtitle), and a right-aligned accessory. A `UIControl` so it highlights on
/// touch; a toggle's `UISwitch` sits outside the (non-interactive) content stack so it
/// captures its own touches while the rest of the row still fires `onTap`.
private final class VibeToolsSheetRowView: UIControl {
  var onTap: (() -> Void)?
  private let highlightBg: UIColor

  init(row: VibeAgentComposerToolsSheet.Row, appearance: VibeAgentKitChatAppearance) {
    highlightBg = appearance.text.withAlphaComponent(appearance.isDark ? 0.08 : 0.06)
    super.init(frame: .zero)
    heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

    let hstack = UIStackView()
    hstack.axis = .horizontal
    hstack.alignment = .center
    hstack.spacing = 12
    hstack.isUserInteractionEnabled = false
    hstack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hstack)

    if let systemImage = row.systemImage {
      let icon = UIImageView(
        image: UIImage(
          systemName: systemImage,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)))
      icon.tintColor = row.tint ?? appearance.text.withAlphaComponent(0.85)
      icon.contentMode = .scaleAspectFit
      icon.setContentHuggingPriority(.required, for: .horizontal)
      icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
      hstack.addArrangedSubview(icon)
    }

    let textStack = UIStackView()
    textStack.axis = .vertical
    textStack.spacing = 2
    let titleLabel = UILabel()
    titleLabel.text = row.title
    titleLabel.font = .systemFont(ofSize: 16)
    titleLabel.textColor = appearance.text
    titleLabel.numberOfLines = 1
    textStack.addArrangedSubview(titleLabel)
    if let subtitle = row.subtitle, !subtitle.isEmpty {
      let sub = UILabel()
      sub.text = subtitle
      sub.font = .systemFont(ofSize: 12.5)
      sub.textColor = appearance.textSecondary
      sub.numberOfLines = 1
      textStack.addArrangedSubview(sub)
    }
    hstack.addArrangedSubview(textStack)

    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    hstack.addArrangedSubview(spacer)

    var isToggle = false
    var switchControl: UISwitch?
    switch row.trailing {
    case .none:
      break
    case .chevron:
      hstack.addArrangedSubview(Self.makeChevron(appearance))
    case .checkmark:
      let check = UIImageView(
        image: UIImage(
          systemName: "checkmark",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
      check.tintColor = appearance.primary
      check.setContentHuggingPriority(.required, for: .horizontal)
      hstack.addArrangedSubview(check)
    case .value(let text):
      hstack.addArrangedSubview(Self.makeValueLabel(text, appearance))
    case .valueChevron(let text):
      hstack.addArrangedSubview(Self.makeValueLabel(text, appearance))
      hstack.addArrangedSubview(Self.makeChevron(appearance))
    case .toggle(let isOn, let onChange):
      isToggle = true
      let toggle = UISwitch()
      toggle.isOn = isOn
      toggle.onTintColor = appearance.primary
      toggle.addAction(UIAction { _ in onChange(toggle.isOn) }, for: .valueChanged)
      switchControl = toggle
    }

    let trailingInset: CGFloat
    if let toggle = switchControl {
      toggle.translatesAutoresizingMaskIntoConstraints = false
      addSubview(toggle)
      NSLayoutConstraint.activate([
        toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
      trailingInset = 62
    } else {
      trailingInset = 16
    }

    NSLayoutConstraint.activate([
      hstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      hstack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
      hstack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
      hstack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
    ])

    if !isToggle {
      addTarget(self, action: #selector(fire), for: .touchUpInside)
    }
  }

  required init?(coder: NSCoder) { return nil }

  override var isHighlighted: Bool {
    didSet { backgroundColor = isHighlighted ? highlightBg : .clear }
  }

  @objc private func fire() { onTap?() }

  private static func makeChevron(_ appearance: VibeAgentKitChatAppearance) -> UIImageView {
    let chevron = UIImageView(
      image: UIImage(
        systemName: "chevron.right",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    chevron.tintColor = appearance.textTertiary
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    return chevron
  }

  private static func makeValueLabel(_ text: String, _ appearance: VibeAgentKitChatAppearance)
    -> UILabel
  {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 15)
    label.textColor = appearance.textSecondary
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
  }
}

/// One big attachment card at the top of the tools sheet (icon over label), matching the
/// reference "Add to Chat" card row.
private final class VibeToolsSheetCardView: UIControl {
  var onTap: (() -> Void)?
  private let highlightBg: UIColor
  private let normalBg: UIColor

  init(card: VibeAgentComposerToolsSheet.Card, appearance: VibeAgentKitChatAppearance) {
    normalBg = appearance.surface
    highlightBg = appearance.surfaceElevated
    super.init(frame: .zero)
    backgroundColor = normalBg
    layer.cornerRadius = 16
    heightAnchor.constraint(equalToConstant: 92).isActive = true

    let icon = UIImageView(
      image: UIImage(
        systemName: card.systemImage,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)))
    icon.tintColor = appearance.text.withAlphaComponent(0.9)
    icon.contentMode = .scaleAspectFit

    let label = UILabel()
    label.text = card.title
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.textColor = appearance.text

    let stack = UIStackView(arrangedSubviews: [icon, label])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 10
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    addTarget(self, action: #selector(fire), for: .touchUpInside)
  }

  required init?(coder: NSCoder) { return nil }

  override var isHighlighted: Bool {
    didSet { backgroundColor = isHighlighted ? highlightBg : normalBg }
  }

  @objc private func fire() { onTap?() }
}

// MARK: - Read-only subagent detail (Claude Task tool)

/// Clean vertical activity timeline for a turn/subagent's progress items — a filled
/// dot + connecting line per step, a bold label, and at most one muted detail line
/// with NO status word ("Completed"/"Started"). Modeled on resolo.ai's
/// ChatActivityStepRow/ChatAgentActivitySheet ("GPT-style" activity log): plain and
/// scannable, in contrast to the denser interleaved step/narration feed renderer
/// (VibeAgentKitAssistantMessageBodyView) used in the live bubble/full-page view.
/// Read-only list; rows with raw command/patch/file detail stay tappable via
/// `onToggleExpand`, forwarded by nodeId to the same expand-state the host already
/// tracks, so the interaction contract is unchanged — only the collapsed look is new.
final class VibeAgentActivityTimelineView: UIView {
  var onToggleExpand: ((String) -> Void)?

  private let stack = UIStackView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { return nil }

  func configure(
    items: [VibeAgentKitProgressItem],
    expandedStepIds: Set<String>,
    appearance: VibeAgentKitChatAppearance
  ) {
    stack.arrangedSubviews.forEach {
      stack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    for (index, item) in items.enumerated() {
      let row = VibeAgentActivityStepRowView(appearance: appearance)
      let isExpanded = item.nodeId.map { expandedStepIds.contains($0) } ?? false
      row.configure(item: item, isLast: index == items.count - 1, isExpanded: isExpanded)
      row.onTap = { [weak self] in
        guard let nodeId = item.nodeId else { return }
        self?.onToggleExpand?(nodeId)
      }
      stack.addArrangedSubview(row)
    }
  }
}

/// One timeline row: dot+line gutter on the left, bold label + optional muted detail
/// line on the right. The connecting line is pinned to the ROW's padded bottom (not
/// just the text content's bottom), so it visually runs through the inter-row gap
/// into the next dot exactly like the reference's SwiftUI `.frame(maxHeight: .infinity)`
/// trick. When the item carries `command`/`patch`/`fileContent`, the row is tappable
/// and reveals that raw text in a monospaced block underneath.
private final class VibeAgentActivityStepRowView: UIView {
  var onTap: (() -> Void)?

  private let appearance: VibeAgentKitChatAppearance
  private let dot = UIView()
  private let line = UIView()
  private let gutter = UIView()
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()
  private let chevron = UIImageView()
  private let expandedTextView = UITextView()
  private let textStack = UIStackView()

  private var isExpandable = false
  private var bottomConstraint: NSLayoutConstraint!

  init(appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    super.init(frame: .zero)
    setUp()
  }

  required init?(coder: NSCoder) { return nil }

  private func setUp() {
    dot.backgroundColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.82)
    dot.layer.cornerRadius = 4.0
    dot.translatesAutoresizingMaskIntoConstraints = false

    line.backgroundColor = vibeAgentKitColorWithAlpha(
      appearance.border, appearance.isDark ? 0.55 : 0.7)
    line.translatesAutoresizingMaskIntoConstraints = false

    gutter.translatesAutoresizingMaskIntoConstraints = false
    gutter.addSubview(line)
    gutter.addSubview(dot)

    titleLabel.font = UIFont.systemFont(ofSize: 15.5, weight: .semibold)
    titleLabel.textColor = appearance.text
    titleLabel.numberOfLines = 0

    detailLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .regular)
    detailLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.78)
    detailLabel.numberOfLines = 0

    chevron.image = UIImage(systemName: "chevron.down")
    chevron.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.55)
    chevron.contentMode = .scaleAspectFit
    chevron.setContentHuggingPriority(.required, for: .horizontal)

    let titleRow = UIStackView(arrangedSubviews: [titleLabel, chevron])
    titleRow.axis = .horizontal
    titleRow.alignment = .top
    titleRow.spacing = 6.0

    expandedTextView.isEditable = false
    expandedTextView.isSelectable = true
    expandedTextView.isScrollEnabled = false
    expandedTextView.backgroundColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.08)
    expandedTextView.font = UIFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
    expandedTextView.textColor = appearance.text
    expandedTextView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    expandedTextView.textContainer.lineFragmentPadding = 0
    expandedTextView.layer.cornerRadius = 8.0
    expandedTextView.clipsToBounds = true
    expandedTextView.isHidden = true

    textStack.axis = .vertical
    textStack.spacing = 3.0
    textStack.addArrangedSubview(titleRow)
    textStack.addArrangedSubview(detailLabel)
    textStack.addArrangedSubview(expandedTextView)
    textStack.setCustomSpacing(8.0, after: detailLabel)
    textStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(gutter)
    addSubview(textStack)

    // `self` is taller than `textStack` by the row's bottom padding (18pt, 0 for the
    // last row) so the gutter — pinned to `self`'s full height below — stretches the
    // connecting line through that gap into the next row's dot.
    bottomConstraint = bottomAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 18.0)

    NSLayoutConstraint.activate([
      gutter.topAnchor.constraint(equalTo: topAnchor),
      gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
      gutter.widthAnchor.constraint(equalToConstant: 8.0),
      gutter.bottomAnchor.constraint(equalTo: bottomAnchor),

      dot.topAnchor.constraint(equalTo: gutter.topAnchor, constant: 5.0),
      dot.leadingAnchor.constraint(equalTo: gutter.leadingAnchor),
      dot.widthAnchor.constraint(equalToConstant: 8.0),
      dot.heightAnchor.constraint(equalToConstant: 8.0),

      line.topAnchor.constraint(equalTo: dot.bottomAnchor),
      line.bottomAnchor.constraint(equalTo: gutter.bottomAnchor),
      line.centerXAnchor.constraint(equalTo: gutter.centerXAnchor),
      line.widthAnchor.constraint(equalToConstant: 1.5),

      textStack.topAnchor.constraint(equalTo: topAnchor),
      textStack.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 12.0),
      textStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomConstraint,
    ])

    isUserInteractionEnabled = true
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
  }

  @objc private func handleTap() {
    guard isExpandable else { return }
    onTap?()
  }

  /// Single best "what happened" line — narrative first, then the richer node-detail
  /// fields Vibe adds for tool steps (Resolo has no equivalent; those fields don't
  /// exist there), then platform as a last resort. Deliberately ONE line, not a join:
  /// the narrative usually already names the file/command, so concatenating both
  /// tends to repeat itself rather than add information. `command` is deliberately
  /// NOT a candidate here — it lives only in the expandable block below, so a
  /// command-only step (no narrative/fileName) doesn't show it twice.
  private static func detailText(for item: VibeAgentKitProgressItem) -> String? {
    let normalizedLabel = item.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let narrative = (item.messageContent ?? item.messagePreview)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let narrative, !narrative.isEmpty, narrative.lowercased() != normalizedLabel {
      return narrative
    }
    if let fileName = item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !fileName.isEmpty
    {
      return fileName
    }
    if let platform = item.platform?.trimmingCharacters(in: .whitespacesAndNewlines),
      !platform.isEmpty
    {
      return platform.capitalized
    }
    return nil
  }

  private static func expandedText(for item: VibeAgentKitProgressItem) -> String? {
    let candidate = item.patch ?? item.fileContent ?? item.command
    guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    return text
  }

  func configure(item: VibeAgentKitProgressItem, isLast: Bool, isExpanded: Bool) {
    titleLabel.text = item.label
    let detail = Self.detailText(for: item)
    detailLabel.text = detail
    detailLabel.isHidden = detail == nil

    line.isHidden = isLast

    let expandable = item.nodeId != nil ? Self.expandedText(for: item) : nil
    isExpandable = expandable != nil
    chevron.isHidden = !isExpandable
    chevron.transform = isExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity
    expandedTextView.text = expandable
    expandedTextView.isHidden = !(isExpandable && isExpanded)

    bottomConstraint.constant = isLast ? 0.0 : 18.0
  }
}

/// A read-only view of one subagent's steps — no composer, no send, just the live
/// Read/Edit/Run feed. Opened from the "Subagent" feed row or its start toast;
/// the host VC calls `update(children:running:)` each transcript tick so it streams.
final class VibeAgentSubagentDetailViewController: UIViewController {
  var onClose: (() -> Void)?

  private let appearance: VibeAgentKitChatAppearance
  private let subagentType: String
  private let titleOverride: String?
  private let bodyText: String
  private var progressItems: [VibeAgentKitProgressItem]
  private var running: Bool

  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let emptyLabel = UILabel()
  private let scrollView = UIScrollView()
  // Renders ONLY the turn's final response text now (progressItems: [] is always passed
  // to it below) — the step feed itself renders via activityTimelineView instead, so the
  // shared renderer's markdown/diff handling stays available for the "Worked for…" case
  // (real bodyText) without duplicating the step list it also knows how to draw.
  private let turnContentView = VibeAgentTurnContentView()
  // Clean vertical timeline (dot + line, bold label, single muted detail line) for the
  // step list itself — see VibeAgentActivityTimelineView above.
  private let activityTimelineView = VibeAgentActivityTimelineView()
  private let activityHeaderLabel = UILabel()
  private let responseHeaderLabel = UILabel()
  private let contentStack = UIStackView()
  private var expandedStepIds: Set<String> = []
  private var lastConfiguredWidth: CGFloat = 0.0

  init(
    subagentType: String,
    titleOverride: String? = nil,
    bodyText: String = "",
    progressItems: [VibeAgentKitProgressItem],
    running: Bool,
    appearance: VibeAgentKitChatAppearance
  ) {
    self.subagentType = subagentType
    self.titleOverride = titleOverride
    self.bodyText = bodyText
    self.progressItems = progressItems
    self.running = running
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Glass sheet body (mirrors VibeAgentAskSheetViewController / the chat share sheet)
    // instead of the solid warm agent background — native material, blurs the chat behind it.
    view.backgroundColor = .clear

    configureNavigationBar()

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)

    activityHeaderLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    activityHeaderLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.65)
    activityHeaderLabel.text = "ACTIVITY"

    responseHeaderLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .semibold)
    responseHeaderLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.65)
    responseHeaderLabel.text = "RESPONSE"

    // Tapping a step in the sheet expands/collapses its detail inline; the expand set
    // lives here (shared with configureTurnContent's expandedStepIds, though that path
    // no longer renders steps itself) and drives a re-configure of the timeline only.
    activityTimelineView.onToggleExpand = { [weak self] nodeId in
      guard let self else { return }
      if self.expandedStepIds.contains(nodeId) {
        self.expandedStepIds.remove(nodeId)
      } else {
        self.expandedStepIds.insert(nodeId)
      }
      UIView.animate(withDuration: 0.22) {
        self.refreshActivityTimeline()
        self.view.layoutIfNeeded()
      }
    }

    turnContentView.translatesAutoresizingMaskIntoConstraints = false

    contentStack.axis = .vertical
    contentStack.spacing = 20.0
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.addArrangedSubview(activityHeaderLabel)
    contentStack.addArrangedSubview(activityTimelineView)
    contentStack.addArrangedSubview(responseHeaderLabel)
    contentStack.addArrangedSubview(turnContentView)
    contentStack.setCustomSpacing(10.0, after: activityHeaderLabel)
    contentStack.setCustomSpacing(10.0, after: responseHeaderLabel)
    scrollView.addSubview(contentStack)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
    emptyLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)
    emptyLabel.numberOfLines = 0
    emptyLabel.textAlignment = .center
    emptyLabel.text = "Waiting for the subagent's first step…"
    view.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentStack.topAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14.0),
      contentStack.leadingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18.0),
      contentStack.trailingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18.0),
      contentStack.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24.0),

      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32.0),
      emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32.0),
    ])

    rebuild()
  }

  /// Real `UINavigationBar` header instead of a hand-rolled view. `UIGlassEffect` is meant
  /// for bars/controls, not arbitrary full-screen views — a homemade header view can only
  /// ever fake a blur, never the real Liquid Glass chrome the OS gives an actual nav bar for
  /// free on iOS 26+. Matches the nav-stack-sheet idiom already used elsewhere in the app
  /// (ChatAgentConfigViewController, AgentRuntimeTaskViewController, ChatListTextPreviewController).
  /// Caller MUST present this VC wrapped in a `UINavigationController` for a bar to exist.
  private func configureNavigationBar() {
    let flavor = subagentType.trimmingCharacters(in: .whitespacesAndNewlines)
    if let titleOverride, !titleOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      titleLabel.text = titleOverride
    } else {
      titleLabel.text = flavor.isEmpty ? "Subagent" : "Subagent · \(flavor)"
    }
    titleLabel.font = UIFont.systemFont(ofSize: 16.0, weight: .semibold)
    titleLabel.textColor = appearance.text
    titleLabel.textAlignment = .center

    subtitleLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
    subtitleLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.85)
    subtitleLabel.textAlignment = .center

    spinner.hidesWhenStopped = true
    spinner.color = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.85)

    let subtitleRow = UIStackView(arrangedSubviews: [subtitleLabel, spinner])
    subtitleRow.axis = .horizontal
    subtitleRow.alignment = .center
    subtitleRow.spacing = 6.0

    let titleStack = UIStackView(arrangedSubviews: [titleLabel, subtitleRow])
    titleStack.axis = .vertical
    titleStack.alignment = .center
    titleStack.spacing = 1.0
    navigationItem.titleView = titleStack

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close, target: self, action: #selector(handleClose))
    navigationItem.rightBarButtonItem?.tintColor = appearance.text

    let navBarAppearance = UINavigationBarAppearance()
    navBarAppearance.configureWithTransparentBackground()
    navigationController?.navigationBar.standardAppearance = navBarAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navBarAppearance
    navigationController?.navigationBar.compactAppearance = navBarAppearance
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // `isBeingDismissed` only flips true on the exact view controller instance passed to
    // `present(...)`. This VC is now always the ROOT of a presented UINavigationController
    // (required for the real nav-bar header above), so the flag that actually flips when the
    // sheet is dismissed lives on `navigationController`, not on `self`.
    let dismissed = isBeingDismissed || (navigationController?.isBeingDismissed ?? false)
    if dismissed || isMovingFromParent { onClose?() }
  }

  func update(progressItems: [VibeAgentKitProgressItem], running: Bool) {
    self.progressItems = progressItems
    self.running = running
    if isViewLoaded { rebuild() }
  }

  /// Progress items actually worth a timeline row: narration/diff-card `"text"` blocks
  /// belong to the response renderer, not the step list, and a bare "Thinking" row with
  /// no real detail is noise (real thinking narration, i.e. one with messageContent/
  /// messagePreview, is kept) — same two filters resolo.ai's ChatAgentActivitySheet
  /// applies before handing items to its own timeline row.
  private var activityItems: [VibeAgentKitProgressItem] {
    progressItems.filter { $0.itemType != "text" && !isPlaceholderThinking($0) }
  }

  private func isPlaceholderThinking(_ item: VibeAgentKitProgressItem) -> Bool {
    let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let messageContent = item.messageContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let messagePreview = item.messagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hasDetail = !messageContent.isEmpty || !messagePreview.isEmpty
    return !hasDetail && (label == "thinking" || label == "thinking...")
  }

  private func refreshActivityTimeline() {
    let items = activityItems
    activityHeaderLabel.isHidden = items.isEmpty
    activityTimelineView.isHidden = items.isEmpty
    activityTimelineView.configure(
      items: items, expandedStepIds: expandedStepIds, appearance: appearance)
  }

  private func rebuild() {
    let items = activityItems
    let hasBody = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasContent = !items.isEmpty || hasBody
    emptyLabel.isHidden = hasContent
    responseHeaderLabel.isHidden = !hasBody
    turnContentView.isHidden = !hasBody
    subtitleLabel.text = running
      ? "Running · \(items.count) \(items.count == 1 ? "step" : "steps")"
      : "\(items.count) \(items.count == 1 ? "step" : "steps")"
    if running { spinner.startAnimating() } else { spinner.stopAnimating() }
    refreshActivityTimeline()
    if hasBody, lastConfiguredWidth > 0.0 { configureTurnContent(width: lastConfiguredWidth) }
  }

  /// Feed the shared renderer this turn's final response text ONLY — `progressItems: []`
  /// keeps it from also drawing the step feed, which now lives in activityTimelineView.
  private func configureTurnContent(width: CGFloat) {
    guard width > 0.0 else { return }
    let hasBody = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    turnContentView.configure(
      text: bodyText,
      isStreaming: running,
      hasFinalResponseText: hasBody,
      appearance: VibeAgentKitMap.appearance(for: traitCollection),
      availableWidth: width,
      messageId: "agent-detail-sheet",
      progressItems: [],
      fallbackProgressLabels: [],
      runtime: nil,
      onLoaderTap: nil,
      isProgressExpanded: true,
      isRuntimeExpanded: false,
      expandedStepIds: expandedStepIds,
      streamingStartDate: nil
    )
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The shared renderer bakes text-wrap heights at the width we pass, so re-feed it
    // whenever the sheet's usable width changes (rotation / detent). 36 = the 18pt
    // leading + trailing insets applied to turnContentView.
    let width = floor(scrollView.bounds.width - 36.0)
    guard width > 0.0, abs(width - lastConfiguredWidth) > 0.5 else { return }
    lastConfiguredWidth = width
    configureTurnContent(width: width)
  }

}

// MARK: - Ask / plan-approval sheet

/// The phone's approver surface for a bridge `ask_request`. Two kinds:
///   • `plan` — shows the proposed plan + Reject / Approve & Implement (with an
///     optional notes field). Approving re-runs the turn with edits enabled.
///   • `ask`  — renders the agent's `questions[]` (the AskUserQuestion shape:
///     header chip, single/multi-select options, an "Other" field) → Submit.
/// Resolves exactly once via `onResolve(decision, answer)` then dismisses.
final class VibeAgentAskSheetViewController: UIViewController {
  /// (decision, answer). decision ∈ "approve" | "reject" | "answer".
  var onResolve: ((String, [String: Any]?) -> Void)?
  /// Fired when the sheet is dismissed WITHOUT a decision (user swiped it away). Lets
  /// the presenter release its presentation claim so a still-pending ask re-shows when
  /// the chat is reopened (the bridge re-emits it on history open).
  var onDismissWithoutResolve: (() -> Void)?

  private let kind: String
  private let request: [String: Any]
  private let appearance: VibeAgentKitChatAppearance
  private let requestId: String
  private var didResolve = false
  private var isCommandExpanded = false
  private var commandHeightConstraint: NSLayoutConstraint?

  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let feedbackField = UITextField()

  // ask-mode question state, parallel to `questions`.
  private struct AskQuestion {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [String]
  }
  private var questions: [AskQuestion] = []
  private var selected: [Set<Int>] = []
  private var otherFields: [UITextField] = []
  private var optionButtonsByQuestion: [[UIButton]] = []

  // Multi-question asks are paginated one-per-page (Question 1 of N). Blocks are
  // built once so selections/Other text persist as the user pages back and forth.
  private var questionBlocks: [UIView] = []
  private var askPageIndex = 0
  private let pageIndicator = UILabel()
  private weak var askBackButton: UIButton?
  private weak var askNextButton: UIButton?

  init(
    kind: String, request: [String: Any], appearance: VibeAgentKitChatAppearance,
    requestId: String = ""
  ) {
    self.kind = kind
    self.request = request
    self.appearance = appearance
    self.requestId = requestId
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  /// The bridge cancelled this ask/command (resolved at the desk, or timed out). Close
  /// the sheet without re-arming it — the request no longer exists.
  @objc private func handleBridgeAskCancel(_ note: Notification) {
    guard (note.userInfo?["reason"] as? String) == "agentBridgeAskCancel" else { return }
    let cancelledId = (note.userInfo?["requestId"] as? String) ?? ""
    guard !cancelledId.isEmpty, cancelledId == requestId, !didResolve else { return }
    didResolve = true  // suppress the swiped-away re-arm path in viewDidDisappear
    if presentingViewController != nil { dismiss(animated: true) }
  }

  @objc private func handleCloseTapped() {
    onDismissWithoutResolve?()
    dismiss(animated: true)
  }

  // Off-mute neutral palette (no brand brown/orange) for the glass sheet.
  private var neutralAccent: UIColor {
    appearance.isDark ? UIColor(white: 0.95, alpha: 1.0) : UIColor(white: 0.13, alpha: 1.0)
  }
  private var neutralAccentText: UIColor {
    appearance.isDark ? .black : .white
  }
  private var neutralFill: UIColor {
    appearance.isDark
      ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.05)
  }
  private var neutralStroke: UIColor {
    appearance.isDark
      ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.12)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Auto-dismiss if the bridge cancels this ask (answered elsewhere / timed out).
    if !requestId.isEmpty {
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleBridgeAskCancel(_:)),
        name: ChatEngine.didChangeNotification, object: nil)
    }

    if kind == "command" {
      title = ">_ Terminal"
    } else if kind == "plan" {
      title = "Review Plan"
    } else {
      title = "Ask"
    }

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(handleCloseTapped)
    )

    let navBarAppearance = UINavigationBarAppearance()
    navBarAppearance.configureWithTransparentBackground()
    navigationController?.navigationBar.standardAppearance = navBarAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navBarAppearance
    navigationController?.navigationBar.tintColor = appearance.isDark ? .white : .black

    view.backgroundColor = .clear

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.keyboardDismissMode = .interactive
    view.addSubview(scrollView)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 14
    contentStack.alignment = .fill
    scrollView.addSubview(contentStack)

    if kind != "plan" && kind != "command" { parseQuestions() }
    let buttonBar = makeButtonBar()
    buttonBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(buttonBar)

    let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
    view.addGestureRecognizer(tap)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor),

      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
      contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
      contentStack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -40),

      buttonBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      buttonBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      buttonBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
    ])

    if kind == "plan" {
      buildPlanContent()
    } else if kind == "command" {
      buildCommandContent()
    } else {
      buildAskContent()
    }
  }

  // MARK: content

  private func titleLabel(_ text: String, size: CGFloat = 20, weight: UIFont.Weight = .bold) -> UILabel {
    let label = UILabel()
    label.text = text
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = appearance.text
    return label
  }

  private func bodyLabel(_ text: String, color: UIColor? = nil) -> UILabel {
    let label = UILabel()
    label.text = text
    label.numberOfLines = 0
    label.font = .systemFont(ofSize: 14.5)
    label.textColor = color ?? appearance.textSecondary
    return label
  }

  private func buildPlanContent() {
    contentStack.addArrangedSubview(titleLabel("Review the plan"))
    if let repo = (request["repoName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !repo.isEmpty
    {
      contentStack.addArrangedSubview(bodyLabel("\(repo) · the agent will not edit until you approve", color: appearance.textTertiary))
    }

    let planText = (request["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no plan text)"
    let card = UIView()
    card.backgroundColor = neutralFill
    card.layer.cornerRadius = 14
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1
    card.layer.borderColor = neutralStroke.cgColor
    let planLabel = UILabel()
    planLabel.text = planText
    planLabel.numberOfLines = 0
    planLabel.font = .systemFont(ofSize: 14)
    planLabel.textColor = appearance.text
    planLabel.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(planLabel)
    NSLayoutConstraint.activate([
      planLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
      planLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      planLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      planLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
    ])
    contentStack.addArrangedSubview(card)

    contentStack.addArrangedSubview(bodyLabel("Notes for the agent (optional)", color: appearance.textTertiary))
    contentStack.addArrangedSubview(makeFeedbackField())
  }

  /// Command-approval card: a placeholder describing what the agent wants to do +
  /// the literal command/file it targets. Resolved via Approve / Skip / Deny.
  private func buildCommandContent() {
    let toolName = (request["toolName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = (request["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    
    let titleText = title?.isEmpty == false ? title! : (toolName.isEmpty ? "Run Command" : "Use \(toolName)")
    contentStack.addArrangedSubview(titleLabel(titleText))

    let repo = (request["repoName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let subtitle =
      toolName.isEmpty
      ? "The agent is requesting permission to continue."
      : "The agent wants to run a command using \(toolName)."
    contentStack.addArrangedSubview(
      bodyLabel(repo?.isEmpty == false ? "\(repo!) · \(subtitle)" : subtitle, color: appearance.textTertiary))

    let description = (request["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !description.isEmpty {
      contentStack.addArrangedSubview(bodyLabel(description))
    }

    let command = (request["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !command.isEmpty {
      let card = UIView()
      card.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
      card.layer.cornerRadius = 14
      card.layer.cornerCurve = .continuous
      card.layer.borderWidth = 1
      card.layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
      card.clipsToBounds = true
      
      let mono = UILabel()
      mono.text = "$ " + command
      mono.numberOfLines = 0
      mono.font = .monospacedSystemFont(ofSize: 13.0, weight: .medium)
      mono.textColor = .white
      mono.translatesAutoresizingMaskIntoConstraints = false
      card.addSubview(mono)
      
      let heightConstraint = card.heightAnchor.constraint(equalToConstant: 80)
      self.commandHeightConstraint = heightConstraint
      heightConstraint.isActive = !isCommandExpanded
      
      let bottomConstraint = mono.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
      bottomConstraint.priority = .defaultHigh
      
      NSLayoutConstraint.activate([
        mono.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
        mono.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
        mono.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        bottomConstraint
      ])
      
      let tap = UITapGestureRecognizer(target: self, action: #selector(toggleCommandExpansion))
      card.addGestureRecognizer(tap)
      card.isUserInteractionEnabled = true
      
      contentStack.addArrangedSubview(card)
    }

    contentStack.addArrangedSubview(
      bodyLabel(
        "Approve runs it once · No stops the agent.",
        color: appearance.textTertiary))
    contentStack.addArrangedSubview(makeFeedbackField())
  }

  /// Decode the questions[] payload and pre-build one block per question. Called
  /// before the button bar so it can size the bar to the page count.
  private func parseQuestions() {
    let rawQuestions = (request["questions"] as? [[String: Any]]) ?? []
    for q in rawQuestions {
      let questionText = (q["question"] as? String) ?? ""
      let header = (q["header"] as? String) ?? ""
      let multi = (q["multiSelect"] as? Bool) ?? false
      let opts = ((q["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
      let model = AskQuestion(question: questionText, header: header, multiSelect: multi, options: opts)
      let index = questions.count
      questions.append(model)
      selected.append([])
      questionBlocks.append(makeQuestionBlock(model, index: index))
    }
  }

  private func buildAskContent() {
    if questions.isEmpty {
      contentStack.addArrangedSubview(titleLabel("A few questions"))
      contentStack.addArrangedSubview(bodyLabel("The agent asked a question but sent no options. Add a note below.", color: appearance.textTertiary))
      contentStack.addArrangedSubview(makeFeedbackField())
    } else {
      renderAskPage()
    }
  }

  /// Swap the visible question to `askPageIndex` (one question per page) and update
  /// the page counter + Back/Next/Submit button bar.
  private func renderAskPage() {
    guard !questions.isEmpty else { return }
    askPageIndex = min(max(askPageIndex, 0), questions.count - 1)
    for sub in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(sub)
      sub.removeFromSuperview()
    }
    if questions.count > 1 {
      pageIndicator.text = "Question \(askPageIndex + 1) of \(questions.count)"
      pageIndicator.font = .systemFont(ofSize: 12, weight: .semibold)
      pageIndicator.textColor = appearance.textTertiary
      contentStack.addArrangedSubview(pageIndicator)
    }
    contentStack.addArrangedSubview(questionBlocks[askPageIndex])

    let isLast = askPageIndex >= questions.count - 1
    askBackButton?.isHidden = askPageIndex == 0
    askNextButton?.setTitle(isLast ? "Submit" : "Next", for: .normal)
    scrollView.setContentOffset(.zero, animated: false)
  }

  private func makeQuestionBlock(_ q: AskQuestion, index: Int) -> UIView {
    let block = UIStackView()
    block.axis = .vertical
    block.spacing = 8
    block.alignment = .fill

    if !q.header.isEmpty {
      let chip = UILabel()
      chip.text = "  \(q.header.uppercased())  "
      chip.font = .systemFont(ofSize: 11, weight: .bold)
      chip.textColor = appearance.text
      chip.backgroundColor = neutralFill
      chip.layer.cornerRadius = 7
      chip.layer.masksToBounds = true
      chip.setContentHuggingPriority(.required, for: .horizontal)
      let wrap = UIStackView(arrangedSubviews: [chip, UIView()])
      wrap.axis = .horizontal
      block.addArrangedSubview(wrap)
    }
    if !q.question.isEmpty {
      block.addArrangedSubview(titleLabel(q.question, size: 15.5, weight: .semibold))
    }
    if q.multiSelect {
      block.addArrangedSubview(bodyLabel("Select all that apply", color: appearance.textTertiary))
    }

    var buttons: [UIButton] = []
    for (optIndex, label) in q.options.enumerated() {
      let button = makeOptionButton(label, questionIndex: index, optionIndex: optIndex)
      buttons.append(button)
      block.addArrangedSubview(button)
    }
    optionButtonsByQuestion.append(buttons)

    let other = UITextField()
    other.placeholder = "Other…"
    other.font = .systemFont(ofSize: 14.5)
    other.textColor = appearance.text
    other.borderStyle = .roundedRect
    other.backgroundColor = neutralFill
    other.heightAnchor.constraint(equalToConstant: 40).isActive = true
    otherFields.append(other)
    block.addArrangedSubview(other)

    return block
  }

  private func makeOptionButton(_ label: String, questionIndex: Int, optionIndex: Int) -> UIButton {
    var config = UIButton.Configuration.bordered()
    config.title = label
    config.baseForegroundColor = appearance.text
    config.background.backgroundColor = neutralFill
    config.background.strokeColor = neutralStroke
    config.background.strokeWidth = 1
    config.background.cornerRadius = 12
    config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14)
    config.titleAlignment = .leading
    let button = UIButton(configuration: config)
    button.accessibilityIdentifier = "agent.ask.option.\(questionIndex).\(optionIndex)"
    button.contentHorizontalAlignment = .leading
    button.tag = questionIndex * 1000 + optionIndex
    button.addTarget(self, action: #selector(optionTapped(_:)), for: .touchUpInside)
    return button
  }

  @objc private func optionTapped(_ sender: UIButton) {
    let questionIndex = sender.tag / 1000
    let optionIndex = sender.tag % 1000
    guard questionIndex < questions.count else { return }
    let multi = questions[questionIndex].multiSelect
    if multi {
      if selected[questionIndex].contains(optionIndex) {
        selected[questionIndex].remove(optionIndex)
      } else {
        selected[questionIndex].insert(optionIndex)
      }
    } else {
      selected[questionIndex] = [optionIndex]
    }
    refreshOptionStyles(questionIndex: questionIndex)
  }

  private func refreshOptionStyles(questionIndex: Int) {
    guard questionIndex < optionButtonsByQuestion.count else { return }
    for (optIndex, button) in optionButtonsByQuestion[questionIndex].enumerated() {
      let isOn = selected[questionIndex].contains(optIndex)
      var config = button.configuration
      config?.background.backgroundColor =
        isOn ? neutralAccent.withAlphaComponent(appearance.isDark ? 0.20 : 0.12) : neutralFill
      config?.background.strokeColor = isOn ? neutralAccent : neutralStroke
      config?.background.strokeWidth = isOn ? 1.5 : 1
      config?.baseForegroundColor = appearance.text
      button.configuration = config
    }
  }

  private func makeFeedbackField() -> UIView {
    let container = UIView()
    container.backgroundColor = neutralFill
    container.layer.cornerRadius = 20
    container.layer.cornerCurve = .continuous
    container.layer.borderWidth = 1
    container.layer.borderColor = neutralStroke.cgColor

    feedbackField.translatesAutoresizingMaskIntoConstraints = false
    feedbackField.backgroundColor = .clear
    feedbackField.font = .systemFont(ofSize: 14.5)
    feedbackField.textColor = appearance.text
    feedbackField.delegate = self
    feedbackField.attributedPlaceholder = NSAttributedString(
      string: "Add notes or changes…",
      attributes: [.foregroundColor: appearance.textTertiary]
    )

    let paddingView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 40))
    feedbackField.leftView = paddingView
    feedbackField.leftViewMode = .always

    if kind == "command" {
      let skipBtn = UIButton(type: .system)
      skipBtn.setTitle("Skip", for: .normal)
      skipBtn.titleLabel?.font = .systemFont(ofSize: 14.5, weight: .semibold)
      skipBtn.setTitleColor(appearance.textSecondary, for: .normal)
      skipBtn.addTarget(self, action: #selector(skipCommandTapped), for: .touchUpInside)
      skipBtn.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
      feedbackField.rightView = skipBtn
      feedbackField.rightViewMode = .always
    } else {
      let rightPadding = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 40))
      feedbackField.rightView = rightPadding
      feedbackField.rightViewMode = .always
    }

    container.addSubview(feedbackField)

    NSLayoutConstraint.activate([
      feedbackField.topAnchor.constraint(equalTo: container.topAnchor),
      feedbackField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      feedbackField.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      feedbackField.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      feedbackField.heightAnchor.constraint(equalToConstant: 40)
    ])
    return container
  }

  // MARK: buttons

  private func makeButtonBar() -> UIView {
    let bar = UIStackView()
    bar.axis = .horizontal
    bar.spacing = 12
    bar.distribution = .fillEqually
    bar.isLayoutMarginsRelativeArrangement = true
    bar.layoutMargins = UIEdgeInsets(top: 8, left: 20, bottom: 0, right: 20)

    if kind == "command" {
      // Live command approval: No · Approve.
      let deny = makeBarButton("No", primary: false)
      deny.accessibilityIdentifier = "agent.ask.deny"
      deny.addTarget(self, action: #selector(denyCommandTapped), for: .touchUpInside)
      let approve = makeBarButton("Approve", primary: true)
      approve.accessibilityIdentifier = "agent.ask.approve"
      approve.addTarget(self, action: #selector(approveCommandTapped), for: .touchUpInside)
      bar.addArrangedSubview(deny)
      bar.addArrangedSubview(approve)
    } else if kind == "plan" {
      let reject = makeBarButton("Reject", primary: false)
      reject.accessibilityIdentifier = "agent.ask.reject"
      reject.addTarget(self, action: #selector(rejectTapped), for: .touchUpInside)
      let approve = makeBarButton("Approve & Implement", primary: true)
      approve.accessibilityIdentifier = "agent.ask.approve"
      approve.addTarget(self, action: #selector(approveTapped), for: .touchUpInside)
      bar.addArrangedSubview(reject)
      bar.addArrangedSubview(approve)
    } else if questions.count > 1 {
      // Paged ask: Back (hidden on page 1) + Next/Submit.
      let back = makeBarButton("Back", primary: false)
      back.accessibilityIdentifier = "agent.ask.back"
      back.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
      back.isHidden = true
      let next = makeBarButton("Next", primary: true)
      next.accessibilityIdentifier = "agent.ask.submit"
      next.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
      askBackButton = back
      askNextButton = next
      bar.addArrangedSubview(back)
      bar.addArrangedSubview(next)
    } else {
      let submit = makeBarButton("Submit", primary: true)
      submit.accessibilityIdentifier = "agent.ask.submit"
      submit.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
      askNextButton = submit
      bar.addArrangedSubview(submit)
    }
    return bar
  }

  @objc private func backTapped() {
    askPageIndex -= 1
    renderAskPage()
  }

  @objc private func nextTapped() {
    if askPageIndex >= questions.count - 1 {
      submitTapped()
    } else {
      askPageIndex += 1
      renderAskPage()
    }
  }

  private func makeBarButton(_ title: String, primary: Bool) -> UIButton {
    var config = UIButton.Configuration.filled()
    config.title = title
    // Full-radius (capsule) buttons with neutral off-mute fills.
    config.cornerStyle = .capsule
    config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    config.baseBackgroundColor = primary ? neutralAccent : neutralFill
    config.baseForegroundColor = primary ? neutralAccentText : appearance.text
    let button = UIButton(configuration: config)
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.8
    return button
  }

  private var feedbackText: String? {
    let t = feedbackField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t?.isEmpty == false) ? t : nil
  }

  @objc private func approveTapped() {
    resolve("approve", answer: feedbackText.map { ["feedback": $0] })
  }

  @objc private func rejectTapped() {
    resolve("reject", answer: feedbackText.map { ["feedback": $0] })
  }

  // Command approval (kind == "command"). A typed note becomes the message handed
  // back to the agent so it knows why a command was skipped/denied.
  @objc private func approveCommandTapped() {
    resolve("approve", answer: nil)
  }

  @objc private func skipCommandTapped() {
    resolve("skip", answer: feedbackText.map { ["message": $0] })
  }

  @objc private func denyCommandTapped() {
    resolve("deny", answer: feedbackText.map { ["message": $0] })
  }

  @objc private func submitTapped() {
    var selections: [[String: Any]] = []
    for (index, q) in questions.enumerated() {
      let labels = selected[index].sorted().compactMap { q.options.indices.contains($0) ? q.options[$0] : nil }
      let other = otherFields.indices.contains(index)
        ? otherFields[index].text?.trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
      var entry: [String: Any] = ["header": q.header, "question": q.question, "selected": labels]
      if let other, !other.isEmpty {
        entry["other"] = other
      }
      selections.append(entry)
    }
    var answer: [String: Any] = ["selections": selections]
    if questions.isEmpty, let note = feedbackText { answer["feedback"] = note }
    resolve("answer", answer: answer)
  }

  @objc private func toggleCommandExpansion() {
    isCommandExpanded.toggle()
    UIView.animate(withDuration: 0.25) {
      self.commandHeightConstraint?.isActive = !self.isCommandExpanded
      self.view.layoutIfNeeded()
    }
  }

  private func resolve(_ decision: String, answer: [String: Any]?) {
    guard !didResolve else { return }
    didResolve = true
    onResolve?(decision, answer)
    dismiss(animated: true)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Swiped away without answering → let the presenter re-arm this ask for reopen.
    if !didResolve, isBeingDismissed || isMovingFromParent {
      onDismissWithoutResolve?()
    }
  }
  @objc private func dismissKeyboard() {
    view.endEditing(true)
  }
}

extension VibeAgentAskSheetViewController: UITextFieldDelegate {
  func textFieldDidBeginEditing(_ textField: UITextField) {
    if let presentation = sheetPresentationController {
      presentation.animateChanges {
        presentation.selectedDetentIdentifier = .large
      }
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    if kind == "command" {
      skipCommandTapped()
    }
    return true
  }
}

extension VibeAgentConversationViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
  public func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    if let image = info[.originalImage] as? UIImage,
       let blob = Self.sealedImageBlob(from: image) {
      self.composerView.addAttachment(blob: blob)
    }
  }

  public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }

  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    if let data = try? Data(contentsOf: url), let image = UIImage(data: data),
       let blob = Self.sealedImageBlob(from: image) {
      self.composerView.addAttachment(blob: blob)
    }
  }
}
