import Foundation

/// One durable record per chat open: the tap→content timeline, written to disk.
///
/// # Why this exists
///
/// Every `[ChatOpen]` / `[Seed]` / `[MainHang]` marker in this app is `NSLog`. `NSLog`
/// goes to the system log, which means it exists only while a console is attached to
/// the device. The two defects still being reported — an empty list on open, and a
/// stall before the chat appears — are both **intermittent**, and an intermittent bug
/// is by definition the one that happens when nobody is watching the stream. Asking the
/// reader to reproduce it under Console is asking them to reproduce it on demand, which
/// is exactly what they cannot do.
///
/// `VibeLog` already solves this — a ring buffer plus a rotating JSONL file under
/// Application Support, exportable from Diagnostics — and nothing in the open path used
/// it. So this collects the open's decisive facts in memory (a few strings, no I/O) and
/// writes **one** entry at the end. One entry per open keeps the 512KB file useful for
/// hundreds of opens rather than being flooded by per-cell chatter.
///
/// # What lands on disk
///
/// ```
/// [chatopen] chat=71312111f04b tap→content=189ms empty-at-push=N hang=0.47s DEGRADED
///   0ms route initial=16 · 85ms warm cached=63 heights=0 · 129ms seed warmSnapshot/63 stash
///   · 130ms seed routePreview/16 refusedShrink · 137ms prestage rows=63 raster=N
///   · 281ms push · 876ms appear · 893ms complete
/// ```
///
/// The verdict fields are the query surface: `empty-at-push=Y` is the empty list, and
/// `hang=` is the stall. Everything before them is the evidence for why.
final class VibeOpenTrace {

  static let shared = VibeOpenTrace()

  /// Beyond this the record is a wall of noise rather than a timeline. Opens that
  /// generate more stages than this are themselves the finding, so the overflow count
  /// is kept and reported rather than silently dropped.
  private static let maxStages = 40

  private struct Stage {
    let ms: Int
    let name: String
    let detail: String
  }

  /// Written from the main thread (every `mark`), read from the watchdog's queue
  /// (`activity`). `os_unfair_lock` for the same reason `VibeMainThreadWatchdog` uses
  /// one: the write side is on the path being measured and must stay free.
  private let lock: UnsafeMutablePointer<os_unfair_lock> = {
    let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    pointer.initialize(to: os_unfair_lock())
    return pointer
  }()

  private var chatId = ""
  private var startedAt: TimeInterval = 0
  private var stages: [Stage] = []
  private var droppedStages = 0
  private var firstContentMs = -1
  private var rowsAtPush = -1
  /// Whether a reopen raster covered the list at the instant of the push. Without it,
  /// `rowsAtPush == 0` reads as "the user saw a blank page" when most of the time it
  /// means the opposite — the seed was deliberately held back because the previous
  /// screenshot of this chat was already on screen. See `snapshotLocked`.
  private var coveredAtPush = false
  private var worstHangSeconds: Double = 0
  private var hangActivity = ""

  private init() {}

  // MARK: Recording

  /// The tap. Anchors every subsequent stage and closes any open record — a second tap
  /// before the first open finished is itself worth seeing on disk.
  func begin(chatId: String, detail: String) {
    let now = ProcessInfo.processInfo.systemUptime
    os_unfair_lock_lock(lock)
    let abandoned = startedAt > 0 && !stages.isEmpty
    let previous = snapshotLocked(verdict: "abandoned")
    self.chatId = String(chatId.prefix(12))
    startedAt = now
    stages = [Stage(ms: 0, name: "route", detail: detail)]
    droppedStages = 0
    firstContentMs = -1
    rowsAtPush = -1
    coveredAtPush = false
    worstHangSeconds = 0
    hangActivity = ""
    os_unfair_lock_unlock(lock)
    if abandoned, let previous {
      VibeLog.warning(previous.line, category: "chatopen", metadata: previous.metadata)
    }
  }

  /// One step of the open. `detail` is an autoclosure so a stage that is never recorded
  /// (no open in flight) costs nothing to describe.
  func mark(_ name: String, _ detail: @autoclosure () -> String = "") {
    let now = ProcessInfo.processInfo.systemUptime
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    guard startedAt > 0 else { return }
    guard stages.count < Self.maxStages else {
      droppedStages += 1
      return
    }
    stages.append(
      Stage(ms: Int((now - startedAt) * 1000), name: name, detail: detail()))
  }

  /// The moment the list stopped being empty. This is the number the reader actually
  /// experiences as "how long until my chat is there", and it is not any of the
  /// existing stage timestamps — a push can start, animate and complete over an empty
  /// list, which is the whole defect.
  func noteContentMounted(rows: Int) {
    let now = ProcessInfo.processInfo.systemUptime
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    guard startedAt > 0, firstContentMs < 0, rows > 0 else { return }
    firstContentMs = Int((now - startedAt) * 1000)
  }

  /// Rows mounted at the instant `pushViewController` is called, and whether a reopen
  /// raster was covering the list at that moment.
  ///
  /// Zero rows is only the empty list when `covered` is false. The first export from a
  /// reader's device made that distinction the difference between a useful log and a
  /// useless one: ten of twelve opens reported `rows@push=0` and were flagged degraded,
  /// all of them `covered=Y` and all of them fine — the seed is *supposed* to wait under
  /// a raster, because those pixels already are the destination. The single genuinely
  /// blank push in the export (`raster=N covered=N`, nothing ever mounted) was sitting in
  /// the middle of nine false alarms wearing the same badge.
  func noteRowsAtPush(_ rows: Int, covered: Bool) {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    guard startedAt > 0, rowsAtPush < 0 else { return }
    rowsAtPush = rows
    coveredAtPush = covered
  }

  /// A main-thread stall observed by the watchdog. Recorded even when no open is in
  /// flight (`startedAt == 0`) — a hang outside an open still gets its own disk entry
  /// from the watchdog; this only attaches it to the open when there is one.
  ///
  /// `activity` is the stage the watchdog captured when it *detected* the hang, and it
  /// is passed in rather than re-derived here for a reason the first export demonstrated:
  /// this used to read `stages.last` at recovery, so the same 0.57s block was filed under
  /// `prestage` by the watchdog and under `seed engineSnapshot/999 retainedFrozen` by the
  /// trace — two names for one stall, in one export, neither obviously the right one.
  /// Where a hang *starts* is the part that assigns blame; where it happens to end is not.
  func noteHang(seconds: Double, mode: String, activity: String) {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    guard startedAt > 0, seconds > worstHangSeconds else { return }
    worstHangSeconds = seconds
    hangActivity = activity
    _ = mode
  }

  /// What the main thread was last seen doing. The watchdog reports a duration and a
  /// run-loop mode but cannot name a function; this is the nearest thing to a stack
  /// that costs nothing to maintain.
  var activity: String {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    guard let last = stages.last else { return "idle" }
    return "\(chatId)/\(last.name)"
  }

  /// Closes the record and writes it. Idempotent: a second call with no open in flight
  /// does nothing, so it is safe to call from both the settle path and teardown.
  func finish(verdict: String) {
    os_unfair_lock_lock(lock)
    let record = snapshotLocked(verdict: verdict)
    startedAt = 0
    stages.removeAll(keepingCapacity: true)
    os_unfair_lock_unlock(lock)
    guard let record else { return }
    if record.degraded {
      VibeLog.warning(record.line, category: "chatopen", metadata: record.metadata)
    } else {
      VibeLog.notice(record.line, category: "chatopen", metadata: record.metadata)
    }
  }

  // MARK: Rendering

  private struct Record {
    let line: String
    let metadata: [String: String]
    let degraded: Bool
  }

  /// Caller holds the lock.
  private func snapshotLocked(verdict: String) -> Record? {
    guard startedAt > 0, !stages.isEmpty else { return nil }
    // Degraded means "the reader would have noticed". Each of these is one of the two
    // standing reports, stated as a condition rather than a threshold on a total:
    // an open can be fast overall and still have shown a blank page mid-way.
    // Empty means the reader was looking at nothing — an uncovered push with no rows.
    // A covered push with no rows is the design working.
    let startedEmpty = rowsAtPush == 0 && !coveredAtPush
    let slow = firstContentMs < 0 || firstContentMs > 700
    let hung = worstHangSeconds > 0
    let degraded = startedEmpty || slow || hung
    let timeline =
      stages
      .map { stage in
        stage.detail.isEmpty
          ? "\(stage.ms)ms \(stage.name)"
          : "\(stage.ms)ms \(stage.name) \(stage.detail)"
      }
      .joined(separator: " · ")
    let overflow = droppedStages > 0 ? " (+\(droppedStages) more)" : ""
    let line =
      "chat=\(chatId) tap→content=\(firstContentMs)ms "
      + "rows@push=\(rowsAtPush)\(coveredAtPush ? " covered" : "") "
      + "hang=\(String(format: "%.2f", worstHangSeconds))s \(verdict)"
      + (degraded ? " DEGRADED" : "") + " | " + timeline + overflow
    var metadata: [String: String] = [
      "chat": chatId,
      "contentMs": String(firstContentMs),
      "rowsAtPush": String(rowsAtPush),
      "coveredAtPush": coveredAtPush ? "Y" : "N",
      "verdict": verdict,
    ]
    if hung {
      metadata["hangSeconds"] = String(format: "%.2f", worstHangSeconds)
      metadata["hangDuring"] = hangActivity
    }
    if startedEmpty { metadata["emptyAtPush"] = "Y" }
    return Record(line: line, metadata: metadata, degraded: degraded)
  }
}
