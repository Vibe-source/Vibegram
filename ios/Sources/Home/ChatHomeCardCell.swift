import UIKit

protocol ChatHomeCardCellSwipeDelegate: AnyObject {
  func homeCardCellDidBeginSwipe(_ cell: ChatHomeCardCell)
  func homeCardCellDidCloseSwipe(_ cell: ChatHomeCardCell)
  func homeCardCell(
    _ cell: ChatHomeCardCell,
    didTriggerSwipeEvent eventType: String,
    chatId: String
  )
}

final class ChatHomeCardCell: UITableViewCell {
  static let reuseIdentifier = "ChatHomeCardCell"

  static func avatarCached(forKey key: String) -> UIImage? {
    ChatAvatarImageStore.cached(for: key)
  }

  static func cacheAvatar(_ image: UIImage, forKey key: String) {
    ChatAvatarImageStore.cache(image, for: key)
  }

  /// Whether the last bridge-status snapshot reports a task actively running for `chatId`.
  /// Only exact chatId matches count. Provider-wide / empty-chatId desktop tasks used
  /// to paint every DM for that provider as "Working…" after sessions settled — false
  /// positive. Desktop-only runs still surface via live `agentProgress` once the chat
  /// channel is joined.
  static func hasRunningBridgeTask(chatId: String, provider: String?) -> Bool {
    let key = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return false }
    return (AgentPairingService.lastStatusSnapshot?.runningTasks ?? [])
      .contains { task in
        let taskChat = task.chatId.trimmingCharacters(in: .whitespacesAndNewlines)
        return taskChat == key
      }
  }

  static func getFallbackInitials(from name: String) -> String {
    ChatAvatarNodeView.fallbackInitials(from: name)
  }

  private let pressOverlayView = UIView()
  private let selectionOverlayView = UIView()
  private let dividerView = UIView()
  private let leadingActionsContainer = UIView()
  private let trailingActionsContainer = UIView()
  private let leadingActionsMaskLayer = CALayer()
  private let trailingActionsMaskLayer = CALayer()
  private let leadingFullSwipeView = ChatHomeSwipeActionTileView(frame: .zero)
  private let trailingFullSwipeView = ChatHomeSwipeActionTileView(frame: .zero)
  private let rowContentContainer = UIView()
  private let editSelectionContainer = UIView()
  private let avatarNode = ChatAvatarNodeView()
  private let editSelectionBackgroundView = UIView()
  private let editSelectionCheckView = UIImageView()
  private let onlineDot = UIView()

  private let titleLabel = UILabel()
  private let tierBadgeImageView = UIImageView()
  private let previewLabel = UILabel()
  private let reactionPreviewLabel = UILabel()
  private let timeLabel = UILabel()
  private let receiptStatusView = UIImageView()
  private let unreadBadge = UIView()
  private let unreadLabel = UILabel()
  private let muteIconView = UIImageView()
  private let pinIconView = UIImageView()
  private let rightCheckmarkView = UIImageView()

  private var rowContentLeadingConstraint: NSLayoutConstraint?
  private var avatarWidthConstraint: NSLayoutConstraint?
  private var avatarHeightConstraint: NSLayoutConstraint?
  private var receiptStatusWidthConstraint: NSLayoutConstraint?
  private var currentEditingLayout = false
  private var compactForwardStyle = false
  private var renderedReceiptStatus: String?
  private lazy var swipePanGestureRecognizer: UIPanGestureRecognizer = {
    let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
    gesture.delegate = self
    gesture.cancelsTouchesInView = true
    return gesture
  }()
  private var currentRow: ChatHomeListRow?
  private var lastBridgePreviewSignature: String?
  private var manualSwipeActionsEnabled = true
  private var isSwipeEnabled = true
  private var swipeOffset: CGFloat = 0
  private var swipeStartOffset: CGFloat = 0
  private var hasCommittedSwipeGesture = false
  private var isPerformingSwipeAction = false
  private var didEmitLargeSwipeHaptic = false
  private var suppressesPressOverlay = false
  private var swipeSurfaceColor = UIColor.clear
  private var leadingDisplaySpecs: [ChatHomeSwipeActionSpec] = []
  private var trailingDisplaySpecs: [ChatHomeSwipeActionSpec] = []
  private var leadingActionButtons: [ChatHomeSwipeActionButton] = []
  private var trailingActionButtons: [ChatHomeSwipeActionButton] = []
  private var leadingFullSwipeSpec: ChatHomeSwipeActionSpec?
  private var trailingFullSwipeSpec: ChatHomeSwipeActionSpec?
  private let largeSwipeHapticGenerator = UIImpactFeedbackGenerator(style: .medium)

  weak var swipeDelegate: ChatHomeCardCellSwipeDelegate?

  func setManualSwipeActionsEnabled(_ enabled: Bool) {
    guard manualSwipeActionsEnabled != enabled else { return }
    manualSwipeActionsEnabled = enabled
    if !enabled {
      closeSwipe(animated: false, notifyDelegate: false)
    }
    isSwipeEnabled = enabled && !(currentEditingLayout)
    swipePanGestureRecognizer.isEnabled = isSwipeEnabled
  }

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    configureView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureView()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    avatarNode.prepareForReuse()
    unreadBadge.isHidden = true
    tierBadgeImageView.isHidden = true
    muteIconView.isHidden = true
    pinIconView.isHidden = true
    selectionOverlayView.alpha = 0
    pressOverlayView.alpha = 0
    editSelectionContainer.alpha = 0
    editSelectionBackgroundView.isHidden = true
    editSelectionCheckView.isHidden = true
    rowContentLeadingConstraint?.constant = 0
    avatarWidthConstraint?.constant = 60
    avatarHeightConstraint?.constant = 60
    compactForwardStyle = false
    previewLabel.isHidden = false
    reactionPreviewLabel.text = nil
    reactionPreviewLabel.isHidden = true
    receiptStatusView.image = nil
    receiptStatusView.isHidden = false
    receiptStatusWidthConstraint?.constant = 20
    renderedReceiptStatus = nil
    rightCheckmarkView.image = UIImage(systemName: "circle")
    rightCheckmarkView.transform = .identity
    currentRow = nil
    lastBridgePreviewSignature = nil
    leadingDisplaySpecs = []
    trailingDisplaySpecs = []
    leadingFullSwipeSpec = nil
    trailingFullSwipeSpec = nil
    hasCommittedSwipeGesture = false
    isPerformingSwipeAction = false
    didEmitLargeSwipeHaptic = false
    closeSwipe(animated: false, notifyDelegate: false)
    currentEditingLayout = false
    transform = .identity
    suppressesPressOverlay = false
    pressOverlayView.alpha = 0
    dividerView.alpha = 1
    dividerView.isHidden = false
    dividerView.transform = .identity
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    setPressedState(highlighted, animated: animated)
  }

  override func setSelected(_ selected: Bool, animated: Bool) {
    super.setSelected(selected, animated: animated)
    setPressedState(selected, animated: animated)
  }

  func configure(
    row: ChatHomeListRow,
    isDark: Bool,
    avatarBackgroundColor: UIColor?,
    avatarGradientColors: (UIColor, UIColor)?,
    unreadBadgeColor: UIColor? = nil,
    isEditing: Bool,
    isEditSelected: Bool,
    showsRightCheckmark: Bool = false,
    compactForwardStyle: Bool = false
  ) {
    self.compactForwardStyle = compactForwardStyle
    let primary =
      isDark ? UIColor.white : UIColor(red: 22 / 255, green: 28 / 255, blue: 36 / 255, alpha: 1)
    let secondary =
      isDark
      ? UIColor(white: 0.76, alpha: 1)
      : UIColor(red: 114 / 255, green: 123 / 255, blue: 138 / 255, alpha: 1)
    let typingColor =
      isDark
      ? UIColor(red: 138 / 255, green: 202 / 255, blue: 255 / 255, alpha: 1)
      : UIColor(red: 43 / 255, green: 135 / 255, blue: 210 / 255, alpha: 1)
    let badgeBackground =
      unreadBadgeColor
      ?? (isDark
        ? UIColor(red: 157 / 255, green: 216 / 255, blue: 255 / 255, alpha: 1)
        : UIColor(red: 23 / 255, green: 132 / 255, blue: 209 / 255, alpha: 1))
    let pressedColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.08)
      : UIColor.black.withAlphaComponent(0.05)
    let selectedOverlayColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.06)
      : UIColor.black.withAlphaComponent(0.035)
    // Visible hairline under every row (system-separator-ish, stronger than
    // the previous near-invisible 3–6% wash).
    let dividerColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.14)
      : UIColor.black.withAlphaComponent(0.10)
    let selectionRingColor =
      isDark
      ? UIColor.white.withAlphaComponent(0.22)
      : UIColor.black.withAlphaComponent(0.12)
    let selectionIdleBackgroundColor =
      isDark
      ? UIColor.black.withAlphaComponent(0.14)
      : UIColor.white.withAlphaComponent(0.84)

    titleLabel.text = row.title
    titleLabel.textColor = primary
    titleLabel.font = .systemFont(ofSize: compactForwardStyle ? 15.5 : 17, weight: .medium)
    rowContentContainer.isHidden = false
    rowContentContainer.alpha = 1.0
    tierBadgeImageView.isHidden = compactForwardStyle || !row.isGoldTier
    if row.isGoldTier && !compactForwardStyle {
      let goldColor = UIColor(red: 255 / 255, green: 205 / 255, blue: 84 / 255, alpha: 1)
      tierBadgeImageView.image = UIImage(systemName: "checkmark.seal.fill")
      tierBadgeImageView.tintColor = goldColor
    }
    let bridgeProvider = ChatHomeListRow.bridgeProvider(
      peerUserId: row.peerUserId,
      name: row.title,
      isAgent: row.isAgentFriend,
      agentId: row.peerAgentId
    )
    // Forward sheet: name-only rows (no preview / time / badges) — denser list.
    if compactForwardStyle {
      previewLabel.text = nil
      previewLabel.isHidden = true
    } else if row.isBridgeAgentSurface,
      let progress = ChatEngine.shared.agentProgress(chatId: row.chatId),
      let liveLabel = (progress["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !liveLabel.isEmpty
    {
      previewLabel.isHidden = false
      previewLabel.text = liveLabel
      previewLabel.textColor = typingColor
      traceBridgePreview(row: row, provider: bridgeProvider, state: "progress:\(liveLabel)")
    } else if row.isBridgeAgentSurface,
      Self.hasRunningBridgeTask(
        chatId: row.chatId,
        provider: bridgeProvider
      )
    {
      // No live agent-stream label yet (a run started on the Mac / IDE, or a cold launch
      // before this chat's channel is joined) — but the bridge status snapshot reports a
      // task running for this chat. Show the working state instead of the idle
      // "Start session" preview so home reflects the in-flight session.
      previewLabel.isHidden = false
      previewLabel.text = "Working…"
      previewLabel.textColor = typingColor
      traceBridgePreview(row: row, provider: bridgeProvider, state: "working")
    } else if row.isBridgeAgentSurface {
      // Agent DMs are launch surfaces, not ordinary chat previews. A persisted
      // message may still exist in the Home row/cache, but it must never replace
      // the explicit idle state after a live task settles or on cold launch.
      previewLabel.isHidden = false
      previewLabel.text = "Start session"
      previewLabel.textColor = secondary
      traceBridgePreview(row: row, provider: bridgeProvider, state: "idle")
    } else {
      previewLabel.isHidden = false
      previewLabel.text = row.isTyping ? "typing..." : row.preview
      previewLabel.textColor = row.isTyping ? typingColor : secondary
    }
    reactionPreviewLabel.text = row.latestReactionPreview
    reactionPreviewLabel.isHidden = compactForwardStyle || row.isTyping || row.latestReactionPreview == nil
    reactionPreviewLabel.textColor = primary
    reactionPreviewLabel.backgroundColor = isDark
      ? UIColor.white.withAlphaComponent(0.12)
      : UIColor.black.withAlphaComponent(0.07)

    timeLabel.isHidden = showsRightCheckmark || compactForwardStyle
    timeLabel.text = row.timeLabel
    timeLabel.textColor = secondary

    let receiptStatus = (showsRightCheckmark || compactForwardStyle)
      ? nil
      : row.latestOutgoingDisplayStatus?.lowercased()
    let receiptGlyphStatus: String? = {
      switch receiptStatus {
      case "sent", "delivered": return "single"
      case "read": return "double"
      default: return nil
      }
    }()
    // Keep a fixed slot throughout the lifecycle of an outgoing message, including
    // pending/sending before its first tick appears. Incoming rows reserve no blank gap.
    // This prevents receipt arrival from shifting the title/preview or looking doubled.
    receiptStatusView.isHidden = false
    let reservesReceiptSlot = !(showsRightCheckmark || compactForwardStyle)
      && ["pending", "sending", "sent", "delivered", "read"].contains(receiptStatus ?? "")
    receiptStatusWidthConstraint?.constant = reservesReceiptSlot ? 20 : 0
    receiptStatusView.isAccessibilityElement = receiptGlyphStatus != nil
    receiptStatusView.accessibilityLabel = receiptGlyphStatus == "double"
      ? NSLocalizedString("Read", comment: "Home list outgoing message receipt")
      : NSLocalizedString("Sent", comment: "Home list outgoing message receipt")
    receiptStatusView.image = receiptGlyphStatus.map {
      homeStatusCheckImage(
        double: $0 == "double",
        color: $0 == "double" ? badgeBackground : secondary
      )
    }
    if let previous = renderedReceiptStatus,
      previous != receiptGlyphStatus,
      receiptGlyphStatus != nil,
      window != nil
    {
      receiptStatusView.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
      receiptStatusView.alpha = 0.35
      UIView.animate(
        withDuration: 0.22,
        delay: 0,
        usingSpringWithDamping: 0.72,
        initialSpringVelocity: 0.25,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.receiptStatusView.transform = .identity
        self.receiptStatusView.alpha = 1
      }
    } else {
      receiptStatusView.transform = .identity
      receiptStatusView.alpha = 1
    }
    renderedReceiptStatus = receiptGlyphStatus

    let unreadVisible =
      !showsRightCheckmark && !compactForwardStyle && (row.unreadCount > 0 || row.markedUnread)
    unreadBadge.isHidden = !unreadVisible
    unreadLabel.text = unreadVisible ? "\(max(1, row.unreadCount))" : ""
    unreadLabel.textColor = .white
    unreadBadge.backgroundColor = badgeBackground

    muteIconView.isHidden = showsRightCheckmark || compactForwardStyle || !row.muted
    pinIconView.isHidden = showsRightCheckmark || compactForwardStyle || !row.pinned
    muteIconView.tintColor = secondary
    pinIconView.tintColor = secondary
    onlineDot.isHidden = compactForwardStyle || !row.isOnline
    selectionOverlayView.backgroundColor = selectedOverlayColor
    // Soft fill morph for selection (forward sheet + edit mode).
    let wantOverlay = isEditSelected && (isEditing || showsRightCheckmark)
    if selectionOverlayView.alpha != (wantOverlay ? 1 : 0) {
      UIView.animate(
        withDuration: 0.26,
        delay: 0,
        options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
      ) {
        self.selectionOverlayView.alpha = wantOverlay ? 1 : 0
      }
    }

    // Selection chrome visibility is driven by updateEditingLayout (animated).
    // Don't snap alpha/hidden here or the edit gutter "pops".
    editSelectionBackgroundView.backgroundColor = isEditSelected ? badgeBackground : selectionIdleBackgroundColor
    editSelectionBackgroundView.layer.borderColor = (isEditSelected ? badgeBackground : selectionRingColor).cgColor
    editSelectionCheckView.isHidden = !(isEditing && isEditSelected)
    editSelectionCheckView.tintColor = isDark ? UIColor.black : UIColor.white

    rightCheckmarkView.isHidden = !showsRightCheckmark
    // Morph empty circle → filled check (no pop).
    let radioName = isEditSelected ? "checkmark.circle.fill" : "circle"
    let nextRadio = UIImage(systemName: radioName)
    if rightCheckmarkView.image !== nextRadio {
      if showsRightCheckmark, window != nil {
        UIView.transition(
          with: rightCheckmarkView,
          duration: 0.22,
          options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
        ) {
          self.rightCheckmarkView.image = nextRadio
          self.rightCheckmarkView.tintColor = isEditSelected
            ? badgeBackground
            : secondary.withAlphaComponent(0.45)
          self.rightCheckmarkView.transform = isEditSelected
            ? CGAffineTransform(scaleX: 1.06, y: 1.06)
            : .identity
        } completion: { _ in
          UIView.animate(withDuration: 0.16) {
            self.rightCheckmarkView.transform = .identity
          }
        }
      } else {
        rightCheckmarkView.image = nextRadio
        rightCheckmarkView.tintColor = isEditSelected
          ? badgeBackground
          : secondary.withAlphaComponent(0.45)
      }
    } else {
      rightCheckmarkView.tintColor = isEditSelected
        ? badgeBackground
        : secondary.withAlphaComponent(0.45)
    }

    let avatarSide: CGFloat = compactForwardStyle ? 36 : 60
    avatarWidthConstraint?.constant = avatarSide
    avatarHeightConstraint?.constant = avatarSide

    let avatarKind: ChatAvatarKind =
      row.isSavedMessages ? .savedMessages : (row.isArchiveEntry ? .archive : .standard)
    avatarNode.configure(
      with: ChatAvatarDescriptor(
        title: row.title,
        rawAvatarURI: row.avatarUri,
        peerUserId: row.peerUserId,
        chatId: row.chatId,
        kind: avatarKind,
        isGroup: row.isGroup || row.isChannel,
        members: row.members,
        preferPushAvatar: !row.isGroup && !row.isChannel,
        gradientColors: avatarGradientColors
      ),
      isDark: isDark,
      renderingSide: avatarSide
    )
    pressOverlayView.backgroundColor = pressedColor
    dividerView.backgroundColor = dividerColor
    // Swipe-delete animation zeros alpha; always restore on reconfigure.
    dividerView.alpha = 1
    dividerView.isHidden = false
    // SwiftUI-List-style swipe surface: while displaced, the row becomes an
    // opaque elevated card (secondary background) instead of a transparent
    // slab the action tiles show through.
    swipeSurfaceColor = isDark ? UIColor(white: 0.12, alpha: 1) : UIColor.white
    updateSwipeChrome()
    updateEditingLayout(isEditing, animated: true)
    configureSwipeActions(for: row, isEditing: isEditing)
  }

  private func traceBridgePreview(row: ChatHomeListRow, provider: String?, state: String) {
    let signature = "\(row.chatId)|\(state)"
    guard signature != lastBridgePreviewSignature else { return }
    lastBridgePreviewSignature = signature
    AppUITrace.notice(
      "ChatHomeCell bridgeState provider=\(provider ?? "?") chatId=\(String(row.chatId.prefix(12))) state=\(state) tasks=\(AgentPairingService.lastStatusSnapshot?.runningTasks.count ?? 0)"
    )
  }

  private func updateEditingLayout(_ isEditing: Bool, animated: Bool) {
    let targetLeading: CGFloat = isEditing ? 44 : 0
    let updates = {
      self.rowContentLeadingConstraint?.constant = targetLeading
      self.contentView.layoutIfNeeded()
      self.layoutIfNeeded()
    }

    let shouldAnimate = animated && currentEditingLayout != isEditing
    currentEditingLayout = isEditing

    // Crossfade selection chrome with the leading shift so edit mode doesn't pop.
    if shouldAnimate {
      if isEditing {
        editSelectionContainer.alpha = 0
        editSelectionBackgroundView.isHidden = false
      }
      UIView.animate(
        withDuration: 0.30,
        delay: 0,
        usingSpringWithDamping: 0.88,
        initialSpringVelocity: 0.15,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
      ) {
        updates()
        self.editSelectionContainer.alpha = isEditing ? 1 : 0
      } completion: { _ in
        if !isEditing {
          self.editSelectionBackgroundView.isHidden = true
        }
      }
    } else {
      updates()
      editSelectionContainer.alpha = isEditing ? 1 : 0
      editSelectionBackgroundView.isHidden = !isEditing
    }
  }

  private func setPressedState(_ pressed: Bool, animated: Bool) {
    let targetAlpha: CGFloat = (pressed && !suppressesPressOverlay) ? 1 : 0
    if animated {
      UIView.animate(withDuration: 0.14) {
        self.pressOverlayView.alpha = targetAlpha
      }
    } else {
      pressOverlayView.alpha = targetAlpha
    }
  }

  /// The preview hold is its own gesture, not a tap: once it engages, the tap
  /// highlight must leave the card (and stay out of the expansion snapshot).
  /// Quick taps never reach suppression, so they keep their normal flash.
  func setPressOverlaySuppressed(_ suppressed: Bool, animated: Bool) {
    suppressesPressOverlay = suppressed
    guard suppressed else { return }
    if animated {
      UIView.animate(
        withDuration: 0.12,
        delay: 0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.pressOverlayView.alpha = 0
      }
    } else {
      pressOverlayView.layer.removeAllAnimations()
      pressOverlayView.alpha = 0
    }
  }

  func flashPressedFeedback(duration: TimeInterval = 0.14) {
    pressOverlayView.layer.removeAllAnimations()
    pressOverlayView.alpha = 1
    UIView.animate(
      withDuration: duration,
      delay: 0.045,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      self.pressOverlayView.alpha = 0
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutSwipeActionViews()
  }

  private func configureView() {
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.clipsToBounds = true

    leadingActionsContainer.translatesAutoresizingMaskIntoConstraints = false
    leadingActionsContainer.backgroundColor = .clear
    leadingActionsContainer.clipsToBounds = true
    leadingActionsMaskLayer.backgroundColor = UIColor.black.cgColor
    leadingActionsContainer.layer.mask = leadingActionsMaskLayer

    trailingActionsContainer.translatesAutoresizingMaskIntoConstraints = false
    trailingActionsContainer.backgroundColor = .clear
    trailingActionsContainer.clipsToBounds = true
    trailingActionsMaskLayer.backgroundColor = UIColor.black.cgColor
    trailingActionsContainer.layer.mask = trailingActionsMaskLayer

    leadingFullSwipeView.isHidden = true
    trailingFullSwipeView.isHidden = true

    selectionOverlayView.translatesAutoresizingMaskIntoConstraints = false
    selectionOverlayView.alpha = 0
    selectionOverlayView.isUserInteractionEnabled = false

    pressOverlayView.translatesAutoresizingMaskIntoConstraints = false
    pressOverlayView.alpha = 0
    pressOverlayView.isUserInteractionEnabled = false

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.isUserInteractionEnabled = false
    dividerView.backgroundColor = UIColor.black.withAlphaComponent(0.10)

    rowContentContainer.translatesAutoresizingMaskIntoConstraints = false
    rowContentContainer.backgroundColor = .clear
    rowContentContainer.clipsToBounds = false

    editSelectionContainer.translatesAutoresizingMaskIntoConstraints = false
    editSelectionContainer.alpha = 0
    editSelectionContainer.isUserInteractionEnabled = false

    avatarNode.translatesAutoresizingMaskIntoConstraints = false

    editSelectionBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    editSelectionBackgroundView.backgroundColor = .clear
    editSelectionBackgroundView.layer.cornerRadius = 11
    editSelectionBackgroundView.layer.borderWidth = 1.25
    editSelectionBackgroundView.isHidden = true

    editSelectionCheckView.translatesAutoresizingMaskIntoConstraints = false
    editSelectionCheckView.image = UIImage(systemName: "checkmark")
    editSelectionCheckView.contentMode = .scaleAspectFit
    editSelectionCheckView.isHidden = true

    onlineDot.translatesAutoresizingMaskIntoConstraints = false
    onlineDot.backgroundColor = UIColor(red: 61 / 255, green: 208 / 255, blue: 102 / 255, alpha: 1)
    onlineDot.layer.cornerRadius = 6
    onlineDot.layer.borderWidth = 2
    onlineDot.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
    onlineDot.isHidden = true

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 17, weight: .medium)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    tierBadgeImageView.translatesAutoresizingMaskIntoConstraints = false
    tierBadgeImageView.contentMode = .scaleAspectFit
    tierBadgeImageView.isHidden = true
    tierBadgeImageView.setContentHuggingPriority(.required, for: .horizontal)
    tierBadgeImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

    previewLabel.translatesAutoresizingMaskIntoConstraints = false
    previewLabel.font = .systemFont(ofSize: 15, weight: .regular)
    previewLabel.numberOfLines = 1

    reactionPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
    reactionPreviewLabel.font = .systemFont(ofSize: 13)
    reactionPreviewLabel.textAlignment = .center
    reactionPreviewLabel.layer.cornerRadius = 9
    reactionPreviewLabel.layer.cornerCurve = .continuous
    reactionPreviewLabel.clipsToBounds = true
    reactionPreviewLabel.setContentHuggingPriority(.required, for: .horizontal)
    reactionPreviewLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    timeLabel.translatesAutoresizingMaskIntoConstraints = false
    timeLabel.font = .systemFont(ofSize: 13, weight: .regular)
    timeLabel.textAlignment = .right
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)
    timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    receiptStatusView.translatesAutoresizingMaskIntoConstraints = false
    receiptStatusView.contentMode = .scaleAspectFit
    receiptStatusView.isHidden = false
    receiptStatusView.setContentHuggingPriority(.required, for: .horizontal)
    receiptStatusView.setContentCompressionResistancePriority(.required, for: .horizontal)

    unreadBadge.translatesAutoresizingMaskIntoConstraints = false
    unreadBadge.layer.cornerRadius = 10
    unreadBadge.isHidden = true

    unreadLabel.translatesAutoresizingMaskIntoConstraints = false
    unreadLabel.font = .systemFont(ofSize: 11, weight: .bold)
    unreadLabel.textAlignment = .center

    muteIconView.translatesAutoresizingMaskIntoConstraints = false
    muteIconView.image = UIImage(systemName: "speaker.slash.fill")
    muteIconView.isHidden = true
    muteIconView.contentMode = .scaleAspectFit

    pinIconView.translatesAutoresizingMaskIntoConstraints = false
    pinIconView.image = UIImage(systemName: "pin.fill")
    pinIconView.isHidden = true
    pinIconView.contentMode = .scaleAspectFit
    pinIconView.transform = CGAffineTransform(rotationAngle: CGFloat.pi / 4)

    rightCheckmarkView.translatesAutoresizingMaskIntoConstraints = false
    rightCheckmarkView.image = UIImage(systemName: "checkmark")
    rightCheckmarkView.contentMode = .scaleAspectFit
    rightCheckmarkView.isHidden = true

    let titleRowStack = UIStackView(arrangedSubviews: [
      titleLabel,
      tierBadgeImageView,
      {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
      }()
    ])
    titleRowStack.translatesAutoresizingMaskIntoConstraints = false
    titleRowStack.axis = .horizontal
    titleRowStack.spacing = 6
    titleRowStack.alignment = .center

    let previewStack = UIStackView(arrangedSubviews: [reactionPreviewLabel, previewLabel])
    previewStack.translatesAutoresizingMaskIntoConstraints = false
    previewStack.axis = .horizontal
    previewStack.spacing = 5
    previewStack.alignment = .center

    let textStack = UIStackView(arrangedSubviews: [titleRowStack, previewStack])
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.axis = .vertical
    textStack.spacing = 2
    textStack.alignment = .fill
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textStack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    NSLayoutConstraint.activate([
      reactionPreviewLabel.heightAnchor.constraint(equalToConstant: 18),
      reactionPreviewLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
    ])

    let iconStack = UIStackView(arrangedSubviews: [muteIconView, pinIconView])
    iconStack.translatesAutoresizingMaskIntoConstraints = false
    iconStack.axis = .horizontal
    iconStack.spacing = 7
    iconStack.alignment = .center

    // Telegram-style metadata: receipt immediately beside the date on the title line;
    // unread/mute/pin occupy the preview line. The former equal-spacing vertical stack
    // centered all three items as a loose column and made the date visibly drift down.
    let topMetaStack = UIStackView(arrangedSubviews: [receiptStatusView, timeLabel])
    topMetaStack.translatesAutoresizingMaskIntoConstraints = false
    topMetaStack.axis = .horizontal
    topMetaStack.spacing = 3
    topMetaStack.alignment = .center

    let bottomMetaStack = UIStackView(arrangedSubviews: [iconStack, unreadBadge])
    bottomMetaStack.translatesAutoresizingMaskIntoConstraints = false
    bottomMetaStack.axis = .horizontal
    bottomMetaStack.spacing = 7
    bottomMetaStack.alignment = .center

    let metaStack = UIStackView(arrangedSubviews: [topMetaStack, bottomMetaStack])
    metaStack.translatesAutoresizingMaskIntoConstraints = false
    metaStack.axis = .vertical
    metaStack.spacing = 2
    metaStack.alignment = .trailing
    metaStack.distribution = .fillEqually
    metaStack.setContentHuggingPriority(.required, for: .horizontal)
    metaStack.setContentCompressionResistancePriority(.required, for: .horizontal)

    contentView.addSubview(leadingActionsContainer)
    contentView.addSubview(trailingActionsContainer)
    contentView.addSubview(selectionOverlayView)
    contentView.addSubview(pressOverlayView)
    contentView.addSubview(editSelectionContainer)
    contentView.addSubview(rowContentContainer)
    // Divider above row chrome so the hairline is never covered.
    contentView.addSubview(dividerView)
    leadingActionsContainer.addSubview(leadingFullSwipeView)
    trailingActionsContainer.addSubview(trailingFullSwipeView)
    rowContentContainer.addSubview(avatarNode)
    editSelectionContainer.addSubview(editSelectionBackgroundView)
    editSelectionBackgroundView.addSubview(editSelectionCheckView)
    rowContentContainer.addSubview(onlineDot)
    rowContentContainer.addSubview(textStack)
    rowContentContainer.addSubview(metaStack)
    rowContentContainer.addSubview(rightCheckmarkView)
    unreadBadge.addSubview(unreadLabel)

    let rowContentLeadingConstraint = rowContentContainer.leadingAnchor.constraint(
      equalTo: contentView.leadingAnchor)
    self.rowContentLeadingConstraint = rowContentLeadingConstraint

    NSLayoutConstraint.activate([
      leadingActionsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      leadingActionsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      leadingActionsContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      leadingActionsContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      trailingActionsContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      trailingActionsContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      trailingActionsContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      trailingActionsContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      selectionOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      selectionOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      selectionOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
      selectionOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      pressOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      pressOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      pressOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
      pressOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      editSelectionContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      editSelectionContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      editSelectionContainer.widthAnchor.constraint(equalToConstant: 44),
      editSelectionContainer.heightAnchor.constraint(equalToConstant: 44),

      rowContentLeadingConstraint,
      rowContentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      rowContentContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      rowContentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      avatarNode.leadingAnchor.constraint(equalTo: rowContentContainer.leadingAnchor, constant: 16),
      avatarNode.centerYAnchor.constraint(equalTo: rowContentContainer.centerYAnchor),
      {
        let w = avatarNode.widthAnchor.constraint(equalToConstant: 60)
        self.avatarWidthConstraint = w
        return w
      }(),
      {
        let h = avatarNode.heightAnchor.constraint(equalToConstant: 60)
        self.avatarHeightConstraint = h
        return h
      }(),

      // Align under the text stack (after avatar + gap). Tracks edit shift
      // because it is relative to the avatar, not fixed contentView leading.
      dividerView.leadingAnchor.constraint(
        equalTo: avatarNode.trailingAnchor, constant: 14),
      dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: max(1 / UIScreen.main.scale, 0.5)),

      editSelectionBackgroundView.centerXAnchor.constraint(equalTo: editSelectionContainer.centerXAnchor),
      editSelectionBackgroundView.centerYAnchor.constraint(equalTo: editSelectionContainer.centerYAnchor),
      editSelectionBackgroundView.widthAnchor.constraint(equalToConstant: 22),
      editSelectionBackgroundView.heightAnchor.constraint(equalToConstant: 22),
      editSelectionCheckView.centerXAnchor.constraint(equalTo: editSelectionBackgroundView.centerXAnchor),
      editSelectionCheckView.centerYAnchor.constraint(equalTo: editSelectionBackgroundView.centerYAnchor),
      editSelectionCheckView.widthAnchor.constraint(equalToConstant: 11),
      editSelectionCheckView.heightAnchor.constraint(equalToConstant: 11),

      onlineDot.widthAnchor.constraint(equalToConstant: 12),
      onlineDot.heightAnchor.constraint(equalToConstant: 12),
      onlineDot.trailingAnchor.constraint(equalTo: avatarNode.trailingAnchor, constant: -1),
      onlineDot.bottomAnchor.constraint(equalTo: avatarNode.bottomAnchor, constant: -1),

      textStack.leadingAnchor.constraint(equalTo: avatarNode.trailingAnchor, constant: 14),
      textStack.centerYAnchor.constraint(equalTo: rowContentContainer.centerYAnchor),
      textStack.trailingAnchor.constraint(equalTo: metaStack.leadingAnchor, constant: -10),

      metaStack.trailingAnchor.constraint(equalTo: rowContentContainer.trailingAnchor, constant: -16),
      // Exact two-line alignment: receipt/date follows the title baseline and lower
      // metadata follows the preview baseline, independent of which icons are hidden.
      metaStack.topAnchor.constraint(equalTo: textStack.topAnchor),
      metaStack.bottomAnchor.constraint(equalTo: textStack.bottomAnchor),
      metaStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),

      {
        let width = receiptStatusView.widthAnchor.constraint(equalToConstant: 20)
        self.receiptStatusWidthConstraint = width
        return width
      }(),
      receiptStatusView.heightAnchor.constraint(equalToConstant: 14),

      unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
      unreadBadge.heightAnchor.constraint(equalToConstant: 20),
      unreadLabel.leadingAnchor.constraint(equalTo: unreadBadge.leadingAnchor, constant: 6),
      unreadLabel.trailingAnchor.constraint(equalTo: unreadBadge.trailingAnchor, constant: -6),
      unreadLabel.centerYAnchor.constraint(equalTo: unreadBadge.centerYAnchor),

      rightCheckmarkView.trailingAnchor.constraint(equalTo: rowContentContainer.trailingAnchor, constant: -20),
      rightCheckmarkView.centerYAnchor.constraint(equalTo: rowContentContainer.centerYAnchor),
      rightCheckmarkView.widthAnchor.constraint(equalToConstant: 20),
      rightCheckmarkView.heightAnchor.constraint(equalToConstant: 20),

      muteIconView.widthAnchor.constraint(equalToConstant: 14),
      muteIconView.heightAnchor.constraint(equalToConstant: 14),
      pinIconView.widthAnchor.constraint(equalToConstant: 14),
      pinIconView.heightAnchor.constraint(equalToConstant: 14),
      tierBadgeImageView.heightAnchor.constraint(equalToConstant: 16),
      tierBadgeImageView.widthAnchor.constraint(equalToConstant: 16),
      { let c = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 84); c.priority = .defaultHigh; return c }(),
    ])

    rowContentContainer.addGestureRecognizer(swipePanGestureRecognizer)
  }

  func closeSwipe(animated: Bool) {
    closeSwipe(animated: animated, notifyDelegate: true)
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === swipePanGestureRecognizer, isSwipeEnabled else { return false }
    let velocity = swipePanGestureRecognizer.velocity(in: contentView)
    return abs(velocity.x) > abs(velocity.y)
  }

  @objc private func handleSwipePan(_ gestureRecognizer: UIPanGestureRecognizer) {
    guard isSwipeEnabled, !isPerformingSwipeAction else { return }

    let translationX = gestureRecognizer.translation(in: contentView).x
    let velocityX = gestureRecognizer.velocity(in: contentView).x

    switch gestureRecognizer.state {
    case .began:
      swipeStartOffset = swipeOffset
      hasCommittedSwipeGesture = abs(swipeOffset) > 0.5
      didEmitLargeSwipeHaptic = false
      largeSwipeHapticGenerator.prepare()
    case .changed:
      let rawOffset = swipeStartOffset + translationX
      let nextOffset: CGFloat
      if hasCommittedSwipeGesture || abs(swipeStartOffset) > 0.5 {
        nextOffset = clampedSwipeOffset(for: rawOffset)
      } else if abs(rawOffset) <= swipeActivationThreshold {
        nextOffset = 0
      } else {
        hasCommittedSwipeGesture = true
        swipeDelegate?.homeCardCellDidBeginSwipe(self)
        let direction: CGFloat = rawOffset >= 0 ? 1 : -1
        nextOffset = clampedSwipeOffset(for: rawOffset - (direction * swipeActivationThreshold))
      }
      setSwipeOffset(nextOffset, animated: false)
      maybeTriggerImmediateLargeSwipeAction(for: nextOffset)
    case .ended, .cancelled, .failed:
      if isPerformingSwipeAction {
        return
      }
      finalizeSwipe(velocityX: velocityX)
    default:
      break
    }
  }

  private func configureSwipeActions(for row: ChatHomeListRow, isEditing: Bool) {
    currentRow = row
    isSwipeEnabled = manualSwipeActionsEnabled && !isEditing
    swipePanGestureRecognizer.isEnabled = isSwipeEnabled

    leadingDisplaySpecs = orderedSwipeSpecs(row.leadingSwipeActionSpecs, edge: .leading)
    trailingDisplaySpecs = orderedSwipeSpecs(row.trailingSwipeActionSpecs, edge: .trailing)
    leadingFullSwipeSpec =
      row.leadingSwipeActionSpecs.first(where: \.isFullSwipeTarget) ?? leadingDisplaySpecs.last
    trailingFullSwipeSpec =
      row.trailingSwipeActionSpecs.first(where: \.isFullSwipeTarget)
      ?? trailingDisplaySpecs.first(where: { $0.eventType == "swipeDelete" })

    syncSwipeButtons(
      in: leadingActionsContainer,
      buttons: &leadingActionButtons,
      specs: leadingDisplaySpecs,
      edge: .leading
    )
    syncSwipeButtons(
      in: trailingActionsContainer,
      buttons: &trailingActionButtons,
      specs: trailingDisplaySpecs,
      edge: .trailing
    )

    if isEditing {
      closeSwipe(animated: false, notifyDelegate: false)
    } else {
      hasCommittedSwipeGesture = false
      setSwipeOffset(0, animated: false)
    }
  }

  private func syncSwipeButtons(
    in container: UIView,
    buttons: inout [ChatHomeSwipeActionButton],
    specs: [ChatHomeSwipeActionSpec],
    edge: ChatHomeSwipeEdge
  ) {
    if buttons.count > specs.count {
      for button in buttons[specs.count...] {
        button.removeFromSuperview()
      }
      buttons.removeSubrange(specs.count...)
    }

    while buttons.count < specs.count {
      let button = ChatHomeSwipeActionButton(frame: .zero)
      button.addTarget(self, action: #selector(handleSwipeActionButtonTap(_:)), for: .touchUpInside)
      container.addSubview(button)
      buttons.append(button)
    }

    for (index, spec) in specs.enumerated() {
      buttons[index].configure(spec: spec, edge: edge)
    }
  }

  @objc private func handleSwipeActionButtonTap(_ sender: ChatHomeSwipeActionButton) {
    guard let row = currentRow, let spec = sender.spec else { return }
    
    if spec.eventType == "swipeDelete" {
      performDeleteAnimation(spec: spec, row: row)
    } else {
      closeSwipe(animated: true, notifyDelegate: false)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.swipeDelegate?.homeCardCell(self, didTriggerSwipeEvent: spec.eventType, chatId: row.chatId)
      }
    }
  }

  private func orderedSwipeSpecs(
    _ specs: [ChatHomeSwipeActionSpec],
    edge: ChatHomeSwipeEdge
  ) -> [ChatHomeSwipeActionSpec] {
    let priorities: [String: Int]
    switch edge {
    case .leading:
      priorities = [
        "swipeMarkRead": 0,
        "swipePin": 1,
      ]
    case .trailing:
      priorities = [
        "swipeMute": 0,
        "swipeDelete": 1,
        "swipeArchive": 2,
      ]
    }

    return specs.sorted { lhs, rhs in
      let lhsPriority = priorities[lhs.eventType] ?? 99
      let rhsPriority = priorities[rhs.eventType] ?? 99
      if lhsPriority == rhsPriority {
        return lhs.title < rhs.title
      }
      return lhsPriority < rhsPriority
    }
  }

  private func clampedSwipeOffset(for proposedOffset: CGFloat) -> CGFloat {
    if proposedOffset > 0 {
      guard !leadingDisplaySpecs.isEmpty else { return 0 }
      return min(proposedOffset, max(leadingOpenWidth, bounds.width - 20))
    }
    if proposedOffset < 0 {
      guard !trailingDisplaySpecs.isEmpty else { return 0 }
      return max(proposedOffset, -max(trailingOpenWidth, bounds.width - 20))
    }
    return 0
  }

  private func maybeTriggerImmediateLargeSwipeAction(for offset: CGFloat) {
    guard abs(offset) > 0.5, !isPerformingSwipeAction else { return }

    if offset < 0,
      let spec = trailingFullSwipeSpec,
      (-offset) >= trailingFullSwipeTriggerDistance
    {
      performImmediateLargeSwipeAction(spec: spec, edge: .trailing)
      return
    }

    if offset > 0,
      let spec = leadingFullSwipeSpec,
      offset >= leadingFullSwipeTriggerDistance
    {
      performImmediateLargeSwipeAction(spec: spec, edge: .leading)
    }
  }

  private func finalizeSwipe(velocityX: CGFloat) {
    if swipeOffset < 0 {
      let revealWidth = -swipeOffset
      if let fullSwipeSpec = trailingFullSwipeSpec,
        revealWidth >= trailingFullSwipeTriggerDistance
          || (velocityX < -1400 && revealWidth > trailingOpenWidth * 0.88)
      {
        triggerFullSwipe(spec: fullSwipeSpec, edge: .trailing)
        return
      }
      let shouldStayOpen = revealWidth > trailingOpenWidth * 0.46 || velocityX < -520
      setSwipeOffset(shouldStayOpen ? -trailingOpenWidth : 0, animated: true)
      if !shouldStayOpen {
        swipeDelegate?.homeCardCellDidCloseSwipe(self)
      }
      return
    }

    if swipeOffset > 0 {
      let revealWidth = swipeOffset
      if let fullSwipeSpec = leadingFullSwipeSpec,
        revealWidth >= leadingFullSwipeTriggerDistance
          || (velocityX > 1400 && revealWidth > leadingOpenWidth * 0.88)
      {
        triggerFullSwipe(spec: fullSwipeSpec, edge: .leading)
        return
      }
      let shouldStayOpen = revealWidth > leadingOpenWidth * 0.46 || velocityX > 520
      setSwipeOffset(shouldStayOpen ? leadingOpenWidth : 0, animated: true)
      if !shouldStayOpen {
        swipeDelegate?.homeCardCellDidCloseSwipe(self)
      }
      return
    }

    swipeDelegate?.homeCardCellDidCloseSwipe(self)
  }

  private func performImmediateLargeSwipeAction(
    spec: ChatHomeSwipeActionSpec,
    edge: ChatHomeSwipeEdge
  ) {
    guard let row = currentRow, !isPerformingSwipeAction else { return }
    isPerformingSwipeAction = true
    hasCommittedSwipeGesture = false

    if !didEmitLargeSwipeHaptic {
      didEmitLargeSwipeHaptic = true
      largeSwipeHapticGenerator.impactOccurred(intensity: 0.92)
    }

    if spec.eventType == "swipeDelete" {
      performDeleteAnimation(spec: spec, row: row)
      return
    }

    let accentOffset = edge == .leading
      ? min(bounds.width * 0.28, leadingOpenWidth + 26)
      : -min(bounds.width * 0.28, trailingOpenWidth + 26)
    setSwipeOffset(accentOffset, animated: true, duration: 0.12)

    swipePanGestureRecognizer.isEnabled = false
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.swipeDelegate?.homeCardCell(self, didTriggerSwipeEvent: spec.eventType, chatId: row.chatId)
      self.closeSwipe(animated: true, notifyDelegate: false)
      self.swipePanGestureRecognizer.isEnabled = self.isSwipeEnabled
      self.isPerformingSwipeAction = false
      self.didEmitLargeSwipeHaptic = false
    }
  }

  private func performDeleteAnimation(spec: ChatHomeSwipeActionSpec, row: ChatHomeListRow) {
    swipePanGestureRecognizer.isEnabled = false

    guard let snapshot = rowContentContainer.snapshotView(afterScreenUpdates: false) else {
      notifySwipeEventAndClose(spec: spec, row: row)
      return
    }

    snapshot.frame = rowContentContainer.frame
    contentView.addSubview(snapshot)
    rowContentContainer.isHidden = true
    leadingActionsContainer.isHidden = true
    trailingActionsContainer.isHidden = true

    let emitter = CAEmitterLayer()
    emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
    emitter.emitterSize = bounds.size
    emitter.emitterShape = .rectangle

    let cell = CAEmitterCell()
    cell.contents = createParticleImage()?.cgImage
    cell.birthRate = 1800
    cell.lifetime = 0.8
    cell.velocity = 180
    cell.velocityRange = 100
    cell.emissionRange = .pi * 2
    cell.scale = 0.8
    cell.scaleRange = 0.4
    cell.scaleSpeed = -0.6
    cell.alphaSpeed = -1.2
    cell.yAcceleration = 400

    emitter.emitterCells = [cell]
    contentView.layer.addSublayer(emitter)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      emitter.birthRate = 0
    }

    var transform = CATransform3DIdentity
    transform.m34 = -1.0 / 600.0
    transform = CATransform3DTranslate(transform, 0, 50, -150)
    transform = CATransform3DRotate(transform, -.pi / 3, 1, 0, 0)
    transform = CATransform3DScale(transform, 0.1, 0.1, 0.1)

    UIView.animate(withDuration: 0.45, delay: 0, options: .curveEaseIn, animations: {
      snapshot.layer.transform = transform
      snapshot.alpha = 0
      self.selectionOverlayView.alpha = 0
      self.dividerView.alpha = 0
      self.backgroundColor = .clear
      self.contentView.backgroundColor = .clear
    }) { _ in
      snapshot.removeFromSuperview()
      emitter.removeFromSuperlayer()
      self.rowContentContainer.isHidden = false
      self.rowContentContainer.alpha = 0 // Hide until reused
      self.notifySwipeEventAndClose(spec: spec, row: row)
    }
  }

  private func notifySwipeEventAndClose(spec: ChatHomeSwipeActionSpec, row: ChatHomeListRow) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.swipeDelegate?.homeCardCell(self, didTriggerSwipeEvent: spec.eventType, chatId: row.chatId)
      self.closeSwipe(animated: false, notifyDelegate: false)
      self.swipePanGestureRecognizer.isEnabled = self.isSwipeEnabled
      self.isPerformingSwipeAction = false
      self.didEmitLargeSwipeHaptic = false
    }
  }

  private func createParticleImage() -> UIImage? {
    let size = CGSize(width: 8, height: 8)
    UIGraphicsBeginImageContextWithOptions(size, false, 0)
    guard let context = UIGraphicsGetCurrentContext() else { return nil }
    context.setFillColor(UIColor.systemGray.withAlphaComponent(0.8).cgColor)
    context.fillEllipse(in: CGRect(origin: .zero, size: size))
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
  }

  private func triggerFullSwipe(
    spec: ChatHomeSwipeActionSpec,
    edge: ChatHomeSwipeEdge
  ) {
    performImmediateLargeSwipeAction(spec: spec, edge: edge)
  }

  private func setSwipeOffset(
    _ offset: CGFloat,
    animated: Bool,
    duration: TimeInterval = 0.22
  ) {
    let updates = {
      self.swipeOffset = offset
      let transform = CGAffineTransform(translationX: offset, y: 0)
      self.selectionOverlayView.transform = transform
      self.pressOverlayView.transform = transform
      self.dividerView.transform = transform
      self.rowContentContainer.transform = transform
      self.editSelectionContainer.transform = transform
      self.updateSwipeChrome()
      self.layoutSwipeActionViews()
    }

    if animated {
      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        updates()
      }
    } else {
      updates()
    }
  }

  /// SwiftUI-List-style swipe chrome: while the row is displaced it becomes an
  /// OPAQUE rounded card (secondary background + continuous corners animating
  /// with the same transaction) sliding over the action tiles. A
  /// clear-background row read as transparent — the actions showed through
  /// the content itself.
  private func updateSwipeChrome() {
    let active = abs(swipeOffset) > 0.5
    rowContentContainer.layer.cornerCurve = .continuous
    rowContentContainer.layer.cornerRadius = active ? 22 : 0
    rowContentContainer.layer.masksToBounds = active
    rowContentContainer.backgroundColor = active ? swipeSurfaceColor : .clear
  }

  private func closeSwipe(animated: Bool, notifyDelegate: Bool) {
    let didClose = abs(swipeOffset) > 0.5
    hasCommittedSwipeGesture = false
    didEmitLargeSwipeHaptic = false
    setSwipeOffset(0, animated: animated)
    if notifyDelegate && didClose {
      swipeDelegate?.homeCardCellDidCloseSwipe(self)
    }
  }

  private func layoutSwipeActionViews() {
    let bounds = contentView.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let leadingRevealWidth = max(0, swipeOffset)
    let trailingRevealWidth = max(0, -swipeOffset)
    let leadingExpansionProgress = expansionProgress(revealWidth: leadingRevealWidth, openWidth: leadingOpenWidth)
    let trailingExpansionProgress = expansionProgress(revealWidth: trailingRevealWidth, openWidth: trailingOpenWidth)

    leadingActionsContainer.alpha = 1
    trailingActionsContainer.alpha = 1
    leadingActionsContainer.isHidden = leadingDisplaySpecs.isEmpty
    trailingActionsContainer.isHidden = trailingDisplaySpecs.isEmpty
    leadingFullSwipeView.isHidden = true
    trailingFullSwipeView.isHidden = true
    updateActionsMask(
      leadingActionsMaskLayer,
      visibleRect: CGRect(x: 0, y: 0, width: leadingRevealWidth, height: bounds.height)
    )
    updateActionsMask(
      trailingActionsMaskLayer,
      visibleRect: CGRect(
        x: max(0, bounds.width - trailingRevealWidth),
        y: 0,
        width: trailingRevealWidth,
        height: bounds.height
      )
    )

    layoutLeadingButtons(
      revealWidth: leadingRevealWidth,
      expansionProgress: leadingExpansionProgress,
      height: bounds.height
    )
    layoutTrailingButtons(
      revealWidth: trailingRevealWidth,
      expansionProgress: trailingExpansionProgress,
      height: bounds.height,
      boundsWidth: bounds.width
    )
  }

  private func layoutLeadingButtons(
    revealWidth: CGFloat,
    expansionProgress: CGFloat,
    height: CGFloat
  ) {
    guard !leadingActionButtons.isEmpty else { return }
    if revealWidth <= 0.5 {
      leadingActionButtons.forEach {
        $0.frame = .zero
        $0.alpha = 0
      }
      return
    }

    let targetIndex = leadingDisplaySpecs.firstIndex(where: \.isFullSwipeTarget)
      ?? max(0, leadingActionButtons.count - 1)
    if revealWidth <= leadingOpenWidth {
      let exposedRect = CGRect(x: 0, y: 0, width: revealWidth, height: height)
      var currentLeft: CGFloat = 0
      for button in leadingActionButtons {
        button.frame = CGRect(x: currentLeft, y: 0, width: leadingActionWidth, height: height)
        let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
        button.alpha = visibleWidth > 0.5 ? 1 : 0
        button.updateRevealWidth(visibleWidth, expansionProgress: 0)
        currentLeft += leadingActionWidth
      }
      return
    }

    let extraWidth = revealWidth - leadingOpenWidth
    let exposedRect = CGRect(x: 0, y: 0, width: revealWidth, height: height)
    var x: CGFloat = 0
    for (index, button) in leadingActionButtons.enumerated() {
      let width = leadingActionWidth + (index == targetIndex ? max(0, extraWidth) : 0)
      button.frame = CGRect(x: x, y: 0, width: width, height: height)
      button.alpha = 1
      let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
      button.updateRevealWidth(
        visibleWidth,
        expansionProgress: index == targetIndex ? expansionProgress : 0
      )
      x += width
    }
  }

  private func layoutTrailingButtons(
    revealWidth: CGFloat,
    expansionProgress: CGFloat,
    height: CGFloat,
    boundsWidth: CGFloat
  ) {
    guard !trailingActionButtons.isEmpty else { return }
    if revealWidth <= 0.5 {
      trailingActionButtons.forEach {
        $0.frame = .zero
        $0.alpha = 0
      }
      return
    }

    let targetIndex = trailingDisplaySpecs.firstIndex(where: \.isFullSwipeTarget) ?? 0
    if revealWidth <= trailingOpenWidth {
      let exposedRect = CGRect(
        x: boundsWidth - revealWidth,
        y: 0,
        width: revealWidth,
        height: height
      )
      var currentLeft = boundsWidth - trailingOpenWidth
      for button in trailingActionButtons {
        button.frame = CGRect(x: currentLeft, y: 0, width: trailingActionWidth, height: height)
        let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
        button.alpha = visibleWidth > 0.5 ? 1 : 0
        button.updateRevealWidth(visibleWidth, expansionProgress: 0)
        currentLeft += trailingActionWidth
      }
      return
    }

    let extraWidth = max(0, revealWidth - trailingOpenWidth)
    let widths = trailingActionButtons.enumerated().map { index, _ in
      trailingActionWidth + (index == targetIndex ? extraWidth : 0)
    }
    let exposedRect = CGRect(
      x: boundsWidth - revealWidth,
      y: 0,
      width: revealWidth,
      height: height
    )
    var currentRight = boundsWidth
    for (index, button) in trailingActionButtons.enumerated().reversed() {
      let width = widths[index]
      button.frame = CGRect(x: currentRight - width, y: 0, width: width, height: height)
      button.alpha = 1
      let visibleWidth = max(0, button.frame.intersection(exposedRect).width)
      button.updateRevealWidth(
        visibleWidth,
        expansionProgress: index == targetIndex ? expansionProgress : 0
      )
      currentRight -= width
    }
  }

  private var leadingActionWidth: CGFloat { 72 }
  private var trailingActionWidth: CGFloat { 74 }
  private var leadingOpenWidth: CGFloat { CGFloat(leadingDisplaySpecs.count) * leadingActionWidth }
  private var trailingOpenWidth: CGFloat { CGFloat(trailingDisplaySpecs.count) * trailingActionWidth }
  private var swipeActivationThreshold: CGFloat { 12 }
  private var leadingFullSwipeTriggerDistance: CGFloat {
    min(bounds.width - 24, max(leadingOpenWidth + 18, bounds.width * 0.58))
  }
  private var trailingFullSwipeTriggerDistance: CGFloat {
    min(bounds.width - 24, max(trailingOpenWidth + 18, bounds.width * 0.58))
  }

  private func expansionProgress(revealWidth: CGFloat, openWidth: CGFloat) -> CGFloat {
    guard revealWidth > openWidth else { return 0 }
    let denominator = max(1, bounds.width - openWidth)
    return clamp((revealWidth - openWidth) / denominator)
  }

  private func updateActionsMask(_ maskLayer: CALayer, visibleRect: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(UIView.inheritedAnimationDuration <= 0)
    maskLayer.frame = visibleRect
    CATransaction.commit()
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    min(1, max(0, value))
  }

}

/// Compact one/two-tick renderer shared by every Home cell configuration. One tick is
/// sent/delivered; two ticks are read. Drawing the paths avoids font-dependent spacing
/// and keeps the mark crisp at the small list-row size.
private func homeStatusCheckImage(double: Bool, color: UIColor) -> UIImage {
  let size = CGSize(width: 20, height: 14)
  return UIGraphicsImageRenderer(size: size).image { context in
    // ~7.5pt visual height: still balanced with the adjacent 13pt date, but a touch
    // quieter than the first enlarged pass. The old 0.60 scale was only ~5.5pt tall.
    let scale: CGFloat = 0.82
    let baseX: CGFloat = 0.16
    let baseY = (size.height - (24 * scale)) * 0.5
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: baseX + x * scale, y: baseY + y * scale)
    }

    color.setStroke()
    let first = UIBezierPath()
    if double {
      first.move(to: point(4, 12.9))
      first.addLine(to: point(7.14286, 16.5))
      first.addLine(to: point(15, 7.5))
    } else {
      first.move(to: point(4, 12))
      first.addLine(to: point(8.94975, 16.9497))
      first.addLine(to: point(19.5572, 6.34326))
    }
    first.lineWidth = (double ? 1.5 : 1.7) * scale
    first.lineCapStyle = .round
    first.lineJoinStyle = .round
    first.stroke()

    if double {
      let second = UIBezierPath()
      second.move(to: point(20, 7.5625))
      second.addLine(to: point(11.4283, 16.5625))
      second.addLine(to: point(11, 16))
      second.lineWidth = 1.5 * scale
      second.lineCapStyle = .round
      second.lineJoinStyle = .round
      second.stroke()
    }
    context.cgContext.flush()
  }.withRenderingMode(.alwaysOriginal)
}

private final class ChatHomeSwipeActionButton: UIButton {
  private let tileView = ChatHomeSwipeActionTileView()
  private(set) var spec: ChatHomeSwipeActionSpec?
  private var edge: ChatHomeSwipeEdge = .trailing
  private var currentRevealWidth: CGFloat = 0
  private var currentExpansionProgress: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerRadius = 0
    adjustsImageWhenHighlighted = false
    showsTouchWhenHighlighted = false
    addSubview(tileView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    tileView.frame = bounds
    tileView.updateRevealWidth(currentRevealWidth, expansionProgress: currentExpansionProgress)
  }

  func configure(spec: ChatHomeSwipeActionSpec, edge: ChatHomeSwipeEdge) {
    self.spec = spec
    self.edge = edge
    currentRevealWidth = 0
    currentExpansionProgress = 0
    backgroundColor = .clear
    tileView.configure(spec: spec, edge: edge)
    setNeedsLayout()
  }

  func updateRevealWidth(_ width: CGFloat, expansionProgress: CGFloat) {
    currentRevealWidth = width
    currentExpansionProgress = expansionProgress
    tileView.frame = bounds
    tileView.updateRevealWidth(width, expansionProgress: expansionProgress)
  }
}

private final class ChatHomeSwipeActionTileView: UIView {
  private let blurView = UIVisualEffectView(effect: nil)
  private let stackView = UIStackView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private var stackLeadingConstraint: NSLayoutConstraint?
  private var stackTrailingConstraint: NSLayoutConstraint?
  private var iconWidthConstraint: NSLayoutConstraint?
  private var iconHeightConstraint: NSLayoutConstraint?
  private var spec: ChatHomeSwipeActionSpec?
  private var edge: ChatHomeSwipeEdge = .trailing

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    layer.cornerRadius = 0

    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      blurView.effect = glass
    } else {
      blurView.effect = UIBlurEffect(style: .systemThinMaterial)
    }
    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)

    iconView.contentMode = .scaleAspectFit
    iconView.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 1
    titleLabel.adjustsFontSizeToFitWidth = true
    titleLabel.minimumScaleFactor = 0.75

    stackView.axis = .vertical
    stackView.alignment = .center
    stackView.distribution = .fill
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.addArrangedSubview(iconView)
    stackView.addArrangedSubview(titleLabel)

    addSubview(stackView)

    let stackLeadingConstraint = stackView.leadingAnchor.constraint(
      greaterThanOrEqualTo: leadingAnchor,
      constant: 8
    )
    let stackTrailingConstraint = stackView.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor,
      constant: -8
    )
    let iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 30)
    let iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 30)
    self.stackLeadingConstraint = stackLeadingConstraint
    self.stackTrailingConstraint = stackTrailingConstraint
    self.iconWidthConstraint = iconWidthConstraint
    self.iconHeightConstraint = iconHeightConstraint

    let centerXConstraint = stackView.centerXAnchor.constraint(equalTo: centerXAnchor)
    let centerYConstraint = stackView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1)
    centerXConstraint.priority = .defaultHigh
    centerYConstraint.priority = .defaultHigh
    stackLeadingConstraint.priority = .defaultHigh
    stackTrailingConstraint.priority = .defaultHigh

    NSLayoutConstraint.activate([
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
      centerXConstraint,
      centerYConstraint,
      stackLeadingConstraint,
      stackTrailingConstraint,
      iconWidthConstraint,
      iconHeightConstraint,
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(spec: ChatHomeSwipeActionSpec, edge: ChatHomeSwipeEdge) {
    self.spec = spec
    self.edge = edge
    backgroundColor = .clear
    iconView.tintColor = UIColor.label
    titleLabel.text = spec.title
    titleLabel.textColor = UIColor.label
    titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
    let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
    iconView.image = UIImage(systemName: spec.systemImageName, withConfiguration: config)?
      .withRenderingMode(.alwaysTemplate)
    updateRevealWidth(bounds.width, expansionProgress: 0)
  }

  func updateRevealWidth(_ width: CGFloat, expansionProgress: CGFloat) {
    let clampedWidth = max(0.0, width)
    let horizontalInset = min(8.0, floor(clampedWidth * 0.25))
    stackLeadingConstraint?.constant = horizontalInset
    stackTrailingConstraint?.constant = -horizontalInset
    let iconSide = min(30.0, max(0.0, clampedWidth - (horizontalInset * 2.0)))
    iconWidthConstraint?.constant = iconSide
    iconHeightConstraint?.constant = iconSide

    let titleProgress = clamp((width - 42) / 16)

    stackView.spacing = 5
    stackView.alpha = clampedWidth > 0.5 ? 1 : 0
    stackView.transform = .identity
    titleLabel.isHidden = titleProgress <= 0.01
    titleLabel.alpha = titleProgress
    titleLabel.transform = .identity
    iconView.alpha = iconSide > 0.5 ? 1 : 0
    iconView.transform = .identity
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    min(1, max(0, value))
  }
}
