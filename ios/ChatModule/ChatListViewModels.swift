import UIKit

/// Which part of a message cell a long press landed on.
enum ChatContextMenuHoldTarget: Equatable {
  case bubble
  case reaction(emoji: String)
}

/// Emoji arrive with and without presentation selectors depending on the source
/// (catalog literal, server payload, core engine), so compare on this form only.
enum ChatReactionKey {
  static func normalized(_ emoji: String) -> String {
    emoji
      .replacingOccurrences(of: "\u{FE0E}", with: "")
      .replacingOccurrences(of: "\u{FE0F}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func matches(_ lhs: String, _ rhs: String) -> Bool {
    normalized(lhs) == normalized(rhs)
  }
}

final class ChatListRegistry {
  static let shared = ChatListRegistry()

  private final class WeakRef {
    weak var value: ChatListView?

    init(_ value: ChatListView) {
      self.value = value
    }
  }

  private var map: [String: WeakRef] = [:]

  func register(surfaceId: String, view: ChatListView) {
    map[surfaceId] = WeakRef(view)
  }

  func view(for surfaceId: String) -> ChatListView? {
    if let value = map[surfaceId]?.value {
      return value
    }
    map.removeValue(forKey: surfaceId)
    return nil
  }
}

struct BubbleShape {
  let isMe: Bool
  let showTail: Bool
  let borderTopLeftRadius: CGFloat
  let borderTopRightRadius: CGFloat
  let borderBottomLeftRadius: CGFloat
  let borderBottomRightRadius: CGFloat

  private static func parseRadius(_ value: Any?, fallback: CGFloat = 18.0) -> CGFloat {
    if let num = value as? NSNumber { return CGFloat(num.doubleValue) }
    if let dbl = value as? Double { return CGFloat(dbl) }
    if let int = value as? Int { return CGFloat(int) }
    if let str = value as? String {
      let clean = str.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)
      if let d = Double(clean) { return CGFloat(d) }
    }
    return fallback
  }

  static func from(raw: [String: Any]?, isMe: Bool) -> BubbleShape {
    let fallback =
      isMe
      ? BubbleShape(
        isMe: true, showTail: true, borderTopLeftRadius: 18, borderTopRightRadius: 18,
        borderBottomLeftRadius: 18, borderBottomRightRadius: 18)
      : BubbleShape(
        isMe: false, showTail: true, borderTopLeftRadius: 18, borderTopRightRadius: 18,
        borderBottomLeftRadius: 18, borderBottomRightRadius: 18)
    guard let raw else {
      return fallback
    }
    return BubbleShape(
      isMe: isMe,
      showTail: (raw["showTail"] as? Bool) ?? true,
      borderTopLeftRadius: parseRadius(raw["borderTopLeftRadius"]),
      borderTopRightRadius: parseRadius(raw["borderTopRightRadius"]),
      borderBottomLeftRadius: parseRadius(raw["borderBottomLeftRadius"]),
      borderBottomRightRadius: parseRadius(raw["borderBottomRightRadius"])
    )
  }
}

struct ChatListRow {
  struct Reaction: Equatable, Hashable {
    let emoji: String
    let count: Int
    let isSelected: Bool
  }

  struct AgentProgressNode: Equatable {
    let id: String
    let label: String
    let status: String
    let depth: Int
    // Claude-Code-style shape for the live tool feed (optional; older payloads
    // only carry label/status/depth).
    var kind: String? = nil
    var target: String? = nil
    var added: Int? = nil
    var removed: Int? = nil
    // Read-tool line range (plaintext) so the row preview reads "Read foo.swift (12–48)".
    var start: Int? = nil
    var end: Int? = nil
    // Subagent (Claude Task tool) grouping. A depth-1 child carries `parentId` =
    // the parent Task node's id; the parent Task node (depth 0, kind "task")
    // carries `subagentType` (e.g. "explore") so it renders as a "🤖 Subagent" row.
    var parentId: String? = nil
    var subagentType: String? = nil
    // Thinking-node metrics: reasoning token count + how long the turn spent thinking,
    // so a "thinking" row renders "Thinking · N tokens" / "Thought for Ns" like the CLI.
    var tokens: Int? = nil
    var durationMs: Int? = nil
    var action: String? = nil
    /// Plaintext detail body (Grok exposed CoT, compacting notes). Live path may ship
    /// this without encrypted agentActionsEnc; tap thinking opens a sheet with it.
    var detail: String? = nil
    /// Runtime tool name (`computer_run`, `browser_open`, …) — anchors the computer band.
    var tool: String? = nil
  }

  struct AgentRuntimeCommand: Equatable {
    let executable: String?
    let display: String?
  }

  struct AgentRuntimeFile: Equatable {
    let path: String
    let name: String
    let status: String
    let additions: Int
    let deletions: Int
  }

  struct AgentRuntimeDiff: Equatable {
    let filesChanged: Int
    let additions: Int
    let deletions: Int
    let files: [AgentRuntimeFile]
    let patch: String?
    let patchTruncated: Bool
  }

  struct AgentRuntimeControls: Equatable {
    let canCancel: Bool
    let canRevert: Bool
  }

  struct AgentRuntimeUsage: Equatable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
    let totalCostUsd: Double?
    let durationMs: Int?
    let durationApiMs: Int?
    let ttftMs: Int?
    let ttftStreamMs: Int?
    let numTurns: Int?
  }

  struct AgentRuntimeMCPServer: Equatable {
    let name: String
    let status: String?
  }

  /// Compact status for one under-hood (or lead) worker in a supervisor team run.
  struct TeamWorkerStatus: Equatable {
    let worker: String
    let label: String
    let status: String
    let startedAt: Int64?
    let finishedAt: Int64?
    let durationMs: Int?
    let summary: String?
    let taskId: String?
    let lastLabel: String?

    var isRunning: Bool {
      let s = status.lowercased()
      return s == "running" || s == "pending" || s == "starting"
    }

    /// Compact chip text: "Claude · running · reading" or "Grok · done · 2m".
    var compactLine: String {
      let name = label.isEmpty ? worker.capitalized : label
      let s = status.lowercased()
      if s == "done" || s == "completed" {
        if let ms = durationMs, ms > 0 {
          return "\(name) · done · \(Self.formatDuration(ms))"
        }
        return "\(name) · done"
      }
      if s == "failed" || s == "error" {
        return "\(name) · failed"
      }
      if s == "skipped" {
        return "\(name) · skipped"
      }
      // Watchdog transitions: a usage-limited slice restarted on another
      // provider, or a run torn down mid-flight.
      if s == "reassigned" {
        if let last = lastLabel, !last.isEmpty {
          let short = last.count > 28 ? String(last.prefix(28)) + "…" : last
          return "\(name) · \(short)"
        }
        return "\(name) · reassigned"
      }
      if s == "cancelled" || s == "canceled" {
        return "\(name) · cancelled"
      }
      if let last = lastLabel, !last.isEmpty {
        let short = last.count > 28 ? String(last.prefix(28)) + "…" : last
        return "\(name) · \(s.isEmpty ? "running" : s) · \(short)"
      }
      return "\(name) · \(s.isEmpty ? "running" : s)"
    }

    static func formatDuration(_ ms: Int) -> String {
      let totalSec = max(0, ms / 1000)
      if totalSec < 60 { return "\(totalSec)s" }
      let m = totalSec / 60
      let s = totalSec % 60
      if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
      let h = m / 60
      let rm = m % 60
      return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }
  }

  struct AgentRuntimeSummary: Equatable {
    let taskId: String?
    let provider: String?
    let status: String
    let repoName: String?
    let cwd: String?
    let workMode: String?
    let model: String?
    /// Bridge-reported thinking/reasoning effort for this run (`low`…`max`).
    let reasoningEffort: String?
    let advisor: String?
    let permissionMode: String?
    let sessionId: String?
    let threadId: String?
    let cliVersion: String?
    let durationMs: Int?
    let dirtyBefore: Bool
    let dirtyBeforeCount: Int
    let exitStatus: Int?
    let command: AgentRuntimeCommand?
    let diff: AgentRuntimeDiff?
    let controls: AgentRuntimeControls?
    let usage: AgentRuntimeUsage?
    let availableTools: [String]
    let slashCommands: [String]
    let cliCommands: [String]
    let providerCommands: [String]
    let mcpServers: [AgentRuntimeMCPServer]
    let agents: [String]
    let skills: [String]
    let teamMode: String?
    let teamRunId: String?
    let teamWorker: String?
    let teamWorkers: [String]
    let leadWorker: String?
    let teamRole: String?
    let suppressVisible: Bool
    // Supervisor team runs render NO agent text bubble — only the progress runner
    // cell + per-worker rows. The lead's final summary is the only prose. Server
    // sets this true when teamMode == supervisor.
    let suppressAllText: Bool
    let teamWorkersStatus: [TeamWorkerStatus]
    let computerId: String?
    let computerLabel: String?

    /// One-line strip for the lead cell: "Claude · running · … · Grok · done · 2m"
    var teamProgressStrip: String? {
      guard !teamWorkersStatus.isEmpty else { return nil }
      let parts = teamWorkersStatus.map(\.compactLine)
      return parts.joined(separator: "  ·  ")
    }

    /// Run-phase headline derived from the roster states (team-architecture-v2):
    /// lead alone planning → workers building → lead verifying/integrating.
    var teamPhaseLabel: String? {
      guard !teamWorkersStatus.isEmpty else { return nil }
      let leadHandle = (leadWorker ?? "").lowercased()
      let workers = teamWorkersStatus.filter { $0.worker.lowercased() != leadHandle }
      guard !workers.isEmpty else { return "Planning…" }
      let runningCount = workers.filter(\.isRunning).count
      let anyStarted = workers.contains {
        !($0.status.lowercased() == "pending" || $0.status.lowercased() == "queued")
      }
      if runningCount > 0 {
        return runningCount == 1 ? "Team building · 1 working" : "Team building · \(runningCount) working"
      }
      if !anyStarted { return "Planning…" }
      // Every worker slice is terminal; the lead is integrating/verifying.
      return "Verifying…"
    }
  }

  struct AgentCardDestination: Codable, Equatable {
    let chatId: String
    let name: String?
    let type: String?
    let openLink: String?

    static func parse(_ raw: [String: Any]) -> AgentCardDestination? {
      guard let chatId = parseNonEmptyString(raw["chat_id"] ?? raw["chatId"]) else { return nil }
      return AgentCardDestination(
        chatId: chatId,
        name: parseNonEmptyString(raw["name"]),
        type: parseNonEmptyString(raw["type"]),
        openLink: parseNonEmptyString(raw["open_link"] ?? raw["openLink"])
      )
    }

    var rawValue: [String: Any] {
      var raw: [String: Any] = ["chat_id": chatId]
      if let name { raw["name"] = name }
      if let type { raw["type"] = type }
      if let openLink { raw["open_link"] = openLink }
      return raw
    }
  }

  struct AgentCard: Codable, Equatable {
    let id: String
    let style: String
    let agentId: String
    let agentUserId: String?
    let displayName: String
    let username: String?
    let identifier: String
    let avatarUrl: String?
    let status: String
    let promptStatus: String?
    let promptPreview: String?
    let systemPrompt: String?
    let modelProvider: String?
    let modelId: String?
    let enabledTools: [String]
    let outputModes: [String]
    let voiceProfile: String?
    /// `"google"` or `"openai_realtime"` — which speech provider this agent's
    /// voice output uses. Nil = not yet configured.
    let voiceProvider: String?
    let callbackURL: String?
    let apiBaseURL: String?
    let invokeURL: String?
    let eventsURL: String?
    let builderLink: String?
    let agentDMURL: String?
    let secretHint: String?
    let latestSecret: String?
    let defaultDestinationChat: AgentCardDestination?
    let attachedChats: [AgentCardDestination]
    let eventInboxMode: String
    let summaryWindowHours: Int
    // "interval" (rolling window) or "daily" (fixed clock times). Optional so
    // older cached cards decode cleanly; treat nil as "interval".
    let summarySchedule: String?
    // Fixed delivery times for the "daily" schedule, as "HH:MM" strings (UTC).
    let summaryTimes: [String]?
    let incomingChatEnabled: Bool
    let canDelete: Bool

    static func parse(_ raw: [String: Any]) -> AgentCard? {
      let rawId = parseNonEmptyString(raw["id"])
      guard
        let agentId =
          parseNonEmptyString(raw["agent_id"] ?? raw["agentId"])
          ?? rawId
      else { return nil }
      let id =
        parseNonEmptyString(raw["card_id"] ?? raw["cardId"])
        ?? ((raw["agent_id"] != nil || raw["agentId"] != nil) ? rawId : nil)
        ?? "agent-card:\(agentId)"
      let style = parseNonEmptyString(raw["style"]) ?? "summary"
      let rawUsername =
        parseNonEmptyString(raw["username"])
        ?? parseNonEmptyString(raw["handle"])?.trimmingCharacters(
          in: CharacterSet(charactersIn: "@"))
      let displayName =
        parseNonEmptyString(raw["display_name"] ?? raw["displayName"])
        ?? rawUsername
        ?? "Agent"
      let identifier = parseNonEmptyString(raw["identifier"]) ?? rawUsername ?? agentId
      let status = parseNonEmptyString(raw["status"]) ?? "draft"

      let defaultDestinationChat =
        ((raw["default_destination_chat"] as? [String: Any])
          ?? (raw["defaultDestinationChat"] as? [String: Any]))
        .flatMap(AgentCardDestination.parse)
      let attachedChats =
        ((raw["attached_chats"] as? [[String: Any]])
          ?? (raw["attachedChats"] as? [[String: Any]])
          ?? []).compactMap(AgentCardDestination.parse)
      let (eventInboxMode, summaryWindowHours) = parseAgentCardEventInbox(raw)
      let summarySchedule = parseAgentCardSummarySchedule(raw)
      let summaryTimes = parseAgentCardSummaryTimes(raw)
      let approvalRules =
        (raw["approval_rules"] as? [String: Any])
        ?? (raw["approvalRules"] as? [String: Any])
      let chatInput =
        (approvalRules?["chat_input"] as? [String: Any])
        ?? (approvalRules?["chatInput"] as? [String: Any])

      return AgentCard(
        id: id,
        style: style,
        agentId: agentId,
        agentUserId:
          parseNonEmptyString(
            raw["agent_user_id"] ?? raw["agentUserId"] ?? raw["user_id"] ?? raw["userId"]),
        displayName: displayName,
        username: rawUsername,
        identifier: identifier,
        avatarUrl:
          parseNonEmptyString(
            raw["avatar_url"] ?? raw["avatarUrl"] ?? raw["profile_image"] ?? raw["profileImage"]),
        status: status,
        promptStatus: parseNonEmptyString(raw["prompt_status"] ?? raw["promptStatus"]),
        promptPreview: parseNonEmptyString(raw["prompt_preview"] ?? raw["promptPreview"]),
        systemPrompt: parseNonEmptyString(raw["system_prompt"] ?? raw["systemPrompt"]),
        modelProvider: parseNonEmptyString(raw["model_provider"] ?? raw["modelProvider"]),
        modelId: parseNonEmptyString(raw["model_id"] ?? raw["modelId"]),
        enabledTools: parseStringArray(raw["enabled_tools"] ?? raw["enabledTools"]),
        outputModes: parseStringArray(raw["output_modes"] ?? raw["outputModes"]),
        voiceProfile: parseNonEmptyString(raw["voice_profile"] ?? raw["voiceProfile"]),
        voiceProvider: parseNonEmptyString(raw["voice_provider"] ?? raw["voiceProvider"]),
        callbackURL: parseNonEmptyString(raw["callback_url"] ?? raw["callbackUrl"]),
        apiBaseURL: parseNonEmptyString(raw["api_base_url"] ?? raw["apiBaseUrl"]),
        invokeURL: parseNonEmptyString(raw["invoke_url"] ?? raw["invokeUrl"]),
        eventsURL: parseNonEmptyString(raw["events_url"] ?? raw["eventsUrl"]),
        builderLink: parseNonEmptyString(raw["builder_link"] ?? raw["builderLink"]),
        agentDMURL: parseNonEmptyString(raw["agent_dm_link"] ?? raw["agentDmLink"]),
        secretHint: parseNonEmptyString(raw["secret_hint"] ?? raw["secretHint"]),
        latestSecret:
          parseNonEmptyString(
            raw["latest_secret"] ?? raw["latestSecret"] ?? raw["secret"] ?? raw["invoke_secret"]
              ?? raw["invokeSecret"]),
        defaultDestinationChat: defaultDestinationChat,
        attachedChats: attachedChats,
        eventInboxMode: eventInboxMode,
        summaryWindowHours: summaryWindowHours,
        summarySchedule: summarySchedule,
        summaryTimes: summaryTimes,
        incomingChatEnabled:
          parseBool(raw["incoming_chat_enabled"] ?? raw["incomingChatEnabled"])
          ?? parseBool(chatInput?["enabled"])
          ?? true,
        canDelete:
          (raw["can_delete"] as? Bool)
          ?? ((raw["canDelete"] as? Bool) ?? true)
      )
    }

    var rawValue: [String: Any] {
      var raw: [String: Any] = [
        "id": id,
        "style": style,
        "agent_id": agentId,
        "display_name": displayName,
        "identifier": identifier,
        "status": status,
        "enabled_tools": enabledTools,
        "output_modes": outputModes,
        "attached_chats": attachedChats.map(\.rawValue),
        "can_delete": canDelete,
      ]
      if let agentUserId { raw["agent_user_id"] = agentUserId }
      if let username { raw["username"] = username }
      if let avatarUrl { raw["avatar_url"] = avatarUrl }
      if let promptStatus { raw["prompt_status"] = promptStatus }
      if let promptPreview { raw["prompt_preview"] = promptPreview }
      if let systemPrompt { raw["system_prompt"] = systemPrompt }
      if let modelProvider { raw["model_provider"] = modelProvider }
      if let modelId { raw["model_id"] = modelId }
      if let voiceProfile { raw["voice_profile"] = voiceProfile }
      if let voiceProvider { raw["voice_provider"] = voiceProvider }
      if let callbackURL { raw["callback_url"] = callbackURL }
      if let apiBaseURL { raw["api_base_url"] = apiBaseURL }
      if let invokeURL { raw["invoke_url"] = invokeURL }
      if let eventsURL { raw["events_url"] = eventsURL }
      if let builderLink { raw["builder_link"] = builderLink }
      if let agentDMURL { raw["agent_dm_link"] = agentDMURL }
      if let secretHint { raw["secret_hint"] = secretHint }
      if let latestSecret { raw["latest_secret"] = latestSecret }
      if let defaultDestinationChat { raw["default_destination_chat"] = defaultDestinationChat.rawValue }
      raw["event_inbox_mode"] = eventInboxMode
      raw["summary_window_hours"] = summaryWindowHours
      if let summarySchedule { raw["summary_schedule"] = summarySchedule }
      if let summaryTimes { raw["summary_times"] = summaryTimes }
      raw["incoming_chat_enabled"] = incomingChatEnabled
      return raw
    }

    var subtitleText: String {
      if let username, !username.isEmpty {
        return "@\(username)"
      }
      return identifier
    }
  }

  enum Kind {
    case day
    case message
  }

  enum MessageVisualKind {
    case text
    case voice
    case video
    case videoNote
    case media
    case document
    case sticker
  }

  let kind: Kind
  /// Stable identity for this row, for as long as it is the same message.
  ///
  /// **Never random.** The previous fallback was `UUID().uuidString` whenever the
  /// payload arrived without a `key`, which looks harmless and is not: identity
  /// is what `ChatTimelineLayout` keys its height memo by, so a row with a fresh
  /// identity on every parse can never be found in the memo, is re-measured on
  /// every rebuild forever, and is treated as a brand-new row by every diff.
  ///
  /// On device that showed as `[TimelineLayout] REBUILD 80ms … measured=1386
  /// reused=0` — a layout whose entire design is "only re-ask about rows it has
  /// not seen" re-asking about all of them, ~80ms at a time, repeatedly, some of
  /// it under the reader's finger. Every derivation below is a pure function of
  /// the payload, so the same row always yields the same string.
  let key: String
  let label: String
  let text: String
  let timestamp: String
  let isMe: Bool
  let status: String?
  let isEdited: Bool
  let editedAtMs: Int64?
  let isPinned: Bool
  let messageId: String?
  let chatId: String?
  /// Sender's user id (`from_id`) for a group/channel message. Used to resolve the
  /// per-sender name label + avatar from the group member directory, and to detect
  /// consecutive same-sender runs. Nil for day dividers and "me" messages we don't
  /// need to attribute. Agent messages also carry `agentUserId`.
  let senderUserId: String?
  let replyToId: String?
  let replyPreviewTitle: String?
  let replyPreviewText: String?
  /// User id of the author referenced by the reply preview (quoted original).
  /// Used to resolve that author's banner palette for the compact preview only.
  let replyPreviewUserId: String?

  /// The row is a reply whose quoted preview has not been resolved yet.
  ///
  /// The reply chip is worth roughly 46pt, and it arrives with enrichment rather than
  /// with the message. A height measured in this state is a guess that WILL change —
  /// the same category as a square-fallback media height — so it must not be trusted
  /// or written to disk. Agent rows are excluded because they never render a reply
  /// band at all and their reply fields flip nil↔value forever, which is exactly why
  /// `==` already ignores them.
  var hasUnresolvedReplyPreview: Bool {
    guard !isAgentMessage, let replyToId, !replyToId.isEmpty else { return false }
    let hasTitle = !(replyPreviewTitle ?? "").isEmpty
    let hasText = !(replyPreviewText ?? "").isEmpty
    return !hasTitle && !hasText
  }
  let reactionEmoji: String?
  let reactions: [Reaction]
  let viewCount: Int?
  let shape: BubbleShape
  let messageType: String
  let mediaUrl: String?
  let localMediaUrl: String?
  let mediaKey: String?
  let thumbnailBase64: String?
  /// Album art / cover URL for music rows (server sends it as metadata "cover").
  /// Rendered in the music bubble, the mini player banner, and the full player.
  let musicCoverURL: String?
  /// Artist / uploader for music rows (metadata "artist").
  let musicArtist: String?
  /// Source platform label for music rows (metadata "source", e.g. soundcloud → SoundCloud).
  let musicSource: String?
  /// Telegram-style forward attribution (metadata isForwarded + forwardedFrom*).
  let isForwarded: Bool
  let forwardedFromName: String?
  let forwardedFromAvatar: String?
  /// Original author id — feeds `ChatAvatarNodeView` palette / URL resolution.
  let forwardedFromUserId: String?
  let fileName: String?
  /// Server-declared content type. A document cell cannot label itself from the
  /// name alone — a printable page arrives with an extensionless url and would
  /// otherwise claim to be a PDF.
  let mimeType: String?
  let duration: Double?
  let waveform: [CGFloat]?
  let isVideoNote: Bool
  let viewOnce: Bool
  let mediaTtlSeconds: Int?
  let uploadProgress: Double?
  let fileSize: Int64?
  let mediaWidth: Double?
  let mediaHeight: Double?

  // Sticker pack fields
  let stickerId: String?
  let stickerPackId: String?
  let stickerBundleFileName: String?

  // Stamped post-parse from ChatListView.isGroupOrChannel (not part of the raw row
  // payload — no per-row group data exists yet). Lets the agent-turn renderer pick
  // bubble vs full-page-only without threading a new parameter through every
  // measurement/layout call site; defaults false so it's a no-op until a route
  // actually sets a bridge-agent DM's isGroupOrChannel (none does today).
  var isGroupOrChannel: Bool = false

  // Agent message fields
  let isAgentMessage: Bool
  let agentName: String?
  let agentId: String?
  let agentUserId: String?
  let agentUsername: String?
  let plainContent: String?
  let isStreamingText: Bool
  let agentProgressNodes: [AgentProgressNode]
  let agentActionSourceId: String?
  // The bridge session this message resumes (stamped by the agent-history composer
  // when sending a follow-up). Durable across devices, so the agent runtime view can
  // fold a resumed turn into the right session no matter which device sent it.
  let agentBridgeResumeSessionId: String?
  // E2E-encrypted bridge image attachments (phone-held key); rendered locally in the
  // agent surface and relayed to the desktop bridge as opaque ciphertext.
  let agentBridgeAttachmentsEnc: [String]
  /// Server-persisted JPEG thumbs for multi-image sends (blobs are stripped on persist).
  let attachmentThumbnailsB64: [String]
  /// Durable URL per picture for a multi-image send in a plain chat, first entry
  /// being the message's own `mediaUrl`. Agent sends carry their pictures inline
  /// as sealed blobs instead, so this stays empty for them.
  let attachmentUrls: [String]
  /// Per-picture media key, index-aligned with `attachmentUrls`. Media is
  /// encrypted per file, so one key cannot open the whole set; an empty string
  /// marks a picture that was uploaded unencrypted.
  let attachmentMediaKeys: [String]
  let agentActionSourceText: String?
  let agentRegeneratePrompt: String?
  let agentCard: AgentCard?
  let agentRuntime: AgentRuntimeSummary?
  // Bridge live-tail per-action detail: the message sub-kind ("action"/"summary")
  // and the E2E-encrypted structured tool detail (command+output, todos, diff
  // counts). Kept opaque here; decrypted at render time with the phone-held key.
  let agentMsgKind: String?
  let agentActionEnc: String?
  // A turn's tool actions sealed as one E2E-encrypted detail array (joined to the
  // plaintext `agentProgressNodes` by node id) — powers the tool sheet's command
  // output / todo contents without leaking them to the server.
  let agentActionsEnc: String?
  let relatedMessageIds: [String]
  let relatedMessagesTitle: String?
  let relatedMessagesSubtitle: String?

  // Agent event-inbox fields. An "event notification" is a message the agent
  // posted from an external event ingestion (eventThread) or a batched event
  // summary (eventInboxSummary). When the attached agent runs in inbox mode
  // these are pulled out of the transcript and surfaced through the Inbox banner.
  let isEventNotification: Bool
  let isEventInboxSummary: Bool
  let eventType: String?
  let eventPriority: String?
  let eventThreadId: String?
  let eventInboxRole: String?
  let hiddenFromTranscript: Bool

  // Outgoing message failed to be delivered/answered (agent error or stopped).
  let isDeliveryFailed: Bool
  // Agent response whose turn errored out — drives the side regenerate button.
  let isAgentError: Bool

  /// Structured service-message node (`metadata.service`) for centred notices
  /// (join/leave/decision). Nil for ordinary bubbles.
  let serviceMessage: ChatServiceMessage?

  var isAgentMention: Bool {
    return isMe && text.lowercased().contains("@vibe")
  }

  var textWithoutMention: String {
    if isAgentMention {
      return text.replacingOccurrences(of: "@vibe", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
  }

  var visualKind: MessageVisualKind {
    guard kind == .message else {
      return .text
    }
    if isVideoNote {
      return .videoNote
    }
    // Sealed Claude/Codex image blobs (or durable thumbs after reopen) ride on
    // messages that must render as media, not bare text.
    //
    // Explicitly NOT for `messageType == "file"`. A PDF ships a page thumbnail, and a
    // thumbnail is decoration inside the document plate — not a reason to render the whole
    // row as a photograph. Worse, whether that thumb is populated depends on which
    // pipeline produced the row (warm snapshot, engine, durable cache), so the same
    // message came back `.media` on one pass and `.document` on the next. The two render
    // at different heights, and a row whose KIND is unstable has a height that oscillates
    // forever: device run 2026-08-04, chat 47157fce5863, key 8-16f4a794ac1d, correcting
    // `was=412 now=612` on one open and `was=612 now=412` on the next, visibly, every
    // time. A genuine image sent as a file is still caught below by `inferredImage`, which
    // reads the file name and url rather than the presence of a thumb.
    if messageType != "file", !agentBridgeAttachmentsEnc.isEmpty || !attachmentThumbnailsB64.isEmpty
    {
      return .media
    }
    let references = ChatMediaReferenceExtensions(mediaUrl: mediaUrl, fileName: fileName)
    let inferredVideo = references.isVideo
    let inferredImage = references.isImage
    let inferredAudio = references.isAudio
    switch messageType {
    case "voice", "music", "mp3", "audio":
      return .voice
    case "video":
      return .video
    case "image", "gif":
      if inferredVideo {
        return .video
      }
      return .media
    case "sticker":
      return .sticker
    case "file":
      if inferredVideo {
        return .video
      }
      if inferredImage {
        return .media
      }
      if inferredAudio {
        return .voice
      }
      return .document
    default:
      if inferredVideo {
        return .video
      }
      if inferredImage {
        return .media
      }
      if inferredAudio {
        return .voice
      }
      let hasAttachmentReference =
        !(fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        || !(mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      if hasAttachmentReference {
        return .document
      }
      return .text
    }
  }

  var shouldShowUploadOverlay: Bool {
    guard isMe, messageType != "gif" else {
      return false
    }
    let normalized = status?.lowercased() ?? ""
    return normalized == "sending" || normalized == "pending"
  }

  /// Derives `key` from the payload, deterministically, in every case.
  ///
  /// The order is by decreasing confidence, and each step is something that does
  /// not change while the row is the same row:
  ///
  /// 1. the key the sender supplied (`ChatEngine` emits `"m-<messageId>"`);
  /// 2. the message id, which is what a supplied key is built from anyway;
  /// 3. the client id, for an outgoing row the server has not acknowledged yet —
  ///    it survives exactly until the real id arrives, which is the moment the
  ///    row legitimately becomes a different row;
  /// 4. the day label, for separators;
  /// 5. a hash of the payload's identifying fields.
  ///
  /// Step 5 is the important one. It replaces a random UUID, and the difference
  /// is that two parses of the same content now agree. A hash can collide where
  /// a UUID cannot — but a collision means two rows the payload describes
  /// identically, which the reader could not tell apart either, whereas the UUID
  /// guaranteed a miss for *every* row that reached this branch.
  private static func stableKey(raw: [String: Any], kindRaw: String) -> String {
    func text(_ value: Any?) -> String? {
      guard let string = value as? String else { return nil }
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let supplied = text(raw["key"]) { return supplied }

    let message = raw["message"] as? [String: Any]
    if let id = text(message?["id"]) ?? text(raw["id"]) { return "m-\(id)" }
    if let clientId = text(message?["clientId"]) ?? text(raw["clientId"]) {
      return "c-\(clientId)"
    }
    if kindRaw == "day", let label = text(raw["label"]) { return "day-\(label)" }

    // Last resort. Hash the fields that identify a row rather than the whole
    // payload: status, upload progress and read receipts all mutate on a row
    // that is still the same row, and folding them in would mint a new identity
    // every time a checkmark changed — reintroducing the bug this replaces.
    //
    // FNV-1a and not `Hasher`. Swift seeds `Hasher` randomly per process, so it
    // is stable within a launch and different on the next one — and row heights
    // are persisted to disk under these keys, so a per-launch identity would
    // hand every relaunch a cold height table while looking correct in testing.
    let identifying = [
      kindRaw,
      text(message?["senderId"]) ?? text(raw["senderUserId"]) ?? "",
      text(message?["createdAt"]) ?? text(raw["timestamp"]) ?? "",
      text(message?["content"]) ?? text(raw["text"]) ?? "",
      text(message?["mediaUrl"]) ?? "",
    ].joined(separator: "\u{1}")
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in identifying.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return "h-\(String(hash, radix: 36))"
  }

  init?(raw: [String: Any]) {
    guard let kindRaw = raw["kind"] as? String else {
      return nil
    }
    key = Self.stableKey(raw: raw, kindRaw: kindRaw)

    if kindRaw == "day" {
      kind = .day
      label = (raw["label"] as? String) ?? ""
      text = ""
      timestamp = ""
      isMe = false
      status = nil
      isEdited = false
      editedAtMs = nil
      isPinned = false
      messageId = nil
      chatId = nil
      senderUserId = nil
      replyToId = nil
      replyPreviewTitle = nil
      replyPreviewText = nil
      replyPreviewUserId = nil
      reactionEmoji = nil
      reactions = []
      viewCount = nil
      shape = BubbleShape(
        isMe: false, showTail: false, borderTopLeftRadius: 18, borderTopRightRadius: 18,
        borderBottomLeftRadius: 18, borderBottomRightRadius: 18)
      messageType = "text"
      mediaUrl = nil
      localMediaUrl = nil
      mediaKey = nil
      thumbnailBase64 = nil
      musicCoverURL = nil
      musicArtist = nil
      musicSource = nil
      isForwarded = false
      forwardedFromName = nil
      forwardedFromAvatar = nil
      forwardedFromUserId = nil
      fileName = nil
      mimeType = nil
      duration = nil
      waveform = nil
      isVideoNote = false
      viewOnce = false
      mediaTtlSeconds = nil
      uploadProgress = nil
      fileSize = nil
      mediaWidth = nil
      mediaHeight = nil
      stickerId = nil
      stickerPackId = nil
      stickerBundleFileName = nil
      isAgentMessage = false
      agentName = nil
      agentId = nil
      agentUserId = nil
      agentUsername = nil
      plainContent = nil
      isStreamingText = false
      agentProgressNodes = []
      agentActionSourceId = nil
      agentBridgeResumeSessionId = nil
      agentBridgeAttachmentsEnc = []
      attachmentThumbnailsB64 = []
      attachmentUrls = []
      attachmentMediaKeys = []
      agentActionSourceText = nil
      agentRegeneratePrompt = nil
      agentCard = nil
      agentRuntime = nil
      agentMsgKind = nil
      agentActionEnc = nil
      agentActionsEnc = nil
      relatedMessageIds = []
      relatedMessagesTitle = nil
      relatedMessagesSubtitle = nil
      isEventNotification = false
      isEventInboxSummary = false
      eventType = nil
      eventPriority = nil
      eventThreadId = nil
      eventInboxRole = nil
      hiddenFromTranscript = false
      isDeliveryFailed = false
      isAgentError = false
      serviceMessage = nil
      return
    }

    guard kindRaw == "message", let message = raw["message"] as? [String: Any] else {
      return nil
    }
    kind = .message
    label = ""
    let metadata = message["metadata"] as? [String: Any]
    let extra = message["extra"] as? [String: Any]
    let primaryText = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let captionText =
      parseNonEmptyString(message["caption"])
      ?? parseNonEmptyString(metadata?["caption"])
      ?? parseNonEmptyString(extra?["caption"])
      ?? ""
    // System notices may only carry body in metadata.text.
    let systemMetaText = parseNonEmptyString(metadata?["text"])
    text = {
      if !primaryText.isEmpty { return primaryText }
      if !captionText.isEmpty { return captionText }
      return systemMetaText ?? ""
    }()
    timestamp = (message["timestamp"] as? String) ?? ""
    isMe = (message["isMe"] as? Bool) ?? false
    status = message["status"] as? String
    isEdited = (message["isEdited"] as? Bool) ?? false
    editedAtMs = Self.int64Value(
      message["editedAt"] ?? message["edited_at"] ?? metadata?["editedAt"])
    isPinned = (message["isPinned"] as? Bool) ?? false
    messageId = parseNonEmptyString(message["id"])
    chatId =
      parseNonEmptyString(message["chatId"])
      ?? parseNonEmptyString(message["chat_id"])
      ?? parseNonEmptyString(metadata?["chatId"])
      ?? parseNonEmptyString(metadata?["chat_id"])
    senderUserId =
      parseNonEmptyString(message["from_id"])
      ?? parseNonEmptyString(message["fromId"])
      ?? parseNonEmptyString(message["senderId"])
      ?? parseNonEmptyString(message["sender_id"])
      ?? parseNonEmptyString(message["userId"])
      ?? parseNonEmptyString(message["user_id"])
      ?? parseNonEmptyString(metadata?["from_id"])
      ?? parseNonEmptyString(metadata?["senderId"])
    let replyPreview =
      (message["replyPreview"] as? [String: Any])
      ?? (message["reply_preview"] as? [String: Any])
      ?? (metadata?["replyPreview"] as? [String: Any])
      ?? (metadata?["reply_preview"] as? [String: Any])
      ?? (extra?["replyPreview"] as? [String: Any])
      ?? (extra?["reply_preview"] as? [String: Any])
    replyToId = firstNonEmptyString(
      in: [message, metadata, extra],
      keys: ["replyToId", "reply_to_id", "replyToMessageId", "reply_to_message_id"]
    )
    replyPreviewTitle = firstNonEmptyString(
      in: [message, metadata],
      keys: ["replyPreviewTitle", "reply_preview_title", "replyAuthorName", "reply_author_name"]
    ) ?? firstNonEmptyString(
      in: [replyPreview],
      keys: ["title", "senderName", "sender_name"]
    )
    replyPreviewText = firstNonEmptyString(
      in: [message, metadata],
      keys: ["replyPreviewText", "reply_preview_text", "replyText", "reply_text"]
    ) ?? firstNonEmptyString(
      in: [replyPreview],
      keys: ["text", "preview"]
    )
    replyPreviewUserId = firstNonEmptyString(
      in: [message, metadata, extra],
      keys: [
        "replyPreviewUserId", "reply_preview_user_id",
        "replyAuthorId", "reply_author_id",
      ]
    ) ?? firstNonEmptyString(
      in: [replyPreview],
      keys: [
        "replyPreviewUserId", "reply_preview_user_id",
        "replyAuthorId", "reply_author_id",
        "senderId", "sender_id",
        "userId", "user_id",
        "from_id", "fromId",
      ]
    )
    let parsedReactions = ((message["reactions"] as? [[String: Any]]) ?? []).compactMap {
      item -> Reaction? in
      guard let emoji = parseNonEmptyString(item["emoji"]),
        let count = Self.intValue(item["count"]), count > 0
      else { return nil }
      return Reaction(
        emoji: emoji,
        count: count,
        isSelected: (item["isSelected"] as? Bool) ?? (item["is_selected"] as? Bool) ?? false)
    }
    let legacyReaction = parseNonEmptyString(message["reactionEmoji"])
    reactions = parsedReactions.isEmpty
      ? legacyReaction.map { [Reaction(emoji: $0, count: 1, isSelected: true)] } ?? []
      : parsedReactions
    reactionEmoji = reactions.first?.emoji
    viewCount = Self.intValue(message["viewCount"] ?? message["view_count"])
    messageType = ((message["type"] as? String) ?? "text").lowercased()
    shape = BubbleShape.from(raw: message["bubbleShape"] as? [String: Any], isMe: isMe)

    let localMediaUrl1 = message["localMediaUrl"] as? String
    let localMediaUrl2 = message["local_media_url"] as? String
    let metaLocalMediaUrl1 = metadata?["localMediaUrl"] as? String
    let metaLocalMediaUrl2 = metadata?["local_media_url"] as? String
    localMediaUrl =
      [localMediaUrl1, localMediaUrl2, metaLocalMediaUrl1, metaLocalMediaUrl2]
      .compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }.first
    let mediaUrl1 = message["mediaUrl"] as? String
    let mediaUrl2 = message["media_url"] as? String
    let mediaUrl3 = message["uri"] as? String
    let mediaUrl4 = message["audioUrl"] as? String
    let mediaUrl5 = message["audio_url"] as? String
    let metaUrl1 = metadata?["mediaUrl"] as? String
    let metaUrl2 = metadata?["media_url"] as? String
    let metaUrl3 = metadata?["uri"] as? String
    let metaUrl4 = metadata?["audioUrl"] as? String
    let metaUrl5 = metadata?["audio_url"] as? String

    let isVoiceLike = messageType == "voice" || messageType == "music"
    var mediaUrlCandidates: [String?] = []
    if isVoiceLike {
      mediaUrlCandidates.append(contentsOf: [
        localMediaUrl1, localMediaUrl2, metaLocalMediaUrl1, metaLocalMediaUrl2,
      ])
    }
    mediaUrlCandidates.append(contentsOf: [
      mediaUrl1, mediaUrl2, mediaUrl3, mediaUrl4, mediaUrl5,
      metaUrl1, metaUrl2, metaUrl3, metaUrl4, metaUrl5,
    ])
    mediaUrl =
      mediaUrlCandidates.compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }.first
    mediaKey = firstNonEmptyString(
      in: [message, metadata],
      keys: ["mediaKey", "media_key"]
    )
    thumbnailBase64 = firstNonEmptyString(
      in: [message, metadata, extra],
      keys: ["thumbnailBase64", "thumbnail_base64"]
    )
    musicCoverURL = firstNonEmptyString(
      in: [metadata, message, extra],
      keys: ["cover", "coverUrl", "cover_url", "artwork", "artworkUrl", "artwork_url", "albumArt", "albumArtUrl"]
    )
    musicArtist = firstNonEmptyString(
      in: [metadata, message, extra],
      keys: ["artist", "uploader", "channel", "creator"]
    )
    if let rawSource = firstNonEmptyString(
      in: [metadata, message, extra],
      keys: ["source", "platform", "provider"]
    ) {
      let lower = rawSource.lowercased()
      if lower.contains("soundcloud") {
        musicSource = "SoundCloud"
      } else if lower.contains("youtu") {
        musicSource = "YouTube"
      } else {
        musicSource = rawSource.prefix(1).uppercased() + rawSource.dropFirst()
      }
    } else {
      musicSource = nil
    }
    let metaIsForwarded =
      (metadata?["isForwarded"] as? Bool) == true
      || (metadata?["is_forwarded"] as? Bool) == true
      || firstNonEmptyString(
        in: [metadata, message],
        keys: [
          "forwardedFromUserId", "forwarded_from_user_id", "forwardedFromName",
          "forwarded_from_name", "forwardedFromMessageId", "forwarded_from_message_id",
        ]
      ) != nil
    isForwarded = metaIsForwarded
    forwardedFromName = firstNonEmptyString(
      in: [metadata, message],
      keys: ["forwardedFromName", "forwarded_from_name", "forwardedFromTitle", "forwarded_from_title"]
    )
    forwardedFromAvatar = firstNonEmptyString(
      in: [metadata, message],
      keys: [
        "forwardedFromAvatar", "forwarded_from_avatar", "forwardedFromAvatarUrl",
        "forwarded_from_avatar_url",
      ]
    )
    forwardedFromUserId = firstNonEmptyString(
      in: [metadata, message],
      keys: ["forwardedFromUserId", "forwarded_from_user_id"]
    )
    fileName =
      (message["fileName"] as? String)
      ?? (message["file_name"] as? String)
      ?? (metadata?["fileName"] as? String)
      ?? (metadata?["file_name"] as? String)
      ?? (metadata?["title"] as? String)
    mimeType =
      (message["mimeType"] as? String)
      ?? (message["mime_type"] as? String)
      ?? (metadata?["mimeType"] as? String)
      ?? (metadata?["mime_type"] as? String)
      ?? (metadata?["mime"] as? String)
    duration =
      parseDouble(message["duration"])
      ?? parseDouble(metadata?["durationSeconds"])
      ?? parseDouble(metadata?["duration_seconds"])
      ?? parseDouble(metadata?["duration"])
    waveform =
      parseWaveform(message["waveform"])
      ?? parseWaveform(metadata?["waveform"])
    isVideoNote =
      (message["isVideoNote"] as? Bool)
      ?? (metadata?["isVideoNote"] as? Bool)
      ?? false
    viewOnce =
      parseBool(message["viewOnce"] ?? message["view_once"])
      ?? parseBool(metadata?["viewOnce"] ?? metadata?["view_once"])
      ?? false
    mediaTtlSeconds =
      parseLong(message["mediaTtlSeconds"] ?? message["media_ttl_seconds"]).map(Int.init)
      ?? parseLong(metadata?["mediaTtlSeconds"] ?? metadata?["media_ttl_seconds"]).map(Int.init)
    uploadProgress =
      parseDouble(message["uploadProgress"])
      ?? parseDouble(message["upload_progress"])
      ?? parseDouble(metadata?["uploadProgress"])
      ?? parseDouble(metadata?["upload_progress"])
    fileSize = {
      let raw =
        parseLong(message["fileSize"])
        ?? parseLong(message["file_size"])
        ?? parseLong(metadata?["fileSize"])
        ?? parseLong(metadata?["file_size"])
      return raw
    }()

    let stickerContainers: [[String: Any]?] = [message, metadata, extra]
    mediaWidth =
      parseDouble(message["width"]) ?? parseDouble(metadata?["width"])
      ?? parseDouble(extra?["width"])
    mediaHeight =
      parseDouble(message["height"]) ?? parseDouble(metadata?["height"])
      ?? parseDouble(extra?["height"])

    // Sticker pack fields
    stickerId = firstNonEmptyString(
      in: stickerContainers,
      keys: ["stickerId", "sticker_id"]
    )
    stickerPackId = firstNonEmptyString(
      in: stickerContainers,
      keys: ["stickerPackId", "packId", "pack_id"]
    )
    stickerBundleFileName = firstNonEmptyString(
      in: stickerContainers,
      keys: ["stickerBundleFileName", "bundleFileName", "bundle_file_name"]
    )

    if messageType == "sticker", stickerId == nil || stickerPackId == nil {
      let metadataKeys = metadata?.keys.sorted().joined(separator: ",") ?? "-"
      let extraKeys = extra?.keys.sorted().joined(separator: ",") ?? "-"
      NSLog(
        "[ChatStickerRow] metadata incomplete msgId=%@ stickerId=%@ packId=%@ bundle=%@ mediaUrl=%@ metadataKeys=%@ extraKeys=%@",
        messageId ?? "-",
        stickerId ?? "-",
        stickerPackId ?? "-",
        stickerBundleFileName ?? "-",
        mediaUrl ?? "-",
        metadataKeys,
        extraKeys
      )
    }

    // Agent message fields
    isAgentMessage = (message["isAgentMessage"] as? Bool) ?? false
    agentName = firstNonEmptyString(
      in: [message, metadata],
      keys: ["agentName", "agent_name"]
    )
    agentId = firstNonEmptyString(
      in: [message, metadata],
      keys: ["agentId", "agent_id"]
    )
    agentUserId = firstNonEmptyString(
      in: [message, metadata],
      keys: ["agentUserId", "agent_user_id"]
    )
    agentUsername =
      firstNonEmptyString(
        in: [message, metadata],
        keys: ["agentUsername", "agent_username", "agentHandle", "agent_handle"]
      )?.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    plainContent = message["plainContent"] as? String
    agentProgressNodes = parseAgentProgressNodes(metadata?["progressNodes"])
    isStreamingText =
      (message["isStreaming"] as? Bool)
      ?? (metadata?["isStreaming"] as? Bool)
      ?? false
    agentActionSourceId = firstNonEmptyString(
      in: [metadata, message],
      keys: ["sourceMessageId", "actionSourceId", "agentActionSourceId", "replyToId", "reply_to_id"]
    ) ?? replyToId
    agentBridgeResumeSessionId = firstNonEmptyString(
      in: [metadata, message],
      keys: ["agentBridgeResumeSessionId", "agent_bridge_resume_session_id"]
    )
    agentBridgeAttachmentsEnc = uniqueStrings(
      parseStringArray(metadata?["agentBridgeAttachmentsEnc"])
        + parseStringArray(metadata?["agent_bridge_attachments_enc"])
        + parseStringArray(metadata?["attachmentsEnc"])
        + parseStringArray(metadata?["attachments_enc"])
        + parseStringArray(message["agentBridgeAttachmentsEnc"])
        + parseStringArray(message["agent_bridge_attachments_enc"])
        + parseStringArray(message["attachmentsEnc"])
        + parseStringArray(message["attachments_enc"])
    )
    attachmentThumbnailsB64 = uniqueStrings(
      parseStringArray(metadata?["attachmentThumbnailsB64"])
        + parseStringArray(metadata?["attachment_thumbnails_b64"])
        + parseStringArray(message["attachmentThumbnailsB64"])
        + parseStringArray(message["attachment_thumbnails_b64"])
    )
    // NOT de-duplicated, and not concatenated across sources: these two are
    // index-aligned with each other and with the thumbs, so dropping a repeat or
    // appending a second source would silently pair a picture with another
    // picture's key.
    let parsedAttachmentUrls =
      parseStringArray(metadata?["attachmentUrls"]).isEmpty
      ? parseStringArray(message["attachmentUrls"])
      : parseStringArray(metadata?["attachmentUrls"])
    let parsedAttachmentKeys =
      parseStringArray(metadata?["attachmentMediaKeys"]).isEmpty
      ? parseStringArray(message["attachmentMediaKeys"])
      : parseStringArray(metadata?["attachmentMediaKeys"])
    attachmentUrls = parsedAttachmentUrls
    attachmentMediaKeys =
      parsedAttachmentKeys.count == parsedAttachmentUrls.count
      ? parsedAttachmentKeys
      : Array(repeating: "", count: parsedAttachmentUrls.count)
    agentActionSourceText = firstNonEmptyString(
      in: [metadata, message],
      keys: ["sourceText", "actionSourceText"]
    ) ?? plainContent
    agentRegeneratePrompt = firstNonEmptyString(
      in: [metadata, message],
      keys: ["regeneratePrompt"]
    )
    agentCard =
      AgentCard.parse(message["agentCard"] as? [String: Any] ?? [:])
      ?? AgentCard.parse(metadata?["agentCard"] as? [String: Any] ?? [:])
    let rawAgentRuntimeForLog =
      metadata?["agentRuntime"] ?? metadata?["agent_runtime"] ?? message["agentRuntime"]
        ?? message["agent_runtime"]
    // Probe only under -VibeVerboseLogs: this init runs for EVERY agent row on EVERY
    // setRows pass, and an always-on NSLog here (hundreds per streamed frame) is a
    // measurable share of the main-thread stall users feel as list jank.
    if VibeDebugLog.verboseEnabled, metadata?["agentWorker"] != nil || rawAgentRuntimeForLog != nil {
      NSLog(
        "[AgentView] rowparse msg=\(parseNonEmptyString(message["id"] ?? message["messageId"]) ?? "?") "
          + "agentWorker=\(metadata?["agentWorker"] ?? "nil") via=\(metadata?["agentWorkerVia"] ?? "nil") "
          + "rawRuntime?=\(rawAgentRuntimeForLog != nil) metaKeys=\((metadata ?? [:]).keys.sorted()) "
          + "progressNodes=\((metadata?["progressNodes"] as? [[String: Any]])?.count ?? -1)")
    }
    // New bridges send the runtime end-to-end encrypted (`agentRuntimeEnc`); the
    // server stores only opaque ciphertext. Decrypt locally with the paired key.
    // Falls back to the legacy plaintext `agentRuntime` for older messages.
    let decryptedRuntime = AgentRuntimeCrypto.decrypt(
      metadata?["agentRuntimeEnc"] ?? message["agentRuntimeEnc"])
    if VibeDebugLog.verboseEnabled,
      metadata?["agentRuntimeEnc"] != nil || message["agentRuntimeEnc"] != nil
    {
      NSLog(
        "[AgentView] rowparse enc present decrypted=\(decryptedRuntime != nil) hasKey=\(AgentRuntimeCrypto.hasKey)"
      )
    }
    agentRuntime =
      parseAgentRuntimeSummary(rawAgentRuntimeForLog)
      ?? parseAgentRuntimeSummary(decryptedRuntime)
    agentMsgKind = firstNonEmptyString(in: [metadata, message], keys: ["agentMsgKind", "agent_msg_kind"])
    agentActionEnc = firstNonEmptyString(in: [metadata, message], keys: ["agentActionEnc", "agent_action_enc"])
    agentActionsEnc = firstNonEmptyString(in: [metadata, message], keys: ["agentActionsEnc", "agent_actions_enc"])
    relatedMessageIds = uniqueStrings(
      parseStringArray(metadata?["relatedMessageIds"])
        + parseStringArray(metadata?["related_message_ids"])
        + parseStringArray(message["relatedMessageIds"])
        + parseStringArray(message["related_message_ids"])
    )
    relatedMessagesTitle = firstNonEmptyString(
      in: [metadata, message],
      keys: ["relatedMessagesTitle", "related_messages_title"]
    )
    relatedMessagesSubtitle = firstNonEmptyString(
      in: [metadata, message],
      keys: ["relatedMessagesSubtitle", "related_messages_subtitle"]
    )
    let eventInboxSummaryFlag =
      (parseBool(metadata?["eventInboxSummary"]) ?? parseBool(metadata?["event_inbox_summary"]))
      ?? (parseBool(message["eventInboxSummary"]) ?? parseBool(message["event_inbox_summary"]))
      ?? false
    let eventThreadFlag =
      (parseBool(metadata?["eventThread"]) ?? parseBool(metadata?["event_thread"]))
      ?? (parseBool(message["eventThread"]) ?? parseBool(message["event_thread"]))
      ?? false
    isEventInboxSummary = eventInboxSummaryFlag
    isEventNotification = eventThreadFlag || eventInboxSummaryFlag
    eventType = firstNonEmptyString(
      in: [metadata, message],
      keys: ["eventType", "event_type"]
    )
    eventPriority = firstNonEmptyString(
      in: [metadata, message],
      keys: ["priority", "eventPriority", "event_priority"]
    )
    eventThreadId = firstNonEmptyString(
      in: [metadata, message],
      keys: ["eventThreadId", "event_thread_id"]
    )
    eventInboxRole = firstNonEmptyString(
      in: [metadata, message],
      keys: ["eventInboxRole", "event_inbox_role"]
    )?.lowercased()
    let explicitHiddenFromTranscript =
      (parseBool(metadata?["hiddenFromTranscript"]) ?? parseBool(metadata?["hidden_from_transcript"]))
      ?? (parseBool(message["hiddenFromTranscript"]) ?? parseBool(message["hidden_from_transcript"]))
      ?? false
    hiddenFromTranscript =
      explicitHiddenFromTranscript
      || eventInboxRole == "raw_event"
      || eventInboxRole == "inbox_item"
    isDeliveryFailed =
      (message["deliveryFailed"] as? Bool)
      ?? (message["delivery_failed"] as? Bool)
      ?? false
    isAgentError =
      (message["isError"] as? Bool)
      ?? (message["is_error"] as? Bool)
      ?? false
    serviceMessage =
      ChatServiceMessage.parse(metadata?["service"])
      ?? ChatServiceMessage.parse(message["service"])
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? UInt64 { return Int(clamping: value) }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private static func int64Value(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? UInt64 { return Int64(clamping: value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
  }
}

private func bubbleShapeEqual(_ lhs: BubbleShape, _ rhs: BubbleShape) -> Bool {
  let epsilon: CGFloat = 0.1
  return lhs.isMe == rhs.isMe && lhs.showTail == rhs.showTail
    && abs(lhs.borderTopLeftRadius - rhs.borderTopLeftRadius) <= epsilon
    && abs(lhs.borderTopRightRadius - rhs.borderTopRightRadius) <= epsilon
    && abs(lhs.borderBottomLeftRadius - rhs.borderBottomLeftRadius) <= epsilon
    && abs(lhs.borderBottomRightRadius - rhs.borderBottomRightRadius) <= epsilon
}

private func parseLong(_ raw: Any?) -> Int64? {
  if let value = raw as? NSNumber { return value.int64Value }
  if let value = raw as? Int64 { return value }
  if let value = raw as? Int { return Int64(value) }
  if let value = raw as? Double, value.isFinite { return Int64(value) }
  if let value = raw as? String { return Int64(value) }
  return nil
}

private func parseDouble(_ raw: Any?) -> Double? {
  if let value = raw as? NSNumber {
    return value.doubleValue
  }
  if let value = raw as? Double {
    return value
  }
  if let value = raw as? Int {
    return Double(value)
  }
  if let value = raw as? String {
    return Double(value)
  }
  return nil
}

private func parseNonEmptyString(_ raw: Any?) -> String? {
  if let value = raw as? String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let value = raw as? NSNumber {
    return value.stringValue
  }
  if let value = raw as? Int {
    return String(value)
  }
  if let value = raw as? Double, value.isFinite {
    return String(value)
  }
  return nil
}

private let videoMediaExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
private let imageMediaExtensions: Set<String> = [
  "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp",
]
private let audioMediaExtensions: Set<String> = [
  "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "oga", "opus", "caf", "alac",
]

private func normalizedMediaExtension(_ value: String?) -> String? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  let pathExtension: String
  // `URL(string:)` is only needed to keep a query string out of the extension. Parsing a
  // bare file name through it costs the same as parsing a URL, and this runs per row per
  // sizing pass — `isVideoMediaReference` was the top frame of a 0.44s main-thread hang.
  if trimmed.contains("?") || trimmed.contains("#"), let url = URL(string: trimmed),
    !url.pathExtension.isEmpty
  {
    pathExtension = url.pathExtension
  } else {
    pathExtension = (trimmed as NSString).pathExtension
  }
  guard !pathExtension.isEmpty else { return nil }
  let normalized = pathExtension.hasPrefix(".")
    ? String(pathExtension.dropFirst()).lowercased() : pathExtension.lowercased()
  return normalized.isEmpty ? nil : normalized
}

/// Both references' extensions, resolved once. `visualKind` asks three questions about
/// the same pair, and resolving per question parsed each string three times over.
struct ChatMediaReferenceExtensions {
  let fileNameExt: String?
  let mediaUrlExt: String?

  init(mediaUrl: String?, fileName: String?) {
    fileNameExt = normalizedMediaExtension(fileName)
    mediaUrlExt = normalizedMediaExtension(mediaUrl)
  }

  private func matches(_ set: Set<String>) -> Bool {
    if let fileNameExt, set.contains(fileNameExt) { return true }
    if let mediaUrlExt, set.contains(mediaUrlExt) { return true }
    return false
  }

  var isVideo: Bool { matches(videoMediaExtensions) }
  var isImage: Bool { matches(imageMediaExtensions) }
  var isAudio: Bool { matches(audioMediaExtensions) }
}

private func isVideoMediaReference(mediaUrl: String?, fileName: String?) -> Bool {
  ChatMediaReferenceExtensions(mediaUrl: mediaUrl, fileName: fileName).isVideo
}

private func isImageMediaReference(mediaUrl: String?, fileName: String?) -> Bool {
  ChatMediaReferenceExtensions(mediaUrl: mediaUrl, fileName: fileName).isImage
}

private func isAudioMediaReference(mediaUrl: String?, fileName: String?) -> Bool {
  ChatMediaReferenceExtensions(mediaUrl: mediaUrl, fileName: fileName).isAudio
}

private func firstNonEmptyString(
  in containers: [[String: Any]?],
  keys: [String]
) -> String? {
  for container in containers {
    guard let container else { continue }
    for key in keys {
      if let value = parseNonEmptyString(container[key]) {
        return value
      }
    }
  }
  return nil
}

private func normalizedWaveformSamples(from rawList: [Any]) -> [CGFloat]? {
  let mapped: [CGFloat] = rawList.compactMap { item in
    if let num = item as? NSNumber {
      return CGFloat(truncating: num)
    }
    if let dbl = item as? Double {
      return CGFloat(dbl)
    }
    if let int = item as? Int {
      return CGFloat(int)
    }
    if let str = item as? String, let dbl = Double(str) {
      return CGFloat(dbl)
    }
    return nil
  }
  let normalized =
    mapped
    .filter { $0.isFinite }
    .map { max(0.0, min(1.0, $0)) }
  return normalized.isEmpty ? nil : normalized
}

private func waveformBitValue(
  data: UnsafeRawPointer,
  length: Int,
  bitOffset: Int,
  bitWidth: Int
) -> Int32 {
  guard length > 0, bitWidth > 0 else { return 0 }

  let byteOffset = bitOffset / 8
  guard byteOffset < length else { return 0 }

  let normalizedData = data.advanced(by: byteOffset)
  let normalizedBitOffset = bitOffset % 8
  let mask = UInt32((1 << bitWidth) - 1)

  var value: UInt32 = 0
  let bytesToCopy = min(MemoryLayout<UInt32>.size, length - byteOffset)
  memcpy(&value, normalizedData, bytesToCopy)

  return Int32((value >> UInt32(normalizedBitOffset)) & mask)
}

private func decodeTelegramWaveformBitstream(_ data: Data, bitsPerSample: Int = 5) -> [CGFloat]? {
  guard !data.isEmpty, bitsPerSample > 0 else { return nil }

  let sampleCount = (data.count * 8) / bitsPerSample
  guard sampleCount > 0 else { return nil }

  let maxValue = CGFloat((1 << bitsPerSample) - 1)
  guard maxValue > 0 else { return nil }

  var result: [CGFloat] = []
  result.reserveCapacity(sampleCount)

  data.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return }
    for index in 0..<sampleCount {
      let value = waveformBitValue(
        data: baseAddress,
        length: data.count,
        bitOffset: index * bitsPerSample,
        bitWidth: bitsPerSample
      )
      result.append(max(0.0, min(1.0, CGFloat(value) / maxValue)))
    }
  }

  return result.isEmpty ? nil : result
}

private func parseWaveform(_ raw: Any?) -> [CGFloat]? {
  if let array = raw as? [Any], !array.isEmpty {
    return normalizedWaveformSamples(from: array)
  }

  if let nsArray = raw as? NSArray, nsArray.count > 0 {
    return normalizedWaveformSamples(from: nsArray.compactMap { $0 })
  }

  if let data = raw as? Data {
    return decodeTelegramWaveformBitstream(data)
  }

  if let text = raw as? String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("["),
      let jsonData = trimmed.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: jsonData),
      let array = json as? [Any]
    {
      return normalizedWaveformSamples(from: array)
    }

    if let data = Data(base64Encoded: trimmed),
      let decoded = decodeTelegramWaveformBitstream(data)
    {
      return decoded
    }

    let tokens = trimmed.split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
    if !tokens.isEmpty {
      return normalizedWaveformSamples(from: tokens.map(String.init))
    }
  }

  return nil
}

private func optionalDoubleEqual(_ lhs: Double?, _ rhs: Double?, epsilon: Double = 0.0001) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case (let l?, let r?):
    return abs(l - r) <= epsilon
  default:
    return false
  }
}

private func optionalWaveformEqual(_ lhs: [CGFloat]?, _ rhs: [CGFloat]?, epsilon: CGFloat = 0.001)
  -> Bool
{
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case (let l?, let r?):
    guard l.count == r.count else { return false }
    for (a, b) in zip(l, r) {
      if abs(a - b) > epsilon {
        return false
      }
    }
    return true
  default:
    return false
  }
}

func chatListRowContentEqual(_ lhs: ChatListRow, _ rhs: ChatListRow) -> Bool {
  return lhs.kind == rhs.kind && lhs.key == rhs.key && lhs.label == rhs.label
    && lhs.text == rhs.text && lhs.timestamp == rhs.timestamp && lhs.isMe == rhs.isMe
    && lhs.status == rhs.status
    && lhs.isEdited == rhs.isEdited && lhs.editedAtMs == rhs.editedAtMs
    && lhs.isPinned == rhs.isPinned && lhs.messageId == rhs.messageId
    && lhs.reactions == rhs.reactions && lhs.viewCount == rhs.viewCount
    // Render-aware: agent-turn bubbles never render reply bands (zero replyPreview
    // reads in the whole VibeAgentKit stack), and reply fields on agent rows are
    // pipeline-unstable — they ride only the live delivery, so history/store copies
    // flip nil↔value forever after. Comparing them repaints (and re-measures) rows
    // whose rendered pixels are identical: the mode=batch changed=73 post-push
    // flicker/shift on every reply-heavy team-chat open.
    && (lhs.isAgentMessage
      || (lhs.replyToId == rhs.replyToId
        && lhs.replyPreviewTitle == rhs.replyPreviewTitle
        && lhs.replyPreviewText == rhs.replyPreviewText
        && lhs.replyPreviewUserId == rhs.replyPreviewUserId))
    && lhs.messageType == rhs.messageType
    && lhs.mediaUrl == rhs.mediaUrl && lhs.localMediaUrl == rhs.localMediaUrl
    && lhs.mediaKey == rhs.mediaKey && lhs.fileName == rhs.fileName
    && lhs.mimeType == rhs.mimeType
    && lhs.musicCoverURL == rhs.musicCoverURL
    && lhs.musicArtist == rhs.musicArtist
    && lhs.musicSource == rhs.musicSource
    && lhs.isForwarded == rhs.isForwarded
    && lhs.forwardedFromName == rhs.forwardedFromName
    && lhs.forwardedFromAvatar == rhs.forwardedFromAvatar
    && lhs.forwardedFromUserId == rhs.forwardedFromUserId
    && optionalDoubleEqual(lhs.duration, rhs.duration) && lhs.isVideoNote == rhs.isVideoNote
    && lhs.viewOnce == rhs.viewOnce && lhs.mediaTtlSeconds == rhs.mediaTtlSeconds
    && optionalWaveformEqual(lhs.waveform, rhs.waveform)
    && optionalDoubleEqual(lhs.uploadProgress, rhs.uploadProgress)
    && lhs.fileSize == rhs.fileSize
    && bubbleShapeEqual(lhs.shape, rhs.shape)
    && lhs.stickerId == rhs.stickerId
    && lhs.stickerPackId == rhs.stickerPackId
    && lhs.stickerBundleFileName == rhs.stickerBundleFileName
    && lhs.isAgentMessage == rhs.isAgentMessage
    && lhs.agentName == rhs.agentName
    && lhs.agentId == rhs.agentId
    && lhs.agentUserId == rhs.agentUserId
    && lhs.agentUsername == rhs.agentUsername
    && lhs.plainContent == rhs.plainContent
    && lhs.isStreamingText == rhs.isStreamingText
    && lhs.agentProgressNodes == rhs.agentProgressNodes
    && lhs.agentActionSourceId == rhs.agentActionSourceId
    && lhs.agentActionSourceText == rhs.agentActionSourceText
    && lhs.agentRegeneratePrompt == rhs.agentRegeneratePrompt
    && lhs.agentCard == rhs.agentCard
    && lhs.agentRuntime == rhs.agentRuntime
    && lhs.agentMsgKind == rhs.agentMsgKind
    && lhs.agentActionEnc == rhs.agentActionEnc
    && lhs.agentActionsEnc == rhs.agentActionsEnc
    && lhs.relatedMessageIds == rhs.relatedMessageIds
    && lhs.relatedMessagesTitle == rhs.relatedMessagesTitle
    && lhs.relatedMessagesSubtitle == rhs.relatedMessagesSubtitle
    && lhs.isEventNotification == rhs.isEventNotification
    && lhs.isEventInboxSummary == rhs.isEventInboxSummary
    && lhs.eventType == rhs.eventType
    && lhs.eventPriority == rhs.eventPriority
    && lhs.eventThreadId == rhs.eventThreadId
    && lhs.eventInboxRole == rhs.eventInboxRole
    && lhs.hiddenFromTranscript == rhs.hiddenFromTranscript
    && lhs.isDeliveryFailed == rhs.isDeliveryFailed
    && lhs.isAgentError == rhs.isAgentError
    && lhs.serviceMessage == rhs.serviceMessage
}

/// Stable (cross-launch) FNV-1a hash — used for persisted-height validation.
private func chatListStableHashHex(_ string: String) -> String {
  var hash: UInt64 = 0xcbf2_9ce4_8422_2325
  for byte in string.utf8 {
    hash ^= UInt64(byte)
    hash = hash &* 0x0000_0100_0000_01b3
  }
  return String(hash, radix: 16)
}

/// Content signature covering the SAME fields as `chatListRowContentEqual` above —
/// keep the two in sync. Rows with equal signatures must have equal layout inputs,
/// so a disk-persisted measured height may be reused across launches. Complex value
/// fields go through `String(describing:)`, which is deterministic for the value
/// types ChatListRow stores; a mismatch is always safe (the row is just re-measured).
/// Single source of truth for the height-validity signature: `(fieldName, value)`
/// per component. `chatListRowContentSignature` hashes the values; the persisted-
/// height miss diagnostic diffs the values field-by-field to NAME the one that
/// flipped between measure-time and reopen (a wrong guess at the culprit removes a
/// height-relevant field and makes the jump worse — so we identify, never guess).
func chatListRowSignatureFields(_ row: ChatListRow) -> [(name: String, value: String)] {
  return [
    ("kind", String(describing: row.kind)), ("key", row.key), ("label", row.label),
    ("text", row.text), ("timestamp", row.timestamp), ("isMe", String(row.isMe)),
    ("status", String(describing: row.status)), ("isEdited", String(row.isEdited)),
    ("isPinned", String(row.isPinned)), ("messageId", String(describing: row.messageId)),
    ("reactionEmoji", String(describing: row.reactionEmoji)),
    // Keep in sync with chatListRowContentEqual: reply fields are render-inert and
    // pipeline-unstable on agent rows — a stable placeholder keeps persisted heights
    // valid across the nil↔value flips (was: 8 reason=sig promote misses per open).
    ("replyToId", row.isAgentMessage ? "-" : String(describing: row.replyToId)),
    ("replyPreviewTitle", row.isAgentMessage ? "-" : String(describing: row.replyPreviewTitle)),
    ("replyPreviewText", row.isAgentMessage ? "-" : String(describing: row.replyPreviewText)),
    // Neutral for EVERY row, not just agent rows: the reply author's id has no effect on
    // any measurement, and it is resolved LATE (the reply-preview pass fills nil→uuid ~2s
    // after open — `[ChatOpen] parse reuse-MISS … fields=[message.replyPreviewUserId=77]`).
    // Heights are persisted after that pass and audited before it, so including it made
    // every reply row fail its signature audit on the next open and re-measure on screen.
    ("replyPreviewUserId", "-"),
    ("messageType", row.messageType), ("mediaUrl", String(describing: row.mediaUrl)),
    ("localMediaUrl", String(describing: row.localMediaUrl)),
    ("mediaKey", String(describing: row.mediaKey)), ("fileName", String(describing: row.fileName)),
    ("musicCoverURL", String(describing: row.musicCoverURL)),
    ("musicArtist", String(describing: row.musicArtist)),
    ("musicSource", String(describing: row.musicSource)),
    ("isForwarded", String(row.isForwarded)),
    ("forwardedFromName", String(describing: row.forwardedFromName)),
    ("forwardedFromAvatar", String(describing: row.forwardedFromAvatar)),
    ("forwardedFromUserId", String(describing: row.forwardedFromUserId)),
    ("duration", String(describing: row.duration)), ("isVideoNote", String(row.isVideoNote)),
    ("waveform", String(describing: row.waveform)),
    ("uploadProgress", String(describing: row.uploadProgress)),
    ("fileSize", String(describing: row.fileSize)),
    // Neutral, same reasoning as `replyPreviewUserId`: nothing in BubbleShape can change a
    // row's HEIGHT. The tail is drawn outside the bubble's bounds (see `applyShapePath`'s
    // paintRect overhang) and the four radii are cosmetic; `isMe`, the one shape field that
    // does move layout, is already its own component above. Meanwhile the value is
    // session-unstable: `rowsByApplyingNativeOutgoingSequenceShape` patches the corner radii
    // and tail of messages you sent in THIS session, so the height is persisted with merged
    // radii and re-read on the next launch with plain 18s — the row then fails its audit and
    // re-measures on screen for a difference that cannot move it (observed as
    // `height-audit stale=1 … sig=1 flipped=[shape=1]`, shifted=0). Keep the slot rather than
    // dropping the tuple: `chatListRowSignatureFlippedFieldNames` diffs positionally against
    // already-persisted `f` arrays, and removing an entry would misname every field after it.
    ("shape", "-"),
    ("stickerId", String(describing: row.stickerId)),
    ("stickerPackId", String(describing: row.stickerPackId)),
    ("stickerBundleFileName", String(describing: row.stickerBundleFileName)),
    ("isAgentMessage", String(row.isAgentMessage)),
    ("agentName", String(describing: row.agentName)), ("agentId", String(describing: row.agentId)),
    ("agentUserId", String(describing: row.agentUserId)),
    ("agentUsername", String(describing: row.agentUsername)),
    ("plainContent", String(describing: row.plainContent)),
    ("isStreamingText", String(row.isStreamingText)),
    ("agentProgressNodes", String(describing: row.agentProgressNodes)),
    ("agentActionSourceId", String(describing: row.agentActionSourceId)),
    ("agentActionSourceText", String(describing: row.agentActionSourceText)),
    ("agentRegeneratePrompt", String(describing: row.agentRegeneratePrompt)),
    ("agentCard", String(describing: row.agentCard)),
    ("agentRuntime", String(describing: row.agentRuntime)),
    ("agentMsgKind", String(describing: row.agentMsgKind)),
    ("agentActionEnc", String(describing: row.agentActionEnc)),
    ("agentActionsEnc", String(describing: row.agentActionsEnc)),
    ("relatedMessageIds", String(describing: row.relatedMessageIds)),
    ("relatedMessagesTitle", String(describing: row.relatedMessagesTitle)),
    ("relatedMessagesSubtitle", String(describing: row.relatedMessagesSubtitle)),
    ("isEventNotification", String(row.isEventNotification)),
    ("isEventInboxSummary", String(row.isEventInboxSummary)),
    ("eventType", String(describing: row.eventType)),
    ("eventPriority", String(describing: row.eventPriority)),
    ("eventThreadId", String(describing: row.eventThreadId)),
    ("eventInboxRole", String(describing: row.eventInboxRole)),
    ("hiddenFromTranscript", String(row.hiddenFromTranscript)),
    ("isDeliveryFailed", String(row.isDeliveryFailed)), ("isAgentError", String(row.isAgentError)),
    // Appended LAST — the flipped-field diff is positional against persisted arrays.
    // Emoji + count only: those set the strip width and its wrap; isSelected is a tint.
    ("reactions", row.reactions.map { "\($0.emoji)x\($0.count)" }.joined(separator: ",")),
  ]
}

func chatListRowContentSignature(_ row: ChatListRow) -> String {
  let joined = chatListRowSignatureFields(row).map(\.value).joined(separator: "\u{1F}")
  return chatListStableHashHex(joined) + ".\(joined.utf8.count)"
}

/// Per-field short hashes of the content signature, positionally aligned with
/// `chatListRowSignatureFields`. Persisted (agent rows only) so a `reason=sig` miss
/// can name the flipped field.
func chatListRowSignatureFieldHashes(_ row: ChatListRow) -> [String] {
  chatListRowSignatureFields(row).map { chatListStableHashHex($0.value) }
}

/// Names of the signature fields whose current hash differs from the persisted one.
func chatListRowSignatureFlippedFieldNames(
  _ row: ChatListRow, against persisted: [String]
) -> [String] {
  let current = chatListRowSignatureFields(row)
  var flipped: [String] = []
  for (i, comp) in current.enumerated() where i < persisted.count {
    if chatListStableHashHex(comp.value) != persisted[i] {
      flipped.append(comp.name)
    }
  }
  return flipped
}

private func progressNodeLabel(from item: [String: Any]) -> String? {
  let textKeys = ["label", "title", "text", "content", "message", "summary"]
  for key in textKeys {
    if let value = parseNonEmptyString(item[key]) {
      return value
    }
  }

  let kind = parseNonEmptyString(item["kind"] ?? item["itemType"])?.lowercased()
  let target =
    parseNonEmptyString(
      item["target"] ?? item["path"] ?? item["file_path"] ?? item["filePath"])

  func verbLabel(_ verb: String) -> String {
    if let target, !target.isEmpty {
      return "\(verb) \(target)"
    }
    return verb
  }

  switch kind {
  case "thinking":
    return "Thinking"
  case "todo":
    let action = (item["action"] as? String)?.lowercased() ?? ""
    if action == "create" || action == "created" {
      return "Created Task"
    } else if action == "update" || action == "updated" {
      return "Updated Task"
    }
    return "Create Task or Update Task"
  case "read":
    return verbLabel("Read")
  case "edit":
    return verbLabel("Edit")
  case "write":
    return verbLabel("Create")
  case "bash":
    return verbLabel("Run")
  case "search":
    return verbLabel("Search")
  case "web":
    return verbLabel("Fetch")
  case "task":
    return verbLabel("Step")
  case let value? where !value.isEmpty:
    return verbLabel(value.prefix(1).uppercased() + String(value.dropFirst()))
  default:
    return target
  }
}

func parseAgentProgressNodesPublic(_ raw: Any?) -> [ChatListRow.AgentProgressNode] {
  parseAgentProgressNodes(raw)
}

private func parseAgentProgressNodes(_ raw: Any?) -> [ChatListRow.AgentProgressNode] {
  guard let items = raw as? [[String: Any]] else {
    // DIAGNOSTIC (text-in-live-feed): the payload isn't even an array of dicts.
    if raw != nil {
      NSLog(
        "[AgentNodes] raw NOT [[String:Any]] type=%@",
        String(describing: type(of: raw!)))
    }
    return []
  }

  // DIAGNOSTIC (text-in-live-feed): keep logging malformed nodes, but first try
  // the known Codex/bridge fallback fields so future payloads do not disappear.
  var dropped: [String] = []
  let nodes: [ChatListRow.AgentProgressNode] = items.compactMap { item in
    guard let label = progressNodeLabel(from: item) else {
      let kind = parseNonEmptyString(item["kind"]) ?? "?"
      dropped.append(kind)
      NSLog(
        "[AgentNodes] DROP kind=%@ keys=[%@] textKey=%@ contentKey=%@ messageKey=%@",
        kind,
        item.keys.sorted().joined(separator: ","),
        String(describing: item["text"] ?? "—").prefix(48).description,
        String(describing: item["content"] ?? "—").prefix(48).description,
        String(describing: item["message"] ?? "—").prefix(48).description)
      return nil
    }
    let id = parseNonEmptyString(item["id"]) ?? UUID().uuidString
    let status = parseNonEmptyString(item["status"]) ?? "running"
    let depth = Int(parseLong(item["depth"]) ?? 0)

    let detail =
      parseNonEmptyString(item["detail"])
      ?? parseNonEmptyString(item["output"])
      ?? parseNonEmptyString(item["messageContent"])
    return ChatListRow.AgentProgressNode(
      id: id,
      label: label,
      status: status,
      depth: max(0, depth),
      kind: parseNonEmptyString(item["kind"])?.lowercased(),
      target: parseNonEmptyString(item["target"]),
      added: parseLong(item["added"]).map { Int($0) },
      removed: parseLong(item["removed"]).map { Int($0) },
      start: parseLong(item["start"]).map { Int($0) },
      end: parseLong(item["end"]).map { Int($0) },
      parentId: parseNonEmptyString(item["parentId"]),
      subagentType: parseNonEmptyString(item["subagentType"]),
      tokens: parseLong(item["tokens"]).map { Int($0) },
      durationMs: parseLong(item["durationMs"]).map { Int($0) },
      action: parseNonEmptyString(item["action"]),
      detail: detail,
      tool: parseNonEmptyString(item["tool"])?.lowercased()
    )
  }

  // DIAGNOSTIC (text-in-live-feed): one summary per parse — how many text nodes
  // survived vs. were dropped. textKept=0 with raw>0 means the prose never arrives
  // as a node at all (it's in the message body, suppressed mid-stream).
  if VibeDebugLog.verboseEnabled, !items.isEmpty {
    let textKept = nodes.filter { $0.kind == "text" }.count
    NSLog(
      "[AgentNodes] parsed raw=%d kept=%d textKept=%d dropped=[%@] kinds=[%@]",
      items.count, nodes.count, textKept, dropped.joined(separator: ","),
      nodes.map { $0.kind ?? "nil" }.joined(separator: ","))
  }
  return nodes
}

// Module-internal (not file-private) so the agent-bridge history renderer can
// reuse it to parse the decrypted runtime card for locally-run sessions.
func parseAgentRuntimeSummary(_ raw: Any?) -> ChatListRow.AgentRuntimeSummary? {
  guard let object = raw as? [String: Any] else {
    return nil
  }
  let diff = parseAgentRuntimeDiff(object["diff"])
  let command = parseAgentRuntimeCommand(object["command"])
  let controls = parseAgentRuntimeControls(object["controls"])
  let usage = parseAgentRuntimeUsage(object["usage"])
  let mcpServers = parseAgentRuntimeMCPServers(object["mcpServers"] ?? object["mcp_servers"])
  let status = parseNonEmptyString(object["status"]) ?? "done"

  return ChatListRow.AgentRuntimeSummary(
    taskId: parseNonEmptyString(object["taskId"] ?? object["task_id"]),
    provider: parseNonEmptyString(object["provider"]),
    status: status,
    repoName: parseNonEmptyString(object["repoName"] ?? object["repo_name"]),
    cwd: parseNonEmptyString(object["cwd"]),
    workMode: parseNonEmptyString(object["workMode"] ?? object["work_mode"]),
    model: parseNonEmptyString(object["model"]),
    reasoningEffort: parseNonEmptyString(
      object["reasoningEffort"]
        ?? object["reasoning_effort"]
        ?? object["agentBridgeReasoningEffort"]
        ?? object["intelligence"]
        ?? object["agentBridgeIntelligence"]
    ),
    advisor: parseNonEmptyString(object["advisor"] ?? object["advisorModel"] ?? object["advisor_model"]),
    permissionMode: parseNonEmptyString(object["permissionMode"] ?? object["permission_mode"]),
    sessionId: parseNonEmptyString(object["sessionId"] ?? object["session_id"]),
    threadId: parseNonEmptyString(object["threadId"] ?? object["thread_id"]),
    cliVersion: parseNonEmptyString(object["cliVersion"] ?? object["cli_version"]),
    durationMs: parseLong(object["durationMs"] ?? object["duration_ms"]).map { Int($0) },
    dirtyBefore: parseBool(object["dirtyBefore"] ?? object["dirty_before"]) ?? false,
    dirtyBeforeCount: Int(parseLong(object["dirtyBeforeCount"] ?? object["dirty_before_count"]) ?? 0),
    exitStatus: parseLong(object["exitStatus"] ?? object["exit_status"]).map { Int($0) },
    command: command,
    diff: diff,
    controls: controls,
    usage: usage,
    availableTools: parseStringArray(object["availableTools"] ?? object["available_tools"]),
    slashCommands: parseStringArray(object["slashCommands"] ?? object["slash_commands"]),
    cliCommands: parseStringArray(object["cliCommands"] ?? object["cli_commands"]),
    providerCommands: parseStringArray(object["providerCommands"] ?? object["provider_commands"]),
    mcpServers: mcpServers,
    agents: parseStringArray(object["agents"]),
    skills: parseStringArray(object["skills"]),
    teamMode: parseNonEmptyString(object["teamMode"] ?? object["team_mode"]),
    teamRunId: parseNonEmptyString(object["teamRunId"] ?? object["team_run_id"]),
    teamWorker: parseNonEmptyString(object["teamWorker"] ?? object["team_worker"]),
    teamWorkers: parseStringArray(object["teamWorkers"] ?? object["team_workers"]),
    leadWorker: parseNonEmptyString(object["leadWorker"] ?? object["lead_worker"]),
    teamRole: parseNonEmptyString(object["teamRole"] ?? object["team_role"]),
    suppressVisible: parseBool(object["suppressVisible"] ?? object["suppress_visible"]) ?? false,
    suppressAllText: parseBool(object["suppressAllText"] ?? object["suppress_all_text"]) ?? false,
    teamWorkersStatus: parseTeamWorkersStatus(
      object["teamWorkersStatus"] ?? object["team_workers_status"]),
    computerId: parseNonEmptyString(object["computerId"] ?? object["computer_id"]),
    computerLabel: parseNonEmptyString(object["computerLabel"] ?? object["computer_label"])
  )
}

func parseTeamWorkersStatus(_ raw: Any?) -> [ChatListRow.TeamWorkerStatus] {
  guard let list = raw as? [[String: Any]] else { return [] }
  return list.compactMap { object in
    guard let worker = parseNonEmptyString(object["worker"] ?? object["handle"]) else {
      return nil
    }
    let label =
      parseNonEmptyString(object["label"] ?? object["name"]) ?? worker.capitalized
    return ChatListRow.TeamWorkerStatus(
      worker: worker,
      label: label,
      status: parseNonEmptyString(object["status"]) ?? "pending",
      startedAt: parseLong(object["startedAt"] ?? object["started_at"]),
      finishedAt: parseLong(object["finishedAt"] ?? object["finished_at"]),
      durationMs: parseLong(object["durationMs"] ?? object["duration_ms"]).map { Int($0) },
      summary: parseNonEmptyString(object["summary"]),
      taskId: parseNonEmptyString(object["taskId"] ?? object["task_id"]),
      lastLabel: parseNonEmptyString(object["lastLabel"] ?? object["last_label"])
    )
  }
}

private func parseAgentRuntimeCommand(_ raw: Any?) -> ChatListRow.AgentRuntimeCommand? {
  guard let object = raw as? [String: Any] else { return nil }
  let executable = parseNonEmptyString(object["executable"])
  let display = parseNonEmptyString(object["display"])
  guard executable != nil || display != nil else { return nil }
  return ChatListRow.AgentRuntimeCommand(executable: executable, display: display)
}

private func parseAgentRuntimeDiff(_ raw: Any?) -> ChatListRow.AgentRuntimeDiff? {
  guard let object = raw as? [String: Any] else { return nil }
  let files = parseAgentRuntimeFiles(object["files"])
  let filesChanged = Int(parseLong(object["filesChanged"] ?? object["files_changed"]) ?? Int64(files.count))
  let additions = Int(parseLong(object["additions"]) ?? 0)
  let deletions = Int(parseLong(object["deletions"]) ?? 0)
  guard filesChanged > 0 || additions > 0 || deletions > 0 || !files.isEmpty else { return nil }
  return ChatListRow.AgentRuntimeDiff(
    filesChanged: max(filesChanged, files.count),
    additions: additions,
    deletions: deletions,
    files: files,
    patch: parseNonEmptyString(object["patch"]),
    patchTruncated: parseBool(object["patchTruncated"] ?? object["patch_truncated"]) ?? false
  )
}

private func parseAgentRuntimeFiles(_ raw: Any?) -> [ChatListRow.AgentRuntimeFile] {
  guard let items = raw as? [[String: Any]] else { return [] }
  return items.compactMap { item in
    let path = parseNonEmptyString(item["path"]) ?? parseNonEmptyString(item["name"])
    guard let path else { return nil }
    let name = parseNonEmptyString(item["name"]) ?? URL(fileURLWithPath: path).lastPathComponent
    return ChatListRow.AgentRuntimeFile(
      path: path,
      name: name.isEmpty ? path : name,
      status: parseNonEmptyString(item["status"]) ?? "M",
      additions: Int(parseLong(item["additions"]) ?? 0),
      deletions: Int(parseLong(item["deletions"]) ?? 0)
    )
  }
}

private func parseAgentRuntimeControls(_ raw: Any?) -> ChatListRow.AgentRuntimeControls? {
  guard let object = raw as? [String: Any] else { return nil }
  let canCancel = parseBool(object["canCancel"] ?? object["can_cancel"]) ?? false
  let canRevert = parseBool(object["canRevert"] ?? object["can_revert"]) ?? false
  guard canCancel || canRevert else { return nil }
  return ChatListRow.AgentRuntimeControls(canCancel: canCancel, canRevert: canRevert)
}

private func parseAgentRuntimeUsage(_ raw: Any?) -> ChatListRow.AgentRuntimeUsage? {
  guard let object = raw as? [String: Any] else { return nil }
  let usage = ChatListRow.AgentRuntimeUsage(
    inputTokens: parseLong(object["inputTokens"] ?? object["input_tokens"]).map { Int($0) },
    cachedInputTokens: parseLong(object["cachedInputTokens"] ?? object["cached_input_tokens"]).map { Int($0) },
    cacheCreationInputTokens: parseLong(object["cacheCreationInputTokens"] ?? object["cache_creation_input_tokens"]).map { Int($0) },
    outputTokens: parseLong(object["outputTokens"] ?? object["output_tokens"]).map { Int($0) },
    reasoningOutputTokens: parseLong(object["reasoningOutputTokens"] ?? object["reasoning_output_tokens"]).map { Int($0) },
    totalCostUsd: parseDouble(object["totalCostUsd"] ?? object["total_cost_usd"]),
    durationMs: parseLong(object["durationMs"] ?? object["duration_ms"]).map { Int($0) },
    durationApiMs: parseLong(object["durationApiMs"] ?? object["duration_api_ms"]).map { Int($0) },
    ttftMs: parseLong(object["ttftMs"] ?? object["ttft_ms"]).map { Int($0) },
    ttftStreamMs: parseLong(object["ttftStreamMs"] ?? object["ttft_stream_ms"]).map { Int($0) },
    numTurns: parseLong(object["numTurns"] ?? object["num_turns"]).map { Int($0) }
  )
  guard usage.inputTokens != nil || usage.cachedInputTokens != nil || usage.outputTokens != nil
    || usage.reasoningOutputTokens != nil || usage.totalCostUsd != nil || usage.durationMs != nil
    || usage.durationApiMs != nil || usage.ttftMs != nil || usage.ttftStreamMs != nil
    || usage.numTurns != nil
  else {
    return nil
  }
  return usage
}

private func parseAgentRuntimeMCPServers(_ raw: Any?) -> [ChatListRow.AgentRuntimeMCPServer] {
  guard let items = raw as? [[String: Any]] else { return [] }
  return items.compactMap { item in
    guard let name = parseNonEmptyString(item["name"]) else { return nil }
    return ChatListRow.AgentRuntimeMCPServer(
      name: name,
      status: parseNonEmptyString(item["status"])
    )
  }
}

private func parseStringArray(_ raw: Any?) -> [String] {
  if let values = raw as? [String] {
    return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  if let values = raw as? [Any] {
    return values.compactMap(parseNonEmptyString)
  }

  if let value = raw as? String {
    return value
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  return []
}

private func parseBool(_ raw: Any?) -> Bool? {
  if let value = raw as? Bool {
    return value
  }
  if let value = raw as? NSNumber {
    return value.boolValue
  }
  if let value = parseNonEmptyString(raw)?.lowercased() {
    switch value {
    case "1", "true", "yes", "on":
      return true
    case "0", "false", "no", "off":
      return false
    default:
      return nil
    }
  }
  return nil
}

private func parseAgentCardEventInbox(_ raw: [String: Any]) -> (mode: String, summaryWindowHours: Int) {
  let directMode =
    parseNonEmptyString(raw["event_inbox_mode"])
    ?? parseNonEmptyString(raw["eventInboxMode"])

  let directHours =
    parseAgentSummaryWindowHours(raw["summary_window_hours"])
    ?? parseAgentSummaryWindowHours(raw["summaryWindowHours"])

  let approvalRules =
    (raw["approval_rules"] as? [String: Any])
    ?? (raw["approvalRules"] as? [String: Any])
  let eventInbox =
    (approvalRules?["event_inbox"] as? [String: Any])
    ?? (approvalRules?["eventInbox"] as? [String: Any])

  let nestedMode =
    parseNonEmptyString(eventInbox?["mode"])
    ?? parseNonEmptyString(eventInbox?["event_inbox_mode"])
    ?? parseNonEmptyString(eventInbox?["eventInboxMode"])
  let nestedHours =
    parseAgentSummaryWindowHours(eventInbox?["summary_window_hours"])
    ?? parseAgentSummaryWindowHours(eventInbox?["summaryWindowHours"])
    ?? parseAgentSummaryWindowHours(eventInbox?["cadence"])

  let normalizedMode =
    normalizeAgentEventInboxMode(directMode ?? nestedMode)
  let normalizedHours =
    normalizeAgentSummaryWindowHours(directHours ?? nestedHours)

  return (normalizedMode, normalizedHours)
}

private func agentCardEventInbox(_ raw: [String: Any]) -> [String: Any]? {
  let approvalRules =
    (raw["approval_rules"] as? [String: Any])
    ?? (raw["approvalRules"] as? [String: Any])
  return (approvalRules?["event_inbox"] as? [String: Any])
    ?? (approvalRules?["eventInbox"] as? [String: Any])
}

private func parseAgentCardSummarySchedule(_ raw: [String: Any]) -> String? {
  let eventInbox = agentCardEventInbox(raw)
  let value =
    parseNonEmptyString(raw["summary_schedule"])
    ?? parseNonEmptyString(raw["summarySchedule"])
    ?? parseNonEmptyString(eventInbox?["summary_schedule"])
    ?? parseNonEmptyString(eventInbox?["summarySchedule"])
  switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "daily", "time_of_day", "times", "fixed":
    return "daily"
  case "interval", "window", "rolling":
    return "interval"
  default:
    return nil
  }
}

private func parseAgentCardSummaryTimes(_ raw: [String: Any]) -> [String]? {
  let eventInbox = agentCardEventInbox(raw)
  let rawList =
    (raw["summary_times"] as? [Any])
    ?? (raw["summaryTimes"] as? [Any])
    ?? (eventInbox?["summary_times"] as? [Any])
    ?? (eventInbox?["summaryTimes"] as? [Any])
  guard let rawList else { return nil }
  let times = rawList.compactMap { normalizeAgentSummaryTime($0) }
  return times.isEmpty ? nil : Array(Set(times)).sorted()
}

/// Normalizes a clock time to "HH:MM" (24h, zero-padded). Accepts "H:MM"/"HH:MM"
/// strings or an integer hour (0–23).
private func normalizeAgentSummaryTime(_ value: Any?) -> String? {
  if let intValue = value as? Int, (0...23).contains(intValue) {
    return String(format: "%02d:00", intValue)
  }
  guard let str = parseNonEmptyString(value) else { return nil }
  let parts = str.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
  if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
    (0...23).contains(h), (0...59).contains(m) {
    return String(format: "%02d:%02d", h, m)
  }
  if parts.count == 1, let h = Int(parts[0]), (0...23).contains(h) {
    return String(format: "%02d:00", h)
  }
  return nil
}

private func normalizeAgentEventInboxMode(_ raw: String?) -> String {
  switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "batched_summary", "batched", "batch", "summary":
    return "batched_summary"
  default:
    return "per_event"
  }
}

private func parseAgentSummaryWindowHours(_ raw: Any?) -> Int64? {
  if let value = parseLong(raw) {
    return value
  }

  switch parseNonEmptyString(raw)?.lowercased() {
  case "4h":
    return 4
  case "daily", "24h":
    return 24
  default:
    return nil
  }
}

private func normalizeAgentSummaryWindowHours(_ raw: Int64?) -> Int {
  switch Int(raw ?? 24) {
  case 1...4:
    return 4
  default:
    return 24
  }
}

private func uniqueStrings(_ values: [String]) -> [String] {
  var seen = Set<String>()
  var ordered: [String] = []

  for value in values {
    if seen.insert(value).inserted {
      ordered.append(value)
    }
  }

  return ordered
}

struct SendTransitionPayload {
  let messageId: String
  let text: String
  let timestamp: String
  /// Legacy source text rect in host coordinates.
  /// Still accepted for backward compatibility with existing JS payloads.
  let startRect: CGRect
  /// Legacy source background rect in host coordinates.
  /// Still accepted for backward compatibility with existing JS payloads.
  let backgroundStartRect: CGRect?
  /// Telegram-style source container rect in host coordinates.
  /// This is the coordinate space for sourceBackgroundRectInContainer/sourceContentRectInContainer.
  let sourceContainerRect: CGRect?
  /// Source background rect in source-container local coordinates.
  let sourceBackgroundRectInContainer: CGRect?
  /// Source content rect in source-container local coordinates.
  let sourceContentRectInContainer: CGRect?
  /// Source text content scroll offset (used to align destination text motion).
  let sourceScrollOffset: CGFloat
  /// Optional live source background snapshot captured before input clear.
  var sourceBackgroundSnapshotView: UIView?
  /// Optional live source content snapshot captured before input clear.
  var sourceContentSnapshotView: UIView?

  var resolvedSourceContainerRect: CGRect {
    if let sourceContainerRect {
      return sourceContainerRect
    }
    if let backgroundStartRect {
      return backgroundStartRect
    }
    return startRect
  }

  var resolvedSourceBackgroundRect: CGRect {
    if let sourceContainerRect, let sourceBackgroundRectInContainer {
      return CGRect(
        x: sourceContainerRect.minX + sourceBackgroundRectInContainer.minX,
        y: sourceContainerRect.minY + sourceBackgroundRectInContainer.minY,
        width: sourceBackgroundRectInContainer.width,
        height: sourceBackgroundRectInContainer.height
      )
    }
    if let backgroundStartRect {
      return backgroundStartRect
    }
    return startRect
  }

  var resolvedSourceContentRect: CGRect {
    if let sourceContainerRect, let sourceContentRectInContainer {
      return CGRect(
        x: sourceContainerRect.minX + sourceContentRectInContainer.minX,
        y: sourceContainerRect.minY + sourceContentRectInContainer.minY,
        width: sourceContentRectInContainer.width,
        height: sourceContentRectInContainer.height
      )
    }
    return startRect
  }

  /// Direct initializer for native send (no bridge, no parsing).
  init(
    messageId: String,
    text: String,
    timestamp: String,
    startRect: CGRect,
    backgroundStartRect: CGRect? = nil,
    sourceContainerRect: CGRect? = nil,
    sourceBackgroundRectInContainer: CGRect? = nil,
    sourceContentRectInContainer: CGRect? = nil,
    sourceScrollOffset: CGFloat = 0.0,
    sourceBackgroundSnapshotView: UIView? = nil,
    sourceContentSnapshotView: UIView? = nil
  ) {
    self.messageId = messageId
    self.text = text
    self.timestamp = timestamp
    self.startRect = startRect
    if let backgroundStartRect {
      self.backgroundStartRect = backgroundStartRect
    } else if let sourceContainerRect, let sourceBackgroundRectInContainer {
      self.backgroundStartRect = CGRect(
        x: sourceContainerRect.minX + sourceBackgroundRectInContainer.minX,
        y: sourceContainerRect.minY + sourceBackgroundRectInContainer.minY,
        width: sourceBackgroundRectInContainer.width,
        height: sourceBackgroundRectInContainer.height
      )
    } else {
      self.backgroundStartRect = nil
    }
    self.sourceContainerRect = sourceContainerRect
    self.sourceBackgroundRectInContainer = sourceBackgroundRectInContainer
    self.sourceContentRectInContainer = sourceContentRectInContainer
    self.sourceScrollOffset = sourceScrollOffset
    self.sourceBackgroundSnapshotView = sourceBackgroundSnapshotView
    self.sourceContentSnapshotView = sourceContentSnapshotView
  }

  init?(payload: [String: Any], hostView: UIView) {
    guard let messageId = payload["messageId"] as? String, !messageId.isEmpty else {
      return nil
    }
    let text = (payload["text"] as? String) ?? ""
    let timestamp = (payload["timestamp"] as? String) ?? ""

    func number(_ key: String) -> CGFloat? {
      if let value = payload[key] as? NSNumber {
        return CGFloat(value.doubleValue)
      }
      if let value = payload[key] as? Double {
        return CGFloat(value)
      }
      if let value = payload[key] as? Int {
        return CGFloat(value)
      }
      if let value = payload[key] as? String, let parsed = Double(value) {
        return CGFloat(parsed)
      }
      return nil
    }

    guard
      let startX = number("startX"),
      let startY = number("startY"),
      let startWidth = number("startWidth"),
      let startHeight = number("startHeight")
    else {
      return nil
    }

    func rectInHost(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
      let originInHost: CGPoint
      if let window = hostView.window {
        originInHost = hostView.convert(CGPoint(x: x, y: y), from: window)
      } else {
        originInHost = CGPoint(x: x, y: y)
      }
      return CGRect(x: originInHost.x, y: originInHost.y, width: width, height: height)
    }

    let textStartRect = rectInHost(x: startX, y: startY, width: startWidth, height: startHeight)

    var parsedBackgroundStartRect: CGRect?
    if let bgX = number("startBackgroundX"),
      let bgY = number("startBackgroundY"),
      let bgWidth = number("startBackgroundWidth"),
      let bgHeight = number("startBackgroundHeight")
    {
      parsedBackgroundStartRect = rectInHost(x: bgX, y: bgY, width: bgWidth, height: bgHeight)
    }

    var parsedContentStartRect: CGRect?
    if let contentX = number("startContentX"),
      let contentY = number("startContentY"),
      let contentWidth = number("startContentWidth"),
      let contentHeight = number("startContentHeight")
    {
      parsedContentStartRect = rectInHost(
        x: contentX,
        y: contentY,
        width: contentWidth,
        height: contentHeight
      )
    }

    var parsedSourceContainerRect: CGRect?
    if let containerX = number("sourceContainerX"),
      let containerY = number("sourceContainerY"),
      let containerWidth = number("sourceContainerWidth"),
      let containerHeight = number("sourceContainerHeight")
    {
      parsedSourceContainerRect = rectInHost(
        x: containerX,
        y: containerY,
        width: containerWidth,
        height: containerHeight
      )
    }

    let sourceContainerRect =
      parsedSourceContainerRect
      ?? parsedBackgroundStartRect
      ?? parsedContentStartRect
      ?? textStartRect

    let sourceBackgroundRectInContainer: CGRect? = {
      guard let parsedBackgroundStartRect else { return nil }
      return CGRect(
        x: parsedBackgroundStartRect.minX - sourceContainerRect.minX,
        y: parsedBackgroundStartRect.minY - sourceContainerRect.minY,
        width: parsedBackgroundStartRect.width,
        height: parsedBackgroundStartRect.height
      )
    }()

    let resolvedContentStartRect = parsedContentStartRect ?? textStartRect
    let sourceContentRectInContainer = CGRect(
      x: resolvedContentStartRect.minX - sourceContainerRect.minX,
      y: resolvedContentStartRect.minY - sourceContainerRect.minY,
      width: resolvedContentStartRect.width,
      height: resolvedContentStartRect.height
    )

    let sourceScrollOffset = number("sourceScrollOffset") ?? 0.0

    self.messageId = messageId
    self.text = text
    self.timestamp = timestamp
    self.startRect = textStartRect
    self.backgroundStartRect = parsedBackgroundStartRect
    self.sourceContainerRect = sourceContainerRect
    self.sourceBackgroundRectInContainer = sourceBackgroundRectInContainer
    self.sourceContentRectInContainer = sourceContentRectInContainer
    self.sourceScrollOffset = sourceScrollOffset
    self.sourceBackgroundSnapshotView = nil
    self.sourceContentSnapshotView = nil
  }
}

struct ChatAttachmentTransitionCapture {
  let sourceContainerFrameInWindow: CGRect
  var sourceBackgroundSnapshotView: UIView?
  var sourceContentSnapshotView: UIView?
}
