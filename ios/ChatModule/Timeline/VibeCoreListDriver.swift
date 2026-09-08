import Foundation
import UIKit

/// Feeds the timeline core the rows the list is about to render, and lets the core
/// answer with the window: which rows, in what order, how tall.
///
/// # The seam
///
/// ```
/// ChatEngine → setRows → VibeCoreListDriver → core
///                                              ↓
///              ChatListView ← VibeTimelineHost ┘
/// ```
///
/// One feed, and it is the one the list already trusts. That is the entire correction
/// over the screen deleted on 2026-08-03: a second feed was written against the row
/// payload and got its shape wrong — see ``messageTimestampMs`` — so the core was handed
/// nothing and rendered nothing. Rows arrive here already proven by the list that is
/// about to draw them.
///
/// # Threading
///
/// `@MainActor` throughout. Core callbacks arrive on the Rust worker thread and hop
/// before touching anything here; `VibeTimelineHost` funnels commits through a
/// display-link committer so a burst of deltas is at most one commit per frame.
@MainActor
final class VibeCoreListDriver {

  private let chatId: String
  private let timelineHost: VibeTimelineHost
  /// The shared core. Borrowed, never owned — see ``shutdown()``.
  private var handle: VibeCoreHandle?

  private(set) var observations = 0
  /// Whether the bottom anchor has been taken once for this chat.
  private var hasAnchoredWindow = false

  /// Publishes the core's rows, in the core's order, in the list's payload shape.
  ///
  /// Fed from the raw `VibeFfiWindow` rather than the render snapshot: a
  /// `VibeRenderItem` carries geometry and paint, never text, so a snapshot cannot
  /// answer what a row *says*. This is the only place both are in hand.
  var onCoreRows: (([[String: Any]]) -> Void)?

  /// Whether the core's window still has newer messages behind it.
  ///
  /// `false` means the window ends on the newest message the core holds — it is
  /// following the tail. The list's authority gate needs this to tell "the core is
  /// behind and would drop the newest message off screen" (refuse) apart from "the
  /// user scrolled back and the window moved with them" (adopt). Without it a
  /// scrolled-back window looks identical to a late one and every page hands the
  /// transcript back to the engine.
  private(set) var windowFollowsTail = true

  /// Main-thread text layouts one mount may run for rows nothing else can size.
  ///
  /// Sized against the two numbers that bound it. Below: the core's geometry is only
  /// ever read on chats of 12 rows or fewer, so anything comfortably above 12 leaves
  /// that case measuring exactly as it did. Above: a cold mount of a 999-row chat ran
  /// ~0.57s, so ≈0.6ms a row — 64 caps the worst case near 40ms, which fits inside a
  /// push instead of replacing it.
  private static let exactMeasurementBudget = 64

  /// Whether a host diagnostic describes something that went wrong.
  ///
  /// An allow-list of the benign ones rather than a list of the failures, so a new
  /// diagnostic is loud by default. A message that should have been ERROR and was
  /// filed as INFO is invisible; the reverse is merely noisy.
  private static func diagnosticIsFailure(_ message: String) -> Bool {
    !(message.hasPrefix("mount skipped") || message.hasPrefix("mount cost"))
  }

  init(chatId: String, listHost: VibeMessageListHost) {
    self.chatId = chatId
    self.timelineHost = VibeTimelineHost(chatId: chatId, listHost: listHost)
    timelineHost.onNeedsResync = { [weak self] in self?.requestWindow() }
    timelineHost.onDiagnostic = { message, meta in
      // Not everything this host reports is a failure, and logging it as one is not a
      // harmless overstatement: `mount skipped: window already applied` is the dedup
      // guard doing its job, and it alone filed **110 ERROR lines** in a single
      // diagnostics export — enough to bury the handful of lines that were real. Route
      // by what the message means.
      guard Self.diagnosticIsFailure(message) else {
        VibeLog.info("core list adapter: \(message)", category: "core", metadata: meta)
        return
      }
      VibeLog.error("core list adapter: \(message)", category: "core", metadata: meta)
      // Also to the device console, and that is not redundancy. A rejected snapshot
      // means `apply(snapshot:)` never runs, so the host's generation stays 0 and every
      // later transaction is fenced — device run 2026-08-04 showed
      // `host TRANSACTION-FENCED base=1 held=0 — resync owed` twice, with nothing
      // anywhere saying why, because the only explanation went to VibeLog and VibeLog
      // is not in the console stream anyone actually reads while reproducing.
      NSLog(
        "[VibeCore] adapter FAILURE %@ %@", message,
        meta.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
  }

  /// Attaches to the shared core and subscribes to this chat. Idempotent.
  ///
  /// The driver used to construct its **own** `VibeCoreHandle` with a synthetic
  /// `ownUserId: "me"`. That was two defects in one line: a second reducer holding
  /// its own tombstones, id aliases and generations for the same conversations,
  /// and a fake identity that decides `author.is_me` and therefore which
  /// wrapped-key slot is tried first. Both are gone — one core, the real user id.
  func start(
    ownUserId: String,
    rowProvider: @escaping (String) -> ChatListRow?,
    agentStateProvider: @escaping (ChatListRow) -> AgentTurnBubbleState,
    knownHeightProvider: @escaping (ChatListRow, CGFloat) -> CGFloat?
  ) {
    guard handle == nil else { return }
    timelineHost.setRowProvider(rowProvider)
    // Measured with the SAME inputs the list uses, or the two can never agree on an agent
    // row's height. Set together with the provider — never one without the other.
    timelineHost.setAgentStateProvider(agentStateProvider)
    // Ask the list before measuring. The list already holds a persisted height for most
    // rows and answers in a dictionary lookup; re-deriving it cost 0.57s of main thread
    // inside the push on a 999-row chat.
    timelineHost.setKnownHeightProvider(knownHeightProvider)
    timelineHost.setExactMeasurementBudget(Self.exactMeasurementBudget)

    guard let core = VibeCoreBridge.sharedCore(ownUserId: ownUserId) else { return }
    handle = core

    VibeCoreBridge.addObserver(
      chatId: chatId,
      onWindow: { [weak self] window in
        guard let self else { return }
        // Built on the worker thread, off main: a 200-row window is order 3,000
        // allocations, and the rule for this boundary is that a window build never
        // runs on the main thread regardless of how cheap it looks.
        let rows = VibeCoreRowPayload.rows(from: window.messages, chatId: self.chatId)
        let followsTail = !window.bounds.hasMoreAfter
        Task { @MainActor in
          self.windowFollowsTail = followsTail
          self.timelineHost.mount(window: window, reason: .engineReconcile)
          self.onCoreRows?(rows)
        }
      },
      onDelta: { [weak self] delta in
        Task { @MainActor in self?.timelineHost.ingest(delta: delta) }
      })
  }

  /// Tells the core the width rows must be measured against.
  func setLayoutWidth(_ width: CGFloat) {
    guard width > 0 else { return }
    timelineHost.setEnvironment(width: width)
  }

  /// Detaches this chat from the shared core.
  ///
  /// Unsubscribes; it does **not** shut the core down. The core is process-wide
  /// and other chats are still reduced by it — tearing it down here is what would
  /// make leaving one conversation drop the state of every other.
  func shutdown() {
    timelineHost.shutdown()
    VibeCoreBridge.removeObserver(chatId: chatId)
    handle = nil
  }

  var measurementStats: (measured: Int, reused: Int, invalidations: Int, placeholders: Int) {
    timelineHost.measurementStats
  }

  /// Ids whose core height is an estimate, not a measurement.
  var placeholderMessageIds: Set<String> { timelineHost.placeholderMessageIds }

  /// The chat this driver was armed with, for log labels.
  var loggingChatId: String { chatId }

  /// Extends the core's window backwards, in step with the engine's scroll-back.
  ///
  /// The core keeps the full history in its store and serves a bounded window; a
  /// page moves the window's head, it does not fetch. Called from the same trigger
  /// that pages the engine so the two stay in step — a core that does not page
  /// falls behind the moment the user scrolls up, and the coverage gate then hands
  /// the transcript back to the engine mid-scroll.
  func pageOlder() {
    guard let handle else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.pageBefore(chatId: chatId, nowMs: now)
  }

  /// Moves the window forward, and re-arms tail following when it reaches the end.
  ///
  /// The counterpart to ``pageOlder()``, and not optional. Once `page_before` takes the
  /// window off the tail it sets `follow_tail = false`, and only `page_after` reaching
  /// the end turns it back on. Without this call a user who scrolled up would never see
  /// another incoming message — the window would stay parked in the past while new
  /// messages landed in the store behind it.
  func pageNewer() {
    guard let handle else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.pageAfter(chatId: chatId, nowMs: now)
  }

  // MARK: Feed

  /// Asks the core for this chat's window.
  ///
  /// # What this used to do, and why it was wrong
  ///
  /// It used to *ingest* — building a synthetic frame per row with
  /// `content: ""`, `type: "text"` and a `"me"`/`"peer"` sender. The core was
  /// therefore handed a conversation with no bodies, no media, no reply, no
  /// agent and no kind, so `canonical.rs`, `envelope.rs`, `media.rs` and most of
  /// `dedup.rs` had nothing to act on. What survived was a sort by
  /// `(ts_ms, message_id)` — a 10,000-line Rust pipeline reduced to ordering ids
  /// it could not read.
  ///
  /// Ingest now happens where the bytes actually arrive: `ChatEngine` hands the
  /// raw server frames straight to the core. The list is a *reader*. It asks for
  /// a window; it does not tell the core what the conversation contains.
  func requestWindow() {
    guard let handle else { return }
    observations += 1
    hasAnchoredWindow = true
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.flush(nowMs: now)
    try? handle.requestWindow(chatId: chatId, nowMs: now)
  }

  /// Steady-state refresh: publish the window without touching the cursor.
  ///
  /// `requestWindow()` re-anchors to the bottom, which resets `follow_tail`, `start`
  /// and `len` to their defaults. Calling it on every engine reconcile — which is what
  /// the list did — silently undid every `pageOlder()` a fraction of a second after it
  /// landed. Device run 2026-08-04: six scroll-back pages against `engine=480`, core
  /// pinned at `rows=200` on the newest messages the whole time, so the top of the
  /// transcript was unreachable and each page bought nothing but a re-mount.
  ///
  /// The first call still anchors, because a reader arriving at a chat does want the
  /// bottom. Every call after that refreshes.
  func refreshWindow() {
    guard let handle else { return }
    guard hasAnchoredWindow else {
      requestWindow()
      return
    }
    observations += 1
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.refreshWindow(chatId: chatId, nowMs: now)
  }

  /// Tells the core a message is gone, so its window stops republishing the row.
  ///
  /// The core is fed server frames; a deletion has no frame — the server sends an id
  /// and a scope. Without this call the engine removed the row, the core did not, and
  /// the core's window is what the list renders: the cell came straight back on the
  /// next publish.
  func deleteMessage(id: String, forEveryone: Bool) {
    guard let handle else { return }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? handle.deleteMessage(
      chatId: chatId, messageId: id, forEveryone: forEveryone, tombstoneMs: now)
  }

}
