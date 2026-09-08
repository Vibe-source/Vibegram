import CoreGraphics
import Foundation
import UIKit

/// Which rows can be measured before the push, and how tall they are.
///
/// # Why this is a gate and not a second implementation
///
/// The first version of this file reimplemented the list's height formulas as pure
/// arithmetic, on the belief that `measureMessageBubbleLayout` was main-thread-bound.
/// **That belief was wrong**, and the audit that produced `docs/row-height-formulas.md`
/// is what disproved it: `ChatListViewCells.swift` contains no `@MainActor`, and every
/// height in it comes from `NSAttributedString.boundingRect` or
/// `NSString.size(withAttributes:)` — CoreText over immutable strings — plus arithmetic.
/// The single exception is `VibeAgentTurnContentView.measuredHeight`, which lays out a
/// real `UIStackView`.
///
/// A parallel implementation would have to agree with the real one to within half a
/// point, forever, across every kind, and a disagreement is not a rounding error — it is
/// a row that changes size after the user can see it. That agreement burden *is* the
/// defect this project exists to remove; `ChatListView` is 22,586 lines partly because
/// heights are decided in more than one place. So this file does not compute heights.
/// It calls the same function the cell calls, and agreement is identity.
///
/// What it adds is the thing that was actually missing: **a decision about which rows may
/// be measured off the main thread**, so a transcript can be measured before it is pushed
/// instead of during. A row measured before the push and never re-measured cannot shift.
///
/// # The one row that cannot
///
/// Agent turns. `VibeAgentTurnContentView.measuredHeight` pins a width constraint on a
/// shared template view, calls `layoutIfNeeded`, then `systemLayoutSizeFitting`, over a
/// stack whose arranged subviews are built in a loop over progress items. It must stay on
/// main. Agent turns therefore move off the *push* rather than off the *thread*: measured
/// at prewarm or at settle, then frozen. At mount time a frozen height and an off-main
/// height are the same thing — a number that already exists.
enum VibeRowMetrics {

  // MARK: The gate

  /// Whether this row's height can only be produced on the main thread.
  ///
  /// Conservative on purpose: a row wrongly called off-main-safe is a race, while a row
  /// wrongly called main-only is merely measured later than it could have been.
  static func requiresMainThread(_ row: ChatListRow) -> Bool {
    bubbleUsesAgentTurnContent(row)
  }

  /// Exact row height, or `nil` when the row must be measured on the main thread.
  ///
  /// Mirrors the structure of `ChatListView.estimateMessageHeight` — which is the *exact*
  /// path despite its name — minus its caches, which are main-thread state. Callers hold
  /// their own storage for the result.
  ///
  /// Safe to call from any thread when `requiresMainThread(row)` is `false`.
  static func height(
    row: ChatListRow,
    rowWidth: CGFloat,
    state: AgentTurnBubbleState = AgentTurnBubbleState()
  ) -> CGFloat? {
    guard !requiresMainThread(row) else { return nil }
    return measuredHeight(row: row, rowWidth: rowWidth, state: state)
  }

  /// Exact row height for a caller that is already on the main thread.
  ///
  /// Answers for every row, agent turns included — the gate above is about *which
  /// thread*, not about capability. A measurer running on main has no reason to refuse
  /// a row and fall back to an estimate, and an estimate that later disagrees with the
  /// measurement is the shift itself.
  ///
  /// `nil` only for a width that cannot be laid out in.
  @MainActor
  static func mainThreadHeight(
    row: ChatListRow,
    rowWidth: CGFloat,
    state: AgentTurnBubbleState = AgentTurnBubbleState()
  ) -> CGFloat? {
    measuredHeight(row: row, rowWidth: rowWidth, state: state)
  }

  /// A height, plus whether it is one this list already knows will change.
  ///
  /// `mediaAspectWasUnknown` is not a detail: a media row whose natural size nothing
  /// knew yet is sized by the square fallback, and that number is corrected the moment
  /// the aspect resolves. A caller that freezes it as exact has cached the shift rather
  /// than removed it — which is the bug `isProvisional` exists to catch in the list's
  /// own cache, and it has to survive the trip through this gate.
  struct Measured: Equatable {
    let height: CGFloat
    let mediaAspectWasUnknown: Bool
  }

  /// ``height(row:rowWidth:state:)`` with the provisional flag kept.
  static func measured(
    row: ChatListRow,
    rowWidth: CGFloat,
    state: AgentTurnBubbleState = AgentTurnBubbleState()
  ) -> Measured? {
    guard !requiresMainThread(row) else { return nil }
    return measuredRow(row: row, rowWidth: rowWidth, state: state)
  }

  private static func measuredHeight(
    row: ChatListRow, rowWidth: CGFloat, state: AgentTurnBubbleState
  ) -> CGFloat? {
    measuredRow(row: row, rowWidth: rowWidth, state: state)?.height
  }

  private static func measuredRow(
    row: ChatListRow, rowWidth: CGFloat, state: AgentTurnBubbleState
  ) -> Measured? {
    guard rowWidth > 0 else { return nil }

    // Centered service pills: agent control events (interrupt, /compact) and failed
    // turns are not bubbles and never reach the measure path.
    if agentSystemDividerText(for: row) != nil || agentErrorNoticeText(for: row) != nil {
      return Measured(
        height: servicePillBaseHeight + serviceDecisionActionsHeight(for: row),
        mediaAspectWasUnknown: false)
    }
    if row.kind == .day { return Measured(height: dayRowHeight, mediaAspectWasUnknown: false) }

    let metrics = measureMessageBubbleLayout(row: row, rowWidth: rowWidth, agentTurnState: state)
    return Measured(
      height: metrics.bubbleHeight + metrics.tallOuterToggleReserve,
      mediaAspectWasUnknown: metrics.mediaAspectWasUnknown)
  }

  /// `height(row:rowWidth:state:)` for a batch, with the main-only rows reported rather
  /// than silently dropped — the caller has to measure or freeze those separately, and a
  /// row that quietly has no height is a row that gets an estimate, which is a shift.
  static func heights(
    rows: [ChatListRow],
    rowWidth: CGFloat,
    state: AgentTurnBubbleState = AgentTurnBubbleState()
  ) -> (byKey: [String: CGFloat], deferredKeys: [String]) {
    let batch = measuredBatch(rows: rows, rowWidth: rowWidth, state: state)
    return (batch.byKey.mapValues(\.height), batch.deferredKeys)
  }

  /// ``heights(rows:rowWidth:state:)`` with the provisional flag kept per row.
  static func measuredBatch(
    rows: [ChatListRow],
    rowWidth: CGFloat,
    state: AgentTurnBubbleState = AgentTurnBubbleState()
  ) -> (byKey: [String: Measured], deferredKeys: [String]) {
    var byKey: [String: Measured] = [:]
    byKey.reserveCapacity(rows.count)
    var deferred: [String] = []
    for row in rows {
      if let measured = measured(row: row, rowWidth: rowWidth, state: state) {
        byKey[row.key] = measured
      } else {
        deferred.append(row.key)
      }
    }
    return (byKey, deferred)
  }

  // MARK: Primitives
  //
  // Kept because they have no counterpart in the measure path and are used to size
  // things the list composes itself (separators, the width a caller lays text out in).
  // Anything with a counterpart lives in `measureMessageBubbleLayout` and only there.

  static let messageHorizontalInset: CGFloat = 8  // ChatListViewConstants:4
  static let bubbleHorizontalPadding: CGFloat = 12  // :9
  static let bubbleMaxWidthFactor: CGFloat = 0.85  // :17
  static let dayRowHeight: CGFloat = 30  // ChatListView:13344
  static let outOfBoundsRowHeight: CGFloat = 56  // :13339
  static let servicePillBaseHeight: CGFloat = 36  // ChatListView:14104

  /// The width a bubble's text is laid out in, from the row width.
  static func textMaxWidth(rowWidth: CGFloat) -> CGFloat {
    let maxBubbleWidth = (rowWidth * bubbleMaxWidthFactor).rounded(.down)
    return max(1, maxBubbleWidth - bubbleHorizontalPadding * 2)
  }

  /// Laid-out height of an attributed string at a given width.
  ///
  /// `boundingRect` is CoreText over an immutable string and is safe off the main thread
  /// — unlike `UILabel.sizeThatFits`. `.usesLineFragmentOrigin` and `.usesFontLeading`
  /// match what the measure path uses; dropping either changes the answer for multi-line
  /// text. `ceil` matches too — the measure path rounds up before it commits.
  static func textHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
    guard width > 0, attributed.length > 0 else { return 0 }
    let bounds = attributed.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil)
    return ceil(bounds.height)
  }

  static func daySeparatorHeight() -> CGFloat { dayRowHeight }
}
