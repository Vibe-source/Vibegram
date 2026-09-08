import AudioToolbox
import ObjectiveC
import Photos
import UIKit

private let swipeReplyTrigger: CGFloat = 56.0
private let swipeReplyMaxOffset: CGFloat = 80.0
private let chatHoldDebugLogs = true
private var chatRestrictSavingContentKey: UInt8 = 0

private struct ChatReactionActorDescriptor {
  let id: String
  let name: String
  let subtitle: String
  let emoji: String
  let avatarURL: String?
}

/// Vibe's reply mark — NOT a frosted disc with an arrow in it (that is Telegram's, and
/// every client that copied Telegram has one). The idea here is our own and it is a single
/// sentence: **a reply is a fragment of your bubble reaching back to their message.**
///
/// So the mark is a miniature bubble in YOUR bubble's accent gradient, with the tail
/// pointing left — back at the message being quoted. It is not stamped on screen; the pull
/// DRAWS it: the outline strokes itself from the tail around as your finger travels, and at
/// the trigger point the outline fills with the gradient and pops. Draw → fill → capture,
/// which is the same "things travel and become other things" vocabulary as the send morph.
/// Nothing rotates in, nothing shimmers, no SF Symbol.
///
/// The composer's reply chip wears the same silhouette (`ChatReplyMarkShape`), so the eye
/// connects what you pulled with what landed above the keyboard.
enum ChatReplyMarkShape {
  /// A mini bubble whose bottom-LEFT corner is a tail, aimed back at the quoted message.
  /// Inset so a stroke centred on the path never clips against the layer bounds.
  static func path(in rect: CGRect, cornerRadius: CGFloat = 7.0) -> UIBezierPath {
    let w = rect.width
    let h = rect.height
    let r = min(cornerRadius, min(w, h) * 0.5)
    let tail: CGFloat = min(5.0, w * 0.22)
    let path = UIBezierPath()
    path.move(to: CGPoint(x: rect.minX + tail + r, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + r),
      controlPoint: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - r, y: rect.maxY),
      controlPoint: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + tail + r * 0.6, y: rect.maxY))
    // The tail: a soft hook off the bottom-left, curving out and back — the same gesture
    // as the message plate's tail, at a twelfth of the size.
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY),
      controlPoint: CGPoint(x: rect.minX + tail * 0.5, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + tail, y: rect.maxY - r * 0.9),
      controlPoint: CGPoint(x: rect.minX + tail * 0.85, y: rect.maxY - r * 0.35))
    path.addLine(to: CGPoint(x: rect.minX + tail, y: rect.minY + r))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + tail + r, y: rect.minY),
      controlPoint: CGPoint(x: rect.minX + tail, y: rect.minY))
    path.close()
    return path
  }

  /// Sentinels for the places that can only take an icon NAME (menu rows, toolbars).
  /// Resolved to a drawn mark instead of an SF Symbol — `arrowshape.turn.up.left` is
  /// Telegram's/Apple's reply glyph and reading it in our menu is what made the rest of
  /// the refactor pointless.
  static let replyGlyphName = "vibe.mark.reply"
  static let forwardGlyphName = "vibe.mark.forward"

  static func glyphImage(
    named name: String, side: CGFloat = 21.0, lineWidth: CGFloat = 1.6
  ) -> UIImage? {
    guard name == replyGlyphName || name == forwardGlyphName else { return nil }
    guard let base = UIImage(named: "ReplyMark")?.withRenderingMode(.alwaysTemplate) else {
      return nil
    }
    if name == forwardGlyphName {
      return UIImage(cgImage: base.cgImage!, scale: base.scale, orientation: .upMirrored)
        .withRenderingMode(.alwaysTemplate)
    }
    return base
  }
}

final class ChatSwipeReplyIconView: UIView {
  static let diameter: CGFloat = 40.0
  private let discLayer = CALayer()
  private let iconView = UIImageView()
  /// Expanding ring on the hit; pull scale/alpha stay the same as before.
  private let ringLayer = CAShapeLayer()
  private(set) var didPop = false

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
    isUserInteractionEnabled = false
    clipsToBounds = false
    backgroundColor = .clear

    discLayer.frame = bounds
    discLayer.cornerRadius = Self.diameter * 0.5
    layer.addSublayer(discLayer)

    iconView.image = UIImage(named: "ReplyMark")?.withRenderingMode(.alwaysTemplate)
    iconView.contentMode = .scaleAspectFit
    iconView.frame = bounds.insetBy(dx: 9.0, dy: 9.0)
    iconView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(iconView)

    ringLayer.frame = bounds
    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.lineWidth = 1.4
    ringLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
    ringLayer.opacity = 0.0
    layer.addSublayer(ringLayer)

    alpha = 0.0
  }

  required init?(coder: NSCoder) { nil }

  func apply(appearance: ChatListAppearance) {
    if appearance.isDark {
      discLayer.backgroundColor = UIColor.black.withAlphaComponent(0.62).cgColor
      iconView.tintColor = .white
      ringLayer.strokeColor = UIColor.white.withAlphaComponent(0.88).cgColor
    } else {
      discLayer.backgroundColor = UIColor.white.withAlphaComponent(0.92).cgColor
      iconView.tintColor = UIColor.black.withAlphaComponent(0.82)
      ringLayer.strokeColor = UIColor.black.withAlphaComponent(0.55).cgColor
    }
  }

  /// progress: 0 at rest, 1 at the trigger threshold (may exceed 1 past it).
  func apply(progress: CGFloat) {
    guard !didPop else { return }
    let p = max(0.0, min(1.0, progress))
    alpha = min(1.0, p * 2.0)
    let scale = 0.72 + (0.28 * p)
    transform = CGAffineTransform(scaleX: scale, y: scale)
  }

  func pop() {
    guard !didPop else { return }
    didPop = true
    alpha = 1.0

    UIView.animate(
      withDuration: 0.5, delay: 0.0, usingSpringWithDamping: 0.46,
      initialSpringVelocity: 0.9, options: [.allowUserInteraction, .beginFromCurrentState],
      animations: { self.transform = CGAffineTransform(scaleX: 1.16, y: 1.16) },
      completion: nil)

    let ringScale = CABasicAnimation(keyPath: "transform.scale")
    ringScale.fromValue = 0.9
    ringScale.toValue = 1.9
    let ringFade = CABasicAnimation(keyPath: "opacity")
    ringFade.fromValue = 0.85
    ringFade.toValue = 0.0
    let ringGroup = CAAnimationGroup()
    ringGroup.animations = [ringScale, ringFade]
    ringGroup.duration = 0.42
    ringGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ringGroup.isRemovedOnCompletion = true
    ringLayer.add(ringGroup, forKey: "ringBurst")
  }
}

private func isKeyboardHostWindow(_ window: UIWindow) -> Bool {
  let typeName = String(describing: type(of: window))
  return typeName.contains("UIRemoteKeyboardWindow") || typeName.contains("UITextEffectsWindow")
}

private final class ChatKeyboardWindowObserver: NSObject {
  static let shared = ChatKeyboardWindowObserver()

  private weak var keyboardWindow: UIWindow?

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeVisible(_:)),
      name: UIWindow.didBecomeVisibleNotification,
      object: nil
    )
  }

  @objc private func windowDidBecomeVisible(_ notification: Notification) {
    guard let window = notification.object as? UIWindow else { return }
    guard isKeyboardHostWindow(window) else { return }
    keyboardWindow = window
  }

  private func discoverKeyboardWindow() -> UIWindow? {
    // iOS can keep the keyboard in a separate window that may not always be exposed
    // through the current scene's window list. Scan UIApplication windows first.
    for window in UIApplication.shared.windows.reversed() {
      guard isKeyboardHostWindow(window) else { continue }
      return window
    }

    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows.reversed() {
        guard isKeyboardHostWindow(window) else { continue }
        return window
      }
    }
    return nil
  }

  func currentKeyboardWindow() -> UIWindow? {
    if keyboardWindow == nil {
      keyboardWindow = discoverKeyboardWindow()
    }
    guard let keyboardWindow else { return nil }
    guard !keyboardWindow.isHidden, keyboardWindow.alpha > 0.01 else { return nil }
    return keyboardWindow
  }
}

extension ChatListView: UIGestureRecognizerDelegate, ChatContextMenuOverlayDelegate {
  func setRestrictSavingContent(_ restricted: Bool) {
    objc_setAssociatedObject(
      self,
      &chatRestrictSavingContentKey,
      NSNumber(value: restricted),
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
  }

  var restrictSavingContent: Bool {
    (objc_getAssociatedObject(self, &chatRestrictSavingContentKey) as? NSNumber)?.boolValue
      ?? false
  }

  private func holdDebugLog(_ message: String) {
    guard chatHoldDebugLogs else { return }
    NSLog("[ChatHold] %@", message)
  }

  private func resolveContextMenuHostWindow(appWindow: UIWindow) -> UIWindow {
    _ = ChatKeyboardWindowObserver.shared

    if let keyboardWindow = ChatKeyboardWindowObserver.shared.currentKeyboardWindow() {
      return keyboardWindow
    }
    return appWindow
  }

  func installInteractionGestures() {
    // Start observing keyboard windows as early as possible so first open is stable.
    _ = ChatKeyboardWindowObserver.shared

    // A UIScrollView runs an implicit ~150ms timer before it delivers touches to
    // its content / lets other recognizers proceed (WWDC "Advanced Scrollviews
    // and Touch Handling"). That delay is what made the swipe-reply bubble lag
    // behind the finger. Disabling it lets our pan track from the first pixel.
    collectionView.delaysContentTouches = false
    collectionView.canCancelContentTouches = true

    let tap = UITapGestureRecognizer(
      target: self, action: #selector(handleDismissInputTap(_:)))
    tap.delegate = self
    tap.cancelsTouchesInView = false
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    collectionView.addGestureRecognizer(tap)
    dismissInputTapGesture = tap

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipeReplyPan(_:)))
    pan.delegate = self
    pan.maximumNumberOfTouches = 1
    pan.delaysTouchesBegan = false
    pan.delaysTouchesEnded = false
    pan.cancelsTouchesInView = false
    collectionView.addGestureRecognizer(pan)
    swipeReplyPanGesture = pan

    let longPress = UILongPressGestureRecognizer(
      target: self, action: #selector(handleLongPress(_:)))
    // Home-card parity: the sink clock starts almost at touch-down so the hold
    // reads as immediate. The easeIn sink keeps its first beats visually
    // silent, so short taps still see nothing (and the commit block re-checks
    // movement/scroll before opening).
    longPress.minimumPressDuration = 0.10
    longPress.allowableMovement = 10.0
    // The hold detector must never hold up touch delivery to the swipe pan: a
    // swipe (movement) and a hold (stationary) are two independent detections.
    // Without these, the long-press can swallow the first touches and the swipe
    // only starts tracking after the hold gives up — felt as lag.
    longPress.delaysTouchesBegan = false
    longPress.delaysTouchesEnded = false
    longPress.cancelsTouchesInView = false
    // Prevent a long-press from also being treated as a tap that dismisses keyboard.
    tap.require(toFail: longPress)
    collectionView.addGestureRecognizer(longPress)
    contextMenuLongPressGesture = longPress
  }

  @objc private func handleDismissInputTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    // Ignore dismiss taps that are part of a context-menu hold/open sequence.
    if let longPress = contextMenuLongPressGesture {
      switch longPress.state {
      case .began, .changed, .ended:
        return
      default:
        break
      }
    }
    guard customContextMenuOverlay == nil else { return }
    guard activeNativeInputView != nil else { return }
    _ = endEditing(true)
  }

  public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    // Usage-banner carousel pan: horizontal drags only, so a scroll that starts
    // on the banner still goes to the list underneath.
    if gestureRecognizer === usageBannerPanGesture,
      let pan = gestureRecognizer as? UIPanGestureRecognizer
    {
      let t = pan.translation(in: pan.view)
      let v = pan.velocity(in: pan.view)
      if abs(t.x) > 2.0 || abs(t.y) > 2.0 { return abs(t.x) > abs(t.y) }
      return abs(v.x) > abs(v.y)
    }
    if gestureRecognizer === contextMenuLongPressGesture {
      let point = gestureRecognizer.location(in: collectionView)
      if let indexPath = collectionView.indexPathForItem(at: point),
        let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell,
        cell.containsReactionPoint(point, in: collectionView)
      {
        return false
      }
    }
    guard gestureRecognizer === swipeReplyPanGesture,
      let pan = gestureRecognizer as? UIPanGestureRecognizer
    else {
      return true
    }

    // A drag that starts on a multi-image deck belongs to that deck. Reply swipe
    // is leftward, and so is "next picture", so without this the two fire on the
    // same gesture and the message slides away instead of turning the card.
    let point = pan.location(in: collectionView)
    if let hit = collectionView.hitTest(point, with: nil),
      hit.isDescendant(of: collectionView),
      firstMediaStackAncestor(of: hit) != nil
    {
      return false
    }

    let translation = pan.translation(in: collectionView)
    let velocity = pan.velocity(in: collectionView)
    let translationVertical = abs(translation.y)

    // Reply swipe is LEFTWARD only. Begin the moment a leftward, mostly-
    // horizontal drag is detected; reject rightward/vertical drags so the scroll
    // view keeps handling them.
    if translation.x < -2.0 || translationVertical > 2.0 {
      return -translation.x > translationVertical * 0.9
    }

    let velocityVertical = abs(velocity.y)
    return velocity.x < -8.0 && -velocity.x > velocityVertical * 0.9
  }

  /// Nearest multi-image deck above `view`, or nil if the touch landed anywhere else.
  private func firstMediaStackAncestor(of view: UIView) -> ChatMediaStackView? {
    var node: UIView? = view
    while let current = node, current !== collectionView {
      if let stack = current as? ChatMediaStackView, stack.imageCount > 1 { return stack }
      node = current.superview
    }
    return nil
  }

  public func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Tap-to-dismiss must not run with context-menu long-press.
    if (gestureRecognizer === dismissInputTapGesture
      && otherGestureRecognizer === contextMenuLongPressGesture)
      || (gestureRecognizer === contextMenuLongPressGesture
        && otherGestureRecognizer === dismissInputTapGesture)
    {
      return false
    }
    // Don't allow our swipe-reply pan to run simultaneously with the long-press
    // context menu gesture — this prevents unwanted X movement during hold.
    if (gestureRecognizer === swipeReplyPanGesture
      && otherGestureRecognizer is UILongPressGestureRecognizer)
      || (gestureRecognizer is UILongPressGestureRecognizer
        && otherGestureRecognizer === swipeReplyPanGesture)
    {
      return false
    }
    // Allow simultaneous with scrollView's built-in pan so swiping tracks at 120fps.
    return true
  }

  @objc private func handleSwipeReplyPan(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: collectionView)
    let translation = gesture.translation(in: collectionView)

    switch gesture.state {
    case .began:
      beginSwipeReply(at: location)
    case .changed:
      updateSwipeReply(translation: translation)
    case .ended, .cancelled, .failed:
      finishSwipeReply()
    default:
      break
    }
  }

  private func beginSwipeReply(at location: CGPoint) {
    resetSwipeReplyTransform(animated: false)
    swipeReplyDidTrigger = false

    guard let indexPath = collectionView.indexPathForItem(at: location),
      indexPath.item < rows.count
    else {
      clearSwipeReplyState()
      return
    }
    let row = rows[indexPath.item]
    guard row.kind == .message, let messageId = row.messageId else {
      clearSwipeReplyState()
      return
    }

    swipeReplyIndexPath = indexPath
    swipeReplyMessageId = messageId
    swipeReplyIsMe = row.isMe

    // Freeze the list for the duration of the reply drag. Without this the scroll
    // view keeps panning/laying out simultaneously and each layout pass fights the
    // cell's transform — which is what made the bubble trail behind the finger.
    // With scrolling off, the transform we set in .changed is the only thing
    // moving the bubble, so it pins to the finger 1:1.
    collectionView.isScrollEnabled = false

    // Rasterize the cell into a bitmap while it's dragged. The bubble background
    // is a live UIVisualEffectView blur; without this it re-samples the wallpaper
    // every frame as it moves, which reads as shimmer/flicker. Caching it as a
    // bitmap (at screen scale, so text stays crisp) makes the slide buttery and
    // solid like Telegram. Cleared again in resetSwipeReplyTransform.
    if let cell = collectionView.cellForItem(at: indexPath) {
      cell.layer.rasterizationScale = window?.screen.scale ?? UIScreen.main.scale
      cell.layer.shouldRasterize = true
    }

    // Build the reply mark that tracks the drag. Add it INSIDE the collection view at
    // index 0 — behind the cells but above the wallpaper — so the bubble slides over it
    // to reveal it on the right edge (true "behind" effect) while still being guaranteed
    // visible.
    let icon = ChatSwipeReplyIconView()
    icon.apply(appearance: resolvedAppearance())
    collectionView.insertSubview(icon, at: 0)
    swipeReplyIconView = icon
  }

  private func updateSwipeReply(translation: CGPoint) {
    guard let indexPath = swipeReplyIndexPath else {
      return
    }

    guard let cell = collectionView.cellForItem(at: indexPath) else { return }

    // Reply swipe is LEFTWARD only. Ignore rightward drags entirely.
    let distance = max(0.0, -translation.x)
    // Rubber-band past the max so the pull feels elastic instead of hitting a wall.
    let visualDistance: CGFloat
    if distance <= swipeReplyMaxOffset {
      visualDistance = distance
    } else {
      visualDistance = swipeReplyMaxOffset + (distance - swipeReplyMaxOffset) * 0.18
    }

    // Set the transform directly (no per-frame CATransaction). A UIView transform
    // doesn't implicitly animate outside an animation block, and the extra commit
    // was adding a redundant render pass that read as flicker.
    cell.transform = CGAffineTransform(translationX: -visualDistance, y: 0.0)

    // Drive the reply indicator (subview of the collection view → content coords).
    // Emerge it from the right edge tracking the gap the bubble opens, so a sliver
    // shows from the very first movement and it settles at its rest spot. Pinning
    // it at a fixed far-right x kept it hidden behind the bubble until the end.
    if let icon = swipeReplyIconView {
      let rightEdge = collectionView.bounds.width
      let restX = rightEdge - 30.0
      let emergeX = rightEdge - (visualDistance * 0.7)
      icon.center = CGPoint(x: max(restX, emergeX), y: cell.frame.midY)
      icon.apply(progress: distance / swipeReplyTrigger)
    }

    guard distance >= swipeReplyTrigger,
      !swipeReplyDidTrigger,
      let messageId = swipeReplyMessageId
    else {
      return
    }
    swipeReplyDidTrigger = true
    swipeReplyIconView?.pop()
    // Harder feedback when the reply locks in: heavy haptic + an audible tick.
    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    AudioServicesPlaySystemSound(1104)
    onNativeEvent([
      "type": "swipeReply",
      "messageId": messageId,
    ])

    // Show reply banner in native input bar
    if let idx = swipeReplyIndexPath?.item, idx < rows.count {
      let row = rows[idx]
      inputBar?.showReplyBanner(
        messageId: messageId,
        text: replyBannerPreviewText(for: row),
        isMe: row.isMe,
        senderName: replyBannerSenderName(for: row)
      )
    }
  }

  private func finishSwipeReply() {
    resetSwipeReplyTransform(animated: true)
    clearSwipeReplyState()
  }

  private func replyBannerSenderName(for row: ChatListRow) -> String {
    if let agent = row.agentName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !agent.isEmpty
    {
      return agent
    }
    return enginePeerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func replyBannerPreviewText(for row: ChatListRow, fallback: String = "") -> String {
    switch row.visualKind {
    case .video, .videoNote:
      return "Video Message"
    case .voice:
      return "Voice Message"
    case .media:
      let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Image" : trimmed
    case .document:
      let name = row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !name.isEmpty { return name }
      let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? fallback : trimmed
    case .text, .sticker:
      let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? fallback : trimmed
    }
  }

  private func resetSwipeReplyTransform(animated: Bool) {
    let icon = swipeReplyIconView
    swipeReplyIconView = nil
    let cell = swipeReplyIndexPath.flatMap { collectionView.cellForItem(at: $0) }
    guard cell != nil || icon != nil else { return }

    let apply = {
      cell?.transform = .identity
      cell?.contentView.transform = .identity
      icon?.alpha = 0.0
      icon?.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
    }
    if animated {
      // Snappy spring return instead of a slow ease-out, so the bubble settles
      // with a lively feel rather than appearing laggy. Keep the cell rasterized
      // through the return so the blur stays smooth, then clear it on completion.
      UIView.animate(
        withDuration: 0.34, delay: 0.0, usingSpringWithDamping: 0.72,
        initialSpringVelocity: 0.5,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: apply,
        completion: { _ in
          cell?.layer.shouldRasterize = false
          icon?.removeFromSuperview()
        })
    } else {
      apply()
      cell?.layer.shouldRasterize = false
      icon?.removeFromSuperview()
    }
  }

  private func clearSwipeReplyState() {
    swipeReplyIndexPath = nil
    swipeReplyMessageId = nil
    swipeReplyIsMe = false
    swipeReplyDidTrigger = false
    // Safety: if any path cleared state without going through the reset, make sure
    // the indicator never lingers on screen.
    swipeReplyIconView?.removeFromSuperview()
    swipeReplyIconView = nil
    // Always restore scrolling — this is the single exit point for every swipe path.
    collectionView.isScrollEnabled = true
  }

  /// Open the hold menu for a specific message, without a hold.
  ///
  /// The "not sent" mark needs to offer Resend and Delete, and those already live in this
  /// menu with the lift, the backdrop and the blur behind them. Routing the tap here
  /// instead of putting up a `UIAlertController` means one presentation for one idea:
  /// the actions available on a message are the ones in its menu.
  func openContextMenuForMessage(_ messageId: String) {
    guard customContextMenuOverlay == nil else { return }
    guard let index = rows.firstIndex(where: { $0.messageId == messageId }) else { return }
    let indexPath = IndexPath(item: index, section: 0)
    guard collectionView.cellForItem(at: indexPath) is ChatListCell else { return }
    // Route through the point-based entry so there is exactly one code path that opens
    // this menu, and it stays the one the long press uses.
    let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? .zero
    openContextMenu(at: CGPoint(x: frame.midX, y: frame.midY))
  }

  private func openContextMenu(
    at point: CGPoint, holdTarget requestedHoldTarget: ChatContextMenuHoldTarget = .bubble
  ) {
    guard customContextMenuOverlay == nil else { return }
    guard let indexPath = collectionView.indexPathForItem(at: point),
      let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
    else { return }

    guard indexPath.item < rows.count else { return }
    let row = rows[indexPath.item]
    guard row.kind == .message, let messageId = row.messageId else { return }
    let isMe = row.isMe
    let showResendAction =
      row.isMe && (row.status?.lowercased() == "error" || row.isDeliveryFailed)
    // Regenerate is only offered on errored responses (matches the side button).
    let showRegenerateAction =
      row.isAgentMessage
      && row.isAgentError
      && !row.isStreamingText
      && (row.agentActionSourceId?.isEmpty == false)
      && (row.agentRegeneratePrompt?.isEmpty == false)
    // Own sent bubbles: text edits its content, media edits (or later adds) the
    // caption. Voice/sticker have no editable text and uploads aren't settled yet.
    let showEditAction =
      row.isMe
      && !row.isAgentMessage
      && row.messageType != "typing"
      && row.visualKind != .voice
      && row.visualKind != .sticker
      && !row.shouldShowUploadOverlay
      && row.status?.lowercased() != "error"

    holdDebugLog(
      "openContextMenu begin mid=\(messageId) cellTransform=\(NSCoder.string(for: cell.transform)) contentTransform=\(NSCoder.string(for: cell.contentView.transform))"
    )

    // Hold is a pre-menu pulse only. Force identity before snapshot/open.
    cell.setContextMenuHeld(false, animated: false, strategy: "scaleCell")

    guard let window = window else { return }

    // Snapshot only the bubble+tail (not the full cell row).
    // bubbleSnapshotView already sets the snapshot's frame in window coordinates.
    // It captures at full scale to ensure tail bounding boxes remain mathematically identical.
    guard let bubbleSnapshot = cell.bubbleSnapshotView(in: window) else { return }
    // Capture deletion material NOW, while the real cell is stable and visible.
    // Waiting until context-menu dismissal with afterScreenUpdates=false returns
    // the previous extracted/hidden render state even though the model is restored.
    let deletionBubbleImage = cell.bubbleSnapshotImage(in: window)?.image
    let bubbleFrame = bubbleSnapshot.frame
    // Snapshot-local so the overlay can hit-test the pill after it shifts the bubble.
    let bubbleReactionRect = cell.reactionStripFrame(in: window).map {
      $0.offsetBy(dx: -bubbleFrame.minX, dy: -bubbleFrame.minY)
    }
    holdDebugLog(
      "openContextMenu snapshot mid=\(messageId) bubbleFrame=\(NSCoder.string(for: bubbleFrame)) deletePixels=\(deletionBubbleImage == nil ? "N" : "Y")"
    )

    let hostWindow = resolveContextMenuHostWindow(appWindow: window)
    let bubbleFrameInHost =
      hostWindow === window
      ? bubbleFrame
      : hostWindow.convert(bubbleFrame, from: window)
    bubbleSnapshot.frame = bubbleFrameInHost

    // A hold that landed on the pill gets the reaction menu; anywhere else gets the bubble menu.
    let selectedReactionEmoji = row.reactions.first(where: { $0.isSelected })?.emoji
    var holdTarget = requestedHoldTarget
    if case .bubble = holdTarget,
      cell.containsReactionPoint(collectionView.convert(point, to: window), in: window),
      let held = selectedReactionEmoji ?? row.reactions.first?.emoji
    {
      holdTarget = .reaction(emoji: held)
    }
    holdDebugLog(
      "openContextMenu target=\(holdTarget == .bubble ? "bubble" : "reaction") current=\(selectedReactionEmoji ?? "nil")"
    )

    let overlay = ChatContextMenuOverlay(
      messageId: messageId,
      bubbleSnapshot: bubbleSnapshot,
      deletionBubbleImage: deletionBubbleImage,
      bubbleFrame: bubbleFrameInHost,
      bubbleIsMe: isMe,
      bubbleReactionRect: bubbleReactionRect,
      holdTarget: holdTarget,
      currentReactionEmoji: selectedReactionEmoji,
      appearance: self.resolvedAppearance(),
      showResendAction: showResendAction,
      showRegenerateAction: showRegenerateAction,
      showEditAction: showEditAction,
      showEditedInfo: row.isEdited,
      editedAtMs: row.editedAtMs,
      showSaveImageAction: row.visualKind == .media
        && (row.mediaUrl?.isEmpty == false || row.localMediaUrl?.isEmpty == false),
      showCopyLinkAction: contextMenuSupportsChannelActions,
      showForwardAction: !showResendAction,
      showReportAction: contextMenuSupportsChannelActions && !row.isMe,
      restrictSavingContent: restrictSavingContent,
      failedSendOnly: showResendAction
    )
    overlay.delegate = self

    overlay.frame = hostWindow.bounds
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostWindow.addSubview(overlay)
    self.customContextMenuWindow = nil

    let hostClass = NSStringFromClass(type(of: hostWindow))
    NSLog(
      "[ChatListView] contextMenu hostWindow=%@ level=%.1f keyboardHost=%@",
      hostClass,
      hostWindow.windowLevel.rawValue,
      hostWindow === window ? "N" : "Y"
    )

    // Clear any conflicting swipe reply state when context menu opens
    if customContextMenuOverlay == nil {
      resetSwipeReplyTransform(animated: false)
      clearSwipeReplyState()
    }

    self.customContextMenuOverlay = overlay
    self.contextMenuHostCell = cell
    self.contextMenuHostCellOriginalTransform = .identity

    // Animate In
    overlay.animateIn()

    // Extract right after overlay is in place so we don't get a blank frame/flicker.
    cell.setContextMenuExtracted(true)
    holdDebugLog("openContextMenu extracted mid=\(messageId)")

    self.onNativeEvent(["type": "contextMenuOpened", "messageId": messageId])
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      guard customContextMenuOverlay == nil else { return }

      // Cancel any in-progress swipe reply immediately to avoid residual X offset.
      resetSwipeReplyTransform(animated: false)
      clearSwipeReplyState()

      let point = gesture.location(in: collectionView)
      guard let indexPath = collectionView.indexPathForItem(at: point),
        let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
      else { return }
      holdDebugLog(
        "longPress began point=\(NSCoder.string(for: point)) index=\(indexPath.item) cellTransform=\(NSCoder.string(for: cell.transform))"
      )

      // The sink itself is silent — with the 0.10s trigger every slow tap and
      // scroll start reaches .began, so a tick here fires constantly and stacks
      // with the commit impact as a double beat. One decisive medium impact at
      // commit (when the menus actually morph out) is the whole grammar.
      cell.contentView.transform = .identity
      cell.setContextMenuHeld(true, animated: true, strategy: "scaleCell")

      // The sink takes 0.28s. Commit exactly when it lands so the expansion
      // continues directly from the depressed state — no rest beat between.
      let holdStartPoint = point
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self, weak cell] in
        guard let self = self else { return }
        guard gesture.state == .began || gesture.state == .changed else {
          self.holdDebugLog("longPress delayed cancel state=\(gesture.state.rawValue)")
          cell?.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
          return
        }
        // With the earlier trigger, a slow scroll can reach here — never open
        // the menu for a finger that is actually dragging.
        let currentPoint = gesture.location(in: self.collectionView)
        let moved = hypot(
          currentPoint.x - holdStartPoint.x, currentPoint.y - holdStartPoint.y)
        if moved > 12 || self.collectionView.isDragging
          || self.collectionView.panGestureRecognizer.state == .began
          || self.collectionView.panGestureRecognizer.state == .changed
        {
          self.holdDebugLog("longPress delayed cancel moved=\(moved)")
          cell?.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
          return
        }
        if self.customContextMenuOverlay != nil {
          cell?.setContextMenuHeld(false, animated: false, strategy: "scaleCell")
          return
        }
        self.holdDebugLog("longPress delayed open state=\(gesture.state.rawValue)")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.openContextMenu(at: point)

        if self.customContextMenuOverlay == nil {
          self.holdDebugLog("longPress delayed open failed")
          cell?.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
        }
      }

    case .ended, .cancelled, .failed:
      holdDebugLog(
        "longPress end state=\(gesture.state.rawValue) overlay=\(customContextMenuOverlay != nil)")
      if customContextMenuOverlay == nil {
        let point = gesture.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: point),
          let cell = collectionView.cellForItem(at: indexPath) as? ChatListCell
        {
          cell.setContextMenuHeld(false, animated: true, strategy: "scaleCell")
        }
      }

    default:
      break
    }
  }

  @available(iOS 13.0, *)
  public func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    return nil
  }


  // MARK: - ChatContextMenuOverlayDelegate

  public func contextMenuDidDismiss(overlay: ChatContextMenuOverlay) {
    holdDebugLog("contextMenuDidDismiss")
    if let cell = contextMenuHostCell as? ChatListCell {
      cell.setContextMenuHeld(false, animated: false, strategy: "scaleCell")
      cell.setContextMenuExtracted(false)
      cell.transform = contextMenuHostCellOriginalTransform
    }
    contextMenuHostCell = nil
    customContextMenuOverlay = nil

    customContextMenuWindow?.isHidden = true
    customContextMenuWindow = nil
  }

  public func contextMenuDidSelectReaction(
    _ reaction: String,
    messageId: String,
    sourcePoint: CGPoint?
  ) {
    holdDebugLog(
      "contextMenuDidSelectReaction id=\(messageId) emoji=\(reaction) source=\(sourcePoint.map { NSCoder.string(for: $0) } ?? "nil")"
    )
    guard let window else { return }
    let flightHost = customContextMenuOverlay?.superview ?? window
    let resolvedMessageId = messageId
    let chatId = contextMenuChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let coordinator = ChatReactionTransitionCoordinator.shared
    let token = coordinator.begin(
      chatId: chatId, messageId: resolvedMessageId, emoji: reaction)
    let previous = applyLocalReactionEmoji(reaction, toMessageId: resolvedMessageId)
    let hostCell = visibleReactionCell(messageId: resolvedMessageId)
      ?? contextMenuHostCell as? ChatListCell
    let targetInWindow = hostCell?.reactionBadgeCenter(for: reaction, in: window)
      ?? convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
    let sourceWindow = customContextMenuOverlay?.window ?? window
    let sourceInWindow = sourcePoint.map { window.convert($0, from: sourceWindow) } ?? targetInWindow
    let targetPoint = flightHost.convert(targetInWindow, from: window)
    let flightSource = flightHost.convert(sourceInWindow, from: window)

    var payload: [String: Any] = [
      "type": "contextMenuReaction",
      "emoji": reaction,
      "messageId": resolvedMessageId,
      "sourceX": flightSource.x,
      "sourceY": flightSource.y,
    ]
    payload["targetX"] = targetPoint.x
    payload["targetY"] = targetPoint.y
    holdDebugLog(
      "emit contextMenuReaction id=\(resolvedMessageId) emoji=\(reaction) source=\(NSCoder.string(for: flightSource)) target=\(NSCoder.string(for: targetPoint))"
    )
    onNativeEvent(payload)
    submitContextMenuReaction(reaction, messageId: resolvedMessageId) { [weak self] accepted in
      guard coordinator.resolveTransport(token, accepted: accepted), !accepted,
        let self
      else { return }
      if let previous { self.restoreLocalReactionSnapshot(previous, toMessageId: resolvedMessageId) }
    }

    ChatReactionFxModule.shared.animateReactionFlight(
      emoji: reaction,
      from: flightSource,
      to: targetPoint,
      in: flightHost,
      bubbleView: nil
    ) { [weak self, weak window] in
      guard let self, let window, coordinator.isCurrent(token) else { return }
      coordinator.finishFlight(token)
      let cell = self.visibleReactionCell(messageId: resolvedMessageId)
      if cell?.playReactionLandingEffect(reaction, in: window) != true {
        ChatReactionFxModule.shared.playLandingEffect(
          emoji: reaction, at: targetInWindow, in: window, tintOverride: nil)
      }
    }
  }

  /// Hold on a reaction pill: same backdrop as the bubble menu, reaction content inside it.
  func openReactionContextMenu(for row: ChatListRow, emoji: String) {
    guard let messageId = row.messageId, let index = indexForMessage(messageId),
      let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? ChatListCell
    else { return }
    openContextMenu(at: cell.center, holdTarget: .reaction(emoji: emoji))
  }

  func presentReactionDetails(
    for row: ChatListRow, emoji: String, sourcePoint _: CGPoint
  ) {
    guard let hostView = window, let messageId = row.messageId else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if let current = reactionDetailOverlay {
      current.onDismiss = nil
      current.dismiss(animated: false)
    }

    let placeholder = localReactionDetailActors(for: row, emoji: emoji)
    let overlay = ChatReactionDetailOverlay(emoji: emoji, actors: placeholder)
    reactionDetailOverlay = overlay
    overlay.onDismiss = { [weak self, weak overlay] in
      guard let self, self.reactionDetailOverlay === overlay else { return }
      self.reactionDetailOverlay = nil
    }
    overlay.present(in: hostView)

    let chatId = contextMenuChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard chatId != "saved_messages" else { return }
    ChatEngine.shared.fetchReactionDetails(chatId: chatId, messageId: messageId) {
      [weak self, weak overlay] body in
      guard let self, let overlay, self.reactionDetailOverlay === overlay, let body else { return }
      let descriptors = self.reactionActorDescriptors(from: body, selectedEmoji: emoji)
      guard !descriptors.isEmpty else { return }
      self.installReactionDetailActors(descriptors, in: overlay, selectedEmoji: emoji)
    }
  }

  private func localReactionDetailActors(
    for row: ChatListRow, emoji: String
  ) -> [ChatReactionDetailActor] {
    guard row.reactions.first(where: { ChatReactionKey.matches($0.emoji, emoji) })?.isSelected == true,
      let config = AppSessionConfig.current
    else { return [] }
    let name = config.name ?? config.username ?? "You"
    return [
      ChatReactionDetailActor(
        id: config.userID, displayName: name, subtitle: "You reacted",
        emoji: emoji, avatarURL: config.profileImage)
    ]
  }

  private func reactionActorDescriptors(
    from body: [String: Any], selectedEmoji: String
  ) -> [ChatReactionActorDescriptor] {
    let payload = (body["data"] as? [String: Any]) ?? body
    let groups = (payload["reactions"] as? [[String: Any]])
      ?? (payload["reactionGroups"] as? [[String: Any]])
      ?? (payload["reaction_groups"] as? [[String: Any]])
      ?? []
    var selected: [ChatReactionActorDescriptor] = []
    var fallback: [ChatReactionActorDescriptor] = []
    for group in groups {
      let groupEmoji = reactionDetailString(group["emoji"] ?? group["reaction"]) ?? selectedEmoji
      let actors = (group["actors"] as? [[String: Any]])
        ?? (group["users"] as? [[String: Any]]) ?? []
      let parsed = actors.compactMap { reactionActorDescriptor($0, emoji: groupEmoji) }
      fallback.append(contentsOf: parsed)
      if groupEmoji == selectedEmoji { selected.append(contentsOf: parsed) }
    }
    if !selected.isEmpty { return selected }
    if !fallback.isEmpty { return fallback }
    let actors = (payload["actors"] as? [[String: Any]])
      ?? (payload["users"] as? [[String: Any]]) ?? []
    return actors.compactMap { reactionActorDescriptor($0, emoji: selectedEmoji) }
  }

  private func reactionActorDescriptor(
    _ raw: [String: Any], emoji: String
  ) -> ChatReactionActorDescriptor? {
    guard let id = reactionDetailString(
      raw["userId"] ?? raw["user_id"] ?? raw["id"]), !id.isEmpty
    else { return nil }
    let name = reactionDetailString(
      raw["displayName"] ?? raw["display_name"] ?? raw["name"] ?? raw["username"])
      ?? "Vibegram User"
    let avatarURL = reactionDetailString(
      raw["avatarUrl"] ?? raw["avatar_url"] ?? raw["profileImage"] ?? raw["profile_image"])
    let reactedAt = raw["reactedAt"] ?? raw["reacted_at"] ?? raw["timestamp"]
    return ChatReactionActorDescriptor(
      id: id, name: name, subtitle: reactionDetailSubtitle(reactedAt),
      emoji: emoji, avatarURL: avatarURL)
  }

  private func installReactionDetailActors(
    _ descriptors: [ChatReactionActorDescriptor], in overlay: ChatReactionDetailOverlay,
    selectedEmoji: String
  ) {
    let initial = descriptors.map { descriptor in
      ChatReactionDetailActor(
        id: descriptor.id, displayName: descriptor.name, subtitle: descriptor.subtitle,
        emoji: descriptor.emoji, avatarURL: descriptor.avatarURL)
    }
    overlay.update(emoji: selectedEmoji, actors: initial)
  }

  private func reactionDetailString(_ value: Any?) -> String? {
    let text: String?
    if let value = value as? String { text = value }
    else if let value = value as? NSNumber { text = value.stringValue }
    else { text = nil }
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func reactionDetailSubtitle(_ value: Any?) -> String {
    let date: Date? = {
      if let number = value as? NSNumber {
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
      }
      guard let text = reactionDetailString(value) else { return nil }
      if let raw = Double(text) {
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
      }
      return ISO8601DateFormatter().date(from: text)
    }()
    guard let date else { return "Reacted" }
    let formatter = DateFormatter()
    formatter.locale = .current
    if Calendar.current.isDateInToday(date) {
      formatter.timeStyle = .short
      return "today at \(formatter.string(from: date))"
    }
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  public func contextMenuDidSelectAction(_ actionId: String, messageId _: String) {
    guard let overlay = customContextMenuOverlay else { return }
    let mid = overlay.messageId

    if restrictSavingContent,
      ["copy", "saveImage", "copyLink", "forward", "select"].contains(actionId)
    {
      overlay.animateOut(reason: "content-protected", completion: nil)
      onNativeEvent(["type": "agentToast", "message": "Content protection is enabled"])
      return
    }

    if actionId == "delete" {
      guard let row = rows.first(where: { $0.messageId == mid }) else {
        NSLog("[DeleteTrace] menu drill-in missing row mid=%@", mid)
        overlay.animateOut(reason: "delete-missing-row", completion: nil)
        return
      }
      let deleteConfig = contextDeleteConfiguration(for: row)
      NSLog(
        "[DeleteTrace] menu drill-in chat=%@ mid=%@ isMe=%@ everyone=%@",
        deleteConfig.chatId,
        mid,
        row.isMe ? "Y" : "N",
        deleteConfig.deleteForEveryoneTitle == nil ? "N" : "Y"
      )
      overlay.presentDeleteConfirmation(
        deleteForEveryoneTitle: deleteConfig.deleteForEveryoneTitle)
      return
    }

    if actionId == "deleteForMe" || actionId == "deleteForEveryone" {
      guard let row = rows.first(where: { $0.messageId == mid }) else {
        NSLog("[DeleteTrace] confirmation missing row mid=%@ action=%@", mid, actionId)
        overlay.animateOut(reason: "delete-missing-row", completion: nil)
        return
      }
      let deleteConfig = contextDeleteConfiguration(for: row)
      let requestedEveryone = actionId == "deleteForEveryone"
      let deleteForEveryone =
        requestedEveryone && deleteConfig.deleteForEveryoneTitle != nil
      let capturedCell = contextMenuHostCell as? ChatListCell
      let deletionMaterial = overlay.deletionBubbleCapture(in: self)
      NSLog(
        "[DeleteTrace] material handoff mid=%@ preExtract=%@ frame=%@",
        mid,
        deletionMaterial == nil ? "N" : "Y",
        deletionMaterial.map { NSCoder.string(for: $0.frame) } ?? "-"
      )
      overlay.animateOut(reason: "delete-confirmed") { [weak self, weak capturedCell] in
        guard let self else { return }
        self.executeMessageDeletion(
          messageId: mid,
          row: row,
          cell: capturedCell,
          deletionMaterial: deletionMaterial,
          chatId: deleteConfig.chatId,
          deleteForEveryone: deleteForEveryone
        )
      }
      return
    }

    if actionId == "select" {
      self.beginMessageSelection(messageId: mid)
      overlay.animateOut(reason: "action:\(actionId)", completion: nil)
      return
    }

    if actionId == "copyLink" {
      UIPasteboard.general.string = contextMessageShareLink(mid)
      overlay.animateOut(reason: "action:copyLink") { [weak self] in
        self?.onNativeEvent(["type": "agentToast", "message": "Link copied"])
      }
      return
    }

    if actionId == "saveImage" {
      let image = (contextMenuHostCell as? ChatListCell)?.mediaImage(atGridIndex: 0)
      overlay.animateOut(reason: "action:saveImage") { [weak self] in
        guard let self else { return }
        guard let image else {
          self.onNativeEvent(["type": "agentToast", "message": "Image is still loading"])
          return
        }
        self.saveContextMenuImage(image)
      }
      return
    }

    if actionId == "forward" {
      overlay.animateOut(reason: "action:forward") { [weak self] in
        guard let self else { return }
        self.beginMessageSelection(messageId: mid)
        self.inputBarDidRequestSelectionAction("shareInside", payload: nil)
      }
      return
    }

    if actionId == "report" {
      guard let row = rows.first(where: { $0.messageId == mid }) else {
        overlay.animateOut(reason: "report-missing-row", completion: nil)
        return
      }
      overlay.animateOut(reason: "action:report") { [weak self] in
        self?.presentMessageReportFlow(row: row, messageId: mid)
      }
      return
    }

    overlay.animateOut(reason: "action:\(actionId)", completion: nil)

    onNativeEvent([
      "type": "contextMenuAction",
      "action": actionId,
      "messageId": mid,
    ])

    if let row = rows.first(where: { $0.messageId == mid }) {
      if actionId == "reply" {
        inputBar?.showReplyBanner(
          messageId: mid,
          text: replyBannerPreviewText(for: row),
          isMe: row.isMe,
          senderName: replyBannerSenderName(for: row)
        )
      } else if actionId == "edit" {
        inputBar?.showEditBanner(messageId: mid, text: row.text)
      } else if actionId == "copy" {
        UIPasteboard.general.string = row.plainContent ?? row.text
      } else if actionId == "resend" {
        retryOutgoingMessage(row: row, source: "context_menu")
      } else if actionId == "regenerate" {
        let sourceMessageId = row.agentActionSourceId ?? ""
        if !sourceMessageId.isEmpty {
          onNativeEvent([
            "type": "agentMessageAction",
            "action": "regenerate",
            "sourceMessageId": sourceMessageId,
            "sourceText": row.agentActionSourceText ?? row.plainContent ?? row.text,
            "regeneratePrompt": row.agentRegeneratePrompt ?? "",
          ])
        }
      }
    }
  }

  private func saveContextMenuImage(_ image: UIImage) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          self?.onNativeEvent(["type": "agentToast", "message": "Photo access is required"])
        }
        return
      }
      PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      } completionHandler: { success, _ in
        DispatchQueue.main.async {
          self?.onNativeEvent([
            "type": "agentToast",
            "message": success ? "Image saved" : "Image could not be saved",
          ])
        }
      }
    }
  }

  private func presentMessageReportFlow(row: ChatListRow, messageId: String) {
    guard let presenter = contextMenuPresenter() else { return }
    let sheet = UIAlertController(title: "Report Message", message: nil, preferredStyle: .actionSheet)
    let reasons: [(String, String)] = [
      ("Spam", "spam"),
      ("Violence", "violence"),
      ("Abuse or harassment", "abuse"),
      ("Sexual content", "sexual_content"),
      ("Copyright", "copyright"),
      ("Personal data", "personal_data"),
      ("Other", "other"),
    ]
    for reason in reasons {
      sheet.addAction(UIAlertAction(title: reason.0, style: .default) { [weak self] _ in
        guard let self else { return }
        if reason.1 == "other" {
          self.presentOtherReportDetails(row: row, messageId: messageId, presenter: presenter)
        } else {
          self.confirmMessageReport(
            row: row, messageId: messageId, reason: reason.1, details: nil,
            presenter: presenter)
        }
      })
    }
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = self
      popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1.0, height: 1.0)
    }
    presenter.present(sheet, animated: true)
  }

  private func presentOtherReportDetails(
    row: ChatListRow, messageId: String, presenter: UIViewController
  ) {
    let alert = UIAlertController(
      title: "What happened?", message: "Add a short note for the moderation team.",
      preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Details"
      field.clearButtonMode = .whileEditing
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self, weak alert] _ in
      self?.confirmMessageReport(
        row: row, messageId: messageId, reason: "other",
        details: alert?.textFields?.first?.text, presenter: presenter)
    })
    presenter.present(alert, animated: true)
  }

  private func confirmMessageReport(
    row: ChatListRow, messageId: String, reason: String, details: String?,
    presenter: UIViewController
  ) {
    let alert = UIAlertController(
      title: "Send report?", message: "The message and its metadata will be queued for review.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Report", style: .destructive) { [weak self] _ in
      self?.submitMessageReport(
        messageId: messageId, reason: reason, details: details, blockSender: false)
    })
    if row.senderUserId?.isEmpty == false {
      alert.addAction(UIAlertAction(title: "Report and Block", style: .destructive) { [weak self] _ in
        self?.submitMessageReport(
          messageId: messageId, reason: reason, details: details, blockSender: true)
      })
    }
    presenter.present(alert, animated: true)
  }

  private func submitMessageReport(
    messageId: String, reason: String, details: String?, blockSender: Bool
  ) {
    onNativeEvent(["type": "agentToast", "message": "Sending report…"])
    submitContextMenuReport(
      messageId: messageId, reason: reason, details: details, blockSender: blockSender
    ) { [weak self] success, error in
      self?.onNativeEvent([
        "type": "agentToast",
        "message": success ? "Report submitted" : (error ?? "Report could not be submitted"),
      ])
    }
  }

  private func contextMenuPresenter() -> UIViewController? {
    guard var presenter = window?.rootViewController else { return nil }
    while let next = presenter.presentedViewController { presenter = next }
    return presenter
  }

  func dismissCustomContextMenu(animated: Bool) {
    guard let overlay = customContextMenuOverlay else { return }

    let cleanup = { [weak self] in
      overlay.removeFromSuperview()
      self?.customContextMenuOverlay = nil
      if let hostCell = self?.contextMenuHostCell as? ChatListCell {
        hostCell.setContextMenuHeld(
          false, animated: false, strategy: "scaleCell")
        hostCell.setContextMenuExtracted(false)
        hostCell.transform = self?.contextMenuHostCellOriginalTransform ?? .identity
        self?.contextMenuHostCell = nil
        self?.contextMenuHostCellOriginalTransform = .identity
      }
    }

    if animated {
      overlay.animateOut(reason: "dismiss", completion: cleanup)
    } else {
      cleanup()
    }
  }
}

// MARK: - Message deletion / exact-pixel disintegration

private struct ChatBubbleFragmentCapture {
  let image: UIImage
  let frame: CGRect
  let isMe: Bool
  let messageId: String
}

extension ChatListView {
  /// Delete a message from somewhere other than the hold menu.
  ///
  /// The hold menu path hands over a bubble capture so the plate can animate out of the
  /// menu it was lifted into. A tap on the "not sent" mark has no such lift and no menu —
  /// there is nothing to hand over — so this finds the live cell and lets the deletion
  /// take its own snapshot, which is the same fallback `executeMessageDeletion` already
  /// uses when a capture is missing.
  func performMessageDeletion(
    messageId: String, row: ChatListRow, chatId: String, deleteForEveryone: Bool
  ) {
    let cell = rows.firstIndex(where: { $0.messageId == messageId })
      .flatMap { collectionView.cellForItem(at: IndexPath(item: $0, section: 0)) }
      as? ChatListCell
    executeMessageDeletion(
      messageId: messageId, row: row, cell: cell, deletionMaterial: nil, chatId: chatId,
      deleteForEveryone: deleteForEveryone)
  }

  /// Visual-only disintegration for a row the engine already removed (view-once consume).
  func animateVisibleMessageDisintegration(messageId: String, row: ChatListRow) {
    let cell = rows.firstIndex(where: { $0.messageId == messageId })
      .flatMap { collectionView.cellForItem(at: IndexPath(item: $0, section: 0)) }
      as? ChatListCell
    guard let cell, cell.contentView.alpha > 0.05,
      let rendered = cell.bubbleSnapshotImage(in: self)
    else { return }
    let capture = ChatBubbleFragmentCapture(
      image: rendered.image,
      frame: rendered.frame,
      isMe: row.isMe,
      messageId: messageId)
    let fragments = ChatBubbleFragmentDisintegrationView(
      frame: bounds,
      captures: [capture],
      perCaptureBudget: deletionFragmentBudget(for: row))
    fragments.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(fragments)
    bringSubviewToFront(fragments)
    cell.contentView.alpha = 0
    fragments.animateAndRemove()
  }

  private func executeMessageDeletion(
    messageId: String,
    row: ChatListRow,
    cell: ChatListCell?,
    deletionMaterial: (image: UIImage, frame: CGRect)?,
    chatId: String,
    deleteForEveryone: Bool
  ) {
    let normalizedChatId = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatId.isEmpty else {
      NSLog("[DeleteTrace] UI reject invalid chat mid=%@", messageId)
      onNativeEvent(["type": "agentToast", "message": "Couldn't identify this chat."])
      return
    }

    let renderedMaterial = deletionMaterial ?? cell?.bubbleSnapshotImage(in: self)
    let capture = renderedMaterial.map {
      ChatBubbleFragmentCapture(
        image: $0.image,
        frame: $0.frame,
        isMe: row.isMe,
        messageId: messageId
      )
    }

    var activeFragments: ChatBubbleFragmentDisintegrationView?
    if let capture {
      let fragments = ChatBubbleFragmentDisintegrationView(
        frame: bounds,
        captures: [capture],
        perCaptureBudget: deletionFragmentBudget(for: row)
      )
      fragments.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(fragments)
      bringSubviewToFront(fragments)
      cell?.contentView.alpha = 0
      fragments.animateAndRemove()
      activeFragments = fragments
      NSLog(
        "[DeleteTrace] fragments start mid=%@ count=%d flow=%@ frame=%@",
        messageId,
        fragments.fragmentCount,
        row.isMe ? "upper-left-inward" : "upper-right-inward",
        NSCoder.string(for: capture.frame)
      )
    } else {
      NSLog("[DeleteTrace] fragments skipped mid=%@ reason=no-visible-capture", messageId)
    }

    UIImpactFeedbackGenerator(style: .soft).impactOccurred()

    // 120 ms visual lead before engine deletion triggers collection reflow
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      [weak self, weak cell, weak activeFragments] in
      // Tell the core first, on the main actor, while the fragments are still in the
      // air. The core's window is what the list renders; a delete it never hears
      // about comes straight back on the next publish.
      self?.coreEngineDidDeleteMessage(id: messageId, forEveryone: deleteForEveryone)

      // `deleteMessage` blocks on the engine's serial queue — 99ms on device, landing
      // exactly on the frame the disintegration animation is drawing. The result is
      // only needed to decide whether to show a failure toast, so nothing about it
      // belongs on the main thread.
      DispatchQueue.global(qos: .userInitiated).async {
        let result = ChatEngine.shared.deleteMessage([
          "chatId": normalizedChatId,
          "messageId": messageId,
          "forEveryone": deleteForEveryone,
        ])
        DispatchQueue.main.async {
          self?.finishMessageDeletion(
            result: result, chatId: normalizedChatId, messageId: messageId,
            deleteForEveryone: deleteForEveryone, hadCapture: capture != nil,
            cell: cell, fragments: activeFragments)
        }
      }
    }

    // Reuse already restores alpha. This is only a safety valve for a rejected or
    // malformed delta so a still-mounted cell can never remain permanently hidden.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self, weak cell] in
      guard let self, let cell,
        cell.row?.messageId == messageId,
        self.rows.contains(where: { $0.messageId == messageId })
      else { return }
      cell.contentView.alpha = 1
      NSLog("[DeleteTrace] visibility safety restore mid=%@", messageId)
    }
  }

  /// Reports the engine's answer once it comes back off the engine queue.
  ///
  /// Split out so the blocking call can run off the main thread: the only thing the
  /// result decides is whether to un-hide the cell and raise a toast, and both of
  /// those are cheap main-thread work that can happen a queue hop later.
  private func finishMessageDeletion(
    result: [String: Any],
    chatId: String,
    messageId: String,
    deleteForEveryone: Bool,
    hadCapture: Bool,
    cell: ChatListCell?,
    fragments: ChatBubbleFragmentDisintegrationView?
  ) {
    let accepted = (result["accepted"] as? Bool) == true
    NSLog(
      "[DeleteTrace] UI result chat=%@ mid=%@ scope=%@ accepted=%@ capture=%@ reason=%@",
      chatId,
      messageId,
      deleteForEveryone ? "everyone" : "me",
      accepted ? "Y" : "N",
      hadCapture ? "Y" : "N",
      String(describing: result["reason"] ?? "-")
    )
    guard !accepted else { return }

    // Restore hidden cell and clean up fragments on deletion failure
    cell?.contentView.alpha = 1
    fragments?.removeFromSuperview()

    let reason = String(describing: result["reason"] ?? "")
    let message: String
    switch reason {
    case "no_native_socket", "chat_not_joined":
      message = "Chat is reconnecting. Try again in a moment."
    case "delete_disabled_in_blackout":
      message = "Deletion is unavailable in relay-only mode."
    case "invalid_payload":
      message = "Couldn't identify this message."
    case "saved_messages_not_ready":
      message = "Saved Messages is still preparing. Try again in a moment."
    default:
      message = "Couldn't delete this message right now."
    }
    onNativeEvent([
      "type": "agentToast",
      "message": message,
    ])
  }

  private func deletionFragmentBudget(for row: ChatListRow) -> Int {
    switch row.visualKind {
    case .media:
      return 3_200
    case .video, .videoNote:
      return 2_800
    case .sticker:
      return 2_200
    case .text, .voice, .document:
      return 900
    }
  }

  /// Clear Chat uses the same material transformation for every visible bubble.
  /// The engine/history clear begins once the exact-pixel fragments have replaced
  /// the cells, while the pieces continue flying independently above the list.
  func animateClearChatDisintegration(completion: @escaping () -> Void) {
    let visibleCells =
      collectionView.visibleCells
      .compactMap { $0 as? ChatListCell }
      .sorted { $0.frame.minY < $1.frame.minY }
    let captures: [ChatBubbleFragmentCapture] = visibleCells.compactMap { cell in
      guard let row = cell.row,
        let messageId = row.messageId,
        let rendered = cell.bubbleSnapshotImage(in: self)
      else { return nil }
      return ChatBubbleFragmentCapture(
        image: rendered.image,
        frame: rendered.frame,
        isMe: row.isMe,
        messageId: messageId
      )
    }
    guard !captures.isEmpty else {
      NSLog("[DeleteTrace] clear fragments skipped visible=0")
      completion()
      return
    }

    let perCaptureBudget = max(180, min(520, 2_400 / max(captures.count, 1)))
    let fragments = ChatBubbleFragmentDisintegrationView(
      frame: bounds,
      captures: captures,
      perCaptureBudget: perCaptureBudget
    )
    fragments.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(fragments)
    bringSubviewToFront(fragments)
    for cell in visibleCells { cell.contentView.alpha = 0 }
    fragments.animateAndRemove()
    NSLog(
      "[DeleteTrace] clear fragments start bubbles=%d fragments=%d",
      captures.count,
      fragments.fragmentCount
    )

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: completion)
  }
}

private final class ChatBubbleFragmentDisintegrationView: UIView {
  private var fragmentLayers: [CALayer] = []
  private var captureIndexByLayer: [ObjectIdentifier: Int] = [:]
  private let captures: [ChatBubbleFragmentCapture]
  private(set) var fragmentCount = 0

  init(
    frame: CGRect,
    captures: [ChatBubbleFragmentCapture],
    perCaptureBudget: Int
  ) {
    self.captures = captures
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = false

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (captureIndex, capture) in captures.enumerated() {
      installFragments(
        for: capture,
        captureIndex: captureIndex,
        budget: max(perCaptureBudget, 36)
      )
    }
    CATransaction.commit()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func installFragments(
    for capture: ChatBubbleFragmentCapture,
    captureIndex: Int,
    budget: Int
  ) {
    guard let cgImage = capture.image.cgImage else { return }
    let width = max(capture.frame.width, 1)
    let height = max(capture.frame.height, 1)
    let area = width * height
    let desired = max(128, min(budget, Int(area / 6.5)))
    let tileSide = max(1.5, sqrt(area / CGFloat(desired)))
    let columns = max(1, Int(ceil(width / tileSide)))
    let rows = max(1, Int(ceil(height / tileSide)))

    for row in 0..<rows {
      for column in 0..<columns {
        let localX = CGFloat(column) * tileSide
        let localY = CGFloat(row) * tileSide
        let tileWidth = min(tileSide, width - localX)
        let tileHeight = min(tileSide, height - localY)
        guard tileWidth > 0.25, tileHeight > 0.25 else { continue }

        let fragment = CALayer()
        fragment.contents = cgImage
        fragment.contentsScale = capture.image.scale
        fragment.contentsGravity = .resize
        fragment.magnificationFilter = .nearest
        fragment.minificationFilter = .nearest
        fragment.allowsEdgeAntialiasing = false
        fragment.contentsRect = CGRect(
          x: localX / width,
          y: localY / height,
          width: tileWidth / width,
          height: tileHeight / height
        )
        fragment.frame = CGRect(
          x: capture.frame.minX + localX,
          y: capture.frame.minY + localY,
          width: tileWidth,
          height: tileHeight
        )
        layer.addSublayer(fragment)
        fragmentLayers.append(fragment)
        captureIndexByLayer[ObjectIdentifier(fragment)] = captureIndex
      }
    }
    fragmentCount = fragmentLayers.count
  }

  func animateAndRemove() {
    let now = CACurrentMediaTime()
    for (index, fragment) in fragmentLayers.enumerated() {
      let captureIndex =
        captureIndexByLayer[ObjectIdentifier(fragment)] ?? 0
      let capture = captures[min(captureIndex, captures.count - 1)]
      // Inward trajectory: outgoing (isMe) moves left (-1), incoming (!isMe) moves right (+1).
      let direction: CGFloat = capture.isMe ? -1 : 1
      let normalizedSideProgress: CGFloat
      if capture.frame.width > 0 {
        let localX = fragment.position.x - capture.frame.minX
        normalizedSideProgress =
          capture.isMe
          ? max(0, min(1, (capture.frame.width - localX) / capture.frame.width))
          : max(0, min(1, localX / capture.frame.width))
      } else {
        normalizedSideProgress = 0
      }
      let jitterA = Self.noise(index &* 17 &+ captureIndex &* 131)
      let jitterB = Self.noise(index &* 29 &+ captureIndex &* 197)
      let jitterC = Self.noise(index &* 43 &+ captureIndex &* 251)
      let delay = TimeInterval((normalizedSideProgress * 0.022) + (jitterA * 0.012))
      let duration = 0.58 + TimeInterval(jitterB * 0.16)
      let start = fragment.position
      let horizontal = direction * (46 + (jitterB * 92))
      let vertical = -(34 + (jitterC * 94))
      let end = CGPoint(x: start.x + horizontal, y: start.y + vertical)
      let curl = (jitterA - 0.5) * 42
      let control1 = CGPoint(
        x: start.x + horizontal * 0.28,
        y: start.y + vertical * 0.18 + curl * 0.18
      )
      let control2 = CGPoint(
        x: start.x + horizontal * 0.74 - direction * curl * 0.12,
        y: start.y + vertical * 0.66
      )

      let position = CAKeyframeAnimation(keyPath: "position")
      let path = CGMutablePath()
      path.move(to: start)
      path.addCurve(to: end, control1: control1, control2: control2)
      position.path = path
      position.timingFunction = CAMediaTimingFunction(name: .easeOut)

      let opacity = CAKeyframeAnimation(keyPath: "opacity")
      opacity.values = [1, 0.96, 0.66, 0]
      opacity.keyTimes = [0, 0.10, 0.68, 1]

      let captureAreaRoot = sqrt(max(capture.frame.width * capture.frame.height, 1.0))
      let heightFactor = max(0.0, min(1.0, (capture.frame.height - 40.0) / 180.0))
      let areaFactor = max(0.0, min(1.0, (captureAreaRoot - 70.0) / 300.0))
      let materialSizeFactor = max(heightFactor, areaFactor)
      let baseSparkleSide = 0.55 + (materialSizeFactor * 1.35) + (jitterC * 0.35)
      let sourceSide = max(max(fragment.bounds.width, fragment.bounds.height), 1.0)
      let adaptiveSparkleScale = min(0.72, max(0.12, baseSparkleSide / sourceSide))
      let scaleMid = 1.0 - (1.0 - adaptiveSparkleScale) * 0.22
      let scaleLate = adaptiveSparkleScale
      let scaleEnd: CGFloat = 0.0

      let scale = CAKeyframeAnimation(keyPath: "transform.scale")
      scale.values = [1.0, scaleMid, scaleLate, scaleEnd]
      scale.keyTimes = [0.0, 0.28, 0.72, 1.0]
      scale.timingFunctions = [
        CAMediaTimingFunction(name: .easeOut),
        CAMediaTimingFunction(name: .easeInEaseOut),
        CAMediaTimingFunction(name: .easeIn),
      ]

      let rotation = CABasicAnimation(keyPath: "transform.rotation")
      rotation.fromValue = 0
      rotation.toValue = direction * (.pi * 0.18 + (jitterA - 0.5) * 2.6)

      let group = CAAnimationGroup()
      group.animations = [position, opacity, scale, rotation]
      group.beginTime = fragment.convertTime(now, from: nil) + delay
      group.duration = duration
      group.fillMode = .forwards
      group.isRemovedOnCompletion = false
      fragment.add(group, forKey: "delete-disintegrate")
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.92) { [weak self] in
      guard let self else { return }
      NSLog("[DeleteTrace] fragments complete count=%d", self.fragmentCount)
      self.removeFromSuperview()
    }
  }

  private static func noise(_ seed: Int) -> CGFloat {
    let value = sin(Double(seed &* 7_919 &+ 104_729)) * 43_758.545_312_3
    return CGFloat(value - floor(value))
  }
}
