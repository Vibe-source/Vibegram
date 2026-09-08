import CoreGraphics
import Foundation

/// Records every time a row that was already sized changes height, and puts it
/// in the log that leaves the device.
///
/// # Why this exists
///
/// `docs/chat-list-seams-map.md` enumerates **twelve** places in `ChatListView`
/// where a settled row's height can change after the fact — the progressive
/// warmup, the stale-provisional media guess, the persisted-height audit, media
/// natural-size correction, slot repair, the tall/expand toggle, streaming
/// growth, a late group-flag flip, and more. Each one is a second code path that
/// can disagree with the first, and each disagreement is paid as a visible jump.
///
/// Those sites already logged, via `NSLog`, to a console nobody has attached
/// while using their phone. The `[HeightShift]` lines were therefore invisible in
/// exactly the situation that produces them. This funnel is the fix: the same
/// events, in `VibeLog`, in an exportable category.
///
/// # Why it does not log everything
///
/// A correction below the fold moves nothing the reader can see. A correction at
/// or above the viewport moves everything under it — that is the felt bug. So
/// the two are treated differently on purpose:
///
/// - **visible or above** → one line each, at `warning`. These are rare and each
///   one is a real defect worth a row in the export.
/// - **below or gone** → counted only, and reported as a periodic summary.
///
/// Logging all of them at full detail would reproduce the failure this project
/// has already shipped once, where a diagnostic flooded the ring buffer and
/// buried the rare line that mattered.
/// Lock-guarded rather than `@MainActor`, for one concrete reason: the summary
/// that matters is the one written when a chat closes, and `deinit` is not
/// actor-isolated. Corrections are rare enough that the lock is free.
final class VibeHeightShiftLog: @unchecked Sendable {
  private let lock = NSLock()

  /// Where a corrected row sat relative to the viewport, as reported by
  /// `ChatListView.heightShiftVisibility`.
  enum Visibility: String {
    case above = "ABOVE"
    case visible
    case below
    case gone
    case noneVisible = "none-visible"

    init(raw: String) {
      self = Visibility(rawValue: raw) ?? .gone
    }

    /// Whether a correction here moves content the reader is looking at.
    var movesTheScreen: Bool {
      self == .above || self == .visible
    }
  }

  private struct Tally {
    var shifts = 0
    var movedTheScreen = 0
    var totalDelta: CGFloat = 0
    var worstDelta: CGFloat = 0
  }

  private var byCause: [String: Tally] = [:]
  private var recorded = 0
  private var lastSummaryAt = 0

  /// Summaries are cheap but not free, and they are only interesting in bulk.
  private static let summaryInterval = 50

  /// Detail lines are capped per chat so a pathological list cannot fill the
  /// ring on its own. The tally keeps counting after the cap, so the summary
  /// still tells the truth about volume.
  private static let detailCap = 40
  private var detailsLogged = 0

  // MARK: Recording

  /// One settled row changed height.
  ///
  /// `cause` is the mechanism (`warmup`, `correct`, …) and `trigger` is what
  /// invoked it. Both are kept: the same corrector fires for very different
  /// reasons, and "which corrector" without "why" does not tell you what to fix.
  func record(
    cause: String,
    chatId: String,
    rowKey: String,
    descriptor: String,
    was: CGFloat,
    now: CGFloat,
    visibility: String,
    trigger: String
  ) {
    let delta = now - was
    let where_ = Visibility(raw: visibility)

    lock.lock()
    recorded += 1
    var tally = byCause[cause] ?? Tally()
    tally.shifts += 1
    tally.totalDelta += delta
    if abs(delta) > abs(tally.worstDelta) { tally.worstDelta = delta }
    if where_.movesTheScreen { tally.movedTheScreen += 1 }
    byCause[cause] = tally
    let shouldDetail = where_.movesTheScreen && detailsLogged < Self.detailCap
    if shouldDetail { detailsLogged += 1 }
    let dueForSummary = recorded - lastSummaryAt >= Self.summaryInterval
    lock.unlock()

    if shouldDetail {
      var meta: [String: String] = [:]
      meta["cause"] = cause
      meta["chat"] = String(chatId.prefix(12))
      meta["row"] = String(rowKey.suffix(14))
      meta["kind"] = descriptor
      meta["was"] = String(format: "%.0f", was)
      meta["now"] = String(format: "%.0f", now)
      meta["dh"] = String(format: "%+.0f", delta)
      meta["where"] = where_.rawValue
      meta["trigger"] = trigger
      VibeLog.warning("settled row changed height on screen", category: "shift", metadata: meta)
    }

    if dueForSummary { logSummary(chatId: chatId, reason: "interval") }
  }

  // MARK: Reporting

  /// Emits the running totals. Called on an interval and when a chat closes —
  /// the close is the one that matters, because it is the only moment the
  /// numbers for that conversation are final.
  func logSummary(chatId: String, reason: String) {
    lock.lock()
    guard recorded > 0 else { return lock.unlock() }
    lastSummaryAt = recorded
    let total = recorded
    let causes = byCause
    lock.unlock()

    var meta: [String: String] = [:]
    meta["chat"] = String(chatId.prefix(12))
    meta["reason"] = reason
    meta["total"] = String(total)
    var movedTotal = 0
    for (cause, tally) in causes.sorted(by: { $0.value.shifts > $1.value.shifts }) {
      movedTotal += tally.movedTheScreen
      meta[cause] =
        "\(tally.shifts) shifts, \(tally.movedTheScreen) on screen, "
        + String(format: "worst %+.0fpt", tally.worstDelta)
    }
    meta["onScreen"] = String(movedTotal)

    // The verdict, not the raw count: a list where nothing the reader could see
    // ever moved is the goal state, and it should be greppable as one word.
    if movedTotal == 0 {
      VibeLog.info("height shifts: none on screen", category: "shift", metadata: meta)
    } else {
      VibeLog.error("height shifts moved the screen", category: "shift", metadata: meta)
    }
  }

  /// Totals for a caller that wants to assert on them (tests, diagnostics).
  var totals: (recorded: Int, onScreen: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (recorded, byCause.values.reduce(0) { $0 + $1.movedTheScreen })
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    byCause.removeAll()
    recorded = 0
    lastSummaryAt = 0
    detailsLogged = 0
  }
}
