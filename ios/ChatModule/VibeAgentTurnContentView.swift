import OSLog
import UIKit

private let agentTurnContentLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "AgentTurn"
)

/// Shape-agnostic host for `VibeAgentKitAssistantMessageBodyView` — the real interleaved
/// step/narration/diff renderer (live feed reuse, expand/collapse, diff card). This wrapper
/// owns exactly one body view and pins it edge-to-edge to itself; sizing/shell (full-page
/// table row vs chat bubble) is entirely the caller's job via ordinary Auto Layout
/// constraints on `self` — the wrapper adds none of its own, so it behaves identically to
/// the `assistantBodyView` it replaces inside `VibeAgentKitMessageCell` (Stage 1) and can
/// be dropped into a bubble shell later (Stage 3) without any internal changes.
final class VibeAgentTurnContentView: UIView {
  let bodyView = VibeAgentKitAssistantMessageBodyView()

  var onStepTap: ((String) -> Void)? {
    get { bodyView.onStepTap }
    set { bodyView.onStepTap = newValue }
  }
  var onOpenSubagent: ((String) -> Void)? {
    get { bodyView.onOpenSubagent }
    set { bodyView.onOpenSubagent = newValue }
  }
  var onToggleRuntimeExpand: (() -> Void)? {
    get { bodyView.onToggleRuntimeExpand }
    set { bodyView.onToggleRuntimeExpand = newValue }
  }
  var onReviewTapped: (() -> Void)? {
    get { bodyView.onReviewTapped }
    set { bodyView.onReviewTapped = newValue }
  }
  var onFileTapped: ((ChatListRow.AgentRuntimeFile) -> Void)? {
    get { bodyView.onFileTapped }
    set { bodyView.onFileTapped = newValue }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    // The body owns required-height text/code rows while the chat list owns this wrapper's
    // manual frame. During a streaming growth tick those two heights can differ for one
    // layout pass; contain the body until the collection installs the newly measured slot.
    clipsToBounds = true
    bodyView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bodyView)
    // The chat-bubble cell positions this wrapper with MANUAL FRAMES (it never turns off
    // translatesAutoresizingMaskIntoConstraints), so the wrapper's frame becomes a REQUIRED
    // autoresizing height constraint — including `height == 0` while parked at `.zero`.
    // If the bottom pin below were also required, any mismatch between that frame height
    // and the body's own required content height (every stream tick, every `.zero` park)
    // is unsatisfiable, and UIKit "recovers" by breaking a random internal stack
    // constraint — collapsing the live feed to nothing (the mid-stream empty-bubble
    // flicker). Priority 999 lets the bottom pin give way silently instead; it still
    // outranks `.fittingSizeLevel`, so `measuredHeight`'s systemLayoutSizeFitting math
    // is unaffected.
    let bottomPin = bodyView.bottomAnchor.constraint(equalTo: bottomAnchor)
    bottomPin.priority = UILayoutPriority(999)
    NSLayoutConstraint.activate([
      bodyView.topAnchor.constraint(equalTo: topAnchor),
      bodyView.leadingAnchor.constraint(equalTo: leadingAnchor),
      bodyView.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomPin,
    ])
  }

  required init?(coder: NSCoder) { return nil }

  func reset() {
    bodyView.reset()
  }

  /// Straight pass-through to `bodyView.configure(...)`. `availableWidth` must match
  /// whatever width `self` will actually resolve to under the caller's own constraints
  /// (the body view's internal text/step measurement math depends on it) — same contract
  /// `VibeAgentKitMessageCell` already relied on for `assistantBodyView`.
  func configure(
    text: String,
    isStreaming: Bool,
    hasFinalResponseText: Bool,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    messageId: String,
    progressItems: [VibeAgentKitProgressItem],
    subagentChildren: [String: [VibeAgentKitProgressItem]] = [:],
    fallbackProgressLabels: [String],
    runtime: ChatListRow.AgentRuntimeSummary?,
    onLoaderTap: (() -> Void)?,
    isProgressExpanded: Bool = false,
    isRuntimeExpanded: Bool = false,
    expandedStepIds: Set<String> = [],
    streamingStartDate: Date? = nil,
    showsLoaderView: Bool = true,
    isContentCollapsed: Bool = false
  ) {
    bodyView.configure(
      text: text,
      isStreaming: isStreaming,
      hasFinalResponseText: hasFinalResponseText,
      appearance: appearance,
      availableWidth: availableWidth,
      messageId: messageId,
      progressItems: progressItems,
      subagentChildren: subagentChildren,
      fallbackProgressLabels: fallbackProgressLabels,
      runtime: runtime,
      onLoaderTap: onLoaderTap,
      isProgressExpanded: isProgressExpanded,
      isRuntimeExpanded: isRuntimeExpanded,
      expandedStepIds: expandedStepIds,
      streamingStartDate: streamingStartDate,
      showsLoaderView: showsLoaderView,
      isContentCollapsed: isContentCollapsed
    )
  }

  /// Row-based convenience for the chat-bubble cell: builds the `VibeAgentKitChatMessage`
  /// via the same `VibeAgentKitMap` bridge the full-page view uses, so the bubble renders
  /// through an identical data path (no second mapping layer to drift out of sync).
  func configure(
    row: ChatListRow,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    isProgressExpanded: Bool,
    isRuntimeExpanded: Bool,
    expandedStepIds: Set<String>,
    streamingStartDate: Date?,
    onLoaderTap: (() -> Void)?,
    showsLoaderView: Bool = true,
    isContentCollapsed: Bool = false
  ) {
    let message = VibeAgentKitMap.chatMessage(from: row)
    var displayText = resoloAssistantDisplayText(for: message)
    var displayItems = message.progressItems

    // Supervisor team lead: the bubble shows a STABLE, append-only team feed — the
    // lead's opening line + one tappable row per worker — instead of the lead's own
    // rolling narration/tool stream. Re-rendering the whole body every stream frame is
    // what made the team cell "reset"/shift constantly and hide all worker progress.
    // The full lead feed stays reachable via the header tap (multi-agent sheet).
    if bubbleRendersTeamRun(row), let runtime = row.agentRuntime {
      let team = vibeAgentTeamDisplayFeed(
        row: row, runtime: runtime, message: message, bodyText: displayText)
      displayItems = team.items
      displayText = team.bodyText
    }

    // Guard against the "stopped mid-stream → blank bubble" bug: when a turn is
    // FINALIZED (not streaming) but maps to nothing renderable — no answer text, no
    // progress steps, no runtime card — the body view produces zero height and the
    // caller floors the shell to ~44pt, leaving a visible-but-empty bubble even though
    // the message row still exists in the list. This happens when the user hits STOP
    // before any assistant text/tool node was persisted (or the finalize dropped the
    // in-flight nodes). Substitute a minimal "Stopped" placeholder so the turn is never
    // invisible, and log it so we can spot any OTHER path that lands here.
    if !message.isStreaming
      && displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && displayItems.isEmpty
      && message.runtime == nil
    {
      let statusText = row.status ?? "nil"
      let kindText = row.agentMsgKind ?? "nil"
      agentTurnContentLogger.notice(
        "EMPTY finalized turn id=\(message.id, privacy: .public) status=\(statusText, privacy: .public) kind=\(kindText, privacy: .public) nodes=\(row.agentProgressNodes.count, privacy: .public) hasRuntime=N -> drop shell (no Stopped placeholder)"
      )
      // Prefer leaving body empty: ChatEngine drops fully-empty agent shells from the
      // merge. A "Stopped" placeholder was painting blank-looking Worked cells that
      // overlapped neighbors when height recovery raced after bridge restart.
      displayText = ""
    }

    // Tools-only finished turn with empty body: surface a short line so the Worked
    // card isn't a zero-height empty shell while steps remain expandable.
    if !message.isStreaming
      && displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !displayItems.isEmpty
      && message.hasFinalResponseText
    {
      let toolCount = displayItems.filter { $0.itemType != "text" }.count
      if toolCount > 0 {
        displayText = ""  // Worked · N steps loader carries the summary; no fake body
      }
    }

    configure(
      text: displayText,
      isStreaming: message.isStreaming,
      hasFinalResponseText: message.hasFinalResponseText,
      appearance: appearance,
      availableWidth: availableWidth,
      messageId: message.id,
      progressItems: displayItems,
      subagentChildren: message.subagentChildren,
      fallbackProgressLabels: message.progress,
      runtime: message.runtime,
      onLoaderTap: onLoaderTap,
      isProgressExpanded: isProgressExpanded,
      isRuntimeExpanded: isRuntimeExpanded,
      expandedStepIds: expandedStepIds,
      streamingStartDate: streamingStartDate,
      showsLoaderView: showsLoaderView,
      isContentCollapsed: isContentCollapsed
    )
  }
}

/// Builds the supervisor-team lead bubble's display feed. Append-only by construction:
/// 1. the lead's OPENING narration paragraph ("I'm going to split this across…") — the
///    first paragraph of the first text node, which stops changing once the lead moves
///    past its intro (later narration/tool churn never touches it);
/// 2. one `teamworker` row per worker (avatar + name + live status/last step), tappable
///    → that worker's read-only detail view. Status text mutates in place (same height),
///    so worker progress is visible without the cell ever re-flowing;
/// 3. when the run settles, the lead's final answer becomes the body below the rows.
/// The lead's own tool steps and rolling narration are deliberately NOT rendered here —
/// they re-measured the bubble every stream frame (the "team cell keeps
/// resetting/shifting" complaint). They remain in the header-tap multi-agent sheet.
func vibeAgentTeamDisplayFeed(
  row: ChatListRow,
  runtime: ChatListRow.AgentRuntimeSummary,
  message: VibeAgentKitChatMessage,
  bodyText: String
) -> (items: [VibeAgentKitProgressItem], bodyText: String) {
  var items: [VibeAgentKitProgressItem] = []

  // Intro: mid-run only — once settled the full final answer renders as the body and
  // would duplicate the opening line. When the run is suppress-all-text (supervisor
  // team), the lead posts NO narration paragraph at all: the cell is a pure progress
  // runner (worker rows with live "reading/editing" status), and the only prose is the
  // lead's final summary at settle.
  if message.isStreaming, !runtime.suppressAllText {
    let firstNarration = message.progressItems.first {
      $0.itemType == "text" && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if let intro = firstNarration?.label
      .components(separatedBy: "\n\n").first?
      .trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty
    {
      items.append(
        VibeAgentKitProgressItem(
          label: intro, badges: [], eventType: "progress", recipient: nil,
          platform: nil, format: nil, messageContent: nil, messagePreview: nil,
          voiceUrl: nil, voiceDuration: nil, status: nil, isRecording: false,
          recordingStartTime: nil, tool: nil, image: nil, itemType: "text", sourceUrl: nil))
    }
  }

  // Worker rows: real statuses when the bridge has reported them, else a synthesized
  // "starting" row per known handle so the team roster shows from the first frame.
  let roster: [ChatListRow.TeamWorkerStatus] =
    runtime.teamWorkersStatus.isEmpty
    ? runtime.teamWorkers.map {
      ChatListRow.TeamWorkerStatus(
        worker: $0, label: $0.capitalized,
        status: message.isStreaming ? "starting" : "done",
        startedAt: nil, finishedAt: nil, durationMs: nil,
        summary: nil, taskId: nil, lastLabel: nil)
    }
    : runtime.teamWorkersStatus

  // Real-time nodes. Each worker appears as a node only once the monitor has actually
  // ENGAGED it — a still-pending/queued member stays hidden until it starts (and a run
  // that finishes without ever engaging it never shows it). The lead is the monitor
  // voice (intro + final answer), not a worker node under itself, so it's filtered out
  // — EXCEPT on a solo run, where the single member IS the lead and must remain visible.
  let leadHandle = (runtime.leadWorker ?? "").lowercased()
  let hasNonLeadWorker = roster.contains { $0.worker.lowercased() != leadHandle }
  let statuses = roster.filter { status in
    let handle = status.worker.lowercased()
    if hasNonLeadWorker, !leadHandle.isEmpty, handle == leadHandle { return false }
    let s = status.status.lowercased()
    if s == "pending" || s == "queued" { return false }
    return true
  }

  // A settled turn has no live workers: once the message stops streaming, any worker
  // still reading running/starting/waiting is stale (the run ended without a terminal
  // frame — CLI crash, or orphaned by a server redeploy). Present it as "stopped" so the
  // row never keeps a lingering shimmer after the run is over. This is the client's half
  // of the fix — the worker statuses live inside the E2E-encrypted runtime, so only here
  // (post-decryption) can they be terminalized; ChatEngine only flips the isStreaming flag.
  let runNotStreaming = !message.isStreaming
  let staleWorkerStates: Set<String> = [
    "running", "starting", "pending", "queued", "active", "streaming",
    "waiting", "in-progress", "in_progress", "working",
  ]
  for status in statuses {
    let name = status.label.isEmpty ? status.worker.capitalized : status.label
    let effectiveStatus =
      (runNotStreaming && staleWorkerStates.contains(status.status.lowercased()))
      ? "stopped" : status.status
    let statusText: String = {
      let s = effectiveStatus.lowercased()
      if s == "done" || s == "completed" {
        if let ms = status.durationMs, ms > 0 {
          return "done · \(ChatListRow.TeamWorkerStatus.formatDuration(ms))"
        }
        return "done"
      }
      if s == "failed" || s == "error" { return "failed" }
      if s == "skipped" { return "skipped" }
      // Settled without a terminal frame (crashed run / orphaned by a server redeploy)
      // — a real stopped state, never a lingering "working…".
      if s == "stopped" || s == "cancelled" || s == "reassigned" { return "stopped" }
      // The spawn beat: the lead has just called this CLI but no tool event has
      // landed yet. "Calling…" next to the worker's avatar reads as "calling grok";
      // the row appends the live elapsed clock ("Calling… · 0m 07s").
      if s == "starting" || s == "pending" { return "Calling…" }
      // Payload-contract barrier: a consumer held until its owner freezes the shape.
      // The server puts "waiting for <contract> from <owner>" in lastLabel; show it so
      // the user sees the barrier working (never a spinner, never hidden).
      if s == "waiting" {
        if let last = status.lastLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
          !last.isEmpty
        {
          return last.count > 40 ? String(last.prefix(40)) + "…" : last
        }
        return "waiting for payload…"
      }
      if let last = status.lastLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
        !last.isEmpty
      {
        return last.count > 34 ? String(last.prefix(34)) + "…" : last
      }
      return "working…"
    }()
    items.append(
      VibeAgentKitProgressItem(
        label: name, badges: [], eventType: "progress", recipient: nil, platform: nil,
        format: nil, messageContent: nil, messagePreview: statusText, voiceUrl: nil,
        voiceDuration: nil, status: effectiveStatus, isRecording: false,
        recordingStartTime: nil, tool: nil, image: nil, itemType: "teamworker",
        sourceUrl: nil, nodeId: "teamworker:\(status.worker)",
        subagentType: status.worker,
        // startedAt drives the row's live elapsed clock while running; durationMs is
        // the frozen final time shown once the worker settles. `effectiveStatus`
        // already coerced a stale running→stopped for a settled turn, so the row
        // will not tick after the run ends even though startedAt is present.
        durationMs: status.durationMs, startedAtMs: status.startedAt))
  }

  // Mid-run the body stays empty (intro rides the feed); settled turns show the lead's
  // final answer under the worker rows, exactly like a normal Worked card body.
  return (items, message.isStreaming ? "" : bodyText)
}

extension VibeAgentTurnContentView {
  /// Offscreen "sizing template" — ONE shared instance reused across measurement calls
  /// (never added to a window), matching the classic self-sizing-cell trick: avoids
  /// allocating a fresh Auto Layout view graph per row on every layout pass, which
  /// `systemLayoutSizeFitting` would otherwise cost given how often the chat list's
  /// manual sizing pipeline re-measures during a live agent stream.
  private static let sizingTemplate: VibeAgentTurnContentView = {
    let view = VibeAgentTurnContentView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()
  private static var sizingWidthConstraint: NSLayoutConstraint?

  /// Height `configure(row:...)` would produce at `availableWidth`, without needing a
  /// live instance in the view hierarchy. Callers should pass the SAME expand-state
  /// values they'll use for the subsequent live `configure(row:...)` call so the
  /// measured height matches what actually renders.
  static func measuredHeight(
    row: ChatListRow,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    isProgressExpanded: Bool,
    isRuntimeExpanded: Bool,
    expandedStepIds: Set<String>,
    streamingStartDate: Date?,
    showsLoaderView: Bool = true
  ) -> CGFloat {
    let template = sizingTemplate
    // CRITICAL: clear any block / feed / loader views left over from measuring a
    // DIFFERENT row on this shared template. `configure(...)` reuses cached subviews
    // keyed by block-signature and node id, so without a reset the previously-measured
    // (often taller) turn's views linger and inflate THIS row's fitting height. The live
    // cell holds its OWN body-view instance with the real (shorter/empty) content, so the
    // desync renders as a tall-but-empty bubble — and because the leftover state changes
    // per measured row / per stream tick, the measured height swings between huge and the
    // caller's floor. Resetting first makes each measurement reflect only this row.
    template.reset()
    if let constraint = sizingWidthConstraint {
      constraint.constant = availableWidth
    } else {
      let constraint = template.widthAnchor.constraint(equalToConstant: availableWidth)
      constraint.isActive = true
      sizingWidthConstraint = constraint
    }
    template.configure(
      row: row,
      appearance: appearance,
      availableWidth: availableWidth,
      isProgressExpanded: isProgressExpanded,
      isRuntimeExpanded: isRuntimeExpanded,
      expandedStepIds: expandedStepIds,
      streamingStartDate: streamingStartDate,
      onLoaderTap: nil,
      showsLoaderView: showsLoaderView
    )
    // Force a layout pass so intrinsic-size-driven subviews (e.g. the loader, which
    // relies on `intrinsicContentSize`/`sizeThatFits` rather than an explicit height
    // constraint) actually resolve on this offscreen, never-windowed template before we
    // read a fitting size. Without this, a transient streaming state can leave the
    // vertical dimension underconstrained.
    template.setNeedsLayout()
    template.layoutIfNeeded()
    // CRITICAL: target height MUST be finite. `systemLayoutSizeFitting` returns the
    // target-size value verbatim for any dimension that ends up unconstrained (the
    // `.fittingSizeLevel` target constraint is then the only one). If that target were
    // `.greatestFiniteMagnitude`, an underconstrained turn would yield an infinite row
    // height → `UICollectionViewCell` rounding assertion / crash. A finite 0 target
    // collapses to the caller's `max(52, …)` floor instead, and self-corrects on the
    // next stream tick.
    let size = template.systemLayoutSizeFitting(
      CGSize(width: availableWidth, height: 0.0),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    guard size.height.isFinite, size.height > 0.0 else { return 0.0 }
    return ceil(size.height)
  }
}
