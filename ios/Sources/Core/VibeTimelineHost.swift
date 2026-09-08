import CoreGraphics
import Foundation
import UIKit

// MARK: - Metrics

/// Bubble geometry constants used to measure a row.
///
/// These live in Swift and always will. The core decides *what* a row is and
/// *whether* a change can affect its height; it cannot decide *how tall* the row
/// is, because that is `UIFont`, Dynamic Type, the text engine, and the device's
/// line-breaking rules. Anyone hoping the Rust core would make scrolling smooth
/// by itself should read this struct and §0 of the refactor doc.
struct VibeTimelineMetrics: Equatable {
  var horizontalInset: CGFloat = 12
  var bubblePaddingH: CGFloat = 11
  var bubblePaddingV: CGFloat = 7
  var interRowSpacing: CGFloat = 4
  var metaHeight: CGFloat = 13
  var maxBubbleWidthFraction: CGFloat = 0.78
  var minRowHeight: CGFloat = 28
  /// Width the inline clock + delivery ticks occupy on the last text line.
  var inlineMetaWidth: CGFloat = 52
  /// Gap between the end of the text and the inline meta.
  var inlineMetaGap: CGFloat = 8

  /// Height reserved for media whose natural size is not yet known.
  ///
  /// Deliberately **not** a square. Guessing square and correcting after decode
  /// is the media list-shift bug; a fixed reservation is wrong-looking at worst,
  /// whereas a corrected guess moves every row below it.
  var unknownMediaHeight: CGFloat = 220

  static let `default` = VibeTimelineMetrics()
}

// MARK: - Measured geometry cache

/// One row's frozen geometry.
///
/// `revision` only advances when something *allowed* to change height did.
struct VibeMeasuredRow: Equatable {
  let size: CGSize
  let layout: VibeBubbleLayoutSpec
  let revision: UInt64
}

/// Measures rows and, more importantly, refuses to re-measure settled ones.
///
/// # The actual layout-shift fix
///
/// The shipped list re-derives a row's height whenever anything about the row
/// changes, and estimates it when measurement is too expensive. Both are how a
/// settled row's height moves after it is on screen: an estimate that was ~16 pt
/// short, a media box that guessed square and corrected after decode, a receipt
/// arriving and dragging a re-layout with it.
///
/// Here a settled row is measured **once** and the result is frozen. A
/// content-only op reuses the frozen size verbatim — it is not re-measured and
/// then compared, it is never measured again at all, so there is nothing to
/// drift. Height can only change through `UpdateGeometry`, which the core emits
/// only for the mask bits that are geometry-relevant (§5.3), and which the host
/// applies with anchor preservation.
///
/// The cache is invalidated wholesale by width, Dynamic Type, or theme changes —
/// those legitimately re-measure everything, and §5.4 says they get one new
/// snapshot and one preserve, not per-row thrash.
@MainActor
final class VibeRowMeasurementCache {
  private var rows: [String: VibeMeasuredRow] = [:]
  private var width: CGFloat = 0
  private var contentSizeCategory: UIContentSizeCategory = .large
  private var themeEpoch: UInt64 = 0

  /// The parsed row behind a message id.
  ///
  /// The seam that lets the core size a **real** conversation. Without it the
  /// measurement below is a placeholder — one font, one media box, no reply chrome, no
  /// reactions, no agent turns — which was fine while the host also drew a placeholder
  /// bubble, and became a guaranteed mismatch the moment it started drawing
  /// `ChatListCell`. A real cell in a placeholder-sized slot is exactly the "measured
  /// one thing, drew another" defect, just relocated.
  ///
  /// Supplied by the chat surface, alongside the host's own `rowProvider`. Absent (the
  /// Diagnostics preview) the placeholder still applies.
  var rowProvider: ((String) -> ChatListRow?)?

  /// The row's live agent-turn state (expanded / streaming / tall), from the same surface
  /// that supplies `rowProvider`.
  ///
  /// Without it this measured every agent row with a default-constructed
  /// `AgentTurnBubbleState`, while the list measures with the row's REAL state — so the
  /// two sized the same row from different inputs and could never agree. That is the
  /// disagreement blocking the geometry flip, and it is not the flat 8pt on every row it
  /// was recorded as: a plain 1,386-row chat reports `geometry AGREES … placeholders=0`,
  /// while the rows that differ carry `b-…` (bridge/agent) keys —
  /// `differed=5 worst=b-74be38704a52 core=34.0 list=40.0`.
  ///
  /// Same row, same width, same state ⇒ same height, because both sides call the same
  /// `VibeRowMetrics` measurement.
  var agentStateProvider: ((ChatListRow) -> AgentTurnBubbleState)?

  /// A height this row already has, from something that measured it for real.
  ///
  /// The seam that stops this cache re-deriving numbers the app is already holding.
  /// `measure` below is a full text layout — `VibeRowMetrics.mainThreadHeight` is the
  /// exact sizing path, not an estimate — and `mount` runs it once per row in the
  /// window, on the main thread, inside the push. On a 999-row chat that measured at
  /// **0.57s** (device export 2026-08-07, `hangDuring=176cdf92eec5/will-appear`), while
  /// the list sized the same 999 rows in **13ms** from its persisted-height file
  /// (`seed-where sizeCalls=999/13ms trust=999 measure=0/0ms`). Same rows, same width,
  /// same answer, 40× apart — the expensive copy ran during the transition.
  ///
  /// So ask first. A hit is a dictionary lookup and counts as a real measurement,
  /// because it *is* one: the persisted entry was measured by this app at this width
  /// and is re-validated off-main after the push by `auditSeedTrustedHeights`.
  ///
  /// Absent (the Diagnostics preview, which has no list behind it) everything below
  /// behaves exactly as before.
  var knownHeightProvider: ((ChatListRow, CGFloat) -> CGFloat?)?

  /// How many rows a single mount may measure from scratch on the main thread.
  ///
  /// Only rows that neither this cache nor ``knownHeightProvider`` can answer are
  /// counted, so on a warm chat the budget is never reached. It exists for the cold
  /// case — a chat opened for the first time, no persisted heights — where the
  /// un-budgeted loop is unbounded main-thread work in the middle of a push.
  ///
  /// Rows past the budget are sized by ``placeholderMeasure(_:revision:)`` and recorded
  /// in ``placeholderIds`` exactly like any other estimate, which is what makes this
  /// safe rather than merely fast: `coreFrozenHeight` already refuses placeholder rows,
  /// so a deferred row's height cannot reach the screen.
  ///
  /// # Why nothing upgrades the deferred rows
  ///
  /// Because on the only surface that can reach the budget, nothing reads the result.
  /// `coreFrozenHeight` is consulted by `estimateMessageHeight` alone, and `rowHeight`
  /// routes there only while `rows.count <= 12` — see the note on
  /// `ChatListView.apply(snapshot:reason:)`. A chat small enough for the geometry to be
  /// load-bearing cannot exhaust a budget set far above 12, and a chat large enough to
  /// exhaust it is one whose heights are already ignored. So the budget engages
  /// **only** where the measurement was dead work, which is why it needs no
  /// compensating machinery — and why ``deferredIds`` is a record rather than a queue.
  ///
  /// That reasoning is load-bearing: if the geometry flip ever widens the reader past
  /// 12 rows, this needs a real upgrade pass before it ships, and `deferred` in the
  /// `mount cost` diagnostic is how you will see that it is owed.
  ///
  /// `.max` is "measure everything", which is the preview's behaviour and was
  /// everyone's before this existed.
  var exactMeasurementBudget: Int = .max

  /// Rows this mount deferred for budget, awaiting a real measurement.
  private(set) var deferredIds: Set<String> = []
  private var exactMeasurementsThisMount = 0

  private(set) var measurements = 0
  private(set) var reuses = 0
  private(set) var invalidations = 0
  /// Rows answered from ``knownHeightProvider`` instead of a fresh text layout.
  private(set) var knownHeightHits = 0
  /// Rows this mount pushed past ``exactMeasurementBudget``.
  private(set) var budgetDeferrals = 0
  /// Rows the provider could not supply, so they were sized by the placeholder. In a
  /// real chat this must be zero — a non-zero count means the core is laying out rows
  /// it cannot actually size, and the heights on screen are fiction.
  private(set) var placeholderMeasurements = 0
  /// Rows whose height is an estimate rather than a measurement. Nothing may
  /// freeze one — see ``measure(_:revision:)``.
  private(set) var placeholderIds: Set<String> = []

  var metrics: VibeTimelineMetrics = .default

  /// Returns true when the environment changed and every row must be re-measured.
  @discardableResult
  func setEnvironment(
    width: CGFloat, contentSizeCategory: UIContentSizeCategory, themeEpoch: UInt64
  ) -> Bool {
    guard
      width != self.width || contentSizeCategory != self.contentSizeCategory
        || themeEpoch != self.themeEpoch
    else { return false }
    self.width = width
    self.contentSizeCategory = contentSizeCategory
    self.themeEpoch = themeEpoch
    rows.removeAll(keepingCapacity: true)
    // Every deferral described the old environment. Keeping them would upgrade rows
    // to heights measured against a width that no longer exists, which is the one
    // failure worse than not upgrading them at all.
    deferredIds.removeAll(keepingCapacity: true)
    placeholderIds.removeAll(keepingCapacity: true)
    invalidations += 1
    return true
  }

  /// Opens a fresh main-thread measurement budget for one mount.
  ///
  /// Per mount, not per session: the budget bounds how long a *single* runloop turn can
  /// block, and a chat open is several mounts (arm, then engine reconcile). Carrying a
  /// spent budget across them would starve every mount after the first.
  func beginMountBudget() { exactMeasurementsThisMount = 0 }

  var layoutWidth: CGFloat { width }

  func cached(_ messageId: String) -> VibeMeasuredRow? { rows[messageId] }

  func forget(_ messageId: String) {
    rows.removeValue(forKey: messageId)
    deferredIds.remove(messageId)
  }

  func forgetAll() {
    rows.removeAll(keepingCapacity: true)
    deferredIds.removeAll(keepingCapacity: true)
    placeholderIds.removeAll(keepingCapacity: true)
  }

  /// Frozen geometry for a settled row: measured on first sight, reused forever.
  ///
  /// With one exception, and it is the exception that decides whether the core can ever
  /// size a real chat. A row first seen before the list mounted its rows has no
  /// `rowProvider` answer, so it is sized by ``placeholderMeasure(_:revision:)`` — and
  /// this cache then reused that guess forever, because a placeholder was stored exactly
  /// like a measurement. The core mounts its window during the push, when the
  /// presentation seed is still stashed, so on a real chat that is *every* row: device
  /// run 2026-08-04, `geometry DIFFERS … differed=9 worst core=42.0 list=34.0` — nine of
  /// nine rows, permanently frozen at a font-and-a-box guess, and nothing in the app
  /// would ever measure them again.
  ///
  /// `measure` already records those ids in `placeholderIds`, and `coreFrozenHeight`
  /// already refuses them, so the guess was never *rendered* — it simply meant the core's
  /// geometry could never become usable, which reads in the log as a permanent 8pt
  /// disagreement and blocks the flip that seam exists for. Retry once the provider can
  /// answer; a real measurement is still taken once and frozen, which is the invariant
  /// this cache is actually defending.
  func settledGeometry(for message: VibeFfiMessage) -> VibeMeasuredRow {
    if let hit = rows[message.messageId] {
      // A real measurement is taken once and frozen. That is the invariant.
      guard placeholderIds.contains(message.messageId) else {
        reuses += 1
        return hit
      }
      // A guess is only worth replacing once the provider can actually answer —
      // otherwise re-running the same estimate on every window buys nothing.
      guard rowProvider?(message.messageId) != nil else {
        reuses += 1
        return hit
      }
    }
    let measured = measure(message, revision: 1)
    rows[message.messageId] = measured
    measurements += 1
    return measured
  }

  /// Re-measures a row that is *allowed* to change height, bumping its revision.
  ///
  /// The only legitimate way a settled row's size moves.
  func remeasure(_ message: VibeFfiMessage) -> VibeMeasuredRow {
    let previous = rows[message.messageId]?.revision ?? 0
    let measured = measure(message, revision: previous + 1)
    rows[message.messageId] = measured
    measurements += 1
    return measured
  }

  // MARK: Measurement

  private func measure(_ message: VibeFfiMessage, revision: UInt64) -> VibeMeasuredRow {
    if let row = rowProvider?(message.messageId) {
      // Free: a height this app already measured, at this width, and persisted.
      // Nothing below can produce a better answer than the one that is already correct.
      if let known = knownHeightProvider?(row, width), known > 0 {
        knownHeightHits += 1
        placeholderIds.remove(message.messageId)
        deferredIds.remove(message.messageId)
        return measuredFromRealRow(height: known, revision: revision)
      }
      // Not free: a full text layout, and on an agent turn a template view plus
      // `systemLayoutSizeFitting`. Budgeted because this runs inside the push — see
      // ``exactMeasurementBudget``.
      if exactMeasurementsThisMount < exactMeasurementBudget {
        if let height = VibeRowMetrics.mainThreadHeight(
          row: row, rowWidth: width,
          state: agentStateProvider?(row) ?? AgentTurnBubbleState())
        {
          exactMeasurementsThisMount += 1
          placeholderIds.remove(message.messageId)
          deferredIds.remove(message.messageId)
          return measuredFromRealRow(height: height, revision: revision)
        }
      } else {
        // Measurable, just not on this runloop turn. Recorded so the deferred pass
        // can finish it; it falls through to the estimate below, which is marked as
        // a placeholder and therefore refused by every consumer that freezes heights.
        budgetDeferrals += 1
        deferredIds.insert(message.messageId)
      }
    }
    // Remember that this row's height is a guess.
    //
    // A placeholder is a font-and-a-box estimate, and the list must never freeze
    // one: at first mount the list holds only its seed rows, so `rowProvider`
    // answers `nil` for almost everything and every row would freeze at the
    // estimate. Measured on device 2026-08-03 — 102 of 118 rows frozen at 55pt
    // against a real 34pt, which is a visible shift on a settled transcript.
    //
    // Cleared as soon as a real measurement lands, so a row is only untrusted for
    // as long as it is actually unmeasured.
    placeholderIds.insert(message.messageId)
    placeholderMeasurements += 1
    return placeholderMeasure(message, revision: revision)
  }

  /// Geometry for a row that `ChatListCell` will draw.
  ///
  /// Only the height is real, and only the height is used: the cell owns its own
  /// internal layout, so the bubble spec and media box below are not consulted for these
  /// rows. They are filled in finite and non-zero because `VibeRenderItemValidator`
  /// rejects degenerate geometry, and a rejected item is a dropped row.
  private func measuredFromRealRow(height: CGFloat, revision: UInt64) -> VibeMeasuredRow {
    VibeMeasuredRow(
      size: CGSize(width: max(1, width), height: max(1, ceil(height))),
      layout: VibeBubbleLayoutSpec(
        textFrame: .zero,
        mediaBoxFrame: .zero,
        replyFrame: .zero,
        metaFrame: .zero,
        avatarGutter: .zero
      ),
      revision: revision
    )
  }

  /// The pre-`rowProvider` measurement: one font, one media box, no chrome.
  ///
  /// Kept for the Diagnostics preview, which has no parsed rows to provide. It must
  /// never size a real chat — see `placeholderMeasurements`.
  private func placeholderMeasure(_ message: VibeFfiMessage, revision: UInt64) -> VibeMeasuredRow {
    let available = max(80, width - metrics.horizontalInset * 2)
    let maxBubble = max(60, available * metrics.maxBubbleWidthFraction)
    let textWidth = maxBubble - metrics.bubblePaddingH * 2

    let font = UIFont.preferredFont(
      forTextStyle: .body,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
    )

    var contentHeight: CGFloat = 0
    var contentWidth: CGFloat = 0

    // Media first: it dictates the bubble width when present.
    var mediaFrame = CGRect.zero
    if message.hasMedia {
      // No natural size crosses this boundary yet, so every media row reserves
      // the same box and keeps it. When `VibeFfiMessage` starts carrying natural
      // size this becomes `aspect * width`, still measured once and frozen.
      mediaFrame = CGRect(x: 0, y: 0, width: textWidth, height: metrics.unknownMediaHeight)
      contentHeight += mediaFrame.height
      contentWidth = max(contentWidth, mediaFrame.width)
    }

    var textFrame = CGRect.zero
    let body = message.text.isEmpty ? (message.caption ?? "") : message.text
    if !body.isEmpty {
      let bounds = (body as NSString).boundingRect(
        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      )
      let h = ceil(bounds.height)
      textFrame = CGRect(x: 0, y: contentHeight, width: ceil(bounds.width), height: h)
      contentHeight += h
      contentWidth = max(contentWidth, textFrame.width)
    }

    var replyFrame = CGRect.zero
    if message.hasReply {
      // Reply chrome is fixed-height by design. A variable-height reply preview
      // whose height arrives with the quoted message is another way a settled row
      // moves, so it does not get to be variable here.
      replyFrame = CGRect(x: 0, y: 0, width: textWidth, height: 34)
      contentHeight += replyFrame.height
      textFrame.origin.y += replyFrame.height
      mediaFrame.origin.y += replyFrame.height
      contentWidth = max(contentWidth, replyFrame.width)
    }

    // The meta (clock + ticks) sits on the LAST TEXT LINE when there is room beside it,
    // and only takes its own line when there is not. Reserving a line unconditionally
    // over-measured every short row by exactly `metaHeight` + its share of padding:
    // device run 2026-08-03 reported `core=55.0 list=34.0` on all 200 rows of a chat
    // whose bubbles are one word long. A renderer that draws the meta inline and a
    // measurer that stacks it can never agree, and this is the measurer's error.
    let metaWidth = metrics.inlineMetaWidth
    let fitsInline =
      !message.hasMedia
      && textFrame.height > 0
      && textFrame.height <= ceil(font.lineHeight) + 1
      && textFrame.width + metrics.inlineMetaGap + metaWidth <= textWidth
    let metaFrame: CGRect
    if fitsInline {
      metaFrame = CGRect(
        x: textFrame.maxX + metrics.inlineMetaGap,
        y: textFrame.maxY - metrics.metaHeight,
        width: metaWidth, height: metrics.metaHeight)
      contentWidth = max(contentWidth, metaFrame.maxX)
    } else {
      contentHeight += metrics.metaHeight
      metaFrame = CGRect(
        x: 0, y: contentHeight - metrics.metaHeight, width: contentWidth,
        height: metrics.metaHeight)
    }

    let bubbleWidth = min(maxBubble, contentWidth + metrics.bubblePaddingH * 2)
    let rowHeight = max(
      metrics.minRowHeight, contentHeight + metrics.bubblePaddingV * 2 + metrics.interRowSpacing)

    return VibeMeasuredRow(
      size: CGSize(width: bubbleWidth, height: ceil(rowHeight)),
      layout: VibeBubbleLayoutSpec(
        textFrame: textFrame,
        mediaBoxFrame: mediaFrame,
        replyFrame: replyFrame,
        metaFrame: metaFrame,
        avatarGutter: .zero
      ),
      revision: revision
    )
  }
}

// MARK: - Order key

enum VibeTimelineOrderKeyFactory {
  /// Maps a message onto the render contract's order key.
  ///
  /// `rank` is the timestamp mapped order-preservingly onto `UInt64` (flip the
  /// sign bit) so pre-1970 timestamps cannot sort above everything.
  ///
  /// `tieBreak` is the first eight bytes of the message id, big-endian and zero
  /// padded — **not** a hash. The core's total order is `ts_ms ASC, message_id
  /// ASC`, and a hash would order same-millisecond messages arbitrarily, which
  /// the snapshot validator would then correctly reject as non-ascending. This
  /// preserves lexicographic order for the first eight bytes; ids sharing a
  /// longer prefix tie, which is harmless because the array order still comes
  /// from the core.
  static func key(tsMs: Int64, messageId: String) -> VibeOrderKey {
    let rank = UInt64(bitPattern: tsMs) ^ (1 << 63)
    var tie: UInt64 = 0
    for byte in messageId.utf8.prefix(8) { tie = (tie << 8) | UInt64(byte) }
    let shortfall = 8 - min(8, messageId.utf8.count)
    tie <<= UInt64(shortfall * 8)
    return VibeOrderKey(rank: rank, tieBreak: tie)
  }
}

// MARK: - Render item factory

/// Turns a core message into a render item, using frozen geometry.
@MainActor
struct VibeRenderItemFactory {
  let cache: VibeRowMeasurementCache

  /// A row as it should look when nothing is changing.
  func settledItem(_ message: VibeFfiMessage) -> VibeRenderItem {
    let geometry = cache.settledGeometry(for: message)
    return item(message, geometry: geometry, contentRevision: message.contentHash)
  }

  /// A row after a content-only change: **the frozen size is reused**.
  ///
  /// This is the contract enforced by construction. There is no code path here
  /// that measures on a content-only op, so no amount of later carelessness can
  /// make a receipt move a bubble.
  func contentUpdatedItem(_ message: VibeFfiMessage) -> VibeRenderItem {
    let geometry = cache.cached(message.messageId) ?? cache.settledGeometry(for: message)
    return item(message, geometry: geometry, contentRevision: message.contentHash)
  }

  /// A row after a geometry-relevant change: re-measured, revision bumped.
  func geometryUpdatedItem(_ message: VibeFfiMessage) -> (VibeRenderItem, CGFloat) {
    let before = cache.cached(message.messageId)?.size.height ?? 0
    let geometry = cache.remeasure(message)
    let updated = item(message, geometry: geometry, contentRevision: message.contentHash)
    return (updated, geometry.size.height - before)
  }

  private func item(
    _ message: VibeFfiMessage, geometry: VibeMeasuredRow, contentRevision: UInt64
  ) -> VibeRenderItem {
    var flags: VibeRenderItemFlags = []
    // `VibeMessageFlags` bit 1 is streaming; see `vibe_core::types`. A streaming
    // row is explicitly not settled, which is what lets it grow.
    let isStreaming = (message.flags & (1 << 1)) != 0
    if isStreaming {
      flags.insert(.streaming)
    } else {
      flags.insert(.settled)
    }
    if message.hasMedia { flags.insert(.provisionalMedia) }

    return VibeRenderItem(
      identity: VibeTimelineAnchor(
        messageId: message.messageId, identityGeneration: geometry.revision),
      orderKey: VibeTimelineOrderKeyFactory.key(
        tsMs: message.tsMs, messageId: message.messageId),
      kind: renderKind(message),
      contentRevision: contentRevision,
      geometryRevision: geometry.revision,
      size: geometry.size,
      layout: geometry.layout,
      paint: VibePaintSpec(
        backgroundToken: message.authorIsMe ? "bubble.outgoing" : "bubble.incoming",
        textStyleToken: message.authorIsMe ? "text.body.outgoing" : "text.body"
      ),
      mediaSlots: message.hasMedia
        ? [
          VibeMediaSlot(
            frame: geometry.layout.mediaBoxFrame,
            aspectRatio: 0,
            placeholderToken: nil,
            loadKey: message.messageId
          )
        ] : [],
      interaction: VibeInteractionSpec(
        accessibilityLabel: message.text.isEmpty ? (message.caption ?? "") : message.text
      ),
      flags: flags
    )
  }

  private func renderKind(_ message: VibeFfiMessage) -> VibeRenderItemKind {
    if message.hasService { return .service }
    if message.hasAgent { return .agentTurn }
    return .message
  }
}

// MARK: - Body sink

/// Optional companion to ``VibeMessageListHost`` for hosts that paint text.
///
/// `VibeRenderItem` deliberately carries geometry and theme *tokens* and no
/// message bodies, so that a render item can be logged, diffed, or compared in
/// shadow mode without leaking plaintext. Painting still needs the text, so it
/// travels on a separate, explicitly-named channel rather than being smuggled
/// into the render contract.
@MainActor
protocol VibeMessageListBodySink: AnyObject {
  func setBodies(_ bodies: [String: String], details: [String: String])
}

/// Optional companion for hosts that outlive the engine driving them.
///
/// A generation fence is only meaningful within one engine's lifetime. When the
/// engine is replaced — logout, chat switch, a `reset` — the new one starts its
/// generations from zero while a long-lived host is still holding the old one's
/// high-water mark, so every transaction from the replacement is fenced off as
/// stale. The host keeps showing the dead engine's rows until a full mount
/// happens to arrive.
///
/// Nothing about a transaction distinguishes "arrived out of order" from "came
/// from a different engine", so the fence cannot infer this. It has to be told.
@MainActor
protocol VibeMessageListEngineLifecycle: AnyObject {
  /// Drops all rows and generation state. The next mount starts clean.
  func detachFromEngine()
}

// MARK: - VibeTimelineHost

/// Drives a ``VibeMessageListHost`` from the Rust core.
///
/// # Where the split falls
///
/// | Concern | Owner |
/// |---|---|
/// | order, dedup, windowing, what changed | Rust core |
/// | *is this change allowed to move the row* | Rust core (`VibeChangeMask`) |
/// | how tall the row is | **this file, in Swift** |
/// | where the scroll offset goes afterwards | the list host |
///
/// The core never learns about points, fonts, or the screen. This class never
/// decides what order rows go in. That boundary is the whole design.
///
/// # Threading
///
/// Core callbacks arrive on the Rust worker thread. Everything here is
/// `@MainActor`; the sink hops before touching any of it. Transactions are
/// funnelled through ``VibeListDisplayLinkCommitter`` so a burst of deltas
/// becomes at most one commit per frame (§5.5).
@MainActor
final class VibeTimelineHost {
  private let chatId: String
  private let listHost: VibeMessageListHost
  private let committer = VibeListDisplayLinkCommitter()
  private let cache = VibeRowMeasurementCache()
  private let factory: VibeRenderItemFactory

  /// Mirror of the applied window, oldest → newest. The core owns truth; this is
  /// only what has actually been committed to the list.
  private var applied: [VibeRenderItem] = []
  private var generation: UInt64 = 0
  private var themeEpoch: UInt64 = 0

  /// Row text, kept out of `VibeRenderItem` on purpose. See ``VibeMessageListBodySink``.
  private var bodies: [String: String] = [:]
  private var details: [String: String] = [:]

  /// A window that arrived before the list knew how wide it was.
  ///
  /// Held rather than dropped: measuring against a placeholder width and
  /// correcting later is precisely the shift this stack exists to remove, so the
  /// mount waits for a real width instead of guessing at one.
  private var pendingMountWindow: VibeFfiWindow?
  private var pendingMountReason: VibeMountReason = .engineReconcile

  /// Set when a delta could not be applied and the core must be re-queried.
  /// The owner drives the resync — this class has no handle to ask with.
  var onNeedsResync: (() -> Void)?

  /// True between asking for a window and mounting one. Keeps a burst from
  /// queueing one full-window request per delta.
  private var resyncOutstanding = false

  /// Counters for the qualification gates in §9.1. Ids and numbers only.
  private(set) var appliedTransactions = 0
  private(set) var rejectedTransactions = 0
  private(set) var settledGeometryChanges = 0

  var onDiagnostic: ((String, [String: String]) -> Void)?

  init(chatId: String, listHost: VibeMessageListHost) {
    self.chatId = chatId
    self.listHost = listHost
    self.factory = VibeRenderItemFactory(cache: cache)
    committer.onCommit = { [weak self] transaction in
      guard let self else { return }
      self.pushBodies()
      self.listHost.apply(transaction: transaction)
      self.appliedTransactions += 1
    }
  }

  deinit {
    // `committer` is main-actor isolated and cannot be invalidated from deinit.
    // `invalidate()` is called from `shutdown()`; the proxy holds no strong
    // reference back, so a missed call leaks a paused display link at worst.
  }

  func shutdown() {
    committer.cancelPending()
    committer.invalidate()
    // The list may well outlive this adapter — it does in the preview, and it
    // will in production, where the view is reused across chats. Leaving it
    // holding this engine's generation high-water mark fences off everything the
    // next engine sends.
    (listHost as? VibeMessageListEngineLifecycle)?.detachFromEngine()
    applied.removeAll()
    bodies.removeAll()
    details.removeAll()
    cache.forgetAll()
    pendingMountWindow = nil
    resyncOutstanding = false
    generation = 0
  }

  /// Sets the layout environment. Returns true when everything must be re-measured.
  @discardableResult
  func setEnvironment(
    width: CGFloat,
    contentSizeCategory: UIContentSizeCategory = UIApplication.shared.preferredContentSizeCategory,
    themeEpoch: UInt64 = 0
  ) -> Bool {
    self.themeEpoch = themeEpoch
    let changed = cache.setEnvironment(
      width: width, contentSizeCategory: contentSizeCategory, themeEpoch: themeEpoch)
    guard changed else { return false }

    // A window that was waiting on a width can now be measured correctly the
    // first time, which is the whole point of having waited.
    if let pending = pendingMountWindow, width > 0 {
      mount(window: pending, reason: pendingMountReason)
      return true
    }
    // Everything already on screen was measured against the old environment and
    // must be re-derived. §5.4: one new snapshot and one preserve, not per-row
    // thrash — so ask the owner for a fresh window rather than re-measuring
    // piecemeal from a mirror that may already be stale.
    if !applied.isEmpty { onNeedsResync?() }
    return true
  }

  /// Supplies the parsed row behind a message id, for both measuring and drawing.
  ///
  /// One provider for both on purpose: a chat that can draw a row but not size it (or
  /// the reverse) puts a real cell in a placeholder slot, which is the same
  /// measured-one-thing-drew-another defect the core exists to remove. Set it before the
  /// first mount — rows measured without it are counted in `placeholderMeasurements`.
  func setRowProvider(_ provider: @escaping (String) -> ChatListRow?) {
    cache.rowProvider = provider
    (listHost as? VibeCollectionMessageListHost)?.rowProvider = provider
  }

  /// Agent-turn state for the rows `rowProvider` supplies. Set it alongside the provider:
  /// measuring an agent row without it uses a default state and produces a height the list
  /// will never draw. See `VibeRowMeasurementCache.agentStateProvider`.
  func setAgentStateProvider(_ provider: @escaping (ChatListRow) -> AgentTurnBubbleState) {
    cache.agentStateProvider = provider
  }

  /// Installs the "you already know this height" seam. See
  /// ``VibeRowMeasurementCache/knownHeightProvider``.
  func setKnownHeightProvider(_ provider: @escaping (ChatListRow, CGFloat) -> CGFloat?) {
    cache.knownHeightProvider = provider
  }

  /// Caps the main-thread text layouts one mount may run. See
  /// ``VibeRowMeasurementCache/exactMeasurementBudget``.
  func setExactMeasurementBudget(_ budget: Int) {
    cache.exactMeasurementBudget = budget
  }

  var measurementStats: (measured: Int, reused: Int, invalidations: Int, placeholders: Int) {
    (cache.measurements, cache.reuses, cache.invalidations, cache.placeholderMeasurements)
  }

  /// Message ids whose height is an estimate. A consumer that freezes heights must
  /// exclude these — an estimate frozen as if it were a measurement is a shift.
  var placeholderMessageIds: Set<String> { cache.placeholderIds }

  // MARK: Mount

  /// Mounts a full window. Used for first paint, reopen, and trait changes.
  func mount(window: VibeFfiWindow, reason: VibeMountReason) {
    guard cache.layoutWidth > 0 else {
      pendingMountWindow = window
      pendingMountReason = reason
      onDiagnostic?("mount deferred: no layout width", ["chat": chatId])
      return
    }
    pendingMountWindow = nil
    resyncOutstanding = false
    // The same window, mounted twice.
    //
    // A chat open publishes one window when the driver is armed and another when the
    // engine reconcile lands, and on a chat that changed nothing in between they are the
    // same generation over the same message ids. The second mount then rebuilds every
    // render item, re-records every body and re-publishes an identical snapshot — device
    // run 2026-08-04, chat 176cdf92eec5: two `host MOUNT gen=2 rows=1000` inside 180ms of
    // an open that was already one continuous main-thread stall.
    //
    // `themeOrTrait` is exempt because that is precisely the case where the content is
    // unchanged and the render must be rebuilt anyway.
    if reason != .themeOrTrait, generation != 0, window.generation == generation,
      applied.count == window.messages.count,
      !zip(applied, window.messages).contains(where: { $0.identity.messageId != $1.messageId })
    {
      onDiagnostic?(
        "mount skipped: window already applied",
        ["chat": chatId, "gen": String(generation), "reason": reason.rawValue])
      return
    }
    // Anything already queued describes a window that is about to be replaced.
    // Committing it after the mount would apply stale ops to fresh state.
    committer.cancelPending()

    // Decrypt health for this window, and the reason it is logged here rather
    // than off the render snapshot: `VibeRenderItem` carries geometry and paint,
    // never text, so by the time a snapshot exists there is nothing left to ask.
    // This is the one place that sees what the core actually opened.
    //
    // `failed > 0` means the key seam refused — locked Keychain, a message sealed
    // to another device, or (the bug this exists to catch) no unwrapper installed
    // at all, in which case *every* row fails and the core is ordering messages it
    // cannot read.
    let failedFlag: UInt32 = 1 << 8  // VibeMessageFlags::DECRYPTION_FAILED
    var failed = 0
    var empty = 0
    var unreadableIds: [String] = []
    for message in window.messages {
      let refused = message.flags & failedFlag != 0
      let blank = message.text.isEmpty && !message.hasMedia
      if refused { failed += 1 }
      if blank { empty += 1 }
      if refused || blank, unreadableIds.count < 3 {
        unreadableIds.append(String(message.messageId.suffix(12)) + (refused ? "!" : ""))
      }
    }
    NSLog(
      "[VibeCore] window chat=%@ rows=%d decryptFailed=%d emptyNoMedia=%d",
      String(chatId.prefix(12)), window.messages.count, failed, empty)
    // The count alone cannot be traced back to a row, and NSLog never reaches the
    // in-app export. A trailing ! marks a row the core itself refused to open.
    if failed > 0 || empty > 0 {
      VibeLog.warning(
        "core window has unreadable rows", category: "crypto",
        metadata: [
          "chat": String(chatId.prefix(12)),
          "rows": String(window.messages.count),
          "decryptFailed": String(failed),
          "emptyNoMedia": String(empty),
          "ids": unreadableIds.joined(separator: ","),
        ])
    }

    // Everything from here to `applied = items` is main-thread work inside a navigation
    // push, so it is measured and reported rather than assumed. The device export that
    // motivated this reported the whole transition as one stall — `hangSeconds=0.57`
    // with `hangDuring=<chat>/will-appear` — and nothing in the log said which part of
    // the mount spent it. Now `mount cost` does.
    cache.beginMountBudget()
    let knownBefore = cache.knownHeightHits
    let measuredBefore = cache.measurements
    let reusedBefore = cache.reuses
    let deferredBefore = cache.budgetDeferrals
    let startedAt = DispatchTime.now().uptimeNanoseconds

    let items = window.messages.map { factory.settledItem($0) }
    // Bodies are read by exactly one consumer (`VibeMessageListBodySink`, which is the
    // Diagnostics preview) and by nothing on the chat surface. Recording them for a
    // host that cannot ask was a string interpolation and two dictionary inserts per
    // message, per mount, on the push — ~1,000 of each on a large chat, for a value
    // no one would ever read.
    if listHost is VibeMessageListBodySink {
      for message in window.messages { recordBody(message) }
    }
    let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000)
    let deferredThisMount = cache.budgetDeferrals - deferredBefore
    onDiagnostic?(
      "mount cost",
      [
        "chat": chatId,
        "rows": String(window.messages.count),
        "ms": String(elapsedMs),
        // The four ways a row got its height, which is the whole question when a mount
        // is slow: `known` and `reused` are lookups, `measured` is a real text layout.
        //
        // `measured` is derived rather than read off `cache.measurements`, which counts
        // every row that went through `settledGeometry` — including the free ones. That
        // made the first device run read `known=1361 measured=1361`, which parses as
        // "1,361 text layouts" when the true number was zero. A counter nobody can read
        // correctly is worse than no counter.
        "known": String(cache.knownHeightHits - knownBefore),
        "reused": String(cache.reuses - reusedBefore),
        "measured": String(
          max(
            0,
            (cache.measurements - measuredBefore)
              - (cache.knownHeightHits - knownBefore) - deferredThisMount)),
        "deferred": String(deferredThisMount),
        "reason": reason.rawValue,
      ])
    generation = window.generation
    applied = items

    let snapshot = VibeRenderSnapshot(
      chatId: chatId,
      generation: generation,
      window: VibeTimelineWindowV1(
        chatId: chatId,
        messageIds: items.map(\.identity.messageId),
        anchors: items.map(\.identity),
        startIndex: 0,
        hasOlder: window.bounds.hasMoreBefore,
        hasNewer: window.bounds.hasMoreAfter
      ),
      items: items,
      anchor: .pinToBottom,
      contentHeight: items.reduce(0) { $0 + $1.size.height },
      themeEpoch: themeEpoch,
      direction: UIView.userInterfaceLayoutDirection(for: .unspecified) == .rightToLeft
        ? .rtl : .ltr,
      preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory.rawValue
    )

    // Validate before mounting, not after. A snapshot that violates the contract
    // is a bug in this file, and mounting it first would turn a diagnosable
    // assertion into a visual glitch someone has to reproduce.
    if case .failure(let failure) = VibeRenderSnapshotValidator.validate(snapshot) {
      rejectedTransactions += 1
      onDiagnostic?(
        "snapshot rejected", ["chat": chatId, "failure": String(describing: failure)])
      return
    }
    pushBodies()
    listHost.apply(snapshot: snapshot, reason: reason)
  }

  private func recordBody(_ message: VibeFfiMessage) {
    bodies[message.messageId] = message.text.isEmpty ? (message.caption ?? "") : message.text
    details[message.messageId] = "\(message.messageId) · ts \(message.tsMs)"
  }

  private func pushBodies() {
    (listHost as? VibeMessageListBodySink)?.setBodies(bodies, details: details)
  }

  // MARK: Deltas

  /// Converts one core delta into a list transaction and queues it.
  func ingest(delta: VibeFfiDelta) {
    switch delta.body {
    case .reset(let window):
      // A reset is not expressible as ops against the current window, and
      // pending ops describe a window that no longer exists.
      committer.cancelPending()
      mount(window: window, reason: .engineReconcile)

    case .ops(let ops):
      guard !ops.isEmpty else { return }
      // Nothing has been measured yet, so ops have no state to apply against.
      // Dropping them is safe because the deferred mount carries the same rows.
      guard cache.layoutWidth > 0 else { return }
      // Behind us: this delta is already folded into the window we mounted.
      // Dropping it is not a resync condition — a requested window is a
      // point-in-time snapshot, so every delta the core emitted before that
      // point arrives late and redundant by construction.
      if delta.baseGeneration < generation { return }

      // The generation fence, honoured rather than assumed. Op indices are
      // relative to the core's window at `baseGeneration`; applying them to a
      // different window puts rows at the wrong index, which shows up as a
      // visibly wrong order. The contract says resync, so resync.
      guard delta.baseGeneration == generation else {
        // ...but resync *once*. A window request is served asynchronously while
        // the core keeps producing, so the snapshot is already behind again by
        // the time it lands. Requesting one per delta turned a 250-message burst
        // into 687 full re-renders, each of which arrived stale and asked for
        // another. One outstanding request, cleared when a window mounts, makes
        // that converge instead of chasing its own tail.
        guard !resyncOutstanding else { return }
        resyncOutstanding = true
        rejectedTransactions += 1
        onDiagnostic?(
          "delta ahead of mounted window — resyncing once",
          ["base": String(delta.baseGeneration), "held": String(generation)])
        committer.cancelPending()
        onNeedsResync?()
        return
      }
      guard let transaction = transaction(from: ops, delta: delta) else { return }
      committer.enqueue(transaction)
    }
  }

  private func transaction(from ops: [VibeFfiOp], delta: VibeFfiDelta) -> VibeListTransaction? {
    var listOps: [VibeListOp] = []
    var next = applied
    var sawGeometryChange = false

    for op in ops {
      switch op {
      case .insert(let index, let message):
        recordBody(message)
        let item = factory.settledItem(message)
        let at = Int(index)
        guard at >= 0, at <= next.count else {
          onDiagnostic?("insert index out of range", ["index": String(index)])
          return nil
        }
        next.insert(item, at: at)
        listOps.append(.insert(items: [item], at: at))

      case .remove(_, let messageId):
        next.removeAll { $0.identity.messageId == messageId }
        cache.forget(messageId)
        bodies.removeValue(forKey: messageId)
        details.removeValue(forKey: messageId)
        listOps.append(.remove(ids: [messageId]))

      case .remapIdentity(let index, let previousMessageId, let message):
        // An optimistic send getting its server id. Remove-then-insert would
        // animate the user's own message away and back; the scroll anchor is
        // supposed to survive this, so the geometry is carried across.
        if let old = cache.cached(previousMessageId) {
          cache.forget(previousMessageId)
          _ = old
        }
        recordBody(message)
        bodies.removeValue(forKey: previousMessageId)
        details.removeValue(forKey: previousMessageId)
        let item = factory.settledItem(message)
        let at = Int(index)
        if at >= 0, at < next.count {
          next[at] = item
        }
        listOps.append(.remove(ids: [previousMessageId]))
        listOps.append(.insert(items: [item], at: min(max(at, 0), next.count - 1)))

      case .updateContent(let index, let message, _):
        recordBody(message)
        let item = factory.contentUpdatedItem(message)
        let at = Int(index)
        if at >= 0, at < next.count {
          // Belt and braces: the factory reuses frozen geometry, and this
          // catches it if that ever stops being true.
          if next[at].flags.locksGeometry, next[at].size != item.size {
            settledGeometryChanges += 1
            onDiagnostic?(
              "settled geometry changed on content op",
              ["id": message.messageId, "was": "\(next[at].size.height)",
               "now": "\(item.size.height)"])
          }
          next[at] = item
        }
        listOps.append(.updateContent(id: message.messageId, item: item))

      case .updateGeometry(let index, let message, _):
        recordBody(message)
        let (item, deltaHeight) = factory.geometryUpdatedItem(message)
        let at = Int(index)
        if at >= 0, at < next.count { next[at] = item }
        sawGeometryChange = true
        listOps.append(
          .updateGeometry(id: message.messageId, item: item, deltaHeight: deltaHeight))

      case .move(let from, let to, let messageId):
        let f = Int(from)
        let t = Int(to)
        guard f >= 0, f < next.count, t >= 0, t < next.count else { return nil }
        let moved = next.remove(at: f)
        next.insert(moved, at: t)
        listOps.append(.move(id: messageId, to: t))

      case .evictHead(let count):
        // A window trim, not a deletion. Kept as a plain remove of the head ids
        // with `.none` animation — collapsing a trim into an animated delete is
        // exactly the bug §5.4 calls out.
        let n = min(Int(count), next.count)
        guard n > 0 else { break }
        let ids = next.prefix(n).map(\.identity.messageId)
        next.removeFirst(n)
        for id in ids { cache.forget(id); bodies[id] = nil; details[id] = nil }
        listOps.append(.remove(ids: ids))

      case .evictTail(let count):
        let n = min(Int(count), next.count)
        guard n > 0 else { break }
        let ids = next.suffix(n).map(\.identity.messageId)
        next.removeLast(n)
        for id in ids { cache.forget(id); bodies[id] = nil; details[id] = nil }
        listOps.append(.remove(ids: ids))
      }
    }

    guard !listOps.isEmpty else { return nil }

    let base = generation
    // The core's generation verbatim. Inventing one (`max(generation + 1, …)`)
    // makes every subsequent fence check compare against a number the core never
    // issued, which silently disables the fence.
    generation = delta.generation
    guard generation > base else {
      onDiagnostic?(
        "delta did not advance the generation",
        ["base": String(base), "next": String(delta.generation)])
      generation = base
      return nil
    }
    applied = next

    return VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: listOps,
      // Bottom pinning is the shipped behaviour for live traffic. A geometry
      // change mid-window needs the item anchor instead, which the host resolves
      // from its own visible range — it knows what is on screen and this does not.
      preserve: .pinToBottom,
      animation: sawGeometryChange ? .heightMorph : .none,
      commitDeadline: .displayLink
    )
  }
}
