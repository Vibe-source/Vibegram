import Foundation

/// One unanswered bridge approval prompt, as the UI needs to see it.
///
/// A value type carrying the exact fields the ask sheet reads, so answering "is there a
/// prompt waiting for this chat" never touches engine state. The engine keys these by
/// request id and scans for a chat match; the UI only ever asks per chat, so the mirror
/// stores them the way they are read.
struct ChatEngineBridgeAskSnapshot: Sendable, Equatable {
  let requestId: String
  let chatId: String
  let kind: String
  let provider: String
  let sessionId: String
  let resumedFromSessionId: String

  /// The payload shape `outstandingAgentBridgeAskInfo` has always returned. Built here
  /// so the mirror path and the queue fallback cannot drift into two different
  /// dictionaries — the sheet reads these keys by name.
  var payload: [AnyHashable: Any] {
    [
      "chatId": chatId,
      "requestId": requestId,
      "kind": kind,
      "provider": provider,
      "sessionId": sessionId,
      "resumedFromSessionId": resumedFromSessionId,
      "reason": "agentBridgeAsk",
    ]
  }
}

/// One chat's agent-progress state, as the UI needs to see it.
///
/// A value type rather than a reference into the engine, so the mirror can hand
/// it to the main thread without the main thread touching engine state.
struct ChatEngineAgentProgressSnapshot: Sendable, Equatable {
  let label: String
  let tool: String?
  let status: String
  let updatedAtMs: Int64

  /// Statuses that mean the work is over. Advertising any of these as live work
  /// is what leaves a row stuck on "Working…" forever.
  private static let terminalStatuses: Set<String> = [
    "done", "completed", "complete", "idle", "failed", "error", "cancelled", "canceled",
    "stopped", "settled", "success",
  ]

  private static let activeHints = [
    "running", "streaming", "in_progress", "active", "thinking", "tool", "wait",
  ]

  /// The payload the UI renders, or `nil` when this is not live work.
  ///
  /// **This is the only implementation of the liveness rule.** It used to live
  /// inside the engine's queue-hopping getter; moving the read off the queue
  /// would have meant a second copy, and two copies of a staleness rule drift —
  /// one of them keeps a spinner running forever and nobody can tell which.
  ///
  /// Because staleness is derived from `nowMs` at *read* time rather than baked
  /// in at publish time, a mirror entry that stops being refreshed expires on
  /// its own. That is what makes it safe for the mirror to be republished only
  /// on engine notifications: the failure mode of a missed publish is a stale
  /// entry, and a stale entry here answers `nil`.
  func activePayload(nowMs: Int64) -> [String: Any]? {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if Self.terminalStatuses.contains(normalized) { return nil }

    // No update for 90s is not live work, whatever the last status claimed.
    let ageMs = nowMs - updatedAtMs
    if ageMs > 90_000 { return nil }

    let looksActive =
      normalized.isEmpty
      || Self.activeHints.contains(where: { normalized.contains($0) })
      || ageMs < 15_000
    guard looksActive else { return nil }

    var payload: [String: Any] = [
      "label": label,
      "status": status,
      "updatedAtMs": updatedAtMs,
      "isActive": true,
    ]
    if let tool { payload["tool"] = tool }
    return payload
  }
}

/// Main-thread-readable mirror of the small state the UI polls constantly.
///
/// # Why this exists
///
/// The engine owns one serial queue, and every UI getter used to hop onto it to
/// read a single dictionary entry. That read costs microseconds; the *wait* does
/// not. A device run on 2026-08-03 measured
/// `[MAIN-THREAD-SYNC-STALL] syncOnQueue blocked main thread for 64ms at
/// agentProgress(chatId:)` — 64 ms of frozen UI to look up one key, because the
/// queue was busy decrypting when the header asked.
///
/// The cost is structural, not incidental: any main-thread reader is exposed to
/// the duration of whatever the queue happens to be running. Making the queue
/// faster narrows the window but never closes it. So the direction inverts — the
/// queue **publishes** and the UI **reads a lock**, and there is nothing left to
/// block on.
///
/// # Freshness
///
/// Published from `postChangeLocked`, the funnel every UI-visible engine
/// mutation already passes through. So the mirror is never staler than the last
/// notification the UI acted on: a reader that woke up because of a change sees
/// the state that caused it.
///
/// A mutation that somehow posts no notification leaves an entry stale rather
/// than wrong, and every field here degrades safely — agent progress expires
/// itself at read time (see ``ChatEngineAgentProgressSnapshot/activePayload(nowMs:)``),
/// typing indicators are re-sent every few seconds by their sender, and presence
/// re-publishes on the next presence event.
///
/// # What does not belong here
///
/// Anything expensive or large. `getChatRows` builds and decrypts a whole
/// transcript; mirroring it would move that cost rather than remove it, and
/// double the memory while doing so. This mirror is for the small, hot, polled
/// reads only.
final class ChatEngineUIMirror: @unchecked Sendable {
  private let lock = NSLock()

  private var typingByChatId: [String: Set<String>] = [:]
  private var agentProgressByChatId: [String: ChatEngineAgentProgressSnapshot] = [:]
  private var onlineUserIds: Set<String> = []
  private var lastSeenByUserId: [String: Int64] = [:]

  /// Unanswered bridge approval prompts, already filtered to the ones still worth
  /// showing. Stored per chat because that is how it is asked for; the engine holds it
  /// keyed by request id and scans, which is the wrong shape for a hot read.
  private var pendingAskByChatId: [String: [ChatEngineBridgeAskSnapshot]] = [:]

  /// When each chat last had an agent turn reported running, so
  /// `ChatEngine.bridgeRunIsActive` can answer off the mirror instead of hopping the
  /// engine's serial queue. See that method — this is the field that removes a
  /// 21-second main-thread block.
  private var agentTurnRunningAtMsByChatId: [String: Int64] = [:]

  /// Chats with ANY outstanding bridge approval request, including ones whose sheet is
  /// already on screen. Deliberately not `pendingAskByChatId`, which excludes presented
  /// prompts: a prompt the user is looking at is a run that is very much still alive, and
  /// reusing the filtered map here would make the composer drop STOP the moment the sheet
  /// appears. Same predicate as the engine's own `agentBridgeAskByRequestId` scan.
  private var agentAskChatIds: Set<String> = []

  /// Outgoing-message status inputs, so the cell footer never waits on the engine queue.
  private var receiptIndex: [String: [String: String]] = [:]
  private var localStatusIndex: [String: [String: String]] = [:]

  /// Chats holding an outgoing message that cannot leave until the peer's MLS session is
  /// confirmed. Drives the one line above the composer; empty in the ordinary case.
  private var secureWaitChatIds: Set<String> = []

  /// Until the first publish the mirror cannot distinguish "nothing is
  /// happening" from "nobody has told me yet", so readers fall back to the
  /// queue. One publish lands on the first engine notification.
  private var hasPublished = false

  private var mirrorReads = 0
  private var fallbackReads = 0
  private var publishes = 0

  // MARK: Publish (engine queue only)

  /// Replaces the mirrored state. Call only from the engine's serial queue.
  ///
  /// Cheap by construction: Swift collections are copy-on-write, so the three
  /// collection assignments are retains rather than deep copies. Only the
  /// agent-progress transform allocates, and that map holds one entry per chat
  /// with a *running* agent — normally zero.
  func publish(
    typingByChatId: [String: Set<String>],
    agentProgressByChatId: [String: ChatEngineAgentProgressSnapshot],
    onlineUserIds: Set<String>,
    lastSeenByUserId: [String: Int64],
    pendingAskByChatId: [String: [ChatEngineBridgeAskSnapshot]] = [:],
    agentTurnRunningAtMsByChatId: [String: Int64] = [:],
    agentAskChatIds: Set<String> = [],
    receiptIndex: [String: [String: String]] = [:],
    localStatusIndex: [String: [String: String]] = [:],
    secureWaitChatIds: Set<String> = []
  ) {
    lock.lock()
    defer { lock.unlock() }
    self.typingByChatId = typingByChatId
    self.agentProgressByChatId = agentProgressByChatId
    self.onlineUserIds = onlineUserIds
    self.lastSeenByUserId = lastSeenByUserId
    self.pendingAskByChatId = pendingAskByChatId
    self.agentTurnRunningAtMsByChatId = agentTurnRunningAtMsByChatId
    self.agentAskChatIds = agentAskChatIds
    self.receiptIndex = receiptIndex
    self.localStatusIndex = localStatusIndex
    self.secureWaitChatIds = secureWaitChatIds
    hasPublished = true
    publishes += 1
  }

  // MARK: Read (any thread, never blocks on the engine)

  /// Reads mirrored state, or returns `nil` when the caller must fall back to
  /// the queue because nothing has been published yet.
  private func read<T>(_ body: () -> T) -> T? {
    lock.lock()
    defer { lock.unlock() }
    guard hasPublished else {
      fallbackReads += 1
      return nil
    }
    mirrorReads += 1
    return body()
  }

  func typingUserIds(chatId: String) -> [String]? {
    read { Array(typingByChatId[chatId] ?? []).sorted() }
  }

  /// Inputs `ChatEngine.resolveDisplayStatus` needs for one outgoing row; outer `nil` = unpublished.
  /// Whether this chat is holding an outgoing message until the peer joins; outer `nil` = unpublished.
  func isWaitingForSecureSession(chatId: String) -> Bool? {
    read { secureWaitChatIds.contains(chatId) }
  }

  func displayStatusInputs(chatId: String, messageId: String, peerUserId: String?)
    -> (receipt: String?, local: String?, peerOnline: Bool)?
  {
    read {
      (
        receiptIndex[chatId]?[messageId], localStatusIndex[chatId]?[messageId],
        peerUserId.map { onlineUserIds.contains($0) } ?? false
      )
    }
  }

  /// Double-optional on purpose, and the two levels mean different things:
  /// the outer `nil` is "the mirror has nothing published, go ask the queue",
  /// the inner `nil` is "published, and this chat has no agent running".
  /// Collapsing them would turn a cold start into a false "no agent".
  func agentProgress(chatId: String) -> ChatEngineAgentProgressSnapshot?? {
    read { agentProgressByChatId[chatId] }
  }

  /// True when any agent-progress entry exists for this chat, regardless of
  /// liveness. Mirrors the engine's own "is there an entry" check rather than
  /// the derived-active one — they are deliberately different questions.
  func hasAgentProgressEntry(chatId: String) -> Bool? {
    read { agentProgressByChatId[chatId] != nil }
  }

  func isUserOnline(userId: String) -> Bool? {
    read { onlineUserIds.contains(userId) }
  }

  /// Whether this chat has a live agent run, answered without touching the engine queue.
  ///
  /// Mirrors all three inputs `ChatEngine.bridgeRunIsActive` reads — a progress entry, a
  /// recent running stamp within `graceMs`, and an unanswered approval prompt — so the
  /// mirrored answer is the same predicate rather than an approximation of it. The grace
  /// window is evaluated against `nowMs` at read time, not at publish time, because the
  /// answer decays with the clock: a stamp published 3s ago must expire on its own
  /// without waiting for another publish to notice.
  func bridgeRunIsActive(chatId: String, nowMs: Int64, graceMs: Int64) -> Bool? {
    read {
      if agentProgressByChatId[chatId] != nil { return true }
      if let runningAt = agentTurnRunningAtMsByChatId[chatId], nowMs - runningAt < graceMs {
        return true
      }
      return agentAskChatIds.contains(chatId)
    }
  }

  /// The oldest unanswered approval prompt for a chat, optionally narrowed to one
  /// provider.
  ///
  /// Double-optional for the same reason `agentProgress` is: the outer `nil` means
  /// nothing has been published and the caller must ask the queue, the inner `nil` means
  /// published and this chat has no prompt waiting. Collapsing them turns a cold start
  /// into a confident "no approval pending" — and a missed approval prompt is a run that
  /// silently waits forever.
  ///
  /// Provider matching is deliberately permissive in the same way the engine's own scan
  /// is: a prompt with no provider recorded matches any provider asked for, because a
  /// prompt that cannot be attributed still has to be answerable.
  func pendingBridgeAsk(chatId: String, provider: String)
    -> ChatEngineBridgeAskSnapshot??
  {
    read {
      guard let prompts = pendingAskByChatId[chatId] else { return nil }
      return prompts.first { prompt in
        guard !provider.isEmpty, !prompt.provider.isEmpty else { return true }
        return prompt.provider == provider
      }
    }
  }

  func lastSeenTimestampMs(userId: String) -> Int64?? {
    read { lastSeenByUserId[userId] }
  }

  // MARK: Diagnostics

  /// Counters for the exported log, so a run can answer "did the UI stop
  /// queueing?" without a profiler. A high `fallback` after launch means the
  /// mirror is not being published and the stalls are back.
  var summary: String {
    lock.lock()
    defer { lock.unlock() }
    return "mirror reads=\(mirrorReads) fallback=\(fallbackReads) publishes=\(publishes)"
  }

  var counts: (mirrorReads: Int, fallbackReads: Int, publishes: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (mirrorReads, fallbackReads, publishes)
  }
}
