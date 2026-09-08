import UIKit

private let chatContextHoldDebugLogs = true
/// Near-zero scale for picker/menu birth and collapse; animate to/from identity.
private let chatContextMenuCollapsedScale: CGFloat = 0.001

public protocol ChatContextMenuOverlayDelegate: AnyObject {
  func contextMenuDidDismiss(overlay: ChatContextMenuOverlay)
  func contextMenuDidSelectReaction(_ reaction: String, messageId: String, sourcePoint: CGPoint?)
  func contextMenuDidSelectAction(_ actionId: String, messageId: String)
}

// MARK: - Glass Helper

/// Creates a UIVisualEffectView that uses real UIGlassEffect on iOS 26+,
/// and falls back to UIBlurEffect on older iOS versions.
func makeChatContextLiquidGlassView(
  style: UIBlurEffect.Style = .systemMaterial,
  cornerRadius: CGFloat,
  capsuleCorners: Bool = false,
  interactive: Bool = false
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: nil)
  view.backgroundColor = .clear
  view.contentView.backgroundColor = .clear
  view.layer.borderWidth = 0
  view.layer.borderColor = UIColor.clear.cgColor
  if #available(iOS 26.0, *) {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    effect.tintColor = .clear
    view.effect = effect
    if capsuleCorners {
      view.cornerConfiguration = .capsule()
    } else {
      view.layer.cornerRadius = cornerRadius
      view.layer.cornerCurve = .continuous
    }
  } else {
    view.effect = UIBlurEffect(style: style)
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
  }
  view.clipsToBounds = true
  return view
}

private func makeBlurMaterialView(
  style: UIBlurEffect.Style,
  cornerRadius: CGFloat
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
  view.backgroundColor = .clear
  view.contentView.backgroundColor = .clear
  view.layer.cornerRadius = cornerRadius
  view.layer.cornerCurve = .continuous
  view.layer.borderWidth = 0
  view.layer.borderColor = UIColor.clear.cgColor
  view.clipsToBounds = true
  return view
}

struct ChatReactionDetailActor {
  let id: String
  let displayName: String
  let subtitle: String
  let emoji: String
  let avatarURL: String?

  init(
    id: String,
    displayName: String,
    subtitle: String,
    emoji: String,
    avatarURL: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.subtitle = subtitle
    self.emoji = emoji
    self.avatarURL = avatarURL
  }
}

final class ChatReactionDetailOverlay: UIView {
  var onDismiss: (() -> Void)?
  var onActorSelected: ((ChatReactionDetailActor) -> Void)?
  var onRemoveReaction: (() -> Void)?

  /// Set when hosted inside the context menu: the card follows the pill instead of
  /// centring on screen, and the host's glass provides the backdrop.
  var anchorRect: CGRect? {
    didSet { applyAnchor() }
  }

  private let backdropView = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let dimView = UIView()
  private let dismissControl = UIControl()
  private let contentView = UIView()
  private let emojiLabel = UILabel()
  private let selectorGlass = makeChatContextLiquidGlassView(
    style: .systemThinMaterialDark, cornerRadius: 26, capsuleCorners: true)
  private let selectorScrollView = UIScrollView()
  private let selectorStack = UIStackView()
  private let actorCard = makeChatContextLiquidGlassView(
    style: .systemMaterialDark, cornerRadius: 24)
  private let avatarView = ChatAvatarNodeView()
  private let actorNameLabel = UILabel()
  private let actorSubtitleLabel = UILabel()
  private let cardEmojiLabel = UILabel()
  private let removeButton = UIButton(type: .system)
  private var actors: [ChatReactionDetailActor] = []
  private var selectedActorID: String?
  private var fallbackEmoji: String
  private var isDismissing = false
  private var contentCenterY: NSLayoutConstraint?
  private var contentTop: NSLayoutConstraint?
  private var removeTopConstraint: NSLayoutConstraint?
  private var removeHeightConstraint: NSLayoutConstraint?

  init(emoji: String, actors: [ChatReactionDetailActor] = [], selectedActorID: String? = nil) {
    self.fallbackEmoji = emoji
    self.actors = actors
    self.selectedActorID = selectedActorID
    super.init(frame: .zero)
    setupReactionDetailViews()
    update(emoji: emoji, actors: actors, selectedActorID: selectedActorID, animated: false)
  }

  required init?(coder: NSCoder) { nil }

  func update(
    emoji: String,
    actors: [ChatReactionDetailActor],
    selectedActorID: String? = nil,
    animated: Bool = true
  ) {
    fallbackEmoji = emoji
    self.actors = actors
    let preferredID = selectedActorID ?? self.selectedActorID
    let preferredActor = preferredID.flatMap { id in actors.first(where: { $0.id == id }) }
    self.selectedActorID = preferredActor?.id ?? actors.first?.id

    let changes = {
      self.rebuildActorSelector()
      self.renderSelectedActor()
    }
    if animated, window != nil {
      UIView.transition(
        with: contentView,
        duration: 0.18,
        options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent],
        animations: changes
      )
    } else {
      changes()
    }
  }

  func present(in hostView: UIView, animated: Bool = true) {
    frame = hostView.bounds
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    applyAnchor()
    alpha = 1
    contentView.transform = .identity
    isUserInteractionEnabled = true
    isDismissing = false
    hostView.addSubview(self)
    guard animated else { return }
    alpha = 0
    contentView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
    UIView.animate(
      withDuration: 0.24,
      delay: 0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.alpha = 1
      self.contentView.transform = .identity
    }
  }

  func dismiss(animated: Bool = true) {
    guard !isDismissing else { return }
    isDismissing = true
    isUserInteractionEnabled = false
    let completion: (Bool) -> Void = { _ in
      self.removeFromSuperview()
      self.onDismiss?()
    }
    guard animated else {
      completion(true)
      return
    }
    UIView.animate(
      withDuration: 0.18,
      delay: 0,
      options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.alpha = 0
      self.contentView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
    } completion: { finished in
      completion(finished)
    }
  }

  private func setupReactionDetailViews() {
    backgroundColor = .clear
    backdropView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backdropView)

    dimView.backgroundColor = UIColor.black.withAlphaComponent(0.50)
    dimView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dimView)

    dismissControl.translatesAutoresizingMaskIntoConstraints = false
    dismissControl.accessibilityLabel = "Close reaction details"
    dismissControl.accessibilityTraits = .button
    dismissControl.addTarget(self, action: #selector(didTapBackdrop), for: .touchUpInside)
    addSubview(dismissControl)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentView)

    emojiLabel.font = UIFont.systemFont(ofSize: 88)
    emojiLabel.textAlignment = .center
    emojiLabel.adjustsFontSizeToFitWidth = true
    emojiLabel.minimumScaleFactor = 0.75
    emojiLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(emojiLabel)

    selectorGlass.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(selectorGlass)

    selectorScrollView.showsHorizontalScrollIndicator = false
    selectorScrollView.alwaysBounceHorizontal = false
    selectorScrollView.translatesAutoresizingMaskIntoConstraints = false
    selectorGlass.contentView.addSubview(selectorScrollView)

    selectorStack.axis = .horizontal
    selectorStack.spacing = 6
    selectorStack.alignment = .center
    selectorStack.translatesAutoresizingMaskIntoConstraints = false
    selectorScrollView.addSubview(selectorStack)

    actorCard.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(actorCard)
    setupActorCard()

    removeButton.translatesAutoresizingMaskIntoConstraints = false
    removeButton.setTitle("Remove my reaction", for: .normal)
    removeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    removeButton.setTitleColor(UIColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1.0), for: .normal)
    removeButton.backgroundColor = UIColor.white.withAlphaComponent(0.10)
    removeButton.layer.cornerRadius = 22
    removeButton.layer.cornerCurve = .continuous
    removeButton.isHidden = true
    removeButton.addTarget(self, action: #selector(didTapRemove), for: .touchUpInside)
    contentView.addSubview(removeButton)

    let guide = selectorScrollView.contentLayoutGuide
    let frameGuide = selectorScrollView.frameLayoutGuide
    let centerY = contentView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12)
    contentCenterY = centerY
    let top = contentView.topAnchor.constraint(equalTo: topAnchor, constant: 0)
    contentTop = top
    let removeTop = removeButton.topAnchor.constraint(equalTo: actorCard.bottomAnchor, constant: 0)
    removeTopConstraint = removeTop
    let removeHeight = removeButton.heightAnchor.constraint(equalToConstant: 0)
    removeHeightConstraint = removeHeight
    NSLayoutConstraint.activate([
      backdropView.topAnchor.constraint(equalTo: topAnchor),
      backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
      backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dimView.topAnchor.constraint(equalTo: topAnchor),
      dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
      dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dismissControl.topAnchor.constraint(equalTo: topAnchor),
      dismissControl.bottomAnchor.constraint(equalTo: bottomAnchor),
      dismissControl.leadingAnchor.constraint(equalTo: leadingAnchor),
      dismissControl.trailingAnchor.constraint(equalTo: trailingAnchor),

      contentView.centerXAnchor.constraint(equalTo: centerXAnchor),
      centerY,
      contentView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
      contentView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
      contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

      emojiLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
      emojiLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      emojiLabel.widthAnchor.constraint(equalToConstant: 116),
      emojiLabel.heightAnchor.constraint(equalToConstant: 116),

      selectorGlass.topAnchor.constraint(equalTo: emojiLabel.bottomAnchor, constant: 18),
      selectorGlass.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      selectorGlass.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor),
      selectorGlass.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
      selectorGlass.widthAnchor.constraint(lessThanOrEqualToConstant: 336),
      selectorGlass.heightAnchor.constraint(equalToConstant: 52),

      selectorScrollView.topAnchor.constraint(equalTo: selectorGlass.contentView.topAnchor),
      selectorScrollView.bottomAnchor.constraint(equalTo: selectorGlass.contentView.bottomAnchor),
      selectorScrollView.leadingAnchor.constraint(equalTo: selectorGlass.contentView.leadingAnchor),
      selectorScrollView.trailingAnchor.constraint(equalTo: selectorGlass.contentView.trailingAnchor),
      selectorStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 6),
      selectorStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -6),
      selectorStack.topAnchor.constraint(equalTo: guide.topAnchor),
      selectorStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
      selectorStack.heightAnchor.constraint(equalTo: frameGuide.heightAnchor),

      actorCard.topAnchor.constraint(equalTo: selectorGlass.bottomAnchor, constant: 14),
      actorCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      actorCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      actorCard.heightAnchor.constraint(equalToConstant: 82),

      removeTop,
      removeButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      removeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      removeHeight,
      removeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    let contentWidth = contentView.widthAnchor.constraint(equalToConstant: 340)
    contentWidth.priority = .defaultHigh
    contentWidth.isActive = true
    let selectorWidth = selectorGlass.widthAnchor.constraint(
      equalTo: selectorStack.widthAnchor, constant: 12)
    selectorWidth.priority = .defaultHigh
    selectorWidth.isActive = true
  }

  private func setupActorCard() {
    avatarView.translatesAutoresizingMaskIntoConstraints = false
    actorCard.contentView.addSubview(avatarView)

    actorNameLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    actorNameLabel.textColor = .white
    actorNameLabel.translatesAutoresizingMaskIntoConstraints = false
    actorCard.contentView.addSubview(actorNameLabel)

    actorSubtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    actorSubtitleLabel.textColor = UIColor.white.withAlphaComponent(0.68)
    actorSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    actorCard.contentView.addSubview(actorSubtitleLabel)

    cardEmojiLabel.font = UIFont.systemFont(ofSize: 25)
    cardEmojiLabel.textAlignment = .center
    cardEmojiLabel.translatesAutoresizingMaskIntoConstraints = false
    actorCard.contentView.addSubview(cardEmojiLabel)

    NSLayoutConstraint.activate([
      avatarView.leadingAnchor.constraint(equalTo: actorCard.contentView.leadingAnchor, constant: 14),
      avatarView.centerYAnchor.constraint(equalTo: actorCard.contentView.centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: 46),
      avatarView.heightAnchor.constraint(equalToConstant: 46),

      actorNameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
      actorNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardEmojiLabel.leadingAnchor, constant: -8),
      actorNameLabel.bottomAnchor.constraint(equalTo: actorCard.contentView.centerYAnchor, constant: -2),
      actorSubtitleLabel.leadingAnchor.constraint(equalTo: actorNameLabel.leadingAnchor),
      actorSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardEmojiLabel.leadingAnchor, constant: -8),
      actorSubtitleLabel.topAnchor.constraint(equalTo: actorCard.contentView.centerYAnchor, constant: 3),
      cardEmojiLabel.trailingAnchor.constraint(equalTo: actorCard.contentView.trailingAnchor, constant: -16),
      cardEmojiLabel.centerYAnchor.constraint(equalTo: actorCard.contentView.centerYAnchor),
      cardEmojiLabel.widthAnchor.constraint(equalToConstant: 34),
      cardEmojiLabel.heightAnchor.constraint(equalToConstant: 34),
    ])
  }

  private func rebuildActorSelector() {
    for arranged in selectorStack.arrangedSubviews {
      selectorStack.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }
    if actors.isEmpty {
      let loading = ChatReactionDetailActorControl(emoji: fallbackEmoji)
      selectorStack.addArrangedSubview(loading)
      return
    }
    for actor in actors {
      let control = ChatReactionDetailActorControl(actor: actor)
      control.isSelected = actor.id == selectedActorID
      control.addTarget(self, action: #selector(didSelectActor(_:)), for: .touchUpInside)
      selectorStack.addArrangedSubview(control)
    }
  }

  private func renderSelectedActor() {
    guard let actor = actors.first(where: { $0.id == selectedActorID }) else {
      emojiLabel.text = fallbackEmoji
      actorNameLabel.text = "Loading reactions…"
      actorSubtitleLabel.text = "Reaction details will appear here"
      cardEmojiLabel.text = fallbackEmoji
      avatarView.configure(
        with: Self.avatarDescriptor(name: "Reaction", id: nil, avatarURL: nil),
        isDark: true,
        renderingSide: 46
      )
      return
    }
    emojiLabel.text = actor.emoji
    actorNameLabel.text = actor.displayName
    actorSubtitleLabel.text = actor.subtitle
    cardEmojiLabel.text = actor.emoji
    avatarView.configure(
      with: Self.avatarDescriptor(
        name: actor.displayName, id: actor.id, avatarURL: actor.avatarURL),
      isDark: true,
      renderingSide: 46
    )
  }

  /// Hosted inside the context menu the glass is already painted, so drop our own.
  func setChromeHidden(_ hidden: Bool) {
    backdropView.isHidden = hidden
    dimView.isHidden = hidden
  }

  func setRemoveActionVisible(_ visible: Bool) {
    removeButton.isHidden = !visible
    removeTopConstraint?.constant = visible ? 12 : 0
    removeHeightConstraint?.constant = visible ? 44 : 0
    applyAnchor()
    setNeedsLayout()
  }

  /// Hangs the card off the pill (below it, or above when there is no room).
  private func applyAnchor() {
    guard let rect = anchorRect, bounds.height > 1 else {
      contentTop?.isActive = false
      contentCenterY?.isActive = true
      return
    }
    contentCenterY?.isActive = false
    let cardHeight = 282.0 + (removeButton.isHidden ? 0.0 : 56.0)
    let below = rect.maxY + 14
    let top =
      below + cardHeight > bounds.height - safeAreaInsets.bottom - 16
      ? max(safeAreaInsets.top + 12, rect.minY - cardHeight - 14)
      : below
    contentTop?.constant = top
    contentTop?.isActive = true
  }

  @objc private func didTapBackdrop() {
    dismiss()
  }

  @objc private func didTapRemove() {
    onRemoveReaction?()
  }

  @objc private func didSelectActor(_ sender: ChatReactionDetailActorControl) {
    guard let actorID = sender.actorID,
      let actor = actors.first(where: { $0.id == actorID })
    else { return }
    selectedActorID = actor.id
    for case let control as ChatReactionDetailActorControl in selectorStack.arrangedSubviews {
      control.isSelected = control.actorID == actor.id
    }
    renderSelectedActor()
    onActorSelected?(actor)
  }

  fileprivate static func avatarDescriptor(
    name: String,
    id: String?,
    avatarURL: String?
  ) -> ChatAvatarDescriptor {
    ChatAvatarDescriptor(
      title: name,
      rawAvatarURI: avatarURL,
      peerUserId: id,
      chatId: nil,
      kind: .standard,
      isGroup: false,
      members: [],
      preferPushAvatar: false,
      gradientColors: nil
    )
  }
}

private final class ChatReactionDetailActorControl: UIControl {
  let actorID: String?
  private let avatarView = ChatAvatarNodeView()
  private let emojiLabel = UILabel()

  init(actor: ChatReactionDetailActor) {
    self.actorID = actor.id
    super.init(frame: .zero)
    setup(emoji: actor.emoji, name: actor.displayName, id: actor.id, avatarURL: actor.avatarURL)
    accessibilityLabel = "\(actor.displayName), \(actor.emoji)"
  }

  init(emoji: String) {
    self.actorID = nil
    super.init(frame: .zero)
    setup(emoji: emoji, name: "Reaction", id: nil, avatarURL: nil)
    isUserInteractionEnabled = false
    accessibilityLabel = "Loading reaction details"
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    avatarView.prepareForReuse()
  }

  override var isSelected: Bool {
    didSet {
      backgroundColor = isSelected ? UIColor.white.withAlphaComponent(0.14) : .clear
    }
  }

  private func setup(emoji: String, name: String, id: String?, avatarURL: String?) {
    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerRadius = 20
    layer.cornerCurve = .continuous
    accessibilityTraits = .button

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatarView)
    avatarView.configure(
      with: ChatReactionDetailOverlay.avatarDescriptor(
        name: name, id: id, avatarURL: avatarURL),
      isDark: true,
      renderingSide: 32
    )

    emojiLabel.text = emoji
    emojiLabel.font = UIFont.systemFont(ofSize: 15)
    emojiLabel.textAlignment = .center
    emojiLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(emojiLabel)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 46),
      heightAnchor.constraint(equalToConstant: 40),
      avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      avatarView.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: 32),
      avatarView.heightAnchor.constraint(equalToConstant: 32),
      emojiLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
      emojiLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1),
      emojiLabel.widthAnchor.constraint(equalToConstant: 20),
      emojiLabel.heightAnchor.constraint(equalToConstant: 20),
    ])
  }
}

// MARK: - ChatContextMenuOverlay

public final class ChatContextMenuOverlay: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  let messageId: String

  // The bubble snapshot (bubble+tail only, already positioned in window coords)
  private let bubbleSnapshot: UIView
  // Stable pre-extraction pixels. Capturing after the overlay dismisses races
  // Core Animation's hidden extracted state and can produce a transparent image.
  private let deletionBubbleImage: UIImage?
  // The bubble's original frame in window coords (before any shifting)
  private let originalBubbleFrame: CGRect
  private let bubbleIsMe: Bool
  /// Reaction pill inside `bubbleSnapshot`, in the snapshot's own coords.
  private let bubbleReactionRect: CGRect?
  /// Which part of the cell the long press landed on. Drives which menu is shown.
  let holdTarget: ChatContextMenuHoldTarget
  /// Emoji this message currently carries, so the picker can mark it selected.
  let currentReactionEmoji: String?

  private let appearance: ChatListAppearance

  // Full-screen native glass background (same as Telegram / UIContextMenuInteraction)
  private let backgroundGlassView: UIVisualEffectView

  // Reaction picker pill
  private let reactionPicker: ReactionPickerView
  /// Suppresses the emoji row entirely — see the failed-send note in `init`.
  private var hidesReactionPicker = false

  // Action menu card
  private let contextMenu: ContextMenuView

  /// A real control over the pill: the snapshot bakes the pill in, so a gesture on
  /// the overlay alone cannot separate a tap on it from a tap on the bubble.
  private let reactionHitControl = UIControl()
  /// Shown instead of the action menu when the hold landed on the pill.
  private var reactionDetail: ChatReactionDetailOverlay?

  private var isDismissing = false
  private var ignoreBackgroundTapUntil: CFTimeInterval = 0
  private var enableControlsWorkItem: DispatchWorkItem?
  private var isSelectingReaction = false
  private var entryAnimator: UIViewPropertyAnimator?

  private func holdDebugLog(_ message: String) {
    guard chatContextHoldDebugLogs else { return }
    NSLog("[ChatContextHold] %@", message)
  }

  // MARK: - Init

  init(
    messageId: String,
    bubbleSnapshot: UIView,
    deletionBubbleImage: UIImage?,
    bubbleFrame: CGRect,
    bubbleIsMe: Bool,
    bubbleReactionRect: CGRect? = nil,
    holdTarget: ChatContextMenuHoldTarget = .bubble,
    currentReactionEmoji: String? = nil,
    appearance: ChatListAppearance,
    showResendAction: Bool,
    showRegenerateAction: Bool = false,
    showEditAction: Bool = false,
    showEditedInfo: Bool = false,
    editedAtMs: Int64? = nil,
    showSaveImageAction: Bool = false,
    showCopyLinkAction: Bool = false,
    showForwardAction: Bool = false,
    showReportAction: Bool = false,
    restrictSavingContent: Bool = false,
    failedSendOnly: Bool = false
  ) {
    self.messageId = messageId
    self.bubbleSnapshot = bubbleSnapshot
    self.deletionBubbleImage = deletionBubbleImage
    self.originalBubbleFrame = bubbleFrame
    self.bubbleIsMe = bubbleIsMe
    self.bubbleReactionRect = bubbleReactionRect
    self.holdTarget = holdTarget
    self.currentReactionEmoji = currentReactionEmoji
    self.appearance = appearance

    // Full-screen background: native system glass blur
    self.backgroundGlassView = UIVisualEffectView(
      effect: UIBlurEffect(style: .systemUltraThinMaterialDark))

    let colorOverlay = UIView()
    let isDarkMode = appearance.isDark
    let overlayBaseColor: UIColor = .black
    let overlayAlpha: CGFloat = isDarkMode ? 0.64 : 0.52
    colorOverlay.backgroundColor = overlayBaseColor.withAlphaComponent(overlayAlpha)
    colorOverlay.translatesAutoresizingMaskIntoConstraints = false
    self.backgroundGlassView.contentView.addSubview(colorOverlay)
    NSLayoutConstraint.activate([
      colorOverlay.topAnchor.constraint(equalTo: self.backgroundGlassView.contentView.topAnchor),
      colorOverlay.bottomAnchor.constraint(
        equalTo: self.backgroundGlassView.contentView.bottomAnchor),
      colorOverlay.leadingAnchor.constraint(
        equalTo: self.backgroundGlassView.contentView.leadingAnchor),
      colorOverlay.trailingAnchor.constraint(
        equalTo: self.backgroundGlassView.contentView.trailingAnchor),
    ])

    self.reactionPicker = ReactionPickerView(appearance: appearance, messageId: messageId)
    self.contextMenu = ContextMenuView(
      appearance: appearance,
      messageId: messageId,
      showResendAction: showResendAction,
      showRegenerateAction: showRegenerateAction,
      showEditAction: showEditAction,
      showEditedInfo: showEditedInfo,
      editedAtMs: editedAtMs,
      showSaveImageAction: showSaveImageAction,
      showCopyLinkAction: showCopyLinkAction,
      showForwardAction: showForwardAction,
      showReportAction: showReportAction,
      restrictSavingContent: restrictSavingContent,
      failedSendOnly: failedSendOnly
    )
    // No reactions on a message that was never delivered — there is nobody on the other
    // end to have reacted to, and a picker above a two-item menu is most of the chrome
    // for none of the meaning.
    // The reaction menu owns its own emoji row, so the quick picker would double it.
    self.hidesReactionPicker = failedSendOnly || holdTarget != .bubble

    super.init(frame: .zero)

    setupViews()
    setupGestures()
  }

  /// The emoji a tap on the pill toggles: the held one, else the message's own.
  private var pillEmoji: String? {
    if case let .reaction(emoji) = holdTarget { return emoji }
    return currentReactionEmoji
  }

  /// Feeds the reaction detail card once the list has resolved who reacted.
  func updateReactionDetail(
    actors: [ChatReactionDetailActor],
    selectedActorID: String? = nil
  ) {
    guard let reactionDetail, let emoji = pillEmoji else { return }
    reactionDetail.update(emoji: emoji, actors: actors, selectedActorID: selectedActorID)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    // Keep the resolved backdrop stable while glass is visible above it.
    backgroundGlassView.alpha = 1
    addSubview(backgroundGlassView)

    // 2. Bubble snapshot (already has correct frame in window coords)
    bubbleSnapshot.alpha = 0
    addSubview(bubbleSnapshot)

    reactionHitControl.backgroundColor = .clear
    reactionHitControl.isHidden = bubbleReactionRect == nil
    reactionHitControl.isUserInteractionEnabled = false
    reactionHitControl.accessibilityLabel = pillEmoji
    reactionHitControl.accessibilityTraits = .button
    reactionHitControl.addTarget(
      self, action: #selector(handleReactionPillTap), for: .touchUpInside)
    addSubview(reactionHitControl)

    // 3. Reaction picker (above bubble)
    reactionPicker.alpha = 1
    reactionPicker.delegate = self
    reactionPicker.onContentSizeChange = { [weak self] in
      guard let self, !self.isDismissing else { return }
      // Stop the entry animation to prevent frame/center conflicts during expand/collapse.
      self.entryAnimator?.stopAnimation(true)
      self.entryAnimator = nil
      // stopAnimation leaves mid-flight transforms; frames are only meaningful at identity.
      self.bubbleSnapshot.transform = .identity
      self.reactionPicker.transform = .identity
      self.contextMenu.transform = .identity
      _ = self.layoutMenus()
    }
    reactionPicker.setSelectedReaction(currentReactionEmoji)
    let pickerSize = reactionPicker.intrinsicContentSize
    reactionPicker.frame = CGRect(origin: .zero, size: pickerSize)
    reactionPicker.isHidden = hidesReactionPicker
    if !hidesReactionPicker { addSubview(reactionPicker) }

    // 4. Context menu (below or above bubble)
    contextMenu.alpha = 1
    contextMenu.delegate = self
    contextMenu.frame = CGRect(x: 0, y: 0, width: 220, height: 1)
    addSubview(contextMenu)

    setupReactionDetailIfNeeded()
  }

  /// A hold on the pill swaps the action list for the reaction detail card.
  private func setupReactionDetailIfNeeded() {
    guard case let .reaction(emoji) = holdTarget else { return }
    contextMenu.isHidden = true
    contextMenu.alpha = 0
    let detail = ChatReactionDetailOverlay(emoji: emoji, actors: seededDetailActors(emoji))
    detail.setChromeHidden(true)
    detail.setRemoveActionVisible(
      currentReactionEmoji.map { ChatReactionKey.matches($0, emoji) } ?? false)
    detail.onDismiss = { [weak self] in
      self?.animateOut(reason: "reactionDetailDismiss")
    }
    detail.onRemoveReaction = { [weak self] in
      guard let self else { return }
      self.contextMenuDidSelectReaction(
        emoji, messageId: self.messageId, sourcePoint: self.pillSourcePoint())
    }
    detail.alpha = 0
    addSubview(detail)
    reactionDetail = detail
  }

  /// Until the list feeds real actors, show the one reaction we already know about.
  private func seededDetailActors(_ emoji: String) -> [ChatReactionDetailActor] {
    guard let current = currentReactionEmoji, ChatReactionKey.matches(current, emoji) else {
      return []
    }
    return [
      ChatReactionDetailActor(
        id: "self", displayName: "You", subtitle: "Reacted with \(emoji)", emoji: emoji)
    ]
  }

  private func setupGestures() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    addGestureRecognizer(tap)
  }

  /// The pill is baked into the bubble snapshot, so hit-test the laid-out control
  /// first and fall back to snapshot coords before the first layout pass.
  private func pointHitsBubbleReaction(_ point: CGPoint) -> Bool {
    if !reactionHitControl.isHidden, reactionHitControl.frame.contains(point) { return true }
    guard let rect = bubbleReactionRect, bubbleSnapshot.superview === self else { return false }
    return rect.insetBy(dx: -6.0, dy: -6.0).contains(convert(point, to: bubbleSnapshot))
  }

  @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
    if isSelectingReaction { return }
    let now = CACurrentMediaTime()
    let point = gesture.location(in: self)
    if now < ignoreBackgroundTapUntil {
      holdDebugLog(
        "backgroundTap ignored point=\(NSCoder.string(for: point)) now=\(String(format: "%.3f", now)) until=\(String(format: "%.3f", ignoreBackgroundTapUntil))"
      )
      return
    }
    if pointHitsBubbleReaction(point) {
      holdDebugLog("reactionPillTap via gesture point=\(NSCoder.string(for: point))")
      handleReactionPillTap()
      return
    }
    holdDebugLog("backgroundTap accepted point=\(NSCoder.string(for: point))")
    animateOut(reason: "backgroundTap")
  }

  /// Tapping the applied reaction re-selects it, which the list reads as toggle-off.
  @objc private func handleReactionPillTap() {
    guard !isDismissing, !isSelectingReaction else { return }
    guard let emoji = pillEmoji else {
      holdDebugLog("reactionPillTap dismiss-only rect=\(bubbleReactionRect == nil ? "N" : "Y")")
      animateOut(reason: "reactionPillTap")
      return
    }
    holdDebugLog("reactionPillTap toggle emoji=\(emoji)")
    contextMenuDidSelectReaction(emoji, messageId: messageId, sourcePoint: pillSourcePoint())
  }

  /// Window-space centre of the pill, so the flight starts where the user touched.
  private func pillSourcePoint() -> CGPoint? {
    guard !reactionHitControl.isHidden else { return nil }
    let center = CGPoint(
      x: reactionHitControl.frame.midX, y: reactionHitControl.frame.midY)
    return convert(center, to: nil)
  }

  // MARK: - Layout

  private func layoutMenus() -> CGRect {
    let safeTop = safeAreaInsets.top + 10
    let safeBottom = bounds.height - safeAreaInsets.bottom - 10
    let safeLeft: CGFloat = 16
    let safeRight = bounds.width - 16

    // Measure reaction picker. Zero height and zero gap when it is suppressed, so the
    // menu sits against the bubble instead of leaving a hole where the emoji row was.
    let pickerExpanded = !hidesReactionPicker && reactionPicker.isExpanded

    // Measure context menu
    let menuWidth: CGFloat = min(220, bounds.width - 32)
    let menuHeight =
      contextMenu.isHidden
      ? 0
      : contextMenu.systemLayoutSizeFitting(
        CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height)
      ).height

    // Expanded, the panel scrolls inside a capped height so the bubble and the
    // action menu both stay on screen instead of being pushed off it.
    let panelRoom = safeBottom - safeTop - originalBubbleFrame.height - menuHeight - 34
    reactionPicker.expandedHeightLimit = max(
      200, min(ReactionPickerView.maxExpandedHeight, panelRoom))
    let pickerSize = hidesReactionPicker ? .zero : reactionPicker.intrinsicContentSize
    let pickerHeight = pickerSize.height
    let pickerGap: CGFloat = hidesReactionPicker ? 0 : 8
    // Keep the action menu visually attached to the bubble (Telegram-like spacing).
    let menuGap: CGFloat = 4

    // Horizontal alignment: align to bubble edge, then clamp to viewport.
    let isRightAligned = bubbleIsMe || originalBubbleFrame.midX > bounds.midX
    reactionPicker.setThinkingBlobDirection(isRightAligned: isRightAligned)

    // Reaction picker: align to bubble edge, clamped strictly to safe viewport
    let pickerWidth = min(pickerSize.width, bounds.width - 24)
    let targetPickerX =
      isRightAligned ? originalBubbleFrame.maxX - pickerWidth : originalBubbleFrame.minX
    let pickerX = max(safeLeft, min(safeRight - pickerWidth, targetPickerX))

    // Vertical placement prefers original bubble Y, then shifts minimally to fit picker+menu.
    var bubbleY = originalBubbleFrame.minY
    var pickerY = bubbleY - pickerHeight - pickerGap
    var menuY = bubbleY + originalBubbleFrame.height + menuGap

    let totalBottom = menuY + menuHeight
    // First, shift UP to ensure the context menu stays fully inside the safe area.
    if totalBottom > safeBottom {
      let shiftUp = totalBottom - safeBottom
      bubbleY -= shiftUp
      pickerY -= shiftUp
      menuY -= shiftUp
    }

    // Next, shift DOWN to ensure the reaction picker stays fully inside the safe area.
    // However, if we shift down too much, we will push the context menu back out of bounds,
    // which results in overlapping the bubble. Limit the shift down to the available space.
    if pickerY < safeTop {
      let desiredShiftDown = safeTop - pickerY
      let availableBottomSpace = max(0, safeBottom - (menuY + menuHeight))
      let allowedShiftDown = min(desiredShiftDown, availableBottomSpace)

      bubbleY += allowedShiftDown
      pickerY += allowedShiftDown
      menuY += allowedShiftDown
    }

    // Expanded and out of room above: pin the panel and hang the bubble off it.
    if pickerExpanded, pickerY < safeTop {
      pickerY = safeTop
      bubbleY = pickerY + pickerHeight + pickerGap
      menuY = bubbleY + originalBubbleFrame.height + menuGap
    }
    if !contextMenu.isHidden {
      contextMenu.alpha = 1.0
      contextMenu.isUserInteractionEnabled = true
    }

    reactionPicker.frame = CGRect(
      x: pickerX,
      y: max(safeTop, pickerY),  // Ensure picker doesn't go off-screen even if bubble is huge
      width: pickerWidth,
      height: pickerHeight
    )

    // Bubble: keep original X, shift Y to computed safe position.
    let finalBubbleFrame = CGRect(
      x: originalBubbleFrame.minX,
      y: bubbleY,
      width: originalBubbleFrame.width,
      height: originalBubbleFrame.height
    )
    bubbleSnapshot.frame = finalBubbleFrame

    // The pill rides inside the snapshot, so its tap target tracks the final frame.
    if let rect = bubbleReactionRect {
      reactionHitControl.frame =
        rect
        .offsetBy(dx: finalBubbleFrame.minX, dy: finalBubbleFrame.minY)
        .insetBy(dx: -6, dy: -6)
      reactionHitControl.isHidden = false
      insertSubview(reactionHitControl, aboveSubview: bubbleSnapshot)
    } else {
      reactionHitControl.isHidden = true
    }

    if let reactionDetail {
      reactionDetail.frame = bounds
      reactionDetail.anchorRect =
        reactionHitControl.isHidden ? finalBubbleFrame : reactionHitControl.frame
      bringSubviewToFront(reactionDetail)
    }

    // Context menu: align to bubble edge
    let menuX: CGFloat
    if isRightAligned {
      menuX = max(safeLeft, finalBubbleFrame.maxX - menuWidth)
    } else {
      menuX = min(safeRight - menuWidth, finalBubbleFrame.minX)
    }
    contextMenu.frame = CGRect(
      x: max(safeLeft, min(safeRight - menuWidth, menuX)),
      y: max(safeTop, min(safeBottom - menuHeight, menuY)),
      width: menuWidth,
      height: menuHeight
    )

    return finalBubbleFrame
  }

  /// Keep the extracted bubble and the existing glass card on-screen while the
  /// action list drills into delete scope. Only the card's inner content moves;
  /// its frame is remeasured in the same animation so this never reads as a
  /// second modal appearing on top of the context menu.
  func presentDeleteConfirmation(deleteForEveryoneTitle: String?) {
    guard !isDismissing else { return }
    holdDebugLog(
      "delete confirmation begin everyone=\(deleteForEveryoneTitle == nil ? "N" : "Y")")
    contextMenu.transitionToDeleteConfirmation(
      deleteForEveryoneTitle: deleteForEveryoneTitle
    ) { [weak self] in
      guard let self else { return }
      _ = self.layoutMenus()
      self.layoutIfNeeded()
    }
  }

  /// Returns the original bubble pixels at the original list slot, even though
  /// the extracted context-menu copy may have shifted vertically to fit menus.
  func deletionBubbleCapture(in targetView: UIView) -> (image: UIImage, frame: CGRect)? {
    guard let deletionBubbleImage else { return nil }
    let frameInTarget = convert(originalBubbleFrame, to: targetView)
    return (deletionBubbleImage, frameInTarget)
  }

  // MARK: - Animate In / Out

  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldOrigin = view.frame.origin
    view.layer.anchorPoint = anchorPoint
    let newOrigin = view.frame.origin
    let transition = CGPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)
    view.center = CGPoint(x: view.center.x - transition.x, y: view.center.y - transition.y)
  }

  func animateIn() {
    guard let window = window else { return }
    frame = window.bounds
    backgroundGlassView.frame = bounds

    // Place bubble at original position first (before layout shifts it)
    bubbleSnapshot.frame = originalBubbleFrame
    bubbleSnapshot.alpha = 1

    layoutIfNeeded()

    // Compute final layout (this shifts the bubble)
    let finalBubbleFrame = layoutMenus()
    let isRightAligned = bubbleIsMe || finalBubbleFrame.midX > bounds.midX
    let pickerFinalFrame = reactionPicker.frame
    let menuFinalFrame = contextMenu.frame

    // Keep interactions disabled briefly so the long-press release does not
    // immediately dismiss/select while the menu is animating in.
    let now = CACurrentMediaTime()
    ignoreBackgroundTapUntil = now + 0.65
    reactionPicker.isUserInteractionEnabled = false
    contextMenu.isUserInteractionEnabled = false
    reactionHitControl.isUserInteractionEnabled = false
    reactionDetail?.isUserInteractionEnabled = false
    enableControlsWorkItem?.cancel()
    let enableWork = DispatchWorkItem { [weak self] in
      guard let self = self, !self.isDismissing else { return }
      self.reactionPicker.isUserInteractionEnabled = true
      self.contextMenu.isUserInteractionEnabled = true
      self.reactionHitControl.isUserInteractionEnabled = true
      self.reactionDetail?.isUserInteractionEnabled = true
      self.holdDebugLog("controls enabled")
    }
    enableControlsWorkItem = enableWork
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: enableWork)
    holdDebugLog(
      "animateIn arm interactions now=\(String(format: "%.3f", now)) until=\(String(format: "%.3f", ignoreBackgroundTapUntil))"
    )

    // --- Bubble: continue from the cell's settled sink (0.95) — the menus
    // morph out of that state on the SAME spring, so nothing pops.
    let startCenter = CGPoint(x: originalBubbleFrame.midX, y: originalBubbleFrame.midY)
    let endCenter = CGPoint(x: finalBubbleFrame.midX, y: finalBubbleFrame.midY)
    bubbleSnapshot.bounds = CGRect(origin: .zero, size: originalBubbleFrame.size)
    bubbleSnapshot.center = startCenter
    bubbleSnapshot.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
    holdDebugLog(
      "animateIn start frame=\(NSCoder.string(for: originalBubbleFrame)) startCenter=\(NSCoder.string(for: startCenter)) endCenter=\(NSCoder.string(for: endCenter))"
    )

    // Anchor X is biased toward the bubble side but never pinned to the corner:
    // a 0/1 anchor with a small birth scale makes the far edge sweep almost the
    // whole width — that read as the menu "entering from the side" instead of
    // growing. A soft bias keeps the left/right identity while both edges
    // expand outward, so the motion reads as scale-up, not lateral entry.
    let pickerAnchorX: CGFloat = isRightAligned ? 0.65 : 0.35
    let menuAnchorX: CGFloat = isRightAligned ? 0.6 : 0.4

    // --- Reaction picker: bottom edge pinned just above the bubble, growing
    // upward/outward; the directional cue comes from the emoji cascade.
    reactionPicker.frame = pickerFinalFrame
    setAnchorPoint(CGPoint(x: pickerAnchorX, y: 1.0), for: reactionPicker)
    let pickerFinalCenter = reactionPicker.center
    reactionPicker.center = CGPoint(
      x: pickerFinalCenter.x,
      y: originalBubbleFrame.minY - 8
    )
    reactionPicker.transform = CGAffineTransform(
      scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
    reactionPicker.alpha = 1

    // --- Context menu: top edge pinned under the bubble, scaling up in place
    // as it pours downward — no horizontal travel.
    contextMenu.frame = menuFinalFrame
    setAnchorPoint(CGPoint(x: menuAnchorX, y: 0.0), for: contextMenu)
    let menuFinalCenter = contextMenu.center
    contextMenu.center = CGPoint(
      x: menuFinalCenter.x,
      y: originalBubbleFrame.maxY + 4
    )
    contextMenu.transform = CGAffineTransform(
      scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
    contextMenu.alpha = 1

    // One under-damped spring drives bubble, picker, and menu together: both
    // menus grow out of the bubble's edges with a visible expansion overshoot.
    entryAnimator = UIViewPropertyAnimator(duration: 0.38, dampingRatio: 0.78) {
      self.bubbleSnapshot.transform = .identity
      self.bubbleSnapshot.center = endCenter
      self.reactionPicker.transform = .identity
      self.reactionPicker.center = pickerFinalCenter
      self.contextMenu.transform = .identity
      self.contextMenu.center = menuFinalCenter
    }
    entryAnimator?.startAnimation()
    // Emoji tiles cascade in from the anchored side while the pill grows.
    reactionPicker.animateIconsIn(fromTrailing: isRightAligned)

    if let reactionDetail {
      reactionDetail.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
      UIView.animate(
        withDuration: 0.26, delay: 0.04, usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        reactionDetail.alpha = 1
        reactionDetail.transform = .identity
      }
    }
  }

  func animateOut(reason: String = "unknown", completion: (() -> Void)? = nil) {
    if isDismissing {
      completion?()
      return
    }
    isDismissing = true
    entryAnimator?.stopAnimation(true)
    entryAnimator = nil
    enableControlsWorkItem?.cancel()
    enableControlsWorkItem = nil
    reactionPicker.isUserInteractionEnabled = false
    contextMenu.isUserInteractionEnabled = false
    reactionHitControl.isUserInteractionEnabled = false
    reactionDetail?.isUserInteractionEnabled = false
    holdDebugLog("animateOut start reason=\(reason)")
    if let reactionDetail {
      UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn]) {
        reactionDetail.alpha = 0
        reactionDetail.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
      }
    }

    // Inverse of the open morph: menus collapse back toward their bubble-edge
    // anchors while the bubble returns to its row slot.
    UIView.animate(
      withDuration: 0.18, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.bubbleSnapshot.transform = .identity
      self.bubbleSnapshot.bounds = CGRect(origin: .zero, size: self.originalBubbleFrame.size)
      self.bubbleSnapshot.center = CGPoint(
        x: self.originalBubbleFrame.midX,
        y: self.originalBubbleFrame.midY
      )
      self.contextMenu.transform = CGAffineTransform(
        scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
      self.contextMenu.center = CGPoint(
        x: self.contextMenu.center.x,
        y: self.originalBubbleFrame.maxY + 4
      )
      self.reactionPicker.transform = CGAffineTransform(
        scaleX: chatContextMenuCollapsedScale, y: chatContextMenuCollapsedScale)
      self.reactionPicker.center = CGPoint(
        x: self.reactionPicker.center.x,
        y: self.originalBubbleFrame.minY - 8
      )
    } completion: { _ in
      self.contextMenu.isHidden = true
      self.reactionPicker.isHidden = true
      UIView.animate(
        withDuration: 0.10, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]
      ) {
        self.backgroundGlassView.alpha = 0
      } completion: { _ in
        self.removeFromSuperview()
        self.delegate?.contextMenuDidDismiss(overlay: self)
        completion?()
      }
    }
  }
}

// MARK: - UIGestureRecognizerDelegate

extension ChatContextMenuOverlay: UIGestureRecognizerDelegate {
  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    if isSelectingReaction { return false }
    let now = CACurrentMediaTime()
    if now < ignoreBackgroundTapUntil {
      holdDebugLog(
        "gestureShouldBegin ignored now=\(String(format: "%.3f", now)) until=\(String(format: "%.3f", ignoreBackgroundTapUntil))"
      )
      return false
    }
    // The detail card owns every tap while it is up, including its own dismiss.
    if reactionDetail != nil { return false }
    let point = gestureRecognizer.location(in: self)
    // The pill rides inside the bubble snapshot, so it must win over the bubble veto.
    if pointHitsBubbleReaction(point) { return true }
    // Only dismiss if tap is outside the bubble, picker, and menu
    if bubbleSnapshot.frame.contains(point) { return false }
    if !reactionPicker.isHidden, reactionPicker.frame.contains(point) { return false }
    if !contextMenu.isHidden, contextMenu.alpha > 0.01, contextMenu.frame.contains(point) {
      return false
    }
    return true
  }
}

// MARK: - ChatContextMenuOverlayDelegate (self-forwarding)

extension ChatContextMenuOverlay: ChatContextMenuOverlayDelegate {
  public func contextMenuDidDismiss(overlay: ChatContextMenuOverlay) {}

  public func contextMenuDidSelectReaction(
    _ reaction: String,
    messageId _: String,
    sourcePoint: CGPoint?
  ) {
    guard !isDismissing, !isSelectingReaction else { return }
    isSelectingReaction = true

    reactionPicker.isUserInteractionEnabled = false
    contextMenu.isUserInteractionEnabled = false

    // Prefer the tapped icon's window point; list coordinator owns the only flight.
    let sourceInWindow: CGPoint = {
      if let sourcePoint { return sourcePoint }
      let fallback = CGPoint(
        x: reactionPicker.frame.midX,
        y: reactionPicker.frame.minY + (reactionPicker.frame.height * 0.4)
      )
      return convert(fallback, to: nil)
    }()
    let captureMessageId = self.messageId

    delegate?.contextMenuDidSelectReaction(
      reaction,
      messageId: captureMessageId,
      sourcePoint: sourceInWindow
    )

    animateOut(reason: "reactionSelected") {
      self.isSelectingReaction = false
    }
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    delegate?.contextMenuDidSelectAction(actionId, messageId: messageId)
  }
}

// MARK: - Reaction Picker View

final class ChatReactionIconNode: UIControl {
  let emoji: String
  private let label = UILabel()

  /// Marks the reaction already on the message, so re-tapping reads as toggle-off.
  var isSelectedReaction = false {
    didSet {
      guard isSelectedReaction != oldValue else { return }
      backgroundColor =
        isSelectedReaction ? UIColor.white.withAlphaComponent(0.22) : .clear
      layer.borderWidth = isSelectedReaction ? 1.0 : 0.0
      layer.borderColor = UIColor.white.withAlphaComponent(0.34).cgColor
    }
  }

  init(emoji: String) {
    self.emoji = emoji
    super.init(frame: .zero)
    layer.cornerCurve = .continuous
    label.text = emoji
    label.font = UIFont.systemFont(ofSize: 28)
    label.textAlignment = .center
    label.isUserInteractionEnabled = false
    addSubview(label)
    accessibilityLabel = emoji
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds
    layer.cornerRadius = min(bounds.width, bounds.height) * 0.5
  }

  func playIntro(delay: TimeInterval) {
    alpha = 0.0
    transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
    UIView.animate(
      withDuration: 0.34, delay: delay, usingSpringWithDamping: 0.68,
      initialSpringVelocity: 0.0, options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.alpha = 1.0
      self.transform = .identity
    }
  }

  func playSelectionEffect() {
    // Pulse only — list coordinator owns flight and landing FX.
    UIView.animate(
      withDuration: 0.12, delay: 0.0, options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.transform = CGAffineTransform(scaleX: 1.28, y: 1.28)
    } completion: { _ in
      UIView.animate(withDuration: 0.18, delay: 0.0, options: .curveEaseOut) {
        self.transform = .identity
      }
    }
  }
}

final class ReactionPickerView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?
  /// Called inside expand/collapse animation so the overlay can relayout safely.
  var onContentSizeChange: (() -> Void)?

  private let blurView: UIVisualEffectView
  private let tailBlobLarge: UIVisualEffectView
  private let tailBlobSmall: UIVisualEffectView
  private let iconsHost = UIView()
  private var iconNodes: [ChatReactionIconNode] = []
  private let expandControl = UIButton(type: .system)
  private let panelView = ReactionEmojiPanelView()
  private var blurHeightConstraint: NSLayoutConstraint!
  private(set) var isExpanded = false
  private var blobsOnRightSide = false

  /// Set by the overlay from the room left above the bubble before it reads the size.
  var expandedHeightLimit: CGFloat = 340.0 {
    didSet {
      guard isExpanded, abs(oldValue - expandedHeightLimit) > 0.5 else { return }
      invalidateIntrinsicContentSize()
    }
  }

  /// Ceiling for the expanded panel; past this the grid scrolls instead of growing.
  static let maxExpandedHeight: CGFloat = 340.0

  private static let pickerButtonSize: CGFloat = 40.0
  private static let pickerSpacing: CGFloat = 4.0
  private static let pickerPadding: CGFloat = 8.0
  private static let pickerPillHeight: CGFloat = 52.0
  private static let pickerTailHeight: CGFloat = 12.0
  private static let pickerVerticalInset: CGFloat = 6.0

  let messageId: String

  private var gridColumns: Int {
    max(1, ChatReactionCatalog.collapsedEmojis.count + 1)
  }

  private var blurContentHeight: CGFloat {
    guard isExpanded else { return Self.pickerPillHeight }
    return min(Self.maxExpandedHeight, max(Self.pickerPillHeight, expandedHeightLimit))
  }

  private var preferredWidth: CGFloat {
    let cols = CGFloat(gridColumns)
    return cols * Self.pickerButtonSize
      + max(0, cols - 1) * Self.pickerSpacing
      + Self.pickerPadding * 2.0
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: preferredWidth, height: blurContentHeight + Self.pickerTailHeight)
  }

  init(appearance: ChatListAppearance, messageId: String) {
    self.messageId = messageId
    let blurStyle: UIBlurEffect.Style =
      appearance.isDark ? .systemMaterialDark : .systemMaterialLight
    self.blurView = makeBlurMaterialView(
      style: blurStyle,
      cornerRadius: Self.pickerPillHeight * 0.5
    )
    self.tailBlobLarge = makeBlurMaterialView(
      style: blurStyle,
      cornerRadius: 5.5
    )
    self.tailBlobSmall = makeBlurMaterialView(
      style: blurStyle,
      cornerRadius: 3.5
    )

    super.init(frame: .zero)

    clipsToBounds = false

    blurView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurView)
    addSubview(tailBlobLarge)
    addSubview(tailBlobSmall)

    iconsHost.translatesAutoresizingMaskIntoConstraints = false
    iconsHost.backgroundColor = .clear
    blurView.contentView.addSubview(iconsHost)

    blurHeightConstraint = blurView.heightAnchor.constraint(equalToConstant: Self.pickerPillHeight)

    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurHeightConstraint,

      iconsHost.topAnchor.constraint(
        equalTo: blurView.contentView.topAnchor, constant: Self.pickerVerticalInset),
      iconsHost.bottomAnchor.constraint(
        equalTo: blurView.contentView.bottomAnchor, constant: -Self.pickerVerticalInset),
      iconsHost.leadingAnchor.constraint(
        equalTo: blurView.contentView.leadingAnchor, constant: Self.pickerPadding),
      iconsHost.trailingAnchor.constraint(
        equalTo: blurView.contentView.trailingAnchor, constant: -Self.pickerPadding),
    ])

    tailBlobLarge.bounds = CGRect(x: 0.0, y: 0.0, width: 11.0, height: 11.0)
    tailBlobSmall.bounds = CGRect(x: 0.0, y: 0.0, width: 7.0, height: 7.0)
    tailBlobLarge.layer.borderWidth = 0
    tailBlobLarge.layer.borderColor = UIColor.clear.cgColor
    tailBlobSmall.layer.borderWidth = 0
    tailBlobSmall.layer.borderColor = UIColor.clear.cgColor

    for emoji in ChatReactionCatalog.collapsedEmojis {
      let node = ChatReactionIconNode(emoji: emoji)
      node.addTarget(self, action: #selector(didTapEmoji(_:)), for: .touchUpInside)
      iconsHost.addSubview(node)
      iconNodes.append(node)
    }

    configureExpandControl(isDark: appearance.isDark)
    iconsHost.addSubview(expandControl)

    panelView.translatesAutoresizingMaskIntoConstraints = false
    panelView.isDark = appearance.isDark
    panelView.alpha = 0.0
    panelView.isHidden = true
    panelView.onSelect = { [weak self] emoji, sourcePoint in
      guard let self else { return }
      self.delegate?.contextMenuDidSelectReaction(
        emoji, messageId: self.messageId, sourcePoint: sourcePoint)
    }
    blurView.contentView.addSubview(panelView)
    NSLayoutConstraint.activate([
      panelView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
      panelView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
      panelView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
      panelView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
    ])

    applyCollapsedVisibility()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func configureExpandControl(isDark: Bool) {
    let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    expandControl.setImage(UIImage(systemName: "chevron.down", withConfiguration: config), for: .normal)
    expandControl.tintColor = isDark ? UIColor.white.withAlphaComponent(0.72) : .secondaryLabel
    expandControl.backgroundColor = .clear
    expandControl.layer.cornerRadius = Self.pickerButtonSize * 0.5
    expandControl.layer.borderWidth = 0
    expandControl.layer.borderColor = UIColor.clear.cgColor
    expandControl.clipsToBounds = true
    expandControl.accessibilityTraits = .button
    expandControl.addTarget(self, action: #selector(didTapExpand), for: .touchUpInside)
    updateExpandControlChrome()
  }

  private func updateExpandControlChrome() {
    let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    let symbol = isExpanded ? "chevron.up" : "chevron.down"
    expandControl.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
    expandControl.accessibilityLabel = isExpanded ? "Show fewer reactions" : "Show more reactions"
    expandControl.accessibilityHint = isExpanded
      ? "Collapses the reaction list"
      : "Expands the full reaction list"
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutIconGrid()
    let blurH = blurView.bounds.height
    let largeX = blobsOnRightSide ? (bounds.width - 24.0) : 24.0
    let smallX = blobsOnRightSide ? (bounds.width - 14.0) : 14.0
    tailBlobLarge.center = CGPoint(x: largeX, y: blurH + 1.5)
    tailBlobSmall.center = CGPoint(x: smallX, y: blurH + 9.0)
  }

  private func layoutIconGrid() {
    let button = Self.pickerButtonSize
    let spacing = Self.pickerSpacing
    let cols = gridColumns
    let primaryCount = ChatReactionCatalog.collapsedEmojis.count
    let hostBounds = iconsHost.bounds
    guard hostBounds.width > 0, hostBounds.height > 0 else { return }

    // First row: primary emojis + trailing expand control.
    for index in 0..<primaryCount {
      guard index < iconNodes.count else { break }
      let col = index
      let x = CGFloat(col) * (button + spacing)
      iconNodes[index].frame = CGRect(x: x, y: 0, width: button, height: button)
    }
    let expandCol = min(primaryCount, cols - 1)
    expandControl.frame = CGRect(
      x: CGFloat(expandCol) * (button + spacing),
      y: 0,
      width: button,
      height: button
    )
  }

  private func applyCollapsedVisibility() {
    for node in iconNodes {
      node.isHidden = false
      node.alpha = 1
      node.transform = .identity
    }
    updateExpandControlChrome()
    blurHeightConstraint.constant = blurContentHeight
    blurView.layer.cornerRadius = min(blurContentHeight * 0.5, 26)
    invalidateIntrinsicContentSize()
  }

  @objc private func didTapExpand() {
    setExpanded(!isExpanded, animated: true)
  }

  /// Height-morph between the quick pill and the full emoji panel. The overlay
  /// relayouts inside the same spring, so the bubble rides the growth down.
  func setExpanded(_ expanded: Bool, animated: Bool) {
    guard expanded != isExpanded else { return }
    isExpanded = expanded
    updateExpandControlChrome()

    if expanded {
      panelView.prepareIfNeeded()
      panelView.isHidden = false
    }
    panelView.isUserInteractionEnabled = expanded
    iconsHost.isUserInteractionEnabled = !expanded

    invalidateIntrinsicContentSize()
    setNeedsLayout()

    let animations = {
      self.blurHeightConstraint.constant = self.blurContentHeight
      self.blurView.layer.cornerRadius = min(self.blurContentHeight * 0.5, 26)
      self.iconsHost.alpha = expanded ? 0.0 : 1.0
      self.panelView.alpha = expanded ? 1.0 : 0.0
      self.onContentSizeChange?()
      self.layoutIfNeeded()
    }
    let settle: (Bool) -> Void = { [weak self] _ in
      guard let self, !self.isExpanded else { return }
      self.panelView.isHidden = true
    }

    if animated {
      UIView.animate(
        withDuration: 0.42,
        delay: 0,
        usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0.15,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: animations,
        completion: settle
      )
    } else {
      animations()
      settle(true)
    }
  }

  /// Highlights the emoji already on the message, in the quick row and the panel.
  func setSelectedReaction(_ emoji: String?) {
    for node in iconNodes {
      node.isSelectedReaction = emoji.map { ChatReactionKey.matches(node.emoji, $0) } ?? false
    }
    panelView.selectedEmoji = emoji
  }

  func setThinkingBlobDirection(isRightAligned: Bool) {
    guard blobsOnRightSide != isRightAligned else { return }
    blobsOnRightSide = isRightAligned
    setNeedsLayout()
  }

  /// Emoji tiles cascade in from the pill's anchored side while it morph-grows.
  func animateIconsIn(fromTrailing: Bool) {
    let primaryCount = min(ChatReactionCatalog.collapsedEmojis.count, iconNodes.count)
    let visible = Array(iconNodes.prefix(primaryCount))
    let ordered = fromTrailing ? Array(visible.reversed()) : visible
    for (index, node) in ordered.enumerated() {
      node.playIntro(delay: 0.05 + 0.04 * Double(index))
    }
    expandControl.alpha = 0
    expandControl.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
    UIView.animate(
      withDuration: 0.34, delay: 0.05 + 0.04 * Double(primaryCount),
      usingSpringWithDamping: 0.68, initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.expandControl.alpha = 1
      self.expandControl.transform = .identity
    }
  }

  @objc private func didTapEmoji(_ sender: ChatReactionIconNode) {
    let emoji = sender.emoji
    sender.playSelectionEffect()
    // Window coordinates for the list coordinator's single flight.
    let sourcePoint = sender.convert(
      CGPoint(x: sender.bounds.midX, y: sender.bounds.midY),
      to: nil
    )
    delegate?.contextMenuDidSelectReaction(emoji, messageId: messageId, sourcePoint: sourcePoint)
  }
}

// MARK: - Expanded Emoji Panel

private final class ReactionEmojiPanelCell: UICollectionViewCell {
  static let reuseIdentifier = "ReactionEmojiPanelCell"
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    label.textAlignment = .center
    label.isUserInteractionEnabled = false
    contentView.addSubview(label)
    contentView.layer.cornerRadius = 10.0
    contentView.layer.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = contentView.bounds
    label.font = .systemFont(ofSize: floor(contentView.bounds.height * 0.74))
  }

  override var isSelected: Bool {
    didSet { applySelectionFill() }
  }

  func configure(_ emoji: String) {
    label.text = emoji
    applySelectionFill()
  }

  private func applySelectionFill() {
    contentView.backgroundColor =
      isSelected ? UIColor.white.withAlphaComponent(0.16) : .clear
  }
}

/// The panel the reaction pill morphs into: a pinned search capsule with quick
/// category filters, over a scrolling 8-column grid of every emoji the device draws.
final class ReactionEmojiPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
  /// Emoji plus the tapped point in window coords, for the list's reaction flight.
  var onSelect: ((String, CGPoint) -> Void)?

  var isDark: Bool = true {
    didSet { applyChrome() }
  }

  /// Emoji already on the message, drawn selected so toggle-off reads as intentional.
  var selectedEmoji: String? {
    didSet { applySelectedEmoji() }
  }

  private static let searchRowHeight: CGFloat = 36.0
  private static let categoryRowHeight: CGFloat = 34.0
  private static let padding: CGFloat = 8.0
  private static let cellSpacing: CGFloat = 4.0
  private static let columns = 8

  private let searchChrome = UIView()
  private let searchIcon = UIImageView()
  private let searchField = UITextField()
  private let categoryScroll = UIScrollView()
  private var categoryButtons: [UIButton] = []
  private let gridLayout = UICollectionViewFlowLayout()
  private let collectionView: UICollectionView
  private var entries: [ChatEmojiEntry] = []
  private var visibleEntries: [ChatEmojiEntry] = []
  private var selectedCategoryIndex: Int?
  private var didPrepare = false

  /// Reference row order: the quick reactions first, then the rest of the catalog.
  private static let catalog: [ChatEmojiEntry] = {
    let all = ChatEmojiCatalogBuilder.build()
    var byValue: [String: ChatEmojiEntry] = [:]
    for entry in all { byValue[entry.value] = entry }
    var seen = Set<String>()
    var head: [ChatEmojiEntry] = []
    for emoji in ChatReactionCatalog.allEmojis {
      let entry =
        byValue[emoji]
        ?? ChatEmojiEntry(
          value: emoji,
          searchText: (emoji.unicodeScalars.first?.properties.name ?? "").lowercased(),
          category: ChatReactionCatalog.browseGroup(for: emoji) ?? .smileys)
      guard seen.insert(entry.value).inserted else { continue }
      head.append(entry)
    }
    return head + all.filter { !seen.contains($0.value) }
  }()

  private static let categories = ChatReactionCatalog.categories

  override init(frame: CGRect) {
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: gridLayout)
    super.init(frame: frame)

    gridLayout.minimumInteritemSpacing = Self.cellSpacing
    gridLayout.minimumLineSpacing = Self.cellSpacing
    gridLayout.sectionInset = UIEdgeInsets(
      top: 0.0, left: Self.padding, bottom: Self.padding, right: Self.padding)

    searchChrome.layer.cornerCurve = .continuous
    searchChrome.clipsToBounds = true
    addSubview(searchChrome)

    searchIcon.image = UIImage(
      systemName: "magnifyingglass",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    searchIcon.contentMode = .scaleAspectFit
    searchChrome.addSubview(searchIcon)

    searchField.font = .systemFont(ofSize: 16)
    searchField.autocorrectionType = .no
    searchField.autocapitalizationType = .none
    searchField.returnKeyType = .search
    searchField.clearButtonMode = .never
    searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
    searchChrome.addSubview(searchField)

    categoryScroll.showsHorizontalScrollIndicator = false
    categoryScroll.alwaysBounceHorizontal = false
    addSubview(categoryScroll)

    // Tag 0 is "all"; every later tag indexes ChatReactionCatalog.categories.
    for index in 0...Self.categories.count {
      let button = UIButton(type: .system)
      button.tag = index
      let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
      let symbol = index == 0 ? "square.grid.2x2" : Self.categories[index - 1].symbolName
      if let image = UIImage(systemName: symbol, withConfiguration: config) {
        button.setImage(image, for: .normal)
      } else {
        button.setTitle(index == 0 ? "★" : Self.categories[index - 1].glyph, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17)
      }
      button.accessibilityLabel = index == 0 ? "All emoji" : Self.categories[index - 1].title
      button.layer.cornerRadius = 8.0
      button.layer.cornerCurve = .continuous
      button.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
      categoryScroll.addSubview(button)
      categoryButtons.append(button)
    }

    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.showsVerticalScrollIndicator = false
    collectionView.keyboardDismissMode = .onDrag
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(
      ReactionEmojiPanelCell.self,
      forCellWithReuseIdentifier: ReactionEmojiPanelCell.reuseIdentifier)
    addSubview(collectionView)

    applyChrome()
  }

  required init?(coder: NSCoder) { nil }

  /// Builds the catalog on first expand — walking Unicode is not launch work.
  func prepareIfNeeded() {
    guard !didPrepare else { return }
    didPrepare = true
    entries = Self.catalog
    visibleEntries = entries
    collectionView.reloadData()
    applySelectedEmoji()
  }

  private func applyChrome() {
    let ink = UIColor(white: isDark ? 1.0 : 0.0, alpha: 1.0)
    searchChrome.backgroundColor = ink.withAlphaComponent(isDark ? 0.12 : 0.06)
    searchIcon.tintColor = ink.withAlphaComponent(0.45)
    searchField.textColor = ink.withAlphaComponent(0.92)
    searchField.attributedPlaceholder = NSAttributedString(
      string: "Search emoji",
      attributes: [.foregroundColor: ink.withAlphaComponent(0.45)])
    for (index, button) in categoryButtons.enumerated() {
      let selected = (selectedCategoryIndex.map { $0 + 1 } ?? 0) == index
      let alpha: CGFloat = selected ? 0.98 : 0.42
      button.tintColor = ink.withAlphaComponent(alpha)
      button.setTitleColor(ink.withAlphaComponent(alpha), for: .normal)
      button.backgroundColor = selected ? ink.withAlphaComponent(0.14) : .clear
    }
  }

  /// Marks the applied emoji's cell, scrolling to it only on the first build.
  private func applySelectedEmoji(scroll: Bool = true) {
    guard didPrepare else { return }
    guard let emoji = selectedEmoji,
      let index = visibleEntries.firstIndex(where: { ChatReactionKey.matches($0.value, emoji) })
    else {
      collectionView.indexPathsForSelectedItems?.forEach {
        collectionView.deselectItem(at: $0, animated: false)
      }
      return
    }
    collectionView.selectItem(
      at: IndexPath(item: index, section: 0),
      animated: false,
      scrollPosition: scroll ? .centeredVertically : []
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let pad = Self.padding
    let rowHeight = Self.searchRowHeight
    // Header rides the panel's own inset, so it never draws a band across the top.
    let headerTop = max(pad, safeAreaInsets.top)
    searchChrome.frame = CGRect(
      x: pad, y: headerTop, width: max(0.0, bounds.width - pad * 2.0), height: rowHeight)
    searchChrome.layer.cornerRadius = rowHeight * 0.5

    let iconSide: CGFloat = 18.0
    searchIcon.frame = CGRect(
      x: 11.0, y: (rowHeight - iconSide) * 0.5, width: iconSide, height: iconSide)
    let fieldX = searchIcon.frame.maxX + 6.0
    searchField.frame = CGRect(
      x: fieldX, y: 0.0,
      width: max(0.0, searchChrome.bounds.width - fieldX - 10.0), height: rowHeight)

    let buttonSide: CGFloat = 36.0
    let categoryRow = Self.categoryRowHeight
    categoryScroll.frame = CGRect(
      x: pad, y: searchChrome.frame.maxY + 4.0,
      width: max(0.0, bounds.width - pad * 2.0), height: categoryRow)
    for (index, button) in categoryButtons.enumerated() {
      button.frame = CGRect(
        x: CGFloat(index) * buttonSide, y: 2.0, width: buttonSide, height: categoryRow - 4.0)
    }
    categoryScroll.contentSize = CGSize(
      width: CGFloat(categoryButtons.count) * buttonSide, height: categoryRow)

    let gridTop = categoryScroll.frame.maxY + 2.0
    collectionView.frame = CGRect(
      x: 0.0, y: gridTop, width: bounds.width, height: max(0.0, bounds.height - gridTop))

    // Solve the item size so the grid is always `columns` wide, never one short.
    let available = max(1.0, bounds.width - pad * 2.0)
    let side = floor(
      (available - CGFloat(Self.columns - 1) * Self.cellSpacing) / CGFloat(Self.columns))
    let itemSize = CGSize(width: max(1.0, side), height: max(1.0, side))
    if gridLayout.itemSize != itemSize {
      gridLayout.itemSize = itemSize
      gridLayout.invalidateLayout()
    }
  }

  @objc private func searchChanged() {
    applyFilter()
  }

  @objc private func categoryTapped(_ sender: UIButton) {
    let index = sender.tag - 1
    guard index < Self.categories.count else { return }
    selectedCategoryIndex = (index < 0 || selectedCategoryIndex == index) ? nil : index
    applyChrome()
    applyFilter()
  }

  /// Category first (curated members, then its Unicode blocks and name hints),
  /// then the live search query narrows whatever the tab left on screen.
  private func applyFilter() {
    prepareIfNeeded()
    var scoped = entries
    if let index = selectedCategoryIndex, index < Self.categories.count {
      let category = Self.categories[index]
      let curated = Set(category.emojis.map { ChatReactionKey.normalized($0) })
      let groups = Set(category.browseGroups)
      var head: [ChatEmojiEntry] = []
      var tail: [ChatEmojiEntry] = []
      for entry in entries {
        if curated.contains(ChatReactionKey.normalized(entry.value)) {
          head.append(entry)
        } else if groups.contains(entry.category)
          || category.searchHints.contains(where: { entry.searchText.contains($0) })
        {
          tail.append(entry)
        }
      }
      scoped = head + tail
    }

    let query = (searchField.text ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if query.isEmpty {
      visibleEntries = scoped
    } else {
      visibleEntries = scoped.filter { $0.searchText.contains(query) || $0.value.contains(query) }
    }
    collectionView.reloadData()
    guard !visibleEntries.isEmpty else { return }
    collectionView.scrollToItem(
      at: IndexPath(item: 0, section: 0), at: .top, animated: false)
    applySelectedEmoji(scroll: false)
  }

  func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
    visibleEntries.count
  }

  func collectionView(
    _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: ReactionEmojiPanelCell.reuseIdentifier, for: indexPath)
    guard let emojiCell = cell as? ReactionEmojiPanelCell,
      indexPath.item < visibleEntries.count
    else { return cell }
    emojiCell.configure(visibleEntries[indexPath.item].value)
    return emojiCell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard indexPath.item < visibleEntries.count else { return }
    let emoji = visibleEntries[indexPath.item].value
    let sourcePoint: CGPoint = {
      guard let cell = collectionView.cellForItem(at: indexPath) else {
        return convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
      }
      return cell.convert(CGPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
    }()
    searchField.resignFirstResponder()
    onSelect?(emoji, sourcePoint)
  }
}

// MARK: - Context Menu View

final class ContextMenuView: UIView {
  weak var delegate: ChatContextMenuOverlayDelegate?

  private let glassView: UIVisualEffectView
  private let stack: UIStackView

  struct ActionItem {
    let id: String
    let title: String
    let iconName: String
    let isDestructive: Bool
    let isInformational: Bool

    init(
      id: String, title: String, iconName: String, isDestructive: Bool,
      isInformational: Bool = false
    ) {
      self.id = id
      self.title = title
      self.iconName = iconName
      self.isDestructive = isDestructive
      self.isInformational = isInformational
    }
  }

  private let actions: [ActionItem]
  private var showsDeleteConfirmation = false

  let messageId: String

  init(
    appearance: ChatListAppearance,
    messageId: String,
    showResendAction: Bool,
    showRegenerateAction: Bool = false,
    showEditAction: Bool = false,
    showEditedInfo: Bool = false,
    editedAtMs: Int64? = nil,
    showSaveImageAction: Bool = false,
    showCopyLinkAction: Bool = false,
    showForwardAction: Bool = false,
    showReportAction: Bool = false,
    restrictSavingContent: Bool = false,
    failedSendOnly: Bool = false
  ) {
    self.messageId = messageId
    var resolvedActions: [ActionItem] = []
    if showEditedInfo {
      resolvedActions.append(
        ActionItem(
          id: "editedInfo", title: editedAtMs.map(Self.editedTitle) ?? "edited",
          iconName: "clock.arrow.circlepath", isDestructive: false, isInformational: true))
    }
    resolvedActions.append(
      ActionItem(
        id: "reply", title: "Reply", iconName: "arrowshape.turn.up.left", isDestructive: false))
    if !restrictSavingContent {
      resolvedActions.append(
        ActionItem(id: "copy", title: "Copy", iconName: "doc.on.doc", isDestructive: false))
      if showSaveImageAction {
        resolvedActions.append(
          ActionItem(
            id: "saveImage", title: "Save Image", iconName: "square.and.arrow.down",
            isDestructive: false))
      }
      if showCopyLinkAction {
        resolvedActions.append(
          ActionItem(id: "copyLink", title: "Copy Link", iconName: "link", isDestructive: false))
      }
      if showForwardAction {
        resolvedActions.append(
          ActionItem(
            id: "forward", title: "Forward", iconName: "arrowshape.turn.up.right",
            isDestructive: false))
      }
    }
    if showReportAction {
      resolvedActions.append(
        ActionItem(
          id: "report", title: "Report", iconName: "exclamationmark.circle",
          isDestructive: false))
    }
    if showEditAction {
      resolvedActions.append(
        ActionItem(id: "edit", title: "Edit", iconName: "pencil", isDestructive: false)
      )
    }
    if showResendAction {
      resolvedActions.append(
        ActionItem(
          id: "resend",
          title: "Resend",
          iconName: "arrow.clockwise",
          isDestructive: false
        )
      )
    }
    if showRegenerateAction {
      resolvedActions.append(
        ActionItem(
          id: "regenerate",
          title: "Regenerate",
          iconName: "arrow.trianglehead.2.counterclockwise",
          isDestructive: false
        )
      )
    }
    resolvedActions.append(
      ActionItem(id: "delete", title: "Delete", iconName: "trash", isDestructive: true)
    )
    if !restrictSavingContent {
      resolvedActions.append(
        ActionItem(
          id: "select", title: "Select", iconName: "checkmark.circle", isDestructive: false)
      )
    }
    // A message that never left the device has exactly two things you can do with it.
    //
    // Reply, Pin, Copy, Forward and Select all address a message that EXISTS for the
    // other person; offering them on a failed send is offering to act on something that
    // is not there. Send it again, or throw it away. Replaces the whole list rather than
    // filtering it, so the order is deliberate instead of whatever survived.
    self.actions =
      failedSendOnly
      ? [
        ActionItem(
          id: "resend", title: "Resend", iconName: "arrow.clockwise", isDestructive: false),
        ActionItem(id: "delete", title: "Delete", iconName: "trash", isDestructive: true),
      ]
      : resolvedActions
    self.glassView = makeChatContextLiquidGlassView(
      style: appearance.isDark ? .systemMaterialDark : .systemMaterial,
      cornerRadius: 24,
      capsuleCorners: false
    )

    self.stack = UIStackView()

    super.init(frame: .zero)

    glassView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glassView)

    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    glassView.contentView.addSubview(stack)

    glassView.layer.borderWidth = 0

    NSLayoutConstraint.activate([
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
    ])
    let stackTop = stack.topAnchor.constraint(
      greaterThanOrEqualTo: glassView.contentView.topAnchor,
      constant: 6
    )
    let stackBottom = stack.bottomAnchor.constraint(
      lessThanOrEqualTo: glassView.contentView.bottomAnchor,
      constant: -6
    )
    let stackCenterY = stack.centerYAnchor.constraint(equalTo: glassView.contentView.centerYAnchor)
    stackTop.priority = .defaultHigh
    stackBottom.priority = .defaultHigh
    stackCenterY.priority = .defaultHigh
    NSLayoutConstraint.activate([stackTop, stackBottom, stackCenterY])

    installActions(actions)
  }

  required init?(coder: NSCoder) { fatalError() }

  private static func editedTitle(_ timestamp: Int64) -> String {
    let seconds = Double(timestamp) / (timestamp > 100_000_000_000 ? 1_000.0 : 1.0)
    let date = Date(timeIntervalSince1970: seconds)
    let time = DateFormatter()
    time.locale = .current
    time.dateStyle = .none
    time.timeStyle = .short
    if Calendar.current.isDateInToday(date) {
      return "edited today at \(time.string(from: date))"
    }
    let day = DateFormatter()
    day.locale = .current
    day.setLocalizedDateFormatFromTemplate("MMM d")
    return "edited \(day.string(from: date)) at \(time.string(from: date))"
  }

  private func installActions(_ actions: [ActionItem]) {
    for arranged in stack.arrangedSubviews {
      stack.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }

    for (index, action) in actions.enumerated() {
      let startsActions = index > 0 && actions[index - 1].isInformational
      if (action.id == "select" || startsActions) && index > 0 {
        let sepContainer = UIView()
        sepContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sepContainer)

        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        line.translatesAutoresizingMaskIntoConstraints = false
        sepContainer.addSubview(line)

        let sepHeight = sepContainer.heightAnchor.constraint(
          equalToConstant: 1.0 / UIScreen.main.scale)
        sepHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
          sepHeight,
          line.leadingAnchor.constraint(equalTo: sepContainer.leadingAnchor, constant: 16),
          line.trailingAnchor.constraint(equalTo: sepContainer.trailingAnchor, constant: -16),
          line.topAnchor.constraint(equalTo: sepContainer.topAnchor),
          line.bottomAnchor.constraint(equalTo: sepContainer.bottomAnchor),
        ])
      }
      let row = ContextMenuRow(action: action)
      if !action.isInformational {
        row.addTarget(self, action: #selector(didTapAction(_:)), for: .touchUpInside)
      }
      stack.addArrangedSubview(row)
    }
  }

  /// Telegram-style drill-in: the original rows travel left, the delete choices
  /// enter from the right, and the same glass card changes height around them.
  func transitionToDeleteConfirmation(
    deleteForEveryoneTitle: String?,
    alongsideLayout: @escaping () -> Void
  ) {
    guard !showsDeleteConfirmation else { return }
    showsDeleteConfirmation = true
    layoutIfNeeded()

    let oldRowsSnapshot = stack.snapshotView(afterScreenUpdates: false)
    if let oldRowsSnapshot {
      oldRowsSnapshot.frame = stack.frame
      oldRowsSnapshot.isUserInteractionEnabled = false
      glassView.contentView.addSubview(oldRowsSnapshot)
    }

    var deleteActions: [ActionItem] = []
    if let title = deleteForEveryoneTitle,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      deleteActions.append(
        ActionItem(
          id: "deleteForEveryone",
          title: title,
          iconName: "",
          isDestructive: true
        ))
    }
    deleteActions.append(
      ActionItem(
        id: "deleteForMe",
        title: "Delete for me",
        iconName: "",
        isDestructive: true
      ))
    installActions(deleteActions)

    let travel = max(bounds.width, 220)
    stack.transform = CGAffineTransform(translationX: travel, y: 0)
    stack.alpha = 0

    UIView.animate(
      withDuration: 0.30,
      delay: 0,
      usingSpringWithDamping: 0.92,
      initialSpringVelocity: 0,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      alongsideLayout()
      self.layoutIfNeeded()
      oldRowsSnapshot?.transform = CGAffineTransform(translationX: -travel, y: 0)
      oldRowsSnapshot?.alpha = 0
      self.stack.transform = .identity
      self.stack.alpha = 1
    } completion: { _ in
      oldRowsSnapshot?.removeFromSuperview()
    }
  }

  @objc private func didTapAction(_ sender: ContextMenuRow) {
    delegate?.contextMenuDidSelectAction(sender.actionId, messageId: messageId)
  }
}

// MARK: - Context Menu Row

final class ContextMenuRow: UIControl {
  let actionId: String
  private let titleLabel: UILabel
  private let iconView: UIImageView
  private let isInformational: Bool

  init(action: ContextMenuView.ActionItem) {
    self.actionId = action.id
    self.titleLabel = UILabel()
    self.iconView = UIImageView()
    self.isInformational = action.isInformational
    super.init(frame: .zero)

    backgroundColor = .clear

    titleLabel.text = action.title
    titleLabel.font = UIFont.systemFont(
      ofSize: action.isInformational ? 15.0 : 17.5,
      weight: action.isInformational ? .medium : .regular)
    titleLabel.textColor = action.isInformational
      ? UIColor.secondaryLabel : (action.isDestructive ? .systemRed : .label)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    if !action.iconName.isEmpty,
      let image = UIImage(systemName: action.iconName, withConfiguration: config)
    {
      iconView.image = image
      iconView.tintColor = action.isInformational
        ? UIColor.secondaryLabel : (action.isDestructive ? .systemRed : .label)
    } else {
      iconView.isHidden = true
    }
    iconView.contentMode = .scaleAspectFit
    isUserInteractionEnabled = !action.isInformational

    addSubview(titleLabel)
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    iconView.translatesAutoresizingMaskIntoConstraints = false

    let rowHeight = heightAnchor.constraint(equalToConstant: 46)
    rowHeight.priority = .defaultHigh

    NSLayoutConstraint.activate([
      rowHeight,

      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),

      titleLabel.leadingAnchor.constraint(
        equalTo: action.iconName.isEmpty ? leadingAnchor : iconView.trailingAnchor,
        constant: action.iconName.isEmpty ? 18 : 14
      ),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isHighlighted: Bool {
    didSet {
      guard !isInformational else { return }
      UIView.animate(withDuration: 0.1) {
        self.backgroundColor =
          self.isHighlighted
          ? UIColor.label.withAlphaComponent(0.08)
          : .clear
      }
    }
  }
}
