import Foundation

/// Builds the list's row payload from a core message.
///
/// # Why a payload and not a new row type
///
/// `ChatListRow` is consumed by ~16,000 lines of cell code, and the product
/// constraint on this migration is that appearance does not change. So the core
/// does not get a new render type — it produces **the same dictionary shape**
/// `ChatEngine.buildLiveRowPayloadLocked` produces, and every cell, mask, gesture
/// and animation downstream keeps working by construction rather than by
/// re-implementation.
///
/// That makes this file the whole content seam. When it is authoritative, the
/// Swift envelope parse, field-alias resolution and media/reply/agent folding in
/// `ChatEngine` have no reader left and can be deleted rather than duplicated.
///
/// # What is deliberately not here
///
/// Day separators are minted by the renderer — if the core emitted them too, both
/// layers would insert them. Only message content crosses.
///
/// Bubble *shape* is computed here rather than in the core, because it is a
/// question about a run of neighbouring rows on screen, not about a message. But
/// it must be computed: it is read straight off the payload by
/// `ChatListRow.init` and nothing downstream recomputes it — see
/// ``applyingBubbleSequenceShapes(_:)``.
enum VibeCoreRowPayload {

  /// Maps a core window to list payloads, oldest → newest.
  static func rows(from messages: [VibeFfiMessage], chatId: String) -> [[String: Any]] {
    applyingBubbleSequenceShapes(messages.map { row(from: $0, chatId: chatId) })
  }

  /// Gives each row the tail and corner radii its position in the sender run implies.
  ///
  /// Mirrors `ChatEngine.bubbleShapePayload` exactly, because the two row sources
  /// alternate on screen while the migration is in flight and a disagreement here
  /// is visible as bubbles changing shape under the user.
  ///
  /// Device run 2026-08-03: core rows shipped a fixed `showTail: true`, so every
  /// bubble in a run grew a tail the moment core authority took over and lost it
  /// again when the coverage gate handed the list back to the engine. Nothing
  /// downstream corrects this — `ChatListViewModels` reads `bubbleShape` as given,
  /// and the list's own `patchBubbleShape` only touches native outgoing sends.
  private static func applyingBubbleSequenceShapes(
    _ rows: [[String: Any]]
  ) -> [[String: Any]] {
    guard !rows.isEmpty else { return rows }
    let senders: [Bool] = rows.map { row in
      ((row["message"] as? [String: Any])?["isMe"] as? Bool) ?? false
    }
    var shaped = rows
    for index in rows.indices {
      guard var message = shaped[index]["message"] as? [String: Any] else { continue }
      let isMe = senders[index]
      let isSequenceStart = index == 0 || senders[index - 1] != isMe
      let isSequenceEnd = index == rows.count - 1 || senders[index + 1] != isMe
      let full = 18
      let merged = 12
      message["bubbleShape"] = [
        "isMe": isMe,
        "showTail": isSequenceEnd,
        "borderTopLeftRadius": isMe ? full : (isSequenceStart ? full : merged),
        "borderTopRightRadius": full,
        "borderBottomLeftRadius": isMe ? full : (isSequenceEnd ? full : merged),
        "borderBottomRightRadius": isMe ? (isSequenceEnd ? full : merged) : full,
      ]
      shaped[index]["message"] = message
    }
    return shaped
  }

  static func row(from message: VibeFfiMessage, chatId: String) -> [String: Any] {
    var payload: [String: Any] = [
      "id": message.messageId,
      "chatId": chatId,
      "timestampMs": Double(message.tsMs),
      "timestamp": timeLabel(tsMs: message.tsMs),
      "text": message.text,
      "type": messageType(message),
      "isMe": message.authorIsMe,
      "isEdited": message.isEdited,
      // `bubbleShape` is filled in by `applyingBubbleSequenceShapes` once the whole
      // window is in hand — a single row cannot know whether it ends a sender run.
    ]

    if !message.authorUserId.isEmpty { payload["fromId"] = message.authorUserId }
    if message.authorIsMe { payload["status"] = deliveryStatus(message) }
    if let editedAtMs = message.editedAtMs { payload["editedAt"] = editedAtMs }
    if !message.reactions.isEmpty {
      payload["reactions"] = message.reactions.map {
        ["emoji": $0.emoji, "count": $0.count, "isSelected": $0.isSelected]
      }
    }
    if let viewCount = message.viewCount { payload["viewCount"] = viewCount }
    if let caption = message.caption, !caption.isEmpty { payload["caption"] = caption }

    if let media = message.media {
      // `remoteUrl` rather than the vault identity: the download path keys off the
      // URL, and identity is the core's *addressing* key, not a fetchable location.
      if let url = media.remoteUrl, !url.isEmpty { payload["mediaUrl"] = url }
      if let fileName = media.fileName, !fileName.isEmpty { payload["fileName"] = fileName }
      if let duration = media.durationS { payload["duration"] = duration }
      if case .gcm1(let keyRef) = media.envelope, !keyRef.isEmpty {
        payload["mediaKey"] = keyRef
      }
      // Natural size only when the core actually knows it. An unknown aspect must
      // stay absent so the renderer reserves a frame it will not later correct —
      // guessing square and fixing it after decode is *the* list-shift bug.
      if let size = media.naturalSize {
        payload["mediaWidth"] = Int(size.width)
        payload["mediaHeight"] = Int(size.height)
      }
    }

    if let reply = message.reply {
      payload["replyToId"] = reply.messageId
      if !reply.previewText.isEmpty { payload["replyPreviewText"] = reply.previewText }
      if let author = reply.authorUserId, !author.isEmpty {
        payload["replyPreviewTitle"] = author
      }
    }

    var metadata: [String: Any] = [:]
    if let agent = message.agent {
      metadata["isAgentMessage"] = true
      if !agent.provider.isEmpty { metadata["agentUserId"] = agent.provider }
      if let taskId = agent.taskId { metadata["taskId"] = taskId }
      if let sessionId = agent.sessionId { metadata["sessionId"] = sessionId }
      if let elapsedMs = agent.elapsedMs { metadata["elapsedMs"] = elapsedMs }
      metadata["isStreaming"] = agent.isStreaming
      if !agent.progress.isEmpty {
        metadata["progressNodes"] = agent.progress.map { node -> [String: Any] in
          var out: [String: Any] = [
            "id": node.id,
            "kind": node.kind,
            "label": node.label,
            "isTerminal": node.isTerminal,
          ]
          if let detail = node.detail { out["detail"] = detail }
          return out
        }
      }
    }
    if let service = message.service {
      metadata["serviceKind"] = service.kind
      metadata["serviceTitle"] = service.title
      if let subtitle = service.subtitle { metadata["serviceSubtitle"] = subtitle }
    }
    if !metadata.isEmpty { payload["metadata"] = metadata }

    return [
      "kind": "message",
      "key": "m-\(message.messageId)",
      "message": payload,
    ]
  }

  // MARK: Field mapping

  /// The engine's `type` vocabulary, which the cells switch on.
  ///
  /// An agent turn maps to `text`, not to a kind of its own: the list decides an
  /// agent cell from `metadata.isAgentMessage`, and inventing a new type string
  /// here would fall through every existing `switch` to the default branch.
  private static func messageType(_ message: VibeFfiMessage) -> String {
    if message.agent != nil { return "text" }
    switch message.kind {
    case .text: return "text"
    case .image: return "image"
    case .video: return "video"
    case .voice: return "voice"
    case .music: return "music"
    case .file: return "file"
    case .sticker: return "sticker"
    case .location: return "location"
    case .contact: return "contact"
    case .service: return "service"
    case .agentTurn: return "text"
    }
  }

  private static func deliveryStatus(_ message: VibeFfiMessage) -> String {
    switch message.displayStatus {
    case .pending: return "pending"
    case .sending: return "sending"
    case .failed: return "error"
    case .sent: return "sent"
    case .delivered: return "delivered"
    case .read: return "read"
    }
  }

  /// The short clock label the bubble draws.
  ///
  /// Locale- and timezone-dependent, so it is platform work by definition — the
  /// core carries `ts_ms` and nothing else, and deliberately ships no timezone
  /// database.
  private static func timeLabel(tsMs: Int64) -> String {
    Self.formatter.string(from: Date(timeIntervalSince1970: Double(tsMs) / 1000.0))
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return formatter
  }()
}
