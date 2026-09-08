import UIKit

/// Desktop-CLI-style display label for a thinking progress item: "Thinking · 1.2k tokens"
/// ticking while the model is still reasoning (the bridge streams a throttled live token
/// count), "Thought for 23s · 1.7k tokens" once the block settles. Every other kind keeps
/// its wire label. Shared by the shimmer line, the live feed rows and the finished step
/// list so all three read identically.
func vibeAgentKitProgressDisplayLabel(_ item: VibeAgentKitProgressItem) -> String {
  let kind = (item.itemType ?? item.tool ?? "").lowercased()
  if kind == "compacting" {
    let status = (item.status ?? "").lowercased()
    let isRunning = ["running", "streaming", "in_progress", "active"].contains(status)
    if isRunning { return "Compacting conversation…" }
    return item.label.isEmpty ? "Compacted conversation" : item.label
  }
  if kind == "mcp" {
    var base = item.label
    if base.isEmpty { base = "MCP tool" }
    let status = (item.status ?? "").lowercased()
    let isRunning = ["running", "streaming", "in_progress", "active"].contains(status)
    if !isRunning, let ms = item.durationMs, ms >= 500 {
      return "\(base) · \(chatAgentThinkingDurationText(ms))"
    }
    if isRunning { return "\(base)…" }
    return base
  }
  guard kind == "thinking" else { return item.label }
  let status = (item.status ?? "").lowercased()
  let isRunning = ["running", "streaming", "in_progress", "active"].contains(status)
  var parts: [String] = []
  if !isRunning, let ms = item.durationMs, ms >= 1000 {
    parts.append("Thought for \(chatAgentThinkingDurationText(ms))")
  } else {
    parts.append("Thinking")
  }
  if let tokens = item.tokens, tokens > 0 {
    parts.append(chatAgentTokenCountText(tokens))
  }
  return parts.joined(separator: " · ")
}

final class VibeAgentKitMessageActionBarView: UIView {
  private let buttonSize: CGFloat = 26.0
  private let buttonSpacing: CGFloat = 8.0
  private let copyButton = UIButton(type: .system)
  private let thumbUpButton = UIButton(type: .system)
  private let thumbDownButton = UIButton(type: .system)
  private let regenerateButton = UIButton(type: .system)

  var onAction: ((VibeAgentKitMessageAction) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let visibleButtons = [copyButton, thumbUpButton, thumbDownButton, regenerateButton].filter {
      !$0.isHidden
    }
    let y = max(0.0, (bounds.height - buttonSize) * 0.5)
    var cursorX: CGFloat = 0.0
    for button in visibleButtons {
      button.frame = CGRect(x: cursorX, y: y, width: buttonSize, height: buttonSize)
      cursorX += buttonSize + buttonSpacing
    }
  }

  override var intrinsicContentSize: CGSize {
    let visibleButtons = [copyButton, thumbUpButton, thumbDownButton, regenerateButton].filter {
      !$0.isHidden
    }
    let width = visibleButtons.isEmpty
      ? 0.0
      : (CGFloat(visibleButtons.count) * buttonSize)
        + (CGFloat(max(visibleButtons.count - 1, 0)) * buttonSpacing)
    return CGSize(width: width, height: buttonSize)
  }

  func configure(
    appearance: VibeAgentKitChatAppearance,
    hasSourceText: Bool,
    canRegenerate: Bool
  ) {
    let tint = vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.66 : 0.58)
    applyIcon(.document, to: copyButton, tint: tint)
    applyIcon(.thumbUp, to: thumbUpButton, tint: tint)
    applyIcon(.thumbDown, to: thumbDownButton, tint: tint)
    applyIcon(.refresh, to: regenerateButton, tint: tint)

    [copyButton, thumbUpButton, thumbDownButton, regenerateButton].forEach {
      $0.tintColor = tint
      $0.backgroundColor = .clear
    }

    copyButton.isHidden = !hasSourceText
    thumbUpButton.isHidden = !hasSourceText
    thumbDownButton.isHidden = !hasSourceText
    regenerateButton.isHidden = !canRegenerate
    isHidden = [copyButton, thumbUpButton, thumbDownButton, regenerateButton].allSatisfy(\.isHidden)
    invalidateIntrinsicContentSize()
  }

  private func setup() {
    backgroundColor = .clear
    semanticContentAttribute = .forceLeftToRight
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)

    configureButton(copyButton, action: .copy)
    configureButton(thumbUpButton, action: .thumbUp)
    configureButton(thumbDownButton, action: .thumbDown)
    configureButton(regenerateButton, action: .regenerate)
  }

  private func configureButton(_ button: UIButton, action: VibeAgentKitMessageAction) {
    button.contentHorizontalAlignment = .center
    button.contentVerticalAlignment = .center
    button.semanticContentAttribute = .forceLeftToRight
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 4.0,
      leading: 4.0,
      bottom: 4.0,
      trailing: 4.0
    )
    button.configuration = buttonConfiguration
    button.accessibilityIdentifier = "\(action)"
    button.addAction(
      UIAction { [weak self] _ in
        self?.onAction?(action)
      },
      for: .touchUpInside
    )
    addSubview(button)
  }

  private func applyIcon(
    _ kind: VibeAgentKitChatVectorIcon.Kind,
    to button: UIButton,
    tint: UIColor
  ) {
    var configuration = button.configuration ?? UIButton.Configuration.plain()
    configuration.image = VibeAgentKitChatVectorIcon.image(kind, color: tint, size: 17.0)
    button.configuration = configuration
  }
}

final class VibeAgentKitAssistantMessageBodyView: UIView {
  private let stackView = UIStackView()
  private let teamHeaderLabel = UILabel()
  private let loaderView = VibeAgentKitAgentLoaderView()
  // Inline, expandable step list that drops in directly under the "Worked · N
  // steps" line when the user taps it (Claude-Code style) — no separate sheet.
  private let stepsStack = UIStackView()
  private let runtimeSummaryView = AgentRuntimeSummaryView()
  private var blockViews: [UIView] = []
  private var blockHeightConstraints: [NSLayoutConstraint] = []
  private var runtimeHeightConstraint: NSLayoutConstraint?
  private var lastBlockSignature: String = ""
  // Per-step inline expansion: which node ids have their detail layer open, plus the
  // tap-up hook that asks the host to toggle one (it flips the set + re-measures).
  var onStepTap: ((String) -> Void)?
  // Tapping a "Subagent" row asks the host to open the read-only subagent view
  // for that parent Task node id (no inline expand — it's its own view).
  var onOpenSubagent: ((String) -> Void)?
  private var subagentChildren: [String: [VibeAgentKitProgressItem]] = [:]
  private var expandedStepIds: Set<String> = []
  // True while the turn is live: the work band + answer read as one continuous,
  // growing feed, so the gaps between them stay tight (no big void mid-stream).
  private var isLiveTurn = false
  // Persistent feed views for the LIVE interleaved feed, keyed by node identity. The
  // streaming path reuses these across frames instead of tearing the feed down and
  // rebuilding it (which created a fresh streaming label every delta → the whole
  // narration re-faded in each frame, looked batched, and flickered). Cleared by
  // `clearStepsList()` when the turn finishes / the cell is reused.
  private var liveFeedViewsByKey: [String: UIView] = [:]
  private var liveFeedHeightByKey: [String: NSLayoutConstraint] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func prepareForInterfaceBuilder() {
    super.prepareForInterfaceBuilder()
    stackView.layoutIfNeeded()
  }

  func reset() {
    teamHeaderLabel.text = nil
    teamHeaderLabel.isHidden = true
    loaderView.configure(text: "", isStreaming: false, progressItems: [])
    loaderView.onTap = nil
    loaderView.isHidden = true
    clearStepsList()
    runtimeSummaryView.onToggleExpand = nil
    runtimeSummaryView.onReviewTapped = nil
    runtimeSummaryView.onFileTapped = nil
    runtimeSummaryView.isHidden = true
    runtimeHeightConstraint?.constant = 0.0
    removeBlockViews()
  }

  private func clearStepsList() {
    stepsStack.arrangedSubviews.forEach {
      stepsStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    liveFeedViewsByKey.removeAll()
    liveFeedHeightByKey.removeAll()
    stepsStack.isHidden = true
  }

  // Build the rows shown when "Worked · N steps" is expanded. Narration ("text")
  // nodes render with the same font/color/parser as the normal streaming answer.
  // Tool nodes render as expandable `StepRowView`s.
  private func updateStepsList(
    _ items: [VibeAgentKitProgressItem],
    leadingText: String? = nil,
    expanded: Bool,
    interactive: Bool,
    appearance: VibeAgentKitChatAppearance,
    streaming: Bool = false,
    availableWidth: CGFloat
  ) {
    clearStepsList()
    let normalizedLeadingText = leadingText?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasLeadingText = normalizedLeadingText?.isEmpty == false
    guard expanded, hasLeadingText || !items.isEmpty else { return }
    stepsStack.spacing = streaming ? 9.0 : 11.0
    // Shell already supplies agent-turn bubble padding — keep stack margins minimal
    // so prose isn't double-indented and hugs the same edge as plain them-bubbles.
    stepsStack.layoutMargins = streaming
      ? UIEdgeInsets(top: 2.0, left: 2.0, bottom: 4.0, right: 2.0)
      : UIEdgeInsets(top: 2.0, left: 2.0, bottom: 4.0, right: 2.0)
    if let leadingText, hasLeadingText {
      stepsStack.addArrangedSubview(
        narrationWorkLogView(
          text: leadingText,
          streaming: streaming,
          appearance: appearance,
          availableWidth: availableWidth))
    }
    for item in items {
      if item.itemType == "text" {
        let narration = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if narration.isEmpty { continue }
        stepsStack.addArrangedSubview(
          narrationWorkLogView(
            text: narration,
            streaming: streaming,
            appearance: appearance,
            availableWidth: availableWidth))
        continue
      }
      let nodeId = item.nodeId ?? item.label
      // Supervisor team worker: avatar + name + status row, tap → worker detail.
      if item.itemType == "teamworker" {
        let workerRow = VibeAgentKitTeamWorkerRowView()
        workerRow.translatesAutoresizingMaskIntoConstraints = false
        workerRow.configure(item: item, appearance: appearance)
        workerRow.onTap = { [weak self] in self?.onOpenSubagent?(nodeId) }
        stepsStack.addArrangedSubview(workerRow)
        continue
      }
      // A subagent (Claude Task tool) node renders as a compact, always-tappable row
      // that opens the read-only subagent view — never an inline expand. Its own
      // Read/Edit/Run steps live only in that view (subagentChildren).
      // Gated on isRealSubagent: a task-kind node WITHOUT a subagentType is a
      // synthetic working placeholder and falls through to a plain step row.
      if item.isRealSubagent {
        let subagentRow = VibeAgentKitSubagentRowView()
        subagentRow.translatesAutoresizingMaskIntoConstraints = false
        let running = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
        let toolStepCount = subagentChildren[nodeId]?.filter { $0.itemType != "text" }.count ?? 0
        subagentRow.configure(
          type: item.subagentType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
          stepCount: toolStepCount,
          running: running,
          appearance: appearance)
        subagentRow.onTap = { [weak self] in self?.onOpenSubagent?(nodeId) }
        stepsStack.addArrangedSubview(subagentRow)
        continue
      }
      let row = VibeAgentKitStepRowView()
      row.translatesAutoresizingMaskIntoConstraints = false
      row.configure(
        item: item,
        // Finished feed: each row is a one-line preview that taps open to its detail
        // (command output / diff / file slice). The live feed has its own builder
        // (`updateStreamingStepsList`) that also makes rows tappable mid-run.
        expanded: interactive && expandedStepIds.contains(nodeId),
        interactive: interactive,
        appearance: appearance
      )
      row.onToggle = interactive ? { [weak self] in self?.onStepTap?(nodeId) } : nil
      stepsStack.addArrangedSubview(row)
    }
    stepsStack.isHidden = false
  }

  /// Incremental builder for the LIVE interleaved feed (narration text + tool steps).
  /// Unlike `updateStepsList`, this REUSES the per-node views across streaming frames
  /// (keyed by stable identity) instead of clearing + rebuilding. That is what makes the
  /// streaming narration label persist so it reveals ONLY the newly-arrived characters —
  /// rebuilding it every frame re-faded the whole accumulated prose (the "old text fades
  /// in alongside the new / batched / flicker" bug). Narration nodes only append, so an
  /// ordinal key is stable; tool/task nodes key on their node id.
  private func updateStreamingStepsList(
    _ items: [VibeAgentKitProgressItem],
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat
  ) {
    let renderable = items.filter { item in
      if item.itemType == "text" {
        return !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return true
    }
    guard !renderable.isEmpty else { clearStepsList(); return }

    // Structured streaming feed: a little more vertical air between narration blocks
    // and tool rows so long answers don't read as one dense column.
    stepsStack.spacing = 11.0
    stepsStack.layoutMargins = UIEdgeInsets(top: 2.0, left: 2.0, bottom: 4.0, right: 2.0)

    let font = UIFont.systemFont(ofSize: 16.0, weight: .regular)
    let lineHeight: CGFloat = 24.0
    let color = appearance.text
    let contentWidth = max(
      120.0, availableWidth - stepsStack.layoutMargins.left - stepsStack.layoutMargins.right)

    var orderedKeys: [String] = []
    var textOrdinal = 0
    for item in renderable {
      if item.itemType == "text" {
        let key = "text#\(textOrdinal)"
        textOrdinal += 1
        orderedKeys.append(key)
        let narration = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let label: VibeAgentKitStreamingTextLabel
        if let existing = liveFeedViewsByKey[key] as? VibeAgentKitStreamingTextLabel {
          label = existing
        } else {
          label = VibeAgentKitStreamingTextLabel()
          label.translatesAutoresizingMaskIntoConstraints = false
          label.numberOfLines = 0
          label.backgroundColor = .clear
          liveFeedViewsByKey[key] = label
        }
        let attributed = VibeAgentKitTextRenderer.makeAttributedText(
          text: narration, font: font, textColor: color, lineHeight: lineHeight)
        let measured = VibeAgentKitTextRenderer.measuredSize(for: attributed, width: contentWidth)
        let height = max(ceil(font.lineHeight), measured.height)
        if let heightConstraint = liveFeedHeightByKey[key] {
          heightConstraint.constant = height
        } else {
          let heightConstraint = label.heightAnchor.constraint(equalToConstant: height)
          heightConstraint.priority = .defaultHigh
          heightConstraint.isActive = true
          liveFeedHeightByKey[key] = heightConstraint
        }
        // Same label instance across frames → only the appended characters fade in.
        label.applyStreamingText(attributed, rawText: narration, isStreaming: true)
        continue
      }

      let nodeId = item.nodeId ?? item.label
      // Supervisor team worker: reuse the SAME row view across stream frames (keyed by
      // node id) so only the status text mutates — no per-frame view churn.
      if item.itemType == "teamworker" {
        let key = "teamworker#\(nodeId)"
        orderedKeys.append(key)
        let workerRow: VibeAgentKitTeamWorkerRowView
        if let existing = liveFeedViewsByKey[key] as? VibeAgentKitTeamWorkerRowView {
          workerRow = existing
        } else {
          workerRow = VibeAgentKitTeamWorkerRowView()
          workerRow.translatesAutoresizingMaskIntoConstraints = false
          liveFeedViewsByKey[key] = workerRow
        }
        workerRow.configure(item: item, appearance: appearance)
        workerRow.onTap = { [weak self] in self?.onOpenSubagent?(nodeId) }
        continue
      }
      // isRealSubagent: synthetic task-kind placeholders (no subagentType) render
      // as plain step rows, never as a phantom "Subagent" row.
      if item.isRealSubagent {
        let key = "task#\(nodeId)"
        orderedKeys.append(key)
        let subagentRow: VibeAgentKitSubagentRowView
        if let existing = liveFeedViewsByKey[key] as? VibeAgentKitSubagentRowView {
          subagentRow = existing
        } else {
          subagentRow = VibeAgentKitSubagentRowView()
          subagentRow.translatesAutoresizingMaskIntoConstraints = false
          liveFeedViewsByKey[key] = subagentRow
        }
        let running = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
        let toolStepCount = subagentChildren[nodeId]?.filter { $0.itemType != "text" }.count ?? 0
        subagentRow.configure(
          type: item.subagentType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
          stepCount: toolStepCount,
          running: running,
          appearance: appearance,
          live: true)
        subagentRow.onTap = { [weak self] in self?.onOpenSubagent?(nodeId) }
        continue
      }

      let key = "tool#\(nodeId)"
      orderedKeys.append(key)
      let row: VibeAgentKitStepRowView
      if let existing = liveFeedViewsByKey[key] as? VibeAgentKitStepRowView {
        row = existing
      } else {
        row = VibeAgentKitStepRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        liveFeedViewsByKey[key] = row
      }
      // Live rows are tappable mid-run: expanding one reveals the command + its output
      // (or the diff / file slice) AS IT STREAMS, instead of waiting for the turn to
      // finish. The header stays compact; expanded detail is the only part that grows.
      // The expand state lives in `expandedStepIds` (owned by the host VC), so it
      // survives the per-frame reconfigure and the row keeps showing the growing output.
      row.configure(
        item: item,
        expanded: expandedStepIds.contains(nodeId),
        interactive: true,
        streaming: true,
        appearance: appearance)
      row.onToggle = { [weak self] in self?.onStepTap?(nodeId) }
    }

    // Drop cached views whose nodes are gone (rare mid-run, e.g. a coalesced feed).
    // Collect the stale keys first — mutating the dictionary while iterating it is unsafe.
    let keep = Set(orderedKeys)
    let staleKeys = liveFeedViewsByKey.keys.filter { !keep.contains($0) }
    for key in staleKeys {
      if let view = liveFeedViewsByKey[key] {
        stepsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      liveFeedViewsByKey.removeValue(forKey: key)
      liveFeedHeightByKey.removeValue(forKey: key)
    }
    // Rebuild arranged order from `orderedKeys` (chronological progressNodes).
    // Incremental insertArrangedSubview reordering was unstable under Grok's
    // multi-segment text/tool interleave: text views could end up pinned under
    // every tool/note row even when progressNodes order was correct ("streaming
    // text always at the bottom, notes on top").
    let desiredViews: [UIView] = orderedKeys.compactMap { liveFeedViewsByKey[$0] }
    let current = stepsStack.arrangedSubviews
    if current.count != desiredViews.count
      || !zip(current, desiredViews).allSatisfy({ $0 === $1 })
    {
      for view in current {
        stepsStack.removeArrangedSubview(view)
      }
      for view in desiredViews {
        stepsStack.addArrangedSubview(view)
      }
    }
    stepsStack.isHidden = false
  }

  private func narrationWorkLogView(
    text: String,
    streaming: Bool,
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat
  ) -> UIView {
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.distribution = .fill
    stack.spacing = 10.0
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 2.0, right: 0.0)

    let font = UIFont.systemFont(ofSize: 16.0, weight: .regular)
    let color = appearance.text
    let lineHeight: CGFloat = 24.0
    let contentWidth = max(120.0, availableWidth - stepsStack.layoutMargins.left - stepsStack.layoutMargins.right)
    let blocks = VibeAgentKitTextRenderer.parseBlocks(text)

    for (index, block) in blocks.enumerated() {
      switch block {
      case .text(let content):
        let attributed = VibeAgentKitTextRenderer.makeAttributedText(
          text: content,
          font: font,
          textColor: color,
          lineHeight: lineHeight
        )
        let measured = VibeAgentKitTextRenderer.measuredSize(for: attributed, width: contentWidth)
        let height = max(ceil(font.lineHeight), measured.height)
        if streaming {
          let label = VibeAgentKitStreamingTextLabel()
          label.translatesAutoresizingMaskIntoConstraints = false
          label.numberOfLines = 0
          label.backgroundColor = .clear
          label.applyStreamingText(attributed, rawText: content, isStreaming: true)
          let heightConstraint = label.heightAnchor.constraint(equalToConstant: height)
          heightConstraint.priority = .required
          heightConstraint.isActive = true
          label.setContentCompressionResistancePriority(.required, for: .vertical)
          stack.addArrangedSubview(label)
        } else {
          let label = UILabel()
          label.translatesAutoresizingMaskIntoConstraints = false
          label.numberOfLines = 0
          label.backgroundColor = .clear
          label.preferredMaxLayoutWidth = contentWidth
          label.attributedText = attributed
          let heightConstraint = label.heightAnchor.constraint(equalToConstant: height)
          heightConstraint.priority = .required
          heightConstraint.isActive = true
          label.setContentCompressionResistancePriority(.required, for: .vertical)
          stack.addArrangedSubview(label)
        }

      case .code(let code, let language):
        let codeView = VibeAgentKitCodeBlockView()
        codeView.translatesAutoresizingMaskIntoConstraints = false
        let height = codeView.configure(
          code: code,
          language: language,
          textColor: color,
          baseFont: font,
          availableWidth: contentWidth,
          storageKey: "worklog-\(text.hashValue)-\(index)"
        )
        let heightConstraint = codeView.heightAnchor.constraint(equalToConstant: height)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        codeView.setContentCompressionResistancePriority(.required, for: .vertical)
        codeView.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(codeView)
      }
    }
    return stack
  }

  /// Color the "+N" additions green and "−N" deletions red inside a step label so the
  /// expanded work card reads like a diff summary (Claude/Codex style), while the verb
  /// + target stay in the muted base color. The minus is U+2212 (the formatter emits
  /// it, not an ASCII hyphen).
  /// Compiled once. Building it per step row blocked main 0.47s in a device export.
  fileprivate static let stepDiffCountRegex = try? NSRegularExpression(
    pattern: "[+\u{2212}]\\d[\\d,]*")

  fileprivate static func styledStepLabel(
    _ string: String,
    font: UIFont,
    baseColor: UIColor,
    paragraph: NSParagraphStyle
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString(
      string: string,
      attributes: [.font: font, .foregroundColor: baseColor, .paragraphStyle: paragraph]
    )
    let full = string as NSString
    guard let regex = Self.stepDiffCountRegex else { return attributed }
    for match in regex.matches(in: string, range: NSRange(location: 0, length: full.length)) {
      let isAdd = full.substring(with: match.range).hasPrefix("+")
      attributed.addAttribute(
        .foregroundColor,
        value: isAdd ? VibeAgentDiffPalette.additionText : VibeAgentDiffPalette.deletionText,
        range: match.range)
      attributed.addAttribute(
        .font, value: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold),
        range: match.range)
    }
    return attributed
  }

  private func removeBlockViews() {
    for view in blockViews {
      if let label = view as? VibeAgentKitStreamingTextLabel {
        label.resetStreamingState()
      }
      stackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    blockViews.removeAll()
    blockHeightConstraints.removeAll()
    lastBlockSignature = ""
  }

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
    self.expandedStepIds = expandedStepIds
    self.subagentChildren = subagentChildren
    let font = UIFont.systemFont(ofSize: 16.0, weight: .regular)
    let lineHeight: CGFloat = 24.0
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasDisplayText = !trimmedText.isEmpty
    let hasToolProgressItems = progressItems.contains { $0.itemType != "text" }
    // A PLAIN-PROSE live turn (the built-in "Vibe AI" conversational agent) streams its
    // answer AS THE MESSAGE BODY — no tool steps, no runtime card, no progress feed. The
    // interleaved-feed machinery below assumes live prose rides as "text" progressItems
    // (true for Claude/Codex) and SUPPRESSES the body while streaming; but this agent has
    // no such nodes, so that path hides the whole answer behind a fixed-size "Thinking"
    // shimmer until the turn settles — the "empty cell, no growth with the stream, then a
    // height jump at settle" bug. Detect it and let the body stream + grow directly: the
    // SAME renderer and SAME hug width are used live and settled, so nothing shifts when
    // the turn finishes. CLI-agent rows (bridge-/stream-/lan- ids, or any turn that
    // carries progress items / a runtime) never qualify — they keep the interleaved feed
    // even on a momentarily-empty first frame. Because `measuredHeight` reuses this exact
    // `configure`, the height measurement follows the body automatically (symmetry), so
    // the per-chunk heightReload path fires and the row grows token-by-token.
    let isPlainProseLiveTurn =
      isStreaming && hasDisplayText && progressItems.isEmpty && runtime == nil
      && !messageId.hasPrefix("bridge-") && !messageId.hasPrefix("stream-")
      && !messageId.hasPrefix("lan-")
    // A live turn stays one interleaved feed even after its first prose arrives.
    // Using hasFinalResponseText here switched to the settled layout mid-stream,
    // rendering the same assistant text once as a progress node and again as body.
    let showsLoader = isStreaming && !isPlainProseLiveTurn
    let runningStatuses: Set<String> = [
      "active", "in-progress", "in_progress", "pending", "queued", "running", "streaming", "working",
    ]
    let hasRunningProgressItem = progressItems.contains { item in
      guard let status = item.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        !status.isEmpty
      else { return false }
      return runningStatuses.contains(status)
    }
    let runtimeIsRunning: Bool = {
      guard let status = runtime?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        !status.isEmpty
      else { return false }
      return runningStatuses.contains(status)
    }()
    // Tools-only finished turns still get the Worked card (hasDisplayText can be false
    // after bridge restart recovery when body text lags the progressNodes payload).
    let canShowCompletedWork =
      !isStreaming && hasToolProgressItems && !hasRunningProgressItem && !runtimeIsRunning
      && (hasFinalResponseText || hasDisplayText || hasToolProgressItems)
    isLiveTurn = isStreaming
    configureTeamHeader(runtime: runtime, appearance: appearance)

    loaderView.applyAppearance(appearance)
    loaderView.onTap = onLoaderTap

    // GPT-style settled follow-up: answer body first, steps under it — no "Worked"
    // header on top. Bridge CLI turns keep the Worked summary.
    let isNativeToolFollowUp =
      !isStreaming && hasDisplayText && hasToolProgressItems && runtime == nil
      && !messageId.hasPrefix("bridge-") && !messageId.hasPrefix("stream-")
      && !messageId.hasPrefix("lan-")

    // Live tool turns always stream the interleaved feed under the shimmer. Settled
    // native follow-ups keep steps expanded under the answer body. Never expand
    // while tall-collapsed.
    let stepsExpanded =
      !isContentCollapsed
      && (
        (isStreaming && hasToolProgressItems)
          || (isProgressExpanded && canShowCompletedWork)
          || isNativeToolFollowUp
      )

    let shouldShowLoader =
      showsLoaderView
      && (showsLoader || (canShowCompletedWork && !isNativeToolFollowUp))

    if shouldShowLoader {
      let loaderText: String
      let teamWorkerItems = progressItems.filter { $0.itemType == "teamworker" }
      if !teamWorkerItems.isEmpty {
        // Supervisor team run: the header states the TEAM's condition, not the last
        // tool step (the worker rows below carry the per-agent detail).
        let doneCount = teamWorkerItems.filter {
          let s = ($0.status ?? "").lowercased()
          return s == "done" || s == "completed" || s == "failed" || s == "skipped"
        }.count
        if showsLoader {
          loaderText =
            doneCount > 0
            ? "Team running · \(doneCount)/\(teamWorkerItems.count) done"
            : "Team running"
        } else if let ms = runtime?.durationMs, ms > 0 {
          loaderText = "Team finished · \(ChatListRow.TeamWorkerStatus.formatDuration(ms))"
        } else {
          loaderText = "Team finished"
        }
      } else if showsLoader {
        // Live turn: shimmer the tool action in flight ("Edit chat.ex", "Run …"). Prefer
        // the last NON-text node so the shimmer never echoes the narration prose that is
        // already rendered (in full) inline in the interleaved feed below; fall back to a
        // generic "Thinking" while the agent is only producing prose. Thinking nodes get
        // the live token counter ("Thinking · 1.2k tokens") so reasoning stretches read
        // like the desktop CLI instead of a frozen label.
        loaderText = progressItems.last(where: { $0.itemType != "text" })
          .map { vibeAgentKitProgressDisplayLabel($0) }
          ?? fallbackProgressLabels.last ?? "Thinking"
      } else {
        // Completed turn: collapse the whole run into one tappable summary line
        // ("Worked for 1m 3s · N steps") that expands the step list inline. The
        // elapsed time rides the decrypted runtime (live turns carry durationMs);
        // history turns have no duration, so they read "Worked · N steps". Same
        // structure for Claude and Codex — both feed progressItems + runtime.
        // "text" nodes are the folded-in narration, not tool steps — don't count
        // them toward "· N steps" (that count means Read/Edit/Run actions).
        let toolStepCount = progressItems.filter { $0.itemType != "text" }.count
        loaderText = Self.workedSummary(
          stepCount: toolStepCount,
          durationMs: runtime?.durationMs,
          usage: runtime?.usage
        )
      }
      loaderView.isHidden = false
      loaderView.configure(
        text: loaderText,
        isStreaming: showsLoader,
        progressItems: progressItems,
        isExpanded: stepsExpanded,
        streamingStartDate: showsLoader ? streamingStartDate : nil
      )
    } else {
      loaderView.isHidden = true
      loaderView.configure(text: "", isStreaming: false, progressItems: [])
    }

    // Live turn: stream the recent steps under the shimmer so you watch the agent
    // work (Read → Edit → Run …) as it happens — labels only (detail bodies would be
    // too noisy mid-run), capped to the most recent few. The shimmer line carries the
    // current action, so the feed shows the ones before it. Completed turn: the steps
    // live inside the tappable "Worked" card and reveal their command output / search
    // hits + diff counts when expanded.
    if showsLoader {
      // Live turn: the work feed is the SINGLE source of the in-flight turn — it
      // interleaves narration text and tool steps (Read → text → Edit → …) in
      // chronological order. The separate streaming answer body is suppressed below
      // (see the `!showsLoader` guard) so the prose is never split off into its own
      // block under a detached group of tool steps.
      let feedOrder =
        progressItems
        .map { ($0.itemType ?? $0.tool ?? "step").lowercased() }
        .joined(separator: ",")
      // DIAGNOSTIC (text-in-live-feed): textNodes = how many "text" prose steps reached
      // the renderer; bodyLen = length of the suppressed answer body. If textNodes=0 but
      // bodyLen>0, the narration is arriving as the message body (hidden mid-stream),
      // not as feed nodes — so the live feed shows only commands.
      let textNodes = progressItems.filter { $0.itemType == "text" }
      let textChars = textNodes.reduce(0) { $0 + $1.label.count }
      let bodyTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      NSLog(
        "[AgentFeed] live msg=%@ items=%d order=[%@] textNodes=%d textChars=%d bodyLen=%d hasFinal=%@ bodyPreview=%@ shimmer=%@",
        messageId, progressItems.count, feedOrder,
        textNodes.count, textChars, bodyTrimmed.count, hasFinalResponseText ? "Y" : "N",
        String(bodyTrimmed.prefix(48)).replacingOccurrences(of: "\n", with: "⏎"),
        progressItems.last(where: { $0.itemType != "text" })
          .map { vibeAgentKitProgressDisplayLabel($0) } ?? "Thinking")
      updateStreamingStepsList(
        progressItems,
        appearance: appearance,
        availableWidth: availableWidth)
    } else {
      updateStepsList(
        progressItems,
        expanded: stepsExpanded,
        interactive: true,
        appearance: appearance,
        availableWidth: availableWidth)
    }

    // The file-change / diff card belongs to a FINISHED turn only — the agent works
    // top-down and the consolidated patch isn't meaningful until it's done, so don't
    // flash an "edited file" card mid-stream. Live turns show the step feed instead.
    // Also hide under tall-collapse (no room for a second card under the preview).
    configureRuntimeSummary(
      (!isContentCollapsed && !isStreaming && hasDisplayText && !runtimeIsRunning
        && Self.hasRuntimeDiff(runtime))
        ? runtime
        : nil,
      textColor: appearance.text,
      availableWidth: availableWidth,
      isExpanded: isRuntimeExpanded
    )

    // Suppress the separate answer body when there is no text yet OR while the turn is
    // live. A live turn's prose rides INSIDE the interleaved feed above (as "text"
    // nodes), so rendering it again here would split the answer into a detached block
    // below the tool steps — the "grouped / disconnected flow" bug. The body returns
    // when the turn finishes (showsLoader == false) and the feed collapses to "Worked".
    guard hasDisplayText, !showsLoader else {
      for (index, view) in blockViews.enumerated() {
        if let label = view as? VibeAgentKitStreamingTextLabel {
          label.resetStreamingState()
        }
        view.isHidden = true
        blockHeightConstraints[index].constant = 0.0
      }
      // Keep the work feed visible so the row never looks frozen; it owns the live
      // narration + tool steps until the turn finishes.
      positionSummaryViews()
      return
    }

    // Tall-collapsed bubble: only a single plain text preview fits under the 420pt
    // cap. Multi-block code cards with required heights fight the cap and paint over
    // each other (table+bash glass overlap). Expand ("Show more") restores full blocks.
    if isContentCollapsed {
      for (index, view) in blockViews.enumerated() {
        if let label = view as? VibeAgentKitStreamingTextLabel {
          label.resetStreamingState()
        }
        view.isHidden = true
        blockHeightConstraints[index].constant = 0.0
      }
      let preview = Self.collapsedBodyPreview(from: text)
      let previewBlocks: [VibeAgentKitParsedBlock] = [.text(preview)]
      // Reuse the normal block path with a single text block only.
      let signature = "T_collapsed"
      if signature != lastBlockSignature || blockViews.count != 1 {
        removeBlockViews()
        let label = VibeAgentKitStreamingTextLabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.backgroundColor = .clear
        stackView.insertArrangedSubview(
          label,
          at: max(1, stackView.arrangedSubviews.count - 1)
        )
        let heightConstraint = label.heightAnchor.constraint(equalToConstant: 0.0)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        blockViews = [label]
        blockHeightConstraints = [heightConstraint]
        lastBlockSignature = signature
      }
      if let label = blockViews.first as? VibeAgentKitStreamingTextLabel {
        let attributed = VibeAgentKitTextRenderer.makeAttributedText(
          text: preview,
          font: font,
          textColor: appearance.text,
          lineHeight: lineHeight
        )
        // Leave room for the Worked loader (~36) + padding inside the collapse cap.
        let maxPreviewHeight = max(80.0, tallBubbleCollapsedContentHeight - 72.0)
        let measured = VibeAgentKitTextRenderer.measuredSize(for: attributed, width: availableWidth)
        let height = min(maxPreviewHeight, max(ceil(font.lineHeight), measured.height))
        label.isHidden = false
        label.applyStreamingText(attributed, rawText: preview, isStreaming: false)
        blockHeightConstraints[0].constant = height
      }
      _ = previewBlocks
      positionSummaryViews()
      return
    }

    let blocks = VibeAgentKitTextRenderer.parseBlocks(text)
    let signature = blocks.map { block -> String in
      switch block {
      case .text:
        return "T"
      case .code:
        return "C"
      }
    }.joined()

    if signature != lastBlockSignature || blockViews.count != blocks.count {
      removeBlockViews()
      for block in blocks {
        let view: UIView
        switch block {
        case .text:
          let label = VibeAgentKitStreamingTextLabel()
          label.translatesAutoresizingMaskIntoConstraints = false
          label.numberOfLines = 0
          label.backgroundColor = .clear
          view = label
        case .code:
          let codeView = VibeAgentKitCodeBlockView()
          codeView.translatesAutoresizingMaskIntoConstraints = false
          view = codeView
        }
        // Insert text blocks above the bottom runtime card. Final ordering of the
        // loader/steps work log is applied by positionSummaryViews() after this loop.
        stackView.insertArrangedSubview(
          view,
          at: max(1, stackView.arrangedSubviews.count - 1)
        )
        // Required height: `.defaultHigh` was compressible, so UIStackView crushed
        // text/code blocks and their frame-drawn glass cards painted on top of each other.
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 0.0)
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        blockViews.append(view)
        blockHeightConstraints.append(heightConstraint)
      }
      lastBlockSignature = signature
    }

    var lastTextIndex: Int?
    for (index, block) in blocks.enumerated() {
      if case .text = block {
        lastTextIndex = index
      }
    }

    for (index, block) in blocks.enumerated() {
      let view = blockViews[index]
      view.isHidden = false
      switch block {
      case .text(let content):
        let label = view as! VibeAgentKitStreamingTextLabel
        let attributed = VibeAgentKitTextRenderer.makeAttributedText(
          text: content,
          font: font,
          textColor: appearance.text,
          lineHeight: lineHeight
        )
        let measured = VibeAgentKitTextRenderer.measuredSize(for: attributed, width: availableWidth)
        let height = max(ceil(font.lineHeight), measured.height)
        label.applyStreamingText(
          attributed,
          rawText: content,
          isStreaming: isStreaming && index == lastTextIndex
        )
        blockHeightConstraints[index].constant = height
        blockHeightConstraints[index].priority = .required

      case .code(let code, let language):
        let codeView = view as! VibeAgentKitCodeBlockView
        let height = codeView.configure(
          code: code,
          language: language,
          textColor: appearance.text,
          baseFont: font,
          availableWidth: availableWidth,
          storageKey: "\(messageId)#\(index)"
        )
        blockHeightConstraints[index].constant = height
        blockHeightConstraints[index].priority = .required
      }
    }

    // Chronological, always: the intent line and the steps the agent ran come FIRST, the
    // answer settles underneath — the same order the user watched it stream, and the same
    // order the bridge CLIs use. Putting the body on top (the old "GPT-style" native
    // follow-up layout) read as scrambled: the summary appeared above the "I'll check…"
    // intent that produced it, with the reasoning row trailing at the bottom.
    positionSummaryViews()
  }

  /// Plain preview for tall-collapsed agent bubbles: drop fenced code (it needs a
  /// full-height glass card) and trim to a short readable lead-in.
  private static func collapsedBodyPreview(from text: String) -> String {
    var lines: [String] = []
    var inFence = false
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        inFence.toggle()
        continue
      }
      if inFence { continue }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      // Skip pure markdown table separator rows in the compact preview.
      if trimmed.hasPrefix("|") && trimmed.contains("---") { continue }
      lines.append(line)
      if lines.joined(separator: "\n").count > 900 { break }
    }
    let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if joined.isEmpty {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if joined.count > 900 {
      return String(joined.prefix(900)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
    return joined
  }

  /// Place the loader/work log above the answer body: header, work feed, then the response
  /// blocks, with the runtime summary always last. One order for every provider and for both
  /// the live and settled rendering of the same turn.
  private func positionSummaryViews() {
    guard stackView.arrangedSubviews.contains(runtimeSummaryView) else { return }
    // Detach both so re-insert order is deterministic.
    for view in [loaderView, stepsStack] {
      if stackView.arrangedSubviews.contains(view) {
        stackView.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
    }
    stackView.insertArrangedSubview(loaderView, at: 0)
    stackView.insertArrangedSubview(stepsStack, at: 1)
    // Spacing follows each view across reordering and is ignored while a view is
    // hidden. Keep gaps tight so the live text/progress timeline reads as one
    // continuous shape under the Working header.
    stackView.setCustomSpacing(isLiveTurn ? 6.0 : 10.0, after: loaderView)
    stackView.setCustomSpacing(isLiveTurn ? 6.0 : 10.0, after: stepsStack)
  }

  // Completed-turn summary line. Matches the Claude Code / Codex "Worked for Xs"
  // affordance: elapsed time first (when the runtime carries it), then the step
  // count, then this turn's usage (tokens + cost) when the runtime carries it — so
  // the user can see their spend without leaving the chat. Provider-agnostic — Claude
  // and Codex both populate progressItems and (for live turns) a runtime with usage.
  static func workedSummary(
    stepCount: Int,
    durationMs: Int?,
    usage: ChatListRow.AgentRuntimeUsage? = nil
  ) -> String {
    let steps = max(0, stepCount)
    let stepText = steps == 1 ? "1 step" : "\(steps) steps"
    let base: String
    if let ms = durationMs, ms >= 1000 {
      base = "Worked for \(formatElapsed(ms)) · \(stepText)"
    } else {
      base = "Worked · \(stepText)"
    }
    guard let suffix = usageSuffix(usage) else { return base }
    return "\(base) · \(suffix)"
  }

  /// Compact "18.4k tokens · $0.06" suffix from a turn's usage, omitting whichever
  /// parts the provider didn't report. Returns nil when there's nothing to show.
  private static func usageSuffix(_ usage: ChatListRow.AgentRuntimeUsage?) -> String? {
    guard let usage else { return nil }
    var parts: [String] = []
    let totalTokens = (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
    if totalTokens > 0 {
      parts.append("\(compactTokens(totalTokens)) tokens")
    }
    if let cost = usage.totalCostUsd, cost > 0 {
      parts.append(String(format: "$%.2f", cost))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func compactTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000.0) }
    if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000.0) }
    return "\(n)"
  }

  private static func formatElapsed(_ ms: Int) -> String {
    let totalSeconds = ms / 1000
    if totalSeconds < 60 { return "\(totalSeconds)s" }
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    if minutes < 60 {
      return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
    let hours = minutes / 60
    let remMinutes = minutes % 60
    return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
  }

  private func setup() {
    backgroundColor = .clear
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 8.0
    teamHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
    teamHeaderLabel.isHidden = true
    teamHeaderLabel.numberOfLines = 1
    teamHeaderLabel.lineBreakMode = .byTruncatingTail
    teamHeaderLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    loaderView.translatesAutoresizingMaskIntoConstraints = false
    loaderView.isHidden = true
    stepsStack.translatesAutoresizingMaskIntoConstraints = false
    stepsStack.axis = .vertical
    stepsStack.alignment = .fill
    stepsStack.distribution = .fill
    // The work log is a subordinate band: a little more air between its rows and a
    // hanging left indent so the whole "what the agent did" block reads as a unit,
    // visually distinct from the answer body that follows it.
    stepsStack.spacing = 7.0
    stepsStack.isHidden = true
    stepsStack.isLayoutMarginsRelativeArrangement = true
    stepsStack.layoutMargins = UIEdgeInsets(top: 2.0, left: 6.0, bottom: 4.0, right: 0.0)
    runtimeSummaryView.translatesAutoresizingMaskIntoConstraints = false
    runtimeSummaryView.isHidden = true
    addSubview(stackView)
    // Order: team identity, loader ("Worked …"), inline steps (expand target), response text
    // blocks (inserted between here and the runtime card), then the diff card.
    stackView.addArrangedSubview(teamHeaderLabel)
    stackView.addArrangedSubview(loaderView)
    stackView.addArrangedSubview(stepsStack)
    stackView.addArrangedSubview(runtimeSummaryView)
    let runtimeHeightConstraint = runtimeSummaryView.heightAnchor.constraint(equalToConstant: 0.0)
    runtimeHeightConstraint.priority = .defaultHigh
    runtimeHeightConstraint.isActive = true
    self.runtimeHeightConstraint = runtimeHeightConstraint

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func configureTeamHeader(
    runtime: ChatListRow.AgentRuntimeSummary?,
    appearance: VibeAgentKitChatAppearance
  ) {
    // The brown "TEAM · Codex · N of M · <device>" footer was noisy clutter in the
    // list — the avatar + per-worker rows already identify the run and its members.
    // Suppress it entirely (kept as a no-op so the call sites stay put).
    _ = runtime
    _ = appearance
    teamHeaderLabel.text = nil
    teamHeaderLabel.isHidden = true
  }

  var onToggleRuntimeExpand: (() -> Void)?
  var onReviewTapped: (() -> Void)?
  var onFileTapped: ((ChatListRow.AgentRuntimeFile) -> Void)?

  private func configureRuntimeSummary(
    _ runtime: ChatListRow.AgentRuntimeSummary?,
    textColor: UIColor,
    availableWidth: CGFloat,
    isExpanded: Bool
  ) {
    guard let runtime else {
      runtimeSummaryView.onToggleExpand = nil
      runtimeSummaryView.onReviewTapped = nil
      runtimeSummaryView.onFileTapped = nil
      runtimeSummaryView.isHidden = true
      runtimeHeightConstraint?.constant = 0.0
      return
    }
    runtimeSummaryView.onToggleExpand = onToggleRuntimeExpand
    runtimeSummaryView.onReviewTapped = onReviewTapped
    runtimeSummaryView.onFileTapped = onFileTapped
    let height = runtimeSummaryView.configure(
      runtime: runtime,
      textColor: textColor,
      availableWidth: availableWidth,
      isExpanded: isExpanded
    )
    runtimeSummaryView.isHidden = false
    runtimeHeightConstraint?.constant = height
  }

  private static func hasRuntimeDiff(_ runtime: ChatListRow.AgentRuntimeSummary?) -> Bool {
    agentRuntimeHasDiff(runtime)
  }
}

// One tool step inside the "Worked" card: a tappable collapsed preview (verb +
// target — or the raw command for bash — plus a chevron) that expands an inline
// detail layer on tap. The layer is built per-kind: bash → full (un-clipped)
// command box + a result code box tinted by success/failure; edit/write → the
// unified-diff patch (green/red lines) with the file name; read → the line range
// and the file slice it read (fallback "Reading…"); everything else → its output.
// All rows self-size (no explicit heights) so the table's automaticDimension grows
// the cell as a row opens.
// One worker of a supervisor team run, rendered inside the lead bubble's feed: the
// agent's avatar (same resolver as the floating group avatars), its name, a live
// status line ("working…", the last step label, "done · 2m"), a spinner while it
// runs, and a chevron. Always tappable — opens that worker's read-only detail view.
// The status label mutates in place across stream frames (single line, fixed row
// height), so worker progress is visible without re-flowing the cell.
private final class VibeAgentKitTeamWorkerRowView: UIView {
  private let header = UIControl()
  private let avatarView = SenderRunAvatarView()
  private let nameLabel = UILabel()
  private let statusLabel = UILabel()
  // A running worker shows a shimmer sweep across its status text instead of a
  // spinner — the status label mutates in place, so a swept highlight reads as
  // "live" without a busy indicator. The mask keeps text ≥35% visible.
  private let statusShimmerMask = CAGradientLayer()
  private var isShimmering = false
  private let doneCheck = UIImageView()
  private let chevron = UIImageView()
  var onTap: (() -> Void)?

  // Live elapsed clock. `runningStartedAtMs` is the server-stamped start (epoch ms),
  // non-nil only while a live worker should tick; the 1Hz timer re-renders the status
  // label ("editing X · 4m 12s") without any stream frame. `terminated` latches a
  // settled worker so a late out-of-order "running" frame can't restart the clock.
  private var elapsedTimer: Timer?
  private var runningStartedAtMs: Int64?
  private var baseStatusText: String = ""
  private var statusTextAttributes: [NSAttributedString.Key: Any] = [:]
  private var terminated = false
  private var latchedStartedAtMs: Int64?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { return nil }

  deinit { elapsedTimer?.invalidate() }

  private func setup() {
    backgroundColor = .clear
    header.translatesAutoresizingMaskIntoConstraints = false
    addSubview(header)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      header.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8.0
    stack.isUserInteractionEnabled = false
    header.addSubview(stack)

    avatarView.translatesAutoresizingMaskIntoConstraints = false

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.numberOfLines = 1
    nameLabel.setContentHuggingPriority(.required, for: .horizontal)
    nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.numberOfLines = 1
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    statusShimmerMask.startPoint = CGPoint(x: 0, y: 0.5)
    statusShimmerMask.endPoint = CGPoint(x: 1, y: 0.5)
    statusShimmerMask.colors = [
      UIColor(white: 1.0, alpha: 0.35).cgColor,
      UIColor(white: 1.0, alpha: 1.0).cgColor,
      UIColor(white: 1.0, alpha: 0.35).cgColor,
    ]
    statusShimmerMask.locations = [0.0, 0.5, 1.0]

    doneCheck.translatesAutoresizingMaskIntoConstraints = false
    doneCheck.contentMode = .scaleAspectFit
    doneCheck.image = UIImage(systemName: "checkmark.circle.fill")?
      .withRenderingMode(.alwaysTemplate)
    doneCheck.setContentHuggingPriority(.required, for: .horizontal)

    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.contentMode = .scaleAspectFit
    chevron.image = UIImage(systemName: "chevron.right")?.withRenderingMode(.alwaysTemplate)
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

    // Avatar-only identity: the avatar alone names the worker (no "Claude/Grok/Agy"
    // text). The status label carries the live narration ("editing X"); the avatar
    // carries who. nameLabel is kept as a field for a11y but not shown in the row.
    stack.addArrangedSubview(avatarView)
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(doneCheck)
    stack.addArrangedSubview(chevron)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 5.0),
      stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -5.0),
      avatarView.widthAnchor.constraint(equalToConstant: 22.0),
      avatarView.heightAnchor.constraint(equalToConstant: 22.0),
      doneCheck.widthAnchor.constraint(equalToConstant: 15.0),
      doneCheck.heightAnchor.constraint(equalToConstant: 15.0),
      chevron.widthAnchor.constraint(equalToConstant: 10.0),
      chevron.heightAnchor.constraint(equalToConstant: 12.0),
    ])

    header.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
  }

  func configure(item: VibeAgentKitProgressItem, appearance: VibeAgentKitChatAppearance) {
    let worker = item.subagentType ?? ""
    let name = item.label.isEmpty ? worker.capitalized : item.label
    avatarView.configure(
      name: name,
      avatarUrl: SenderRunAvatarView.agentAvatarURL(for: worker),
      tint: appearance.primary,
      provider: worker)
    nameLabel.attributedText = NSAttributedString(
      string: name,
      attributes: [
        .font: UIFont.systemFont(ofSize: 14.0, weight: .semibold),
        .foregroundColor: appearance.text,
      ])
    let s = (item.status ?? "").lowercased()
    let running = vibeAgentKitRunningStepStatuses.contains(s) || s == "starting"
    let done = s == "done" || s == "completed"
    let failed = s == "failed" || s == "error"
    let rawStatus = item.messagePreview ?? ""
    // Never blank: a stopped/settled worker reads a real state, not an empty row.
    let statusText: String =
      !rawStatus.isEmpty
      ? rawStatus
      : done ? "done" : failed ? "failed" : s == "skipped" ? "skipped"
        : running ? "working…" : "stopped"

    // Live elapsed clock — tick from the server-stamped spawn moment while running.
    // Terminal latch: once done/failed, never re-arm on a late frame; a genuinely new
    // run (different startedAt) for the same reused row clears the latch.
    if done || failed {
      terminated = true
    } else if running, item.startedAtMs != latchedStartedAtMs {
      terminated = false
      latchedStartedAtMs = item.startedAtMs
    }
    runningStartedAtMs = (running && !terminated) ? item.startedAtMs : nil

    baseStatusText = statusText
    // Tabular figures so the ticking seconds never jitter the single-line row width
    // (no re-measure): only the text updates, height is fixed.
    statusTextAttributes = [
      .font: UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
      .foregroundColor: vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.78),
    ]
    renderStatusText()
    updateElapsedTimerState()
    // Shimmer only while genuinely working (running AND with a real live status).
    // A blank "starting" with no progress, a barrier "waiting" row, or a terminal
    // row is static — the shimmer must mean "actively working", nothing else.
    if running && !rawStatus.isEmpty { startStatusShimmer() } else { stopStatusShimmer() }
    doneCheck.isHidden = !(done || failed)
    doneCheck.tintColor =
      failed
      ? UIColor.systemRed.withAlphaComponent(0.85)
      : UIColor.systemGreen.withAlphaComponent(0.85)
    if failed {
      doneCheck.image = UIImage(systemName: "xmark.circle.fill")?
        .withRenderingMode(.alwaysTemplate)
    } else if done {
      doneCheck.image = UIImage(systemName: "checkmark.circle.fill")?
        .withRenderingMode(.alwaysTemplate)
    }
    // Arrow only when the row can actually open something — a finished worker (its
    // steps/summary), or one that is genuinely working right now. A settled "stopped"
    // / "waiting" / bare row has nothing to reveal, so no chevron and no tap target.
    let tappable = done || failed || (running && !rawStatus.isEmpty)
    chevron.isHidden = !tappable
    header.isUserInteractionEnabled = tappable
    chevron.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.6)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if isShimmering { statusShimmerMask.frame = statusLabel.bounds }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // A windowless row (offscreen sizing template, or a reused cell scrolled away)
    // must never tick — that was the prewarm-timer leak class. Re-arms on return.
    updateElapsedTimerState()
  }

  // Re-render the status label as base text + live elapsed suffix. Recomputed from the
  // absolute start each tick (never an incrementing counter), so it self-corrects after
  // the app is backgrounded and clamps a device/server clock skew to ≥ 0.
  private func renderStatusText() {
    var text = baseStatusText
    if let started = runningStartedAtMs {
      let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
      let suffix = Self.liveElapsed(Int(max(0, nowMs - started)))
      text = baseStatusText.isEmpty ? suffix : "\(baseStatusText) · \(suffix)"
    }
    statusLabel.attributedText = NSAttributedString(string: text, attributes: statusTextAttributes)
    if isShimmering { statusShimmerMask.frame = statusLabel.bounds }
  }

  private func updateElapsedTimerState() {
    let shouldTick = runningStartedAtMs != nil && window != nil
    if shouldTick {
      guard elapsedTimer == nil else { return }  // never stack across stream frames
      let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
        self?.renderStatusText()
      }
      timer.tolerance = 0.2
      // .common so the clock keeps ticking while the chat list is being scrolled.
      RunLoop.main.add(timer, forMode: .common)
      elapsedTimer = timer
    } else if let timer = elapsedTimer {
      timer.invalidate()
      elapsedTimer = nil
    }
  }

  // Always shows seconds under an hour so the clock visibly ticks every second, and
  // stays in the "Xm Ys" family the settled row uses ("done · 4m 30s").
  static func liveElapsed(_ ms: Int) -> String {
    let total = max(0, ms / 1000)
    if total < 60 { return "\(total)s" }
    let m = total / 60
    let sec = total % 60
    if m < 60 { return String(format: "%dm %02ds", m, sec) }
    let h = m / 60
    let rm = m % 60
    return String(format: "%dh %02dm", h, rm)
  }

  private func startStatusShimmer() {
    if isShimmering { return }
    isShimmering = true
    statusLabel.layer.mask = statusShimmerMask
    statusShimmerMask.frame = statusLabel.bounds
    let anim = CABasicAnimation(keyPath: "locations")
    anim.fromValue = [-0.6, -0.3, 0.0]
    anim.toValue = [1.0, 1.3, 1.6]
    anim.duration = 1.15
    anim.repeatCount = .infinity
    statusShimmerMask.add(anim, forKey: "vibe.worker.shimmer")
  }

  private func stopStatusShimmer() {
    if !isShimmering { return }
    isShimmering = false
    statusShimmerMask.removeAnimation(forKey: "vibe.worker.shimmer")
    statusLabel.layer.mask = nil
  }
}

// A compact, always-tappable row for a Claude subagent (Task tool). Shows the
// subagent flavor ("Subagent · explore"), a live spinner while it runs, the step
// count, and a chevron. Tapping opens the read-only subagent view; it never expands
// inline (the subagent's own steps live in that separate view).
private final class VibeAgentKitSubagentRowView: UIView {
  private let header = UIControl()
  private let titleLabel = UILabel()
  private let countLabel = UILabel()
  private let chevron = UIImageView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { return nil }

  private func setup() {
    backgroundColor = .clear
    header.translatesAutoresizingMaskIntoConstraints = false
    addSubview(header)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: topAnchor),
      header.leadingAnchor.constraint(equalTo: leadingAnchor),
      header.trailingAnchor.constraint(equalTo: trailingAnchor),
      header.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 7.0
    stack.isUserInteractionEnabled = false
    header.addSubview(stack)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.setContentHuggingPriority(.required, for: .horizontal)
    countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    spinner.setContentHuggingPriority(.required, for: .horizontal)

    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.contentMode = .scaleAspectFit
    chevron.image = UIImage(systemName: "chevron.right")?.withRenderingMode(.alwaysTemplate)
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

    stack.addArrangedSubview(titleLabel)
    stack.addArrangedSubview(spinner)
    stack.addArrangedSubview(countLabel)
    stack.addArrangedSubview(chevron)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 6.0),
      stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6.0),
      chevron.widthAnchor.constraint(equalToConstant: 10.0),
      chevron.heightAnchor.constraint(equalToConstant: 12.0),
    ])

    header.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
  }

  func configure(
    type: String,
    stepCount: Int,
    running: Bool,
    appearance: VibeAgentKitChatAppearance,
    live: Bool = false
  ) {
    let flavor = type.isEmpty ? "Subagent" : "Subagent · \(type)"
    let titleColor = live
      ? vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.78 : 0.68)
      : appearance.text
    titleLabel.attributedText = NSAttributedString(
      string: flavor,
      attributes: [
        .font: UIFont.systemFont(ofSize: live ? 13.4 : 14.75, weight: .semibold),
        .foregroundColor: titleColor,
      ])
    if stepCount > 0 {
      countLabel.text = stepCount == 1 ? "1 step" : "\(stepCount) steps"
      countLabel.isHidden = false
    } else {
      countLabel.text = nil
      countLabel.isHidden = true
    }
    countLabel.font = UIFont.systemFont(ofSize: live ? 11.8 : 12.5, weight: .regular)
    countLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, live ? 0.68 : 0.8)
    chevron.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, live ? 0.76 : 0.6)
    spinner.color = vibeAgentKitColorWithAlpha(appearance.textSecondary, live ? 0.72 : 0.85)
    if running { spinner.startAnimating() } else { spinner.stopAnimating() }
  }
}

private final class VibeAgentKitStepRowView: UIView {
  private let container = UIStackView()
  private let header = UIControl()
  private let titleLabel = UILabel()
  private let chevron = UIImageView()
  private let detailStack = UIStackView()
  private var isExpandedState = false
  var onToggle: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) { return nil }

  private func setup() {
    backgroundColor = .clear
    container.translatesAutoresizingMaskIntoConstraints = false
    container.axis = .vertical
    container.alignment = .fill
    container.spacing = 8.0
    addSubview(container)
    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: topAnchor),
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    header.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.numberOfLines = 2
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.contentMode = .scaleAspectFit
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
    header.addSubview(titleLabel)
    header.addSubview(chevron)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 5.0),
      titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -5.0),
      chevron.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8.0),
      chevron.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      chevron.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -5.0),
      chevron.widthAnchor.constraint(equalToConstant: 11.0),
      chevron.heightAnchor.constraint(equalToConstant: 11.0),
    ])
    header.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
    container.addArrangedSubview(header)

    detailStack.translatesAutoresizingMaskIntoConstraints = false
    detailStack.axis = .vertical
    detailStack.alignment = .fill
    detailStack.spacing = 8.0
    detailStack.isLayoutMarginsRelativeArrangement = true
    detailStack.layoutMargins = UIEdgeInsets(top: 2.0, left: 8.0, bottom: 8.0, right: 0.0)
    detailStack.isHidden = true
    container.addArrangedSubview(detailStack)
  }

  func configure(
    item: VibeAgentKitProgressItem,
    expanded: Bool,
    interactive: Bool,
    streaming: Bool = false,
    appearance: VibeAgentKitChatAppearance
  ) {
    let kind = (item.itemType ?? item.tool ?? "").lowercased()
    let isError = ["error", "failed", "failure"].contains((item.status ?? "").lowercased())
    let wasExpanded = isExpandedState
    let liveTextColor = vibeAgentKitColorWithAlpha(
      appearance.textSecondary,
      appearance.isDark ? 0.78 : 0.68
    )
    let previewTextColor = streaming ? liveTextColor : appearance.textSecondary

    // Header preview stays compact even in the live feed; the full command/output opens
    // inside this row's detail area so the whole table does not balloon while streaming.
    if kind == "bash", let cmd = item.command, !cmd.isEmpty {
      titleLabel.numberOfLines = 1
      titleLabel.lineBreakMode = .byTruncatingTail
      let commandText = cmd.replacingOccurrences(of: "\n", with: " ")
      titleLabel.attributedText = NSAttributedString(
        string: commandText,
        attributes: [
          .font: UIFont.monospacedSystemFont(ofSize: streaming ? 13.0 : 14.0, weight: .regular),
          .foregroundColor: streaming ? liveTextColor : appearance.text,
        ]
      )
    } else {
      titleLabel.numberOfLines = 2
      titleLabel.lineBreakMode = .byTruncatingTail
      var labelText = vibeAgentKitProgressDisplayLabel(item)
      if kind == "read", let start = item.lineStart {
        let range = item.lineEnd.map { "\(start)–\($0)" } ?? "\(start)"
        labelText += "  (\(range))"
      }
      let para = NSMutableParagraphStyle()
      para.lineBreakMode = .byTruncatingTail
      titleLabel.attributedText = VibeAgentKitAssistantMessageBodyView.styledStepLabel(
        labelText,
        font: UIFont.systemFont(ofSize: streaming ? 14.5 : 15.5, weight: .regular),
        baseColor: previewTextColor,
        paragraph: para
      )
    }

    let hasDetail = Self.hasDetail(item, kind: kind)
    let canToggle = interactive && (hasDetail || streaming)
    chevron.isHidden = !canToggle
    header.isUserInteractionEnabled = canToggle
    if canToggle {
      chevron.image = UIImage(systemName: "chevron.down")?.withRenderingMode(.alwaysTemplate)
      chevron.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, streaming ? 0.76 : 0.6)
      let target = expanded ? CGAffineTransform.identity : CGAffineTransform(rotationAngle: -CGFloat.pi / 2.0)
      if expanded != isExpandedState && chevron.window != nil {
        UIView.animate(withDuration: 0.2, delay: 0.0, options: [.beginFromCurrentState]) {
          self.chevron.transform = target
        }
      } else {
        chevron.transform = target
      }
      isExpandedState = expanded
    } else {
      chevron.image = nil
      chevron.transform = .identity
      isExpandedState = false
    }

    guard expanded else {
      detailStack.alpha = 1.0
      if wasExpanded { animateDetailCollapseSnapshot() }
      clearDetailStack()
      detailStack.transform = .identity
      detailStack.isHidden = true
      return
    }

    clearDetailStack()
    detailStack.alpha = 1.0
    detailStack.transform = .identity
    buildDetail(item: item, kind: kind, isError: isError, streaming: streaming, appearance: appearance)
    if streaming && detailStack.arrangedSubviews.isEmpty {
      detailStack.addArrangedSubview(caption("Waiting for details...", liveTextColor))
    }
    let hasVisibleDetail = !detailStack.arrangedSubviews.isEmpty
    detailStack.isHidden = !hasVisibleDetail
    guard hasVisibleDetail else { return }

    if !wasExpanded, window != nil {
      detailStack.transform = CGAffineTransform(translationX: 0.0, y: -8.0)
      UIView.animate(
        withDuration: 0.22,
        delay: 0.0,
        options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
      ) {
        self.detailStack.transform = .identity
      }
    } else {
      detailStack.transform = .identity
    }
  }

  private func clearDetailStack() {
    detailStack.arrangedSubviews.forEach {
      detailStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
  }

  private func animateDetailCollapseSnapshot() {
    guard window != nil,
      !detailStack.isHidden,
      detailStack.bounds.width > 0.0,
      detailStack.bounds.height > 0.0,
      let snapshot = detailStack.snapshotView(afterScreenUpdates: false)
    else { return }
    snapshot.frame = detailStack.convert(detailStack.bounds, to: self)
    snapshot.isUserInteractionEnabled = false
    addSubview(snapshot)
    UIView.animate(
      withDuration: 0.18,
      delay: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseIn]
    ) {
      snapshot.transform = CGAffineTransform(translationX: 0.0, y: -8.0)
    } completion: { _ in
      snapshot.removeFromSuperview()
    }
  }

  private static func hasDetail(_ item: VibeAgentKitProgressItem, kind: String) -> Bool {
    if let c = item.command, !c.isEmpty { return true }
    if let p = item.patch, !p.isEmpty { return true }
    if let f = item.fileContent, !f.isEmpty { return true }
    if let m = item.messageContent, !m.isEmpty { return true }
    // A read with no shipped slice still expands to show its range / a "Reading…" note.
    return kind == "read"
  }

  private func buildDetail(
    item: VibeAgentKitProgressItem,
    kind: String,
    isError: Bool,
    streaming: Bool = false,
    appearance: VibeAgentKitChatAppearance
  ) {
    // A step whose result hasn't arrived yet (live turn's trailing tool) must not
    // read "✓ Success" over an empty output — verdicts only exist once the tool
    // finished. `running` covers the bridge's result-less status; an empty output
    // on a still-STREAMING row is the same in-flight state (a finished step with
    // genuinely empty output — mkdir & co — still reads Success).
    let isRunning = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
    switch kind {
    case "bash":
      detailStack.addArrangedSubview(caption("Shell", appearance.textSecondary))
      let output = item.messageContent
      let pending = isRunning || (streaming && !isError && (output?.isEmpty ?? true))
      detailStack.addArrangedSubview(
        terminalCard(
          command: item.command, output: output, isError: isError, pending: pending,
          appearance: appearance))

    case "edit", "write":
      if let name = item.fileName, !name.isEmpty {
        detailStack.addArrangedSubview(caption(name, appearance.textSecondary))
      }
      if let patch = item.patch, !patch.isEmpty {
        detailStack.addArrangedSubview(patchBox(patch, appearance: appearance))
      } else {
        detailStack.addArrangedSubview(
          caption("No diff available.", vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)))
      }

    case "read":
      if let start = item.lineStart {
        let range = item.lineEnd.map { "Lines \(start)–\($0)" } ?? "From line \(start)"
        detailStack.addArrangedSubview(caption(range, appearance.textSecondary))
      }
      if let content = item.fileContent, !content.isEmpty {
        detailStack.addArrangedSubview(monoBox(content, appearance: appearance))
      } else {
        detailStack.addArrangedSubview(
          caption("Reading…", vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)))
      }

    default:
      if let output = item.messageContent, !output.isEmpty {
        detailStack.addArrangedSubview(monoBox(output, appearance: appearance))
      }
    }
  }

  // MARK: Detail builders (all self-sizing)

  private func caption(_ text: String, _ color: UIColor) -> UILabel {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 0
    label.font = UIFont.systemFont(ofSize: 12.0, weight: .semibold)
    label.textColor = color
    label.text = text
    return label
  }

  /// One terminal-style card: the `$ command`, its output, and a right-aligned
  /// ✓ Success / ✕ Failed result — the shell-result look.
  private func terminalCard(
    command: String?,
    output: String?,
    isError: Bool,
    pending: Bool = false,
    appearance: VibeAgentKitChatAppearance
  ) -> UIView {
    let dark = appearance.isDark
    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = vibeAgentKitColorWithAlpha(
      dark ? UIColor.white : UIColor.black, dark ? 0.06 : 0.045)
    card.layer.cornerRadius = 12.0
    card.layer.cornerCurve = .continuous

    let inner = UIStackView()
    inner.translatesAutoresizingMaskIntoConstraints = false
    inner.axis = .vertical
    inner.alignment = .fill
    inner.spacing = 12.0
    card.addSubview(inner)

    let mono = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
    let monoBold = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .semibold)
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byCharWrapping
    para.lineSpacing = 1.5

    if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 0
      label.lineBreakMode = .byCharWrapping
      let line = NSMutableAttributedString(
        string: "$ ",
        attributes: [
          .font: monoBold,
          .foregroundColor: vibeAgentKitColorWithAlpha(appearance.primary, 0.9),
          .paragraphStyle: para,
        ])
      line.append(
        NSAttributedString(
          string: command,
          attributes: [.font: monoBold, .foregroundColor: appearance.text, .paragraphStyle: para]))
      label.attributedText = line
      inner.addArrangedSubview(label)
    }

    if let output, !output.isEmpty {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 0
      label.lineBreakMode = .byCharWrapping
      label.attributedText = NSAttributedString(
        string: output,
        attributes: [
          .font: mono,
          .foregroundColor: vibeAgentKitColorWithAlpha(appearance.text, 0.82),
          .paragraphStyle: para,
        ])
      inner.addArrangedSubview(label)
    }

    let status = UILabel()
    status.translatesAutoresizingMaskIntoConstraints = false
    status.font = UIFont.systemFont(ofSize: 12.0, weight: .semibold)
    if pending {
      // No result yet — don't claim a verdict over an empty output.
      status.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.8)
      status.text = "Running…"
    } else {
      status.textColor = isError ? VibeAgentDiffPalette.deletionText : VibeAgentDiffPalette.additionText
      status.text = isError ? "✕ Failed" : "✓ Success"
    }
    status.textAlignment = .right
    inner.addArrangedSubview(status)

    NSLayoutConstraint.activate([
      inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14.0),
      inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14.0),
      inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14.0),
      inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14.0),
    ])
    return card
  }

  /// A padded, rounded monospace box (command, result, or read slice). `accent`
  /// tints the border so a bash result reads green (success) / red (failure).
  private func monoBox(
    _ text: String,
    appearance: VibeAgentKitChatAppearance,
    accent: UIColor? = nil
  ) -> UIView {
    let box = UIView()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.backgroundColor = vibeAgentKitColorWithAlpha(
      appearance.isDark ? UIColor.white : UIColor.black, appearance.isDark ? 0.05 : 0.04)
    box.layer.cornerRadius = 10.0
    box.layer.cornerCurve = .continuous
    if let accent {
      box.layer.borderWidth = 1.0
      box.layer.borderColor = vibeAgentKitColorWithAlpha(accent, 0.45).cgColor
    }
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 0
    label.lineBreakMode = .byCharWrapping
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byCharWrapping
    para.lineSpacing = 1.0
    label.attributedText = NSAttributedString(
      string: text,
      attributes: [
        .font: UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular),
        .foregroundColor: appearance.text,
        .paragraphStyle: para,
      ]
    )
    box.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: box.topAnchor, constant: 11.0),
      label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13.0),
      label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -13.0),
      label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11.0),
    ])
    return box
  }

  /// A padded box rendering a unified diff with per-line coloring (+ green, − red,
  /// @@ hunks muted) — the edit/write patch layer.
  private func patchBox(_ patch: String, appearance: VibeAgentKitChatAppearance) -> UIView {
    let font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    return diffLayoutView(patch: patch, appearance: appearance, font: font)
  }
}

fileprivate func diffLayoutView(patch: String, appearance: VibeAgentKitChatAppearance, font: UIFont) -> UIView {
  let box = UIView()
  box.translatesAutoresizingMaskIntoConstraints = false
  box.backgroundColor = vibeAgentKitColorWithAlpha(
    appearance.isDark ? UIColor.white : UIColor.black, appearance.isDark ? 0.05 : 0.04)
  box.layer.cornerRadius = 10.0
  box.layer.cornerCurve = .continuous
  box.clipsToBounds = true
  
  let stack = UIStackView()
  stack.translatesAutoresizingMaskIntoConstraints = false
  stack.axis = .vertical
  stack.spacing = 0
  box.addSubview(stack)
  
  NSLayoutConstraint.activate([
    stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 8.0),
    stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8.0),
    stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
    stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
  ])
  
  var lines = patch.components(separatedBy: "\n")
  if lines.last?.isEmpty == true {
    lines.removeLast()
  }
  
  let faint = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.55)
  
  for line in lines {
    let lineRow = UIView()
    lineRow.translatesAutoresizingMaskIntoConstraints = false
    
    let isAddition = line.hasPrefix("+") && !line.hasPrefix("+++")
    let isDeletion = line.hasPrefix("-") && !line.hasPrefix("---")
    
    if isAddition {
      lineRow.backgroundColor = VibeAgentDiffPalette.additionBackground(isDark: appearance.isDark)
    } else if isDeletion {
      lineRow.backgroundColor = VibeAgentDiffPalette.deletionBackground(isDark: appearance.isDark)
    }
    
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = font
    label.numberOfLines = 0
    label.lineBreakMode = .byCharWrapping
    
    if isAddition || isDeletion {
      label.textColor = .white
    } else if line.hasPrefix("@@") {
      label.textColor = appearance.primary
    } else if line.hasPrefix("diff ") || line.hasPrefix("---") || line.hasPrefix("+++")
      || line.hasPrefix("new file") || line.hasPrefix("deleted file")
    {
      label.textColor = faint
    } else {
      label.textColor = appearance.text
    }
    
    label.text = line
    lineRow.addSubview(label)
    
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: lineRow.topAnchor, constant: 4.0),
      label.bottomAnchor.constraint(equalTo: lineRow.bottomAnchor, constant: -4.0),
      label.leadingAnchor.constraint(equalTo: lineRow.leadingAnchor, constant: 16.0),
      label.trailingAnchor.constraint(equalTo: lineRow.trailingAnchor, constant: -16.0),
    ])
    
    stack.addArrangedSubview(lineRow)
  }
  
  return box
}

func resoloAssistantDisplayText(for message: VibeAgentKitChatMessage) -> String {
  let finalText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
  let initialText = message.hasInitialResponseText
    ? message.initialResponseText?.trimmingCharacters(in: .whitespacesAndNewlines)
    : nil

  if message.hasFinalResponseText, !finalText.isEmpty {
    return finalText
  }

  guard let initialText, !initialText.isEmpty else {
    return message.text
  }

  guard !finalText.isEmpty else {
    return initialText
  }

  if finalText.hasPrefix(initialText) {
    return finalText
  }

  return "\(initialText)\n\n\(finalText)"
}

final class VibeAgentKitAttachmentGridView: UIView {
  private var tileControls: [UIControl] = []
  private var tileImageViews: [UIImageView] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) { return nil }

  func reset() {
    tileControls.forEach { $0.removeFromSuperview() }
    tileControls.removeAll()
    tileImageViews.removeAll()
  }

  @discardableResult
  func configure(
    attachments: [VibeAgentKitImageAttachment],
    appearance: VibeAgentKitChatAppearance,
    availableWidth: CGFloat,
    onTap: @escaping (VibeAgentKitImageAttachment) -> Void
  ) -> CGFloat {
    reset()
    let items = Array(attachments.prefix(6))
    guard !items.isEmpty else { return 0.0 }

    let gap: CGFloat = 6.0
    let columns = items.count == 1 ? 1 : min(3, items.count)
    let rawTileWidth = (availableWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
    let tileWidth = items.count == 1 ? min(availableWidth, 230.0) : min(max(62.0, rawTileWidth), 92.0)
    let tileHeight = items.count == 1 ? min(172.0, max(118.0, tileWidth * 0.72)) : tileWidth
    let rows = Int(ceil(Double(items.count) / Double(columns)))
    let totalWidth = tileWidth * CGFloat(columns) + gap * CGFloat(columns - 1)
    let startX = max(0.0, (availableWidth - totalWidth) * 0.5)
    let totalHeight = tileHeight * CGFloat(rows) + gap * CGFloat(rows - 1)

    for (index, attachment) in items.enumerated() {
      let row = index / columns
      let column = index % columns
      let frame = CGRect(
        x: startX + CGFloat(column) * (tileWidth + gap),
        y: CGFloat(row) * (tileHeight + gap),
        width: tileWidth,
        height: tileHeight
      )

      let control = UIControl(frame: frame)
      control.clipsToBounds = true
      control.layer.cornerRadius = items.count == 1 ? 14.0 : 11.0
      control.layer.cornerCurve = .continuous
      control.backgroundColor = vibeAgentKitColorWithAlpha(
        appearance.isDark ? UIColor.white : UIColor.black,
        appearance.isDark ? 0.08 : 0.055
      )
      control.accessibilityLabel = attachment.name ?? "Image attachment"

      let imageView = UIImageView(frame: control.bounds)
      imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      imageView.contentMode = .scaleAspectFill
      imageView.clipsToBounds = true
      control.addSubview(imageView)
      installPlaceholder(in: control, appearance: appearance)

      control.addAction(UIAction { _ in onTap(attachment) }, for: .touchUpInside)
      addSubview(control)
      tileControls.append(control)
      tileImageViews.append(imageView)
      loadImage(for: attachment, into: imageView)
    }

    return totalHeight
  }

  private func installPlaceholder(in control: UIControl, appearance: VibeAgentKitChatAppearance) {
    let icon = UIImageView(
      image: UIImage(systemName: "photo")?.withRenderingMode(.alwaysTemplate)
    )
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.75)
    icon.contentMode = .scaleAspectFit
    icon.tag = 9327
    control.addSubview(icon)
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: control.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: control.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 26.0),
      icon.heightAnchor.constraint(equalToConstant: 26.0),
    ])
  }

  private func loadImage(
    for attachment: VibeAgentKitImageAttachment,
    into imageView: UIImageView
  ) {
    if let image = decodedImage(from: attachment) {
      imageView.superview?.viewWithTag(9327)?.removeFromSuperview()
      imageView.image = image
      return
    }

    guard let source = attachment.sourceURI?.trimmingCharacters(in: .whitespacesAndNewlines),
      !source.isEmpty
    else { return }

    if let cached = ChatAvatarImageStore.cached(for: source) {
      imageView.superview?.viewWithTag(9327)?.removeFromSuperview()
      imageView.image = cached
      return
    }

    Task { [weak imageView] in
      let image = await ChatAvatarImageStore.load(from: source)
      await MainActor.run {
        guard let imageView, let image else { return }
        imageView.superview?.viewWithTag(9327)?.removeFromSuperview()
        imageView.image = image
      }
    }
  }

  static func decodedImage(from attachment: VibeAgentKitImageAttachment) -> UIImage? {
    guard let data = imageData(from: attachment) else { return nil }
    return UIImage(data: data)
  }

  static func imageData(from attachment: VibeAgentKitImageAttachment) -> Data? {
    if let base64 = attachment.dataBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
      !base64.isEmpty
    {
      let payload = base64.components(separatedBy: ",").last ?? base64
      if let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) {
        return data
      }
    }

    guard let source = attachment.sourceURI?.trimmingCharacters(in: .whitespacesAndNewlines),
      !source.isEmpty
    else { return nil }
    if source.hasPrefix("file://"), let url = URL(string: source) {
      return try? Data(contentsOf: url)
    }
    if source.hasPrefix("/") {
      return try? Data(contentsOf: URL(fileURLWithPath: source))
    }
    return nil
  }

  private func decodedImage(from attachment: VibeAgentKitImageAttachment) -> UIImage? {
    Self.decodedImage(from: attachment)
  }
}

final class VibeAgentKitMessageCell: UITableViewCell {
  static let reuseIdentifier = "VibeAgentKitMessageCell"

  private let rowContainer = UIView()
  private let messageContainerView = UIView()
  private let userAttachmentGrid = VibeAgentKitAttachmentGridView()
  private let userTextView = VibeAgentKitStreamingTextLabel()
  private let userExpandButton = UIButton(type: .system)
  // Owns VibeAgentKitAssistantMessageBodyView through the shape-agnostic wrapper so the
  // same renderer can be reused full-width here or bubble-shelled in ChatListCell.
  private let assistantBodyView = VibeAgentTurnContentView()
  private let progressStack = UIStackView()
  private let actionBar = VibeAgentKitMessageActionBarView()

  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var assistantMaxWidthConstraint: NSLayoutConstraint!
  private var assistantWidthConstraint: NSLayoutConstraint!
  private var userMaxWidthConstraint: NSLayoutConstraint!
  private var userAttachmentMinWidthConstraint: NSLayoutConstraint!
  private var userTopConstraint: NSLayoutConstraint!
  private var userLeadingConstraint: NSLayoutConstraint!
  private var userTrailingConstraint: NSLayoutConstraint!
  private var userBottomConstraint: NSLayoutConstraint!
  private var userTextHeightConstraint: NSLayoutConstraint!
  private var userAttachmentTopConstraint: NSLayoutConstraint!
  private var userAttachmentLeadingConstraint: NSLayoutConstraint!
  private var userAttachmentTrailingConstraint: NSLayoutConstraint!
  private var userAttachmentHeightConstraint: NSLayoutConstraint!
  private var userTextTopToAttachmentConstraint: NSLayoutConstraint!
  private var userTextBottomToExpandConstraint: NSLayoutConstraint!
  private var userExpandTrailingConstraint: NSLayoutConstraint!
  private var userExpandBottomConstraint: NSLayoutConstraint!
  private var userExpandHeightConstraint: NSLayoutConstraint!
  private var userExpandWidthConstraint: NSLayoutConstraint!
  private var assistantTopConstraint: NSLayoutConstraint!
  private var assistantLeadingConstraint: NSLayoutConstraint!
  private var assistantTrailingConstraint: NSLayoutConstraint!
  private var assistantBottomConstraint: NSLayoutConstraint!
  private var actionBarHeightConstraint: NSLayoutConstraint!
  private var actionBarTopToProgressConstraint: NSLayoutConstraint!
  private var actionBarTopToMessageConstraint: NSLayoutConstraint!
  private var rowTopConstraint: NSLayoutConstraint!
  private var rowBottomConstraint: NSLayoutConstraint!
  private var currentIsUser = false
  private var storedMessageText: String = ""
  private var previousUserTextExpanded: Bool?
  // A long user message collapses to this height (~5 lines) with a chevron to expand —
  // so a pasted wall of text can't dominate the screen and shove the answer off-screen.
  private let userCollapsedTextMaxHeight: CGFloat = 150.0

  var onAction: ((VibeAgentKitMessageAction) -> Void)? {
    didSet {
      actionBar.onAction = onAction
    }
  }

  var onProgressTap: (() -> Void)?
  var onRuntimeTap: ((ChatListRow.AgentRuntimeSummary) -> Void)?
  var onStepTap: ((String) -> Void)?
  var onOpenSubagent: ((String) -> Void)?
  var onTextExpansionTap: (() -> Void)?
  var onAttachmentTap: ((VibeAgentKitImageAttachment) -> Void)?
  var onToggleRuntimeExpand: (() -> Void)?
  var onReviewTapped: (() -> Void)?
  var onFileTapped: ((ChatListRow.AgentRuntimeFile) -> Void)?

  /// The visible text currently displayed (exposed for the hold context menu).
  var currentMessageText: String { storedMessageText }

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onAction = nil
    transform = .identity
    alpha = 1.0
    userTextView.resetStreamingState()
    userAttachmentGrid.reset()
    assistantBodyView.reset()
    onProgressTap = nil
    onRuntimeTap = nil
    onStepTap = nil
    onOpenSubagent = nil
    onTextExpansionTap = nil
    onAttachmentTap = nil
    assistantBodyView.onStepTap = nil
    assistantBodyView.onOpenSubagent = nil
    progressStack.arrangedSubviews.forEach {
      progressStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    messageContainerView.layer.shadowOpacity = 0.0
    messageContainerView.layer.shadowRadius = 0.0
    messageContainerView.layer.shadowOffset = .zero
    messageContainerView.layer.mask = nil
    currentIsUser = false
    storedMessageText = ""
    previousUserTextExpanded = nil
    userExpandButton.isHidden = true
    userExpandButton.transform = .identity
    userTextView.alpha = 1.0
    userTextView.transform = .identity
    userAttachmentGrid.isHidden = true
    // Restore bubble transform / anchor in case the cell is reused while held
    setBubbleHeld(false, animated: false)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    applyCurrentBubbleShape()
  }
  func configure(
    message: VibeAgentKitChatMessage,
    appearance: VibeAgentKitChatAppearance,
    regeneratePrompt: String,
    showsActions: Bool = true,
    isProgressExpanded: Bool = false,
    expandedStepIds: Set<String> = [],
    isTextExpanded: Bool = false,
    isRuntimeExpanded: Bool = false,
    streamingStartDate: Date? = nil,
    availableWidth: CGFloat? = nil
  ) {
    let isUser = message.role.isUser
    currentIsUser = isUser
    let displayText = isUser ? message.text : resoloAssistantDisplayText(for: message)
    storedMessageText = displayText

    NSLayoutConstraint.deactivate([
      leadingConstraint,
      trailingConstraint,
      assistantMaxWidthConstraint,
      assistantWidthConstraint,
      userMaxWidthConstraint,
      userAttachmentMinWidthConstraint,
      userTopConstraint,
      userLeadingConstraint,
      userTrailingConstraint,
      userBottomConstraint,
      userTextHeightConstraint,
      userAttachmentTopConstraint,
      userAttachmentLeadingConstraint,
      userAttachmentTrailingConstraint,
      userAttachmentHeightConstraint,
      userTextTopToAttachmentConstraint,
      userTextBottomToExpandConstraint,
      userExpandTrailingConstraint,
      userExpandBottomConstraint,
      userExpandHeightConstraint,
      userExpandWidthConstraint,
      assistantTopConstraint,
      assistantLeadingConstraint,
      assistantTrailingConstraint,
      assistantBottomConstraint,
      actionBarTopToProgressConstraint,
      actionBarTopToMessageConstraint,
    ])

    let usesCompactAssistantWidth = !isUser
      && !message.isStreaming
      && message.progressItems.isEmpty
      && message.runtime == nil
      && displayText.count <= 180
      && !displayText.contains("\n\n")

    if isUser {
      NSLayoutConstraint.activate([
        trailingConstraint,
        userMaxWidthConstraint,
        userLeadingConstraint,
        userTrailingConstraint,
        userTextHeightConstraint,
      ])
    } else {
      NSLayoutConstraint.activate([
        leadingConstraint,
        usesCompactAssistantWidth ? assistantMaxWidthConstraint : assistantWidthConstraint,
        assistantTopConstraint,
        assistantLeadingConstraint,
        assistantTrailingConstraint,
        assistantBottomConstraint,
      ])
    }

    rowTopConstraint.constant = isUser ? 4.0 : 3.0
    rowBottomConstraint.constant = isUser ? -4.0 : -3.0

    userTextView.isHidden = !isUser
    userAttachmentGrid.isHidden = true
    userExpandButton.isHidden = true
    assistantBodyView.isHidden = isUser

    progressStack.arrangedSubviews.forEach {
      progressStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }

    let fallbackWidth = window?.bounds.width ?? 390.0

    if isUser {
      let attributed = VibeAgentKitTextRenderer.makeAttributedText(
        text: displayText,
        font: UIFont.systemFont(ofSize: 16.0, weight: .regular),
        textColor: userBubbleTextColor(for: appearance),
        lineHeight: 24.0
      )
      let baseWidth = availableWidth ?? (contentView.bounds.width > 0.0 ? contentView.bounds.width : fallbackWidth)
      let userWidth = max(
        140.0,
        baseWidth * 0.78
      )
      let textWidth = userWidth - 32.0
      let hasText = !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let measured = hasText
        ? VibeAgentKitTextRenderer.measuredSize(for: attributed, width: textWidth)
        : .zero
      let fullTextHeight = hasText
        ? max(ceil(UIFont.systemFont(ofSize: 16.0, weight: .regular).lineHeight), measured.height)
        : 0.0
      let attachmentHeight = userAttachmentGrid.configure(
        attachments: message.attachments,
        appearance: appearance,
        availableWidth: userWidth - 20.0
      ) { [weak self] attachment in
        self?.onAttachmentTap?(attachment)
      }
      let hasAttachments = attachmentHeight > 0.0
      userAttachmentMinWidthConstraint.constant = min(max(150.0, userWidth * 0.64), userWidth)
      let isCollapsible = fullTextHeight > userCollapsedTextMaxHeight + 1.0
      let resolvedTextHeight = isCollapsible && !isTextExpanded
        ? userCollapsedTextMaxHeight
        : fullTextHeight

      userAttachmentGrid.isHidden = !hasAttachments
      userAttachmentHeightConstraint.constant = attachmentHeight
      userTextView.isHidden = !hasText
      userTextHeightConstraint.constant = resolvedTextHeight
      userTextView.clipsToBounds = isCollapsible && !isTextExpanded
      userTextView.applyStreamingText(attributed, rawText: displayText, isStreaming: false)

      var userConstraints: [NSLayoutConstraint] = []
      if hasAttachments {
        userConstraints.append(contentsOf: [
          userAttachmentTopConstraint,
          userAttachmentLeadingConstraint,
          userAttachmentTrailingConstraint,
          userAttachmentHeightConstraint,
          userAttachmentMinWidthConstraint,
          userTextTopToAttachmentConstraint,
        ])
      } else {
        userConstraints.append(userTopConstraint)
      }

      if isCollapsible {
        userExpandButton.isHidden = false
        // A small, light chevron — not the default body-sized glyph, which read as an
        // oversized SVG sitting in the corner of the bubble.
        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
        let previousExpanded = previousUserTextExpanded
        userExpandButton.setImage(
          UIImage(systemName: "chevron.down")?
            .withConfiguration(chevronConfig)
            .withRenderingMode(.alwaysTemplate),
          for: .normal
        )
        let chevronTransform = isTextExpanded
          ? CGAffineTransform(rotationAngle: .pi)
          : .identity
        if let previousExpanded, previousExpanded != isTextExpanded, userExpandButton.window != nil {
          UIView.animate(
            withDuration: 0.2,
            delay: 0.0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
          ) {
            self.userExpandButton.transform = chevronTransform
          }
        } else {
          userExpandButton.transform = chevronTransform
        }
        if let previousExpanded, previousExpanded != isTextExpanded, userTextView.window != nil {
          userTextView.transform = CGAffineTransform(
            translationX: 0.0,
            y: isTextExpanded ? -8.0 : 8.0
          )
          UIView.animate(
            withDuration: 0.22,
            delay: 0.0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
          ) {
            self.userTextView.transform = .identity
          }
        } else {
          userTextView.alpha = 1.0
          userTextView.transform = .identity
        }
        previousUserTextExpanded = isTextExpanded
        userExpandButton.tintColor = vibeAgentKitColorWithAlpha(
          userBubbleTextColor(for: appearance),
          appearance.isDark ? 0.72 : 0.58
        )
        userConstraints.append(contentsOf: [
          userTextBottomToExpandConstraint,
          userExpandTrailingConstraint,
          userExpandBottomConstraint,
          userExpandHeightConstraint,
          userExpandWidthConstraint,
        ])
      } else {
        previousUserTextExpanded = nil
        userExpandButton.transform = .identity
        userTextView.alpha = 1.0
        userTextView.transform = .identity
        userConstraints.append(userBottomConstraint)
      }
      NSLayoutConstraint.activate(userConstraints)

      messageContainerView.backgroundColor = userBubbleColor(for: appearance)
      messageContainerView.layer.cornerRadius = 20.0
      messageContainerView.layer.cornerCurve = .continuous
      messageContainerView.layer.maskedCorners = [
        .layerMaxXMinYCorner,
        .layerMinXMinYCorner,
        .layerMinXMaxYCorner,
        .layerMaxXMaxYCorner,
      ]
      messageContainerView.layer.borderWidth = 0.0
      messageContainerView.layer.borderColor = UIColor.clear.cgColor
      messageContainerView.layer.shadowOpacity = 0.0
      messageContainerView.layer.shadowRadius = 0.0
      messageContainerView.layer.shadowOffset = .zero
    } else {
      let baseWidth = availableWidth ?? (contentView.bounds.width > 0.0 ? contentView.bounds.width : fallbackWidth)
      let assistantAvailableWidth = max(
        160.0,
        (baseWidth - 64.0) * 0.92
      )
      assistantBodyView.isHidden = false
      assistantBodyView.onStepTap = onStepTap
      assistantBodyView.onOpenSubagent = onOpenSubagent
      assistantBodyView.onToggleRuntimeExpand = onToggleRuntimeExpand
      assistantBodyView.onReviewTapped = onReviewTapped
      assistantBodyView.onFileTapped = onFileTapped
      assistantBodyView.configure(
        text: displayText,
        isStreaming: message.isStreaming,
        hasFinalResponseText: message.hasFinalResponseText,
        appearance: appearance,
        availableWidth: assistantAvailableWidth,
        messageId: message.id,
        progressItems: message.progressItems,
        subagentChildren: message.subagentChildren,
        fallbackProgressLabels: message.progress,
        runtime: message.runtime,
        onLoaderTap: onProgressTap,
        isProgressExpanded: isProgressExpanded,
        isRuntimeExpanded: isRuntimeExpanded,
        expandedStepIds: expandedStepIds,
        streamingStartDate: streamingStartDate
      )

      messageContainerView.backgroundColor = .clear
      messageContainerView.layer.cornerRadius = 0.0
      messageContainerView.layer.borderWidth = 0.0
      messageContainerView.layer.borderColor = UIColor.clear.cgColor
      messageContainerView.layer.shadowOpacity = 0.0
      messageContainerView.layer.shadowRadius = 0.0
      messageContainerView.layer.shadowOffset = .zero
    }

    let visibleProgress: ArraySlice<String> =
      (!displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.isStreaming)
      ? []
      : message.progress.suffix(3)
    for item in visibleProgress where !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let label = UILabel()
      label.font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
      label.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.82)
      label.numberOfLines = 0
      label.text = item
      progressStack.addArrangedSubview(label)
    }
    let showsVisibleProgress = !isUser && !visibleProgress.isEmpty && !message.isStreaming
    progressStack.isHidden = !showsVisibleProgress
    NSLayoutConstraint.activate([
      showsVisibleProgress ? actionBarTopToProgressConstraint : actionBarTopToMessageConstraint
    ])

    let hasSourceText = !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let canRegenerate = !regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let shouldShowActions =
      !isUser
      && showsActions
      && !message.isStreaming
      && !message.isError
      && (hasSourceText || canRegenerate)
    actionBar.configure(
      appearance: appearance,
      hasSourceText: hasSourceText,
      canRegenerate: canRegenerate
    )
    actionBarHeightConstraint.constant = shouldShowActions ? 26.0 : 0.0
    actionBar.isHidden = !shouldShowActions
    setNeedsLayout()
  }

  private func setup() {
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    selectionStyle = .none

    [
      rowContainer,
      messageContainerView,
      userAttachmentGrid,
      userTextView,
      userExpandButton,
      assistantBodyView,
      progressStack,
      actionBar,
    ]
      .forEach {
        $0.translatesAutoresizingMaskIntoConstraints = false
      }

    contentView.addSubview(rowContainer)
    rowContainer.addSubview(messageContainerView)
    rowContainer.addSubview(progressStack)
    rowContainer.addSubview(actionBar)
    messageContainerView.addSubview(userAttachmentGrid)
    messageContainerView.addSubview(userTextView)
    messageContainerView.addSubview(userExpandButton)
    messageContainerView.addSubview(assistantBodyView)

    progressStack.axis = .vertical
    progressStack.spacing = 3.0
    progressStack.alignment = .leading

    userExpandButton.backgroundColor = .clear
    userExpandButton.contentHorizontalAlignment = .center
    userExpandButton.contentVerticalAlignment = .center
    userExpandButton.addTarget(self, action: #selector(userExpandTapped), for: .touchUpInside)

    rowTopConstraint = rowContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6.0)
    rowBottomConstraint = rowContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6.0)
    leadingConstraint = messageContainerView.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: 4.0)
    trailingConstraint = messageContainerView.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor, constant: -4.0)
    assistantMaxWidthConstraint = messageContainerView.widthAnchor.constraint(
      lessThanOrEqualTo: rowContainer.widthAnchor,
      multiplier: 0.85
    )
    assistantWidthConstraint = messageContainerView.widthAnchor.constraint(
      equalTo: rowContainer.widthAnchor,
      multiplier: 0.85
    )
    userMaxWidthConstraint = messageContainerView.widthAnchor.constraint(
      lessThanOrEqualTo: rowContainer.widthAnchor,
      multiplier: 0.78
    )
    userAttachmentMinWidthConstraint = messageContainerView.widthAnchor.constraint(
      greaterThanOrEqualToConstant: 150.0
    )
    userAttachmentMinWidthConstraint.priority = .defaultHigh

    userTopConstraint = userTextView.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: 14.0)
    userLeadingConstraint = userTextView.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 16.0)
    userTrailingConstraint = userTextView.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor, constant: -16.0)
    userBottomConstraint = userTextView.bottomAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: -14.0)
    userTextHeightConstraint = userTextView.heightAnchor.constraint(equalToConstant: 24.0)
    userAttachmentTopConstraint = userAttachmentGrid.topAnchor.constraint(
      equalTo: messageContainerView.topAnchor, constant: 10.0)
    userAttachmentLeadingConstraint = userAttachmentGrid.leadingAnchor.constraint(
      equalTo: messageContainerView.leadingAnchor, constant: 10.0)
    userAttachmentTrailingConstraint = userAttachmentGrid.trailingAnchor.constraint(
      equalTo: messageContainerView.trailingAnchor, constant: -10.0)
    userAttachmentHeightConstraint = userAttachmentGrid.heightAnchor.constraint(equalToConstant: 0.0)
    userTextTopToAttachmentConstraint = userTextView.topAnchor.constraint(
      equalTo: userAttachmentGrid.bottomAnchor, constant: 8.0)
    userTextBottomToExpandConstraint = userTextView.bottomAnchor.constraint(
      equalTo: userExpandButton.topAnchor, constant: -4.0)
    userExpandTrailingConstraint = userExpandButton.trailingAnchor.constraint(
      equalTo: messageContainerView.trailingAnchor, constant: -10.0)
    userExpandBottomConstraint = userExpandButton.bottomAnchor.constraint(
      equalTo: messageContainerView.bottomAnchor, constant: -7.0)
    userExpandHeightConstraint = userExpandButton.heightAnchor.constraint(equalToConstant: 26.0)
    userExpandWidthConstraint = userExpandButton.widthAnchor.constraint(equalToConstant: 42.0)

    assistantTopConstraint = assistantBodyView.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: 4.0)
    assistantLeadingConstraint = assistantBodyView.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 8.0)
    assistantTrailingConstraint = assistantBodyView.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor, constant: -8.0)
    assistantBottomConstraint = assistantBodyView.bottomAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: -4.0)

    userTextHeightConstraint.priority = .defaultHigh
    userAttachmentHeightConstraint.priority = .defaultHigh
    actionBarHeightConstraint = actionBar.heightAnchor.constraint(equalToConstant: 0.0)
    actionBarHeightConstraint.priority = .defaultHigh
    actionBarTopToProgressConstraint = actionBar.topAnchor.constraint(equalTo: progressStack.bottomAnchor, constant: 4.0)
    actionBarTopToMessageConstraint = actionBar.topAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: 6.0)

    NSLayoutConstraint.activate([
      rowTopConstraint,
      rowContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8.0),
      rowContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8.0),
      rowBottomConstraint,

      messageContainerView.topAnchor.constraint(equalTo: rowContainer.topAnchor),
      userTextHeightConstraint,
      actionBarHeightConstraint,

      progressStack.topAnchor.constraint(equalTo: messageContainerView.bottomAnchor, constant: 4.0),
      progressStack.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor),
      progressStack.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor),

      actionBar.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 1.0),
      actionBar.trailingAnchor.constraint(lessThanOrEqualTo: messageContainerView.trailingAnchor),
      actionBar.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
    ])

    leadingConstraint.isActive = true
    assistantWidthConstraint.isActive = true
    assistantTopConstraint.isActive = true
    assistantLeadingConstraint.isActive = true
    assistantTrailingConstraint.isActive = true
    assistantBottomConstraint.isActive = true
    actionBarTopToMessageConstraint.isActive = true
  }

  private func userBubbleColor(for appearance: VibeAgentKitChatAppearance) -> UIColor {
    appearance.userBubbleBackground
  }

  private func userBubbleTextColor(for appearance: VibeAgentKitChatAppearance) -> UIColor {
    appearance.userBubbleText
  }


  private func applyCurrentBubbleShape() {
    if currentIsUser {
      messageContainerView.layer.cornerRadius = 20.0
      messageContainerView.layer.cornerCurve = .continuous
      messageContainerView.layer.maskedCorners = [
        .layerMaxXMinYCorner,
        .layerMinXMinYCorner,
        .layerMinXMaxYCorner,
        .layerMaxXMaxYCorner,
      ]
      messageContainerView.layer.mask = nil
    } else {
      messageContainerView.layer.mask = nil
    }
  }

  // MARK: - Bubble hold / long-press transform (Vibe-style)

  /// Applies a scale-down transform to the bubble container when the user long-presses,
  /// pivoted from the bubble's centre so the bubble doesn't drift.
  func setBubbleHeld(_ held: Bool, animated: Bool) {
    let targetScale: CGFloat = held ? 0.965 : 1.0
    let targetTransform: CGAffineTransform =
      held ? CGAffineTransform(scaleX: targetScale, y: targetScale) : .identity

    // Pivot the scale around the bubble's own centre within contentView
    if held {
      let bubbleCenter = messageContainerView.center
      let parentBounds = messageContainerView.superview?.bounds ?? contentView.bounds
      let anchorX = max(0.0, min(1.0, bubbleCenter.x / max(1.0, parentBounds.width)))
      let anchorY = max(0.0, min(1.0, bubbleCenter.y / max(1.0, parentBounds.height)))
      setAnchorPoint(CGPoint(x: anchorX, y: anchorY), for: messageContainerView)
    }

    if animated {
      if held {
        UIView.animate(
          withDuration: 0.18,
          delay: 0.0,
          options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
          self.messageContainerView.transform = targetTransform
        }
      } else {
        UIView.animate(
          withDuration: 0.24,
          delay: 0.0,
          usingSpringWithDamping: 0.90,
          initialSpringVelocity: 0.0,
          options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
          self.messageContainerView.transform = targetTransform
        } completion: { _ in
          self.setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: self.messageContainerView)
        }
      }
    } else {
      messageContainerView.transform = targetTransform
      if !held {
        setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: messageContainerView)
      }
    }
  }

  /// Returns the frame of the bubble container in the cell's own coordinate space.
  func bubbleFrameInSelf() -> CGRect {
    messageContainerView.convert(messageContainerView.bounds, to: self)
  }

  /// A targeted preview of just the rounded bubble, so the hold menu's system lift
  /// ("mold" effect) raises the clean bubble shape on a clear platter rather than the
  /// whole row (which includes the action bar / progress).
  func bubblePreview() -> UITargetedPreview {
    let params = UIPreviewParameters()
    params.backgroundColor = .clear
    let radius = currentIsUser ? messageContainerView.layer.cornerRadius : 12.0
    params.visiblePath = UIBezierPath(
      roundedRect: messageContainerView.bounds,
      cornerRadius: radius
    )
    return UITargetedPreview(view: messageContainerView, parameters: params)
  }

  @objc private func userExpandTapped() {
    onTextExpansionTap?()
  }

  // MARK: - Private helpers

  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldOrigin = view.frame.origin
    view.layer.anchorPoint = anchorPoint
    let newOrigin = view.frame.origin
    let delta = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)
    view.center = CGPoint(x: view.center.x - delta.x, y: view.center.y - delta.y)
  }
}

// Centered muted system row. /compact rows can expand to reveal the kept summary;
// status rows such as interruptions render as a non-expandable divider.
final class VibeAgentKitCompactionCell: UITableViewCell {
  static let reuseIdentifier = "VibeAgentKitCompactionCell"

  private let headerControl = UIControl()
  private let leftRule = UIView()
  private let rightRule = UIView()
  private let pill = UIView()
  private let pillIcon = UIImageView()
  private let pillLabel = UILabel()
  private let chevron = UIImageView()
  private let summaryLabel = UILabel()
  private var summaryTopConstraint: NSLayoutConstraint!
  private var isExpandedState = false

  var onToggle: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    setup()
  }

  required init?(coder: NSCoder) { return nil }

  override func prepareForReuse() {
    super.prepareForReuse()
    onToggle = nil
    isExpandedState = false
    chevron.transform = .identity
  }

  private func setup() {
    backgroundColor = .clear
    selectionStyle = .none
    contentView.backgroundColor = .clear

    headerControl.translatesAutoresizingMaskIntoConstraints = false
    headerControl.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
    contentView.addSubview(headerControl)

    leftRule.translatesAutoresizingMaskIntoConstraints = false
    rightRule.translatesAutoresizingMaskIntoConstraints = false
    headerControl.addSubview(leftRule)
    headerControl.addSubview(rightRule)

    pill.translatesAutoresizingMaskIntoConstraints = false
    pill.backgroundColor = .clear
    pill.isUserInteractionEnabled = false
    headerControl.addSubview(pill)

    pillIcon.translatesAutoresizingMaskIntoConstraints = false
    pillIcon.contentMode = .scaleAspectFit
    pillIcon.isHidden = true
    pill.addSubview(pillIcon)

    pillLabel.translatesAutoresizingMaskIntoConstraints = false
    pillLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    pill.addSubview(pillLabel)

    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.contentMode = .scaleAspectFit
    pill.addSubview(chevron)

    summaryLabel.translatesAutoresizingMaskIntoConstraints = false
    summaryLabel.numberOfLines = 0
    summaryLabel.backgroundColor = .clear
    contentView.addSubview(summaryLabel)

    summaryTopConstraint = summaryLabel.topAnchor.constraint(
      equalTo: headerControl.bottomAnchor, constant: 0.0)

    NSLayoutConstraint.activate([
      headerControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10.0),
      headerControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8.0),
      headerControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8.0),
      headerControl.heightAnchor.constraint(equalToConstant: 24.0),

      pill.centerXAnchor.constraint(equalTo: headerControl.centerXAnchor),
      pill.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
      pill.heightAnchor.constraint(equalToConstant: 24.0),

      pillIcon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10.0),
      pillIcon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
      pillIcon.widthAnchor.constraint(equalToConstant: 12.0),
      pillIcon.heightAnchor.constraint(equalToConstant: 12.0),

      pillLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8.0),
      pillLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

      chevron.leadingAnchor.constraint(equalTo: pillLabel.trailingAnchor, constant: 6.0),
      chevron.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10.0),
      chevron.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
      chevron.widthAnchor.constraint(equalToConstant: 10.0),
      chevron.heightAnchor.constraint(equalToConstant: 10.0),

      leftRule.leadingAnchor.constraint(equalTo: headerControl.leadingAnchor),
      leftRule.trailingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -10.0),
      leftRule.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
      leftRule.heightAnchor.constraint(equalToConstant: 1.0),

      rightRule.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 10.0),
      rightRule.trailingAnchor.constraint(equalTo: headerControl.trailingAnchor),
      rightRule.centerYAnchor.constraint(equalTo: headerControl.centerYAnchor),
      rightRule.heightAnchor.constraint(equalToConstant: 1.0),

      summaryTopConstraint,
      summaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8.0),
      summaryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8.0),
      summaryLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10.0),
    ])
  }

  func configure(
    text: String,
    title: String = "Context compacted",
    expanded: Bool,
    canExpand: Bool = true,
    appearance: VibeAgentKitChatAppearance
  ) {
    let ruleColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.22)
    leftRule.backgroundColor = ruleColor
    rightRule.backgroundColor = ruleColor
    pill.backgroundColor = .clear
    pillIcon.isHidden = true
    pillLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.95)
    pillLabel.text = canExpand && expanded ? "Hide summary" : title
    // One chevron that rotates (down when collapsed, up when expanded) so the toggle
    // direction reads clearly and animates rather than snapping between two glyphs.
    chevron.image = UIImage(systemName: "chevron.down")?.withRenderingMode(.alwaysTemplate)
    chevron.tintColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)
    chevron.isHidden = !canExpand
    headerControl.isUserInteractionEnabled = canExpand
    let rotation = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
    if expanded != isExpandedState {
      UIView.animate(withDuration: 0.22, delay: 0.0, options: [.beginFromCurrentState]) {
        self.chevron.transform = rotation
      }
    } else {
      chevron.transform = rotation
    }
    isExpandedState = expanded

    if canExpand, expanded, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      summaryLabel.isHidden = false
      summaryLabel.attributedText = VibeAgentKitTextRenderer.makeAttributedText(
        text: text,
        font: UIFont.systemFont(ofSize: 14.5, weight: .regular),
        textColor: vibeAgentKitColorWithAlpha(appearance.text, 0.78),
        lineHeight: 21.0
      )
      summaryTopConstraint.constant = 12.0
    } else {
      summaryLabel.isHidden = true
      summaryLabel.attributedText = nil
      summaryTopConstraint.constant = 0.0
    }
  }
}

// MARK: - Step detail sheet

/// Full detail for ONE tool step, shown in a bottom sheet when its card is tapped (the
/// step list itself stays put — no inline unfolding). Renders per-kind: bash → the full
/// command box + a success/failure-tinted result box; edit/write → the file name + the
/// unified-diff patch (green/red); read → the line range + the file slice; everything
/// else → its output. Generous vertical spacing keeps the command and the terminal
/// output as clearly separated blocks.
final class VibeAgentKitStepDetailViewController: UIViewController {
  private let item: VibeAgentKitProgressItem
  private let appearance: VibeAgentKitChatAppearance
  private let scrollView = UIScrollView()
  private let stack = UIStackView()

  init(item: VibeAgentKitProgressItem, appearance: VibeAgentKitChatAppearance) {
    self.item = item
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    let kind = (item.itemType ?? item.tool ?? "").lowercased()
    navigationItem.title = stepTitle(kind: kind)
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
    navigationItem.leftBarButtonItem?.tintColor = appearance.text

    let navBarAppearance = UINavigationBarAppearance()
    navBarAppearance.configureWithTransparentBackground()
    navigationController?.navigationBar.standardAppearance = navBarAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navBarAppearance
    navigationController?.navigationBar.compactAppearance = navBarAppearance

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.backgroundColor = .clear
    view.addSubview(scrollView)

    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    // Wide gaps so the command block and the terminal-output block read as distinct,
    // un-cramped sections (the padding the previous inline layout was missing).
    stack.spacing = 18.0
    scrollView.addSubview(stack)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20.0),
      stack.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28.0),
      stack.leadingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 8.0),
      stack.trailingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -8.0),
    ])

    buildContent(kind: kind)
  }

  @objc private func closeTapped() { dismiss(animated: true) }

  private func stepTitle(kind: String) -> String {
    switch kind {
    case "bash": return "Shell"
    case "edit", "write": return item.fileName ?? "Edit"
    case "read": return item.fileName ?? "Read"
    case "thinking": return "Thinking"
    case "compacting": return "Compacting"
    case "mcp":
      if let tool = item.fileName, !tool.isEmpty {
        return chatAgentPrettyMcpLabel("MCP · \(tool)")
      }
      return item.label.isEmpty ? "MCP tool" : chatAgentPrettyMcpLabel(item.label)
    case "tool": return item.label.isEmpty ? "Tool" : item.label
    default: return item.label.isEmpty ? "Step" : item.label
    }
  }

  private func buildContent(kind: String) {
    let isError = ["error", "failed", "failure"].contains((item.status ?? "").lowercased())

    // A label header so the sheet always names what ran, even for non-bash steps.
    if kind != "bash", !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      stack.addArrangedSubview(sectionLabel(item.label, weight: .semibold, size: 16.0))
    }

    // No verdict before the result arrives (see the step-row terminal card). The
    // bridge marks result-less tools "running"; a finished step with genuinely
    // empty output still reads Success.
    let isRunning = vibeAgentKitRunningStepStatuses.contains((item.status ?? "").lowercased())
    switch kind {
    case "bash":
      stack.addArrangedSubview(caption("Shell", appearance.textSecondary))
      stack.addArrangedSubview(
        terminalCard(
          command: item.command, output: item.messageContent, isError: isError,
          pending: isRunning))

    case "edit", "write":
      if let name = item.fileName, !name.isEmpty {
        stack.addArrangedSubview(caption(name, appearance.textSecondary))
      }
      if let patch = item.patch, !patch.isEmpty {
        stack.addArrangedSubview(monoBox(patch, isPatch: true))
      } else {
        stack.addArrangedSubview(
          caption("No diff available.", vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)))
      }

    case "read":
      if let start = item.lineStart {
        let range = item.lineEnd.map { "Lines \(start)–\($0)" } ?? "From line \(start)"
        stack.addArrangedSubview(caption(range, appearance.textSecondary))
      }
      if let content = item.fileContent, !content.isEmpty {
        stack.addArrangedSubview(monoBox(content))
      } else {
        stack.addArrangedSubview(
          caption("No file slice available.", vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)))
      }

    case "todo", "planning":
      if let todos = item.todos, !todos.isEmpty {
        stack.addArrangedSubview(todoListCard(todos: todos))
      } else if let output = item.messageContent, !output.isEmpty {
        stack.addArrangedSubview(monoBox(output))
      } else {
        stack.addArrangedSubview(
          caption("No planning details available.", vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)))
      }

    default:
      if let output = item.messageContent, !output.isEmpty {
        stack.addArrangedSubview(monoBox(output))
      } else {
        stack.addArrangedSubview(
          caption("Nothing more to show for this step.",
            vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)))
      }
    }
  }

  private func todoListCard(todos: [VibeAgentKitTodoItem]) -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.backgroundColor = .clear
    
    let listStack = UIStackView()
    listStack.translatesAutoresizingMaskIntoConstraints = false
    listStack.axis = .vertical
    listStack.spacing = 14.0
    container.addSubview(listStack)
    
    NSLayoutConstraint.activate([
      listStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 0.0),
      listStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 0.0),
      listStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0.0),
      listStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 0.0),
    ])
    
    for todo in todos {
      let row = UIStackView()
      row.axis = .horizontal
      row.spacing = 12.0
      row.alignment = .top
      
      let iconView = UIImageView()
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.contentMode = .scaleAspectFit
      
      let status = todo.status.lowercased()
      let isCompleted = status == "completed" || status == "done" || status == "success"
      let isInProgress = status == "in_progress" || status == "in-progress" || status == "running" || status == "active"
      
      if isCompleted {
        iconView.image = UIImage(systemName: "checkmark.circle.fill")
        iconView.tintColor = UIColor.systemGreen
      } else if isInProgress {
        iconView.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        iconView.tintColor = appearance.primary
        
        let rotation = CABasicAnimation(keyPath: "transform.rotation")
        rotation.fromValue = 0
        rotation.toValue = Float.pi * 2
        rotation.duration = 1.5
        rotation.repeatCount = .infinity
        iconView.layer.add(rotation, forKey: "rotate")
      } else {
        iconView.image = UIImage(systemName: "circle")
        iconView.tintColor = appearance.textTertiary
      }
      
      NSLayoutConstraint.activate([
        iconView.widthAnchor.constraint(equalToConstant: 18.0),
        iconView.heightAnchor.constraint(equalToConstant: 18.0)
      ])
      
      row.addArrangedSubview(iconView)
      
      let textStack = UIStackView()
      textStack.axis = .vertical
      textStack.spacing = 4.0
      
      let font = UIFont.systemFont(ofSize: 14.5, weight: isCompleted ? .regular : (isInProgress ? .semibold : .medium))
      
      if isCompleted {
        let titleLabel = UILabel()
        titleLabel.numberOfLines = 0
        titleLabel.font = font
        titleLabel.textColor = appearance.textTertiary
        let attributeString = NSMutableAttributedString(string: todo.content)
        attributeString.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSMakeRange(0, attributeString.length))
        titleLabel.attributedText = attributeString
        textStack.addArrangedSubview(titleLabel)
      } else if isInProgress {
        let isDark = appearance.isDark
        let baseColor: UIColor = isDark ? UIColor.white.withAlphaComponent(0.4) : UIColor.black.withAlphaComponent(0.3)
        let shimmerColor: UIColor = isDark ? .white : .black
        let shimmerView = VibeTodoShimmerLabel(
          text: todo.content,
          font: font,
          baseColor: baseColor,
          shimmerColor: shimmerColor
        )
        textStack.addArrangedSubview(shimmerView)
      } else {
        let titleLabel = UILabel()
        titleLabel.numberOfLines = 0
        titleLabel.font = font
        titleLabel.textColor = appearance.text
        titleLabel.text = todo.content
        textStack.addArrangedSubview(titleLabel)
      }
      
      if let activeForm = todo.activeForm, !activeForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let formLabel = UILabel()
        formLabel.numberOfLines = 0
        formLabel.font = UIFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
        formLabel.textColor = appearance.textSecondary
        formLabel.text = activeForm
        
        textStack.addArrangedSubview(formLabel)
      }
      
      row.addArrangedSubview(textStack)
      listStack.addArrangedSubview(row)
    }
    
    return container
  }

  private func sectionLabel(_ text: String, weight: UIFont.Weight, size: CGFloat) -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = UIFont.systemFont(ofSize: size, weight: weight)
    label.textColor = appearance.text
    label.text = text
    return label
  }

  private func caption(_ text: String, _ color: UIColor) -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    label.textColor = color
    label.text = text
    return label
  }

  /// One terminal-style card: the `$ command`, its output, and a right-aligned
  /// ✓ Success / ✕ Failed result — the shell-result look.
  private func terminalCard(command: String?, output: String?, isError: Bool, pending: Bool = false) -> UIView {
    let dark = appearance.isDark
    let card = UIView()
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = vibeAgentKitColorWithAlpha(
      dark ? UIColor.white : UIColor.black, dark ? 0.06 : 0.045)
    card.layer.cornerRadius = 14.0
    card.layer.cornerCurve = .continuous

    let inner = UIStackView()
    inner.translatesAutoresizingMaskIntoConstraints = false
    inner.axis = .vertical
    inner.alignment = .fill
    inner.spacing = 12.0
    card.addSubview(inner)

    let mono = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
    let monoBold = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .semibold)
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byCharWrapping
    para.lineSpacing = 2.0

    if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 0
      label.lineBreakMode = .byCharWrapping
      let line = NSMutableAttributedString(
        string: "$ ",
        attributes: [
          .font: monoBold,
          .foregroundColor: vibeAgentKitColorWithAlpha(appearance.primary, 0.9),
          .paragraphStyle: para,
        ])
      line.append(
        NSAttributedString(
          string: command,
          attributes: [.font: monoBold, .foregroundColor: appearance.text, .paragraphStyle: para]))
      label.attributedText = line
      inner.addArrangedSubview(label)
    }

    if let output, !output.isEmpty {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 0
      label.lineBreakMode = .byCharWrapping
      label.attributedText = NSAttributedString(
        string: output,
        attributes: [
          .font: mono,
          .foregroundColor: vibeAgentKitColorWithAlpha(appearance.text, 0.82),
          .paragraphStyle: para,
        ])
      inner.addArrangedSubview(label)
    }

    let status = UILabel()
    status.translatesAutoresizingMaskIntoConstraints = false
    status.font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
    if pending {
      status.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.8)
      status.text = "Running…"
    } else {
      status.textColor = isError ? VibeAgentDiffPalette.deletionText : VibeAgentDiffPalette.additionText
      status.text = isError ? "✕ Failed" : "✓ Success"
    }
    status.textAlignment = .right
    inner.addArrangedSubview(status)

    NSLayoutConstraint.activate([
      inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14.0),
      inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14.0),
      inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14.0),
      inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14.0),
    ])
    return card
  }

  /// A padded monospace box. `isPatch` colours +/− diff lines green/red.
  private func monoBox(_ text: String, accent: UIColor? = nil, isPatch: Bool = false) -> UIView {
    let font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    if isPatch {
      return diffLayoutView(patch: text, appearance: appearance, font: font)
    }
    
    let box = UIView()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.backgroundColor = vibeAgentKitColorWithAlpha(
      appearance.isDark ? UIColor.white : UIColor.black, appearance.isDark ? 0.05 : 0.04)
    box.layer.cornerRadius = 10.0
    box.layer.cornerCurve = .continuous
    if let accent {
      box.layer.borderWidth = 1.0
      box.layer.borderColor = vibeAgentKitColorWithAlpha(accent, 0.45).cgColor
    }
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 0
    label.lineBreakMode = .byCharWrapping
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byCharWrapping
    para.lineSpacing = 1.5
    label.attributedText = NSAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: appearance.text, .paragraphStyle: para])
    box.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: box.topAnchor, constant: 12.0),
      label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12.0),
      label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12.0),
      label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12.0),
    ])
    return box
  }
}

private final class VibeTodoShimmerLabel: UIView {
  let baseLabel = UILabel()
  let shimmerLabel = UILabel()
  let gradientLayer = CAGradientLayer()

  init(text: String, font: UIFont, baseColor: UIColor, shimmerColor: UIColor) {
    super.init(frame: .zero)
    self.translatesAutoresizingMaskIntoConstraints = false

    baseLabel.numberOfLines = 0
    baseLabel.font = font
    baseLabel.textColor = baseColor
    baseLabel.text = text
    baseLabel.translatesAutoresizingMaskIntoConstraints = false

    shimmerLabel.numberOfLines = 0
    shimmerLabel.font = font
    shimmerLabel.textColor = shimmerColor
    shimmerLabel.text = text
    shimmerLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(baseLabel)
    addSubview(shimmerLabel)

    NSLayoutConstraint.activate([
      baseLabel.topAnchor.constraint(equalTo: topAnchor),
      baseLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      baseLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      baseLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

      shimmerLabel.topAnchor.constraint(equalTo: topAnchor),
      shimmerLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      shimmerLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      shimmerLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
    gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
    gradientLayer.locations = [0.0, 0.3, 0.5, 0.7, 1.0]
    gradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.white.withAlphaComponent(0.4).cgColor,
      UIColor.white.cgColor,
      UIColor.white.withAlphaComponent(0.4).cgColor,
      UIColor.clear.cgColor,
    ]
    shimmerLabel.layer.mask = gradientLayer
  }

  required init?(coder: NSCoder) { return nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = max(bounds.width, 200.0)
    gradientLayer.frame = CGRect(x: -w, y: 0, width: w * 3, height: bounds.height)
    if gradientLayer.animation(forKey: "shimmer") == nil {
      startShimmer()
    }
  }

  func startShimmer() {
    let w = max(bounds.width, 200.0)
    let anim = CABasicAnimation(keyPath: "transform.translation.x")
    anim.fromValue = 0
    anim.toValue = w * 2
    anim.duration = 2.0
    anim.repeatCount = .infinity
    gradientLayer.add(anim, forKey: "shimmer")
  }
}
