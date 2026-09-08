import Foundation
import UIKit

/// The one answer to "is a chat open in flight", for background work that must yield to it.
///
/// A launch fan-out measured other chats' transcripts (1000 rows, 818ms) and unsealed
/// store rows inside someone's push. Self-expiring, so a lost `noteFinished` cannot
/// wedge background work for the rest of the session.
enum VibeChatOpenGate {
  private static let lock = NSLock()
  private static var inFlightUntil: TimeInterval = 0
  private static let maxSeconds: TimeInterval = 1.5

  static func noteStarted() {
    lock.lock()
    inFlightUntil = ProcessInfo.processInfo.systemUptime + maxSeconds
    lock.unlock()
  }

  static func noteFinished() {
    lock.lock()
    inFlightUntil = 0
    lock.unlock()
  }

  /// How long to wait so the work lands after the push instead of inside it.
  static var delay: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return max(0, inFlightUntil - ProcessInfo.processInfo.systemUptime)
  }

  /// `launch` is exempt: its whole job is to be ready BEFORE the tap, and it is already
  /// bounded to a few chats' tails. Delaying it starves the open it exists to serve.
  static func delay(forPrepareReason reason: String) -> TimeInterval {
    reason == "launch" ? 0 : delay
  }
}

/// A transcript that was parsed and measured **before** the push, so opening a chat
/// costs a dictionary lookup per row instead of a measurement per row.
///
/// # Why this exists
///
/// `presentationSeedMessageHeight` measures every non-agent kind exactly, and that is
/// the right answer: an estimate that disagrees with the later measurement *is* the
/// shift this project exists to remove, and each kind was converted estimate→exact to
/// kill a named jump (voice 3 pt, video note 20 pt, media 20 pt, text 16 pt).
///
/// But it runs those measurements at seed time, and seed time is inside the push. A
/// device run on the current build reads:
///
/// ```
/// [ChatOpen] presentation-seed rows=134 layoutMs=164 mountMs=176 totalMs=180
/// [ChatOpen] host-stage pre-push prestage 214ms
/// ```
///
/// Requirement 1 is that the push is not settled by the main thread **at all**.
/// Measuring on the push satisfies "never shifts" and violates that one. Measuring
/// off the push satisfies both, and that is the entire content of this file — the
/// numbers are identical, only *when* they are produced changes.
///
/// # What it is not
///
/// It is not a second height system. It calls `VibeRowMetrics.height`, which calls
/// `measureMessageBubbleLayout`, which is the same function the cell calls — so
/// agreement is identity, not tolerance. A store that computed its own answer would
/// owe the real path 0.5 pt of agreement forever, which is the defect, not the fix.
///
/// # Threading
///
/// Written from a background queue, read from the seed on main, so every access is
/// behind one lock. The measurement is off-main-safe by construction:
/// `VibeRowMetrics.height` returns `nil` for the one kind that needs a live view
/// (`VibeAgentTurnContentView`), and those keys come back as `deferredKeys` rather
/// than being silently dropped — a row with no prepared height falls back to the
/// estimate, and an unnoticed estimate is how this bug survived for months.
final class VibeTimelinePreparedStore: @unchecked Sendable {
  static let shared = VibeTimelinePreparedStore()

  /// One chat's transcript, ordered and sized, as of a particular width.
  struct Prepared {
    let chatId: String
    /// The width every height in `heightsByKey` was measured against. A prepared set
    /// is only valid at its own width; handing it out at another one would be a
    /// wrong number rather than a missing one, which is strictly worse.
    let width: CGFloat
    /// Row keys oldest → newest, as the engine ordered them.
    let orderedKeys: [String]
    let heightsByKey: [String: VibeRowMetrics.Measured]
    /// The row each height was measured from.
    ///
    /// Kept, rather than trusting the key, because a key is stable across an edit, a
    /// status change and a tail change, and every one of those changes the height. The
    /// in-memory height cache already guards itself this way (`chatListRowContentEqual`);
    /// a prepared height that skipped the same check would be a *stale* height, which is
    /// a shift with an extra step — and the caller owns that predicate, so it is handed
    /// back the row rather than asked to trust a fingerprint computed here.
    let rowsByKey: [String: ChatListRow]
    /// Keys that could only be measured on the main thread (agent turns). Recorded
    /// so the seed can tell "no prepared height" from "prepared height of zero".
    let deferredKeys: Set<String>
    let preparedAt: TimeInterval
    /// How long the off-push measurement actually took, for the liveness log.
    let measureMs: Int
  }

  /// What a payload represents, and therefore whether keys missing from it are dead.
  ///
  /// The prune used to be unconditional, which silently assumed every caller hands over
  /// the whole transcript. One does not: the engine's persist choke prepares **the rows
  /// it just wrote**, so a history page arrives here as 100 rows and every other row in
  /// the chat looked like a row that no longer exists. Device run 2026-08-05, one open of
  /// a 1,387-row chat:
  ///
  /// ```
  /// prepared rows=100  fresh=100  carried=1002 ms=64   reason=persist  ← evicted 1002
  /// prepared rows=1103 fresh=1003 carried=100  ms=595  reason=settle   ← re-measured them
  /// prepared rows=100  fresh=100  carried=1103 ms=60   reason=persist  ← evicted 1103
  /// ```
  ///
  /// Four pages, and each one threw the transcript's measurements away for the next pass
  /// to rebuild — ~600ms of duplicated measurement per page, for heights that had just
  /// been computed. Coverage could never accumulate past whatever the last pass happened
  /// to be handed.
  enum Scope {
    /// Every row the chat has. Keys absent from it are gone, and are pruned.
    case fullTranscript
    /// Part of it — a page, or one persist's worth of writes. Contributes heights and
    /// evicts nothing: a payload that does not mention a row is not evidence about it.
    case page
  }

  /// Chats kept prepared at once. The MRU list the raster prewarm uses is six; eight
  /// leaves room for the two the user bounces between without letting a long session
  /// accumulate transcripts nothing will open.
  private static let maxChats = 8

  /// Ceiling on rows kept prepared per chat. A memory guard, nothing more.
  ///
  /// This was 200, justified by "the core's own window is 200". That has not been true
  /// since the core window went unbounded (`core/vibe_core/src/window.rs`), and the stale
  /// cap had a consequence nobody could see from here: a 1,386-row chat could never be
  /// more than 14% prepared, no matter how many times it was opened. Every pass measured
  /// the same newest 200 rows and the rest stayed permanently unmeasured — which is what
  /// `storeHit=361 storeMiss=1031` was reporting, and why the seed fell back to
  /// estimating rows whose heights were sitting on disk.
  ///
  /// Heights are a `String` key and a few floats, so 4,000 rows across 8 chats is a couple
  /// of megabytes. The measurement is off-main and, since `prepare` merges, incremental.
  private static let maxRows = 4000

  private let lock = NSLock()
  private var byChat: [String: Prepared] = [:]
  /// MRU, most recent last.
  private var order: [String] = []

  /// Width the list last reported. Preparation is skipped until it is known, because
  /// measuring against a guessed width and correcting on mount is the shift.
  ///
  /// Seeded from disk so a launch can prepare before the first list reports a width —
  /// otherwise nothing is preparable until a chat has already been opened, which is the
  /// one open that needed it.
  private var measurementWidth: CGFloat = CGFloat(
    UserDefaults.standard.double(forKey: VibeTimelinePreparedStore.widthDefaultsKey))

  private static let widthDefaultsKey = "vibe.timeline.prepared.width"

  /// Serial so two persists for the same chat cannot interleave into a half-old,
  /// half-new height map. Utility QoS: this is work that must not compete with the
  /// engine queue or with a scroll.
  private let queue = DispatchQueue(
    label: "com.vibegram.timeline.prepare", qos: .utility)

  // Counters for the liveness line. Ids and numbers only.
  private(set) var preparations = 0
  private(set) var hits = 0
  private(set) var misses = 0

  private init() {}

  // MARK: Environment

  /// Publishes the width rows must be measured against.
  ///
  /// The list owns this number (`bounds.width - messageHorizontalInset * 2`), and it
  /// is uniform for a 1:1 DM because there is no sender-name gutter to subtract. A
  /// change invalidates everything: heights measured at another width are not stale,
  /// they are wrong.
  func setMeasurementWidth(_ width: CGFloat) {
    guard width > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    guard abs(measurementWidth - width) > 0.5 else { return }
    let previous = measurementWidth
    measurementWidth = width
    UserDefaults.standard.set(Double(width), forKey: Self.widthDefaultsKey)
    guard !byChat.isEmpty else { return }
    byChat.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    NSLog(
      "[VibeCore] prepared-store WIDTH %.0f→%.0f — dropped every prepared transcript",
      previous, width)
  }

  var currentMeasurementWidth: CGFloat {
    lock.lock()
    defer { lock.unlock() }
    return measurementWidth
  }

  // MARK: Write

  /// Prepares a chat off the caller's thread.
  ///
  /// Takes raw rows rather than `ChatListRow` on purpose: the parse and the decrypt
  /// are themselves main-thread work at open today, and moving the measurement while
  /// leaving the parse behind would only relocate half the cost.
  func prepareAsync(
    chatId: String, rawRows: [[String: Any]], reason: String, scope: Scope
  ) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !rawRows.isEmpty else { return }
    let width = currentMeasurementWidth
    guard width > 0 else { return }
    // Newest rows are the ones a chat opens on, so a transcript longer than the cap
    // keeps its tail rather than its head.
    let bounded = rawRows.count > Self.maxRows ? Array(rawRows.suffix(Self.maxRows)) : rawRows
    queue.asyncAfter(deadline: .now() + VibeChatOpenGate.delay(forPrepareReason: reason)) {
      [weak self] in
      self?.prepareNow(
        chatId: trimmed, rawRows: bounded, width: width, reason: reason, scope: scope)
    }
  }

  /// Prepares from rows the caller has **already parsed**.
  ///
  /// The list has them; re-serialising them so this could parse them again would be
  /// pure ceremony. Used on the way *out* of a chat, which is the moment the transcript
  /// is final, the main thread is idle, and the next open is the one that pays.
  func prepareAsync(chatId: String, rows: [ChatListRow], reason: String, scope: Scope) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !rows.isEmpty else { return }
    let width = currentMeasurementWidth
    guard width > 0 else { return }
    // Bounded before the hop as well as inside `prepareNow`, so a long transcript is not
    // copied across a queue boundary only to have most of it thrown away.
    let bounded = rows.count > Self.maxRows ? Array(rows.suffix(Self.maxRows)) : rows
    queue.asyncAfter(deadline: .now() + VibeChatOpenGate.delay(forPrepareReason: reason)) {
      [weak self] in
      self?.prepareNow(
        chatId: trimmed, rows: bounded, width: width, reason: reason, scope: scope)
    }
  }

  /// The measurement itself. Synchronous, and never called on main by the app —
  /// exposed at this level so a test can assert the result without a queue hop.
  @discardableResult
  func prepareNow(
    chatId: String, rawRows: [[String: Any]], width: CGFloat, reason: String,
    scope: Scope = .fullTranscript
  ) -> Prepared? {
    var rows: [ChatListRow] = []
    rows.reserveCapacity(rawRows.count)
    for raw in rawRows {
      guard let row = ChatListRow(raw: raw) else { continue }
      rows.append(row)
    }
    return prepareNow(chatId: chatId, rows: rows, width: width, reason: reason, scope: scope)
  }

  @discardableResult
  func prepareNow(
    chatId: String, rows: [ChatListRow], width: CGFloat, reason: String,
    scope: Scope = .fullTranscript
  ) -> Prepared? {
    guard width > 0, !rows.isEmpty else { return nil }
    let started = ProcessInfo.processInfo.systemUptime
    // The cap is enforced here rather than at the async wrapper so no entry point can
    // bypass it. Newest rows are the ones a chat opens on, so a transcript longer than
    // the cap keeps its tail.
    let rows = rows.count > Self.maxRows ? Array(rows.suffix(Self.maxRows)) : rows

    // Measure only what is not already measured at this width, and MERGE.
    //
    // This used to measure every row it was handed and then overwrite the chat's entry
    // outright. Both halves were wrong. Overwriting meant a pass could only ever lose
    // coverage it already had, so a long transcript never accumulated — the device log
    // showed `rows=200 sized=200 ms=204` on pass after pass, re-measuring the identical
    // 200 rows for 200ms each time while the other ~1,100 rows stayed unmeasured
    // forever. Opening the chat again could not help; there was no path by which it ever
    // became more prepared.
    //
    // A width change is different: every stored height was measured against the old
    // width and is now wrong, so that case starts clean rather than merging.
    let existing: Prepared? = {
      lock.lock()
      defer { lock.unlock() }
      guard let entry = byChat[chatId], abs(entry.width - width) <= 0.5 else { return nil }
      return entry
    }()

    let pending = rows.filter { existing?.heightsByKey[$0.key] == nil }
    let measured = VibeRowMetrics.measuredBatch(rows: pending, rowWidth: width)

    var heightsByKey = existing?.heightsByKey ?? [:]
    var rowsByKey = existing?.rowsByKey ?? [:]
    var deferredKeys = existing?.deferredKeys ?? []
    for row in pending where measured.byKey[row.key] != nil {
      heightsByKey[row.key] = measured.byKey[row.key]
      rowsByKey[row.key] = row
    }
    deferredKeys.formUnion(measured.deferredKeys)
    // A row that measured cleanly this time is no longer deferred.
    deferredKeys.subtract(pending.map(\.key).filter { measured.byKey[$0] != nil })

    // Which measurements survive this pass — and that depends on what the payload *is*.
    // See ``Scope``: only a full transcript is evidence that an absent row is gone, so
    // only a full transcript prunes. A page adds.
    let payloadKeys = rows.map(\.key)
    var orderedKeys: [String]
    switch scope {
    case .fullTranscript:
      orderedKeys = payloadKeys
    case .page:
      // Transcript order comes from the last full pass — a page knows its own rows, not
      // where they sit — with anything new appended so its heights are retained. The
      // list reads this store by key (``preparedRow``), never by position, so a page's
      // placement here costs nothing; the next full pass restores true order.
      var merged = existing?.orderedKeys ?? []
      var seen = Set(merged)
      for key in payloadKeys where seen.insert(key).inserted {
        merged.append(key)
      }
      orderedKeys = merged
    }
    // The memory bound applies to the union, or a chat drained page by page would grow
    // without limit. Least-recently-prepared goes first.
    if orderedKeys.count > Self.maxRows {
      orderedKeys = Array(orderedKeys.suffix(Self.maxRows))
    }
    let liveKeys = Set(orderedKeys)
    heightsByKey = heightsByKey.filter { liveKeys.contains($0.key) }
    rowsByKey = rowsByKey.filter { liveKeys.contains($0.key) }
    deferredKeys = deferredKeys.intersection(liveKeys)

    let prepared = Prepared(
      chatId: chatId,
      width: width,
      orderedKeys: orderedKeys,
      heightsByKey: heightsByKey,
      rowsByKey: rowsByKey,
      deferredKeys: deferredKeys,
      preparedAt: ProcessInfo.processInfo.systemUptime,
      measureMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
    )

    lock.lock()
    // A width change while this was measuring makes every number in it wrong. Drop it
    // rather than store it — the seed would have no way to tell.
    guard abs(measurementWidth - width) <= 0.5 else {
      lock.unlock()
      return nil
    }
    byChat[chatId] = prepared
    order.removeAll { $0 == chatId }
    order.append(chatId)
    while order.count > Self.maxChats, let oldest = order.first {
      order.removeFirst()
      byChat.removeValue(forKey: oldest)
    }
    preparations += 1
    let total = preparations
    lock.unlock()

    // `sized` is cumulative coverage, `fresh` is what this pass actually measured. Both
    // are needed: the old line printed only a count that happened to equal the cap on
    // every pass, which read as healthy while coverage never moved.
    NSLog(
      "[VibeCore] prepared chat=%@ rows=%d sized=%d fresh=%d carried=%d deferred=%d width=%.0f ms=%d reason=%@ scope=%@ total=%d",
      String(chatId.prefix(12)), rows.count, prepared.heightsByKey.count,
      pending.count, (existing?.heightsByKey.count ?? 0),
      prepared.deferredKeys.count, width, prepared.measureMs, reason,
      scope == .fullTranscript ? "full" : "page", total)
    return prepared
  }

  /// Whether a chat already has coverage at the current width — lets the launch restore
  /// skip a chat a persist has already prepared since launch.
  func hasCoverage(chatId: String) -> Bool {
    let width = currentMeasurementWidth
    guard width > 0 else { return false }
    return prepared(chatId: chatId, width: width) != nil
  }

  /// Forgets one chat. Called when its transcript is structurally healed — prepared
  /// heights for rows that no longer exist are a gap of the wrong size.
  func invalidate(chatId: String) {
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    guard byChat.removeValue(forKey: trimmed) != nil else { return }
    order.removeAll { $0 == trimmed }
  }

  // MARK: Read

  /// The prepared transcript for a chat, or `nil` when there is none at this width.
  ///
  /// Deliberately returns `nil` rather than a best effort: the caller's fallback is
  /// the exact measurement it does today, so a miss costs what the current build
  /// costs and nothing is risked by not having an answer.
  func prepared(chatId: String, width: CGFloat) -> Prepared? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = byChat[chatId], abs(entry.width - width) <= 0.5 else { return nil }
    return entry
  }

  /// One row's prepared height **and the row it was measured from**.
  ///
  /// The caller must confirm the row it is about to size still equals the one measured
  /// here before using the height, with the same predicate its in-memory cache uses.
  /// Returning the height alone would make this store the one height source in the app
  /// that cannot tell a stale answer from a fresh one.
  ///
  /// Hits and misses are tallied by ``noteHit(_:)`` at the call site rather than here,
  /// so a lookup the caller then rejects on content is counted as the miss it is.
  func preparedRow(chatId: String, key: String, width: CGFloat)
    -> (row: ChatListRow, measured: VibeRowMetrics.Measured)?
  {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = byChat[chatId], abs(entry.width - width) <= 0.5,
      let measured = entry.heightsByKey[key], let row = entry.rowsByKey[key]
    else { return nil }
    return (row, measured)
  }

  /// Records whether a prepared height was actually used.
  func noteHit(_ used: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if used { hits += 1 } else { misses += 1 }
  }

  /// `(hits, misses, preparations)` for the seed's liveness line.
  var stats: (hits: Int, misses: Int, preparations: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (hits, misses, preparations)
  }

  /// Resets counters and content. Tests only — the app has no reason to forget
  /// everything at once, and a shared singleton that tests mutate needs a way back.
  func resetForTesting() {
    lock.lock()
    defer { lock.unlock() }
    byChat.removeAll()
    order.removeAll()
    measurementWidth = 0
    preparations = 0
    hits = 0
    misses = 0
  }
}
