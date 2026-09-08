import AVFoundation
import Photos
import SwiftUI
import UIKit

private enum NativeStoryComposerMediaType: String {
  case image
  case video
}

private enum NativeStoryComposerAudience: String, CaseIterable {
  case everyone
  case contacts
  case closeFriends = "close_friends"

  var title: String {
    switch self {
    case .everyone:
      return "Everyone"
    case .contacts:
      return "Contacts"
    case .closeFriends:
      return "Close Friends"
    }
  }
}

private enum NativeStoryComposerFont: String, CaseIterable {
  case system
  case serif
  case mono
  case rounded

  var title: String {
    switch self {
    case .system:
      return "Default"
    case .serif:
      return "Serif"
    case .mono:
      return "Mono"
    case .rounded:
      return "Rounded"
    }
  }

  func font(ofSize size: CGFloat) -> UIFont {
    switch self {
    case .system:
      return .systemFont(ofSize: size, weight: .bold)
    case .serif:
      return UIFont(name: "TimesNewRomanPS-BoldMT", size: size)
        ?? .systemFont(ofSize: size, weight: .bold)
    case .mono:
      return .monospacedSystemFont(ofSize: size, weight: .bold)
    case .rounded:
      let baseFont = UIFont.systemFont(ofSize: size, weight: .bold)
      let descriptor =
        baseFont.fontDescriptor.withDesign(.rounded)
        ?? baseFont.fontDescriptor
      return UIFont(descriptor: descriptor, size: size)
    }
  }
}

private struct NativeStoryComposerTextOverlay {
  let id: String
  var text: String
  var center: CGPoint
  var colorHex: String
  var fontSize: CGFloat
  var font: NativeStoryComposerFont
  var alignment: NSTextAlignment
}

private extension UIColor {
  static func nativeStoryComposerColor(from hex: String) -> UIColor {
    let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "#", with: "")
    guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
      return .white
    }
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }
}

private final class NativeStoryComposerMediaView: UIView {
  private let imageView = UIImageView()
  private let videoContainerView = UIView()
  private let playerLayer = AVPlayerLayer()
  private var player: AVPlayer?
  private var playbackObserver: NSObjectProtocol?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    addSubview(imageView)

    videoContainerView.clipsToBounds = true
    addSubview(videoContainerView)
    playerLayer.videoGravity = .resizeAspectFill
    videoContainerView.layer.addSublayer(playerLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    clearPlayer()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    videoContainerView.frame = bounds
    playerLayer.frame = videoContainerView.bounds
  }

  func setMedia(uri: String?, type: NativeStoryComposerMediaType?, mirrored: Bool) {
    clearPlayer()
    imageView.image = nil
    imageView.isHidden = true
    videoContainerView.isHidden = true

    let transform = mirrored ? CGAffineTransform(scaleX: -1.0, y: 1.0) : .identity
    imageView.transform = transform
    videoContainerView.transform = transform

    guard let uri, let type else { return }
    switch type {
    case .image:
      imageView.isHidden = false
      loadImage(uri: uri)
    case .video:
      videoContainerView.isHidden = false
      loadVideo(uri: uri)
    }
  }

  func setPlaybackPaused(_ paused: Bool) {
    guard let player else { return }
    if paused {
      player.pause()
    } else {
      player.play()
    }
  }

  private func clearPlayer() {
    if let playbackObserver {
      NotificationCenter.default.removeObserver(playbackObserver)
      self.playbackObserver = nil
    }
    playerLayer.player = nil
    player?.pause()
    player = nil
  }

  private func loadImage(uri: String) {
    guard let url = URL(string: uri) else { return }
    if url.isFileURL {
      imageView.image = UIImage(contentsOfFile: url.path)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        self?.imageView.image = image
      }
    }
  }

  private func loadVideo(uri: String) {
    guard let url = URL(string: uri) else { return }
    let player = AVPlayer(url: url)
    player.actionAtItemEnd = .none
    playerLayer.player = player
    self.player = player
    playbackObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { _ in
      player.seek(to: .zero)
      player.play()
    }
    player.play()
  }
}

private final class NativeStoryComposerStickerView: UIView {
  private let label = UILabel()
  private let padding = UIEdgeInsets(top: 8.0, left: 10.0, bottom: 8.0, right: 10.0)
  private var panOrigin = CGPoint.zero

  var overlayId: String = ""
  var onSelect: ((String) -> Void)?
  var onMove: ((String, CGPoint) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true

    label.numberOfLines = 0
    addSubview(label)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)

    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    addGestureRecognizer(panGesture)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    label.frame = bounds.inset(by: padding)
  }

  func apply(overlay: NativeStoryComposerTextOverlay, selected: Bool) {
    overlayId = overlay.id
    label.text = overlay.text
    label.textColor = UIColor.nativeStoryComposerColor(from: overlay.colorHex)
    label.font = overlay.font.font(ofSize: overlay.fontSize)
    label.textAlignment = overlay.alignment
    label.shadowColor = UIColor.black.withAlphaComponent(0.55)
    label.shadowOffset = CGSize(width: 0.0, height: 1.0)

    let maxLabelSize = CGSize(width: 240.0, height: CGFloat.greatestFiniteMagnitude)
    let labelSize = label.sizeThatFits(maxLabelSize)
    bounds = CGRect(
      x: 0.0,
      y: 0.0,
      width: ceil(labelSize.width + padding.left + padding.right),
      height: ceil(labelSize.height + padding.top + padding.bottom)
    )

    layer.cornerRadius = 12.0
    layer.cornerCurve = .continuous
    layer.borderWidth = selected ? 1.0 : 0.0
    layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
    backgroundColor = selected ? UIColor.black.withAlphaComponent(0.18) : .clear
    setNeedsLayout()
  }

  @objc private func handleTap() {
    onSelect?(overlayId)
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard let superview else { return }
    switch gesture.state {
    case .began:
      panOrigin = center
      onSelect?(overlayId)
    case .changed:
      let translation = gesture.translation(in: superview)
      center = CGPoint(x: panOrigin.x + translation.x, y: panOrigin.y + translation.y)
    case .ended, .cancelled:
      onMove?(overlayId, center)
    default:
      break
    }
  }
}

private final class NativeStoryComposerSliderTrackView: UIView {
  private let shapeLayer = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    shapeLayer.fillColor = UIColor.white.withAlphaComponent(0.24).cgColor
    layer.addSublayer(shapeLayer)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 2.0
    let path = UIBezierPath()
    path.move(to: CGPoint(x: inset, y: 0.0))
    path.addLine(to: CGPoint(x: bounds.width - inset, y: 0.0))
    path.addLine(to: CGPoint(x: bounds.width * 0.58, y: bounds.height))
    path.addLine(to: CGPoint(x: bounds.width * 0.42, y: bounds.height))
    path.close()
    shapeLayer.frame = bounds
    shapeLayer.path = path.cgPath
  }
}

private func makeLiquidGlassView(
  cornerRadius: CGFloat = 0.0,
  capsule: Bool = false,
  tintColor: UIColor? = nil
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: nil)
  if #available(iOS 26.0, *) {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = true
    effect.tintColor = tintColor
    view.effect = effect
    if capsule {
      view.cornerConfiguration = .capsule()
    } else {
      view.cornerConfiguration = .uniformCorners(radius: .fixed(cornerRadius))
    }
  } else {
    view.effect = UIBlurEffect(style: .systemThinMaterialDark)
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
  }
  view.clipsToBounds = true
  view.contentView.backgroundColor = .clear
  return view
}

private final class NativeStoryComposerPassthroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}

final class AppNativeStoryComposerView: UIView, UITextViewDelegate {
  var onEvent: (([String: Any]) -> Void)?

  private let cardContainer = UIView()
  private let mediaView = NativeStoryComposerMediaView()
  private let overlaysContainer = UIView()
  private let topBar = NativeStoryComposerPassthroughView()
  private var closeButtonGlassView = UIVisualEffectView()
  private let closeButton = UIButton(type: .system)
  private var topActionsView = UIVisualEffectView()
  private let downloadButton = UIButton(type: .system)
  private let addTextButton = UIButton(type: .system)
  private let emojiButton = UIButton(type: .system)
  private let musicButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)
  private var nextButtonGlassView = UIVisualEffectView()
  private let nextButton = UIButton(type: .system)
  private let bottomBar = UIView()
  private var promptChromeView = UIVisualEffectView()
  private let promptTextView = UITextView()
  private let promptPlaceholderLabel = UILabel()
  private let promptSendButton = UIButton(type: .system)

  private var selectedActionBarGlassView = UIVisualEffectView()
  private let selectedEditButton = UIButton(type: .system)
  private let selectedDeleteButton = UIButton(type: .system)

  private let editorOverlay = UIView()
  private var editorCancelGlassView = UIVisualEffectView()
  private var editorDoneGlassView = UIVisualEffectView()
  private let editorCancelButton = UIButton(type: .system)
  private let editorDoneButton = UIButton(type: .system)
  private let editorTextView = UITextView()
  private var editorSliderGlassView = UIVisualEffectView()
  private let editorSliderContainer = UIView()
  private let editorSliderTrackView = NativeStoryComposerSliderTrackView()
  private let editorSliderHandleView = UIView()
  private var editorControlsGlassView = UIVisualEffectView()
  private let colorToggleButton = UIButton(type: .system)
  private let fontCycleButton = UIButton(type: .system)
  private let alignCycleButton = UIButton(type: .system)
  private let colorsScrollView = UIScrollView()

  private let publishBackdropView = UIView()
  private var publishSheetGlassView = UIVisualEffectView()
  private let publishTitleLabel = UILabel()
  private let audienceStackView = UIStackView()
  private let allowScreenshotsLabel = UILabel()
  private let allowScreenshotsSwitch = UISwitch()
  private let postToProfileLabel = UILabel()
  private let postToProfileSwitch = UISwitch()
  private let durationTitleLabel = UILabel()
  private let durationStackView = UIStackView()
  private let publishCancelButton = UIButton(type: .system)
  private let saveDraftButton = UIButton(type: .system)
  private let publishButton = UIButton(type: .system)

  private let composerColors = [
    "#FFFFFF", "#000000", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#5AC8FA", "#007AFF",
    "#5856D6", "#AF52DE", "#FF2D55", "#8E8E93",
  ]
  private var colorButtons: [UIButton] = []
  private var audienceButtons: [NativeStoryComposerAudience: UIButton] = [:]
  private var durationButtons: [Int: UIButton] = [:]

  private var mediaUri: String?
  private var mediaType: NativeStoryComposerMediaType?
  private var mirrored = false

  private var overlays: [NativeStoryComposerTextOverlay] = []
  private var stickerViews: [String: NativeStoryComposerStickerView] = [:]
  private var selectedOverlayId: String?
  private var editingOverlayId: String?
  private var editorColorHex = "#FFFFFF"
  private var editorFontSize: CGFloat = 30.0
  private var editorFont: NativeStoryComposerFont = .system
  private var editorAlignment: NSTextAlignment = .center
  private var editorShowsColorPicker = false
  private var keyboardHeight: CGFloat = 0.0
  private var promptText = ""

  private var selectedAudience: NativeStoryComposerAudience = .everyone
  private var selectedDuration = 24

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = UIColor(white: 0.04, alpha: 1.0)
    clipsToBounds = true
    configureView()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleKeyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleKeyboardWillHide),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    backgroundColor = UIColor(white: 0.04, alpha: 1.0)
    clipsToBounds = true
    configureView()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    mediaView.setPlaybackPaused(window == nil)
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let safeTop = max(safeAreaInsets.top, 12.0)
    let safeBottom = max(safeAreaInsets.bottom, 16.0)

    cardContainer.frame = bounds
    mediaView.frame = cardContainer.bounds
    overlaysContainer.frame = cardContainer.bounds

    let topY = safeTop + 4.0
    let railWidth: CGFloat = 40.0
    let actionButtonSize: CGFloat = 36.0
    let actionSpacing: CGFloat = 4.0
    let railPadding: CGFloat = 4.0
    let railHeight = (actionButtonSize * 5.0) + (actionSpacing * 4.0) + (railPadding * 2.0)

    topBar.frame = CGRect(x: 14.0, y: topY, width: max(0.0, bounds.width - 28.0), height: railHeight)

    closeButtonGlassView.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    closeButton.frame = closeButtonGlassView.bounds

    topActionsView.frame = CGRect(
      x: max(52.0, topBar.bounds.width - railWidth),
      y: 0.0,
      width: railWidth,
      height: railHeight
    )
    let topButtons = [downloadButton, addTextButton, emojiButton, musicButton, settingsButton]
    for (index, button) in topButtons.enumerated() {
      button.frame = CGRect(
        x: (railWidth - actionButtonSize) * 0.5,
        y: railPadding + (CGFloat(index) * (actionButtonSize + actionSpacing)),
        width: actionButtonSize,
        height: actionButtonSize
      )
    }

    let bottomBarHeight: CGFloat = 48.0
    let promptKeyboardLift = promptTextView.isFirstResponder
      ? max(0.0, keyboardHeight - safeBottom + 6.0)
      : 0.0
    bottomBar.frame = CGRect(
      x: 12.0,
      y: bounds.height - safeBottom - bottomBarHeight - promptKeyboardLift,
      width: max(0.0, bounds.width - 24.0),
      height: bottomBarHeight
    )
    let promptExpanded = isPromptExpanded
    let nextButtonWidth: CGFloat = promptExpanded ? 0.0 : 76.0
    let nextGap: CGFloat = promptExpanded ? 0.0 : 8.0
    let promptWidth = max(0.0, bottomBar.bounds.width - nextButtonWidth - nextGap)
    promptChromeView.frame = CGRect(x: 0.0, y: 0.0, width: promptWidth, height: bottomBarHeight)
    nextButtonGlassView.frame = CGRect(
      x: promptChromeView.frame.maxX + nextGap,
      y: 0.0,
      width: nextButtonWidth,
      height: bottomBarHeight
    )
    nextButton.frame = nextButtonGlassView.bounds
    nextButtonGlassView.alpha = promptExpanded ? 0.0 : 1.0
    promptTextView.frame = CGRect(
      x: 14.0,
      y: 6.0,
      width: max(0.0, promptChromeView.bounds.width - 58.0),
      height: bottomBarHeight - 12.0
    )
    promptPlaceholderLabel.frame = CGRect(
      x: promptTextView.frame.minX + 4.0,
      y: 0.0,
      width: max(0.0, promptChromeView.bounds.width - 80.0),
      height: bottomBarHeight
    )
    promptSendButton.frame = CGRect(
      x: max(0.0, promptChromeView.bounds.width - 42.0),
      y: 6.0,
      width: 36.0,
      height: 36.0
    )

    if let selectedOverlayId, stickerViews[selectedOverlayId] != nil, !editorOverlay.isHidden {
      selectedActionBarGlassView.isHidden = true
    } else if let selectedOverlayId, let stickerView = stickerViews[selectedOverlayId] {
      selectedActionBarGlassView.isHidden = false
      let stickerFrame = overlaysContainer.convert(stickerView.frame, to: cardContainer)
      let barWidth: CGFloat = 92.0
      let barHeight: CGFloat = 36.0
      let barX = min(max(12.0, stickerFrame.midX - (barWidth * 0.5)), max(12.0, cardContainer.bounds.width - barWidth - 12.0))
      let barY = max(16.0, stickerFrame.minY - barHeight - 10.0)
      selectedActionBarGlassView.frame = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
      selectedEditButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: barHeight)
      selectedDeleteButton.frame = CGRect(x: barWidth - 44.0, y: 0.0, width: 44.0, height: barHeight)
    } else {
      selectedActionBarGlassView.isHidden = true
    }

    editorOverlay.frame = bounds
    let editorTop = safeTop + 4.0
    editorCancelGlassView.frame = CGRect(x: 16.0, y: editorTop, width: 72.0, height: 44.0)
    editorDoneGlassView.frame = CGRect(x: bounds.width - 88.0, y: editorTop, width: 72.0, height: 44.0)
    editorCancelButton.frame = editorCancelGlassView.bounds
    editorDoneButton.frame = editorDoneGlassView.bounds
    let controlsHeight: CGFloat = editorShowsColorPicker ? 96.0 : 48.0
    let editorBottomInset = keyboardHeight > 0.0 ? keyboardHeight + 6.0 : safeBottom
    editorControlsGlassView.frame = CGRect(
      x: 16.0,
      y: bounds.height - editorBottomInset - controlsHeight,
      width: max(0.0, bounds.width - 32.0),
      height: controlsHeight
    )

    let paddleWidth: CGFloat = 32.0
    let paddleHeight: CGFloat = 120.0
    let paddleY = max(editorTop + 52.0, (editorControlsGlassView.frame.minY - paddleHeight) * 0.5)
    editorSliderGlassView.frame = CGRect(
      x: 12.0,
      y: paddleY,
      width: paddleWidth,
      height: paddleHeight
    )
    editorSliderContainer.frame = editorSliderGlassView.bounds
    editorSliderTrackView.frame = editorSliderContainer.bounds
    let handleSize: CGFloat = 24.0
    editorSliderHandleView.frame = CGRect(
      x: (paddleWidth - handleSize) * 0.5,
      y: sliderHandleY(for: editorFontSize),
      width: handleSize,
      height: handleSize
    )

    let textX: CGFloat = 52.0
    let textWidth = max(120.0, bounds.width - 104.0)
    editorTextView.frame = CGRect(
      x: textX,
      y: paddleY,
      width: textWidth,
      height: min(220.0, editorControlsGlassView.frame.minY - paddleY - 20.0)
    )

    colorToggleButton.frame = CGRect(x: 6.0, y: 6.0, width: 36.0, height: 36.0)
    fontCycleButton.frame = CGRect(x: 48.0, y: 6.0, width: 86.0, height: 36.0)
    alignCycleButton.frame = CGRect(x: editorControlsGlassView.bounds.width - 42.0, y: 6.0, width: 36.0, height: 36.0)
    colorsScrollView.frame = CGRect(
      x: 6.0,
      y: 46.0,
      width: max(0.0, editorControlsGlassView.bounds.width - 12.0),
      height: editorShowsColorPicker ? 42.0 : 0.0
    )

    let colorButtonSize: CGFloat = 30.0
    for (index, button) in colorButtons.enumerated() {
      button.frame = CGRect(
        x: CGFloat(index) * (colorButtonSize + 8.0),
        y: 6.0,
        width: colorButtonSize,
        height: colorButtonSize
      )
    }
    colorsScrollView.contentSize = CGSize(
      width: CGFloat(colorButtons.count) * (colorButtonSize + 8.0),
      height: 42.0
    )

    publishBackdropView.frame = bounds
    let sheetHeight: CGFloat = 310.0 + safeBottom
    publishSheetGlassView.frame = CGRect(
      x: 12.0,
      y: bounds.height - sheetHeight - 8.0,
      width: max(0.0, bounds.width - 24.0),
      height: sheetHeight
    )
    publishTitleLabel.frame = CGRect(x: 18.0, y: 16.0, width: publishSheetGlassView.bounds.width - 36.0, height: 24.0)
    audienceStackView.frame = CGRect(x: 18.0, y: 50.0, width: publishSheetGlassView.bounds.width - 36.0, height: 38.0)
    durationTitleLabel.frame = CGRect(x: 18.0, y: audienceStackView.frame.maxY + 12.0, width: 140.0, height: 20.0)
    durationStackView.frame = CGRect(x: 18.0, y: durationTitleLabel.frame.maxY + 8.0, width: publishSheetGlassView.bounds.width - 36.0, height: 36.0)

    let switchRowY = durationStackView.frame.maxY + 14.0
    allowScreenshotsLabel.frame = CGRect(x: 18.0, y: switchRowY, width: 200.0, height: 24.0)
    allowScreenshotsSwitch.frame = CGRect(
      x: publishSheetGlassView.bounds.width - allowScreenshotsSwitch.bounds.width - 18.0,
      y: switchRowY - 4.0,
      width: allowScreenshotsSwitch.bounds.width,
      height: allowScreenshotsSwitch.bounds.height
    )
    postToProfileLabel.frame = CGRect(x: 18.0, y: switchRowY + 36.0, width: 200.0, height: 24.0)
    postToProfileSwitch.frame = CGRect(
      x: publishSheetGlassView.bounds.width - postToProfileSwitch.bounds.width - 18.0,
      y: switchRowY + 32.0,
      width: postToProfileSwitch.bounds.width,
      height: postToProfileSwitch.bounds.height
    )

    let actionY = publishSheetGlassView.bounds.height - safeBottom - 50.0
    let buttonWidth = floor((publishSheetGlassView.bounds.width - 46.0) / 3.0)
    publishCancelButton.frame = CGRect(x: 14.0, y: actionY, width: buttonWidth, height: 44.0)
    saveDraftButton.frame = CGRect(x: publishCancelButton.frame.maxX + 9.0, y: actionY, width: buttonWidth, height: 44.0)
    publishButton.frame = CGRect(x: saveDraftButton.frame.maxX + 9.0, y: actionY, width: buttonWidth, height: 44.0)
  }

  func setMediaUri(_ value: String?) {
    mediaUri = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    applyMedia()
  }

  func setMediaType(_ value: String?) {
    mediaType = value.flatMap(NativeStoryComposerMediaType.init(rawValue:))
    applyMedia()
  }

  func setMirrored(_ value: Bool) {
    mirrored = value
    applyMedia()
  }

  @objc private func handleKeyboardWillChangeFrame(_ notification: Notification) {
    guard
      let userInfo = notification.userInfo,
      let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
    else { return }

    let convertedFrame = convert(endFrame, from: nil)
    keyboardHeight = max(0.0, bounds.maxY - convertedFrame.minY)
    let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    UIView.animate(withDuration: duration) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  @objc private func handleKeyboardWillHide() {
    keyboardHeight = 0.0
    UIView.animate(withDuration: 0.25) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  @objc private func handleCanvasTap() {
    selectedOverlayId = nil
    updateStickerSelection()
  }

  @objc private func handleClosePress() {
    let alert = UIAlertController(
      title: "Discard Edits?",
      message: "Are you sure you want to discard your story? This cannot be undone.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
        self?.onEvent?(["type": "discard"])
      }
    )
    if let controller = presentingViewController() {
      controller.present(alert, animated: true)
    } else {
      onEvent?(["type": "discard"])
    }
  }

  @objc private func handleAddTextPress() {
    beginEditingOverlay(nil)
  }

  @objc private func handleDownloadPress() {
    saveCurrentMediaToLibrary()
  }

  @objc private func handleEmojiPress() {
    presentInfoAlert(title: "Not Available Yet", message: "Emoji stickers are not wired in the native composer yet.")
  }

  @objc private func handleMusicPress() {
    presentInfoAlert(title: "Not Available Yet", message: "Music stickers are not wired in the native composer yet.")
  }

  @objc private func handleSettingsPress() {
    presentInfoAlert(title: "No Settings Yet", message: "Story settings are still using the publish sheet for now.")
  }

  @objc private func handleNextPress() {
    endEditing(true)
    showPublishSheet(true)
  }

  @objc private func handleSelectedEditPress() {
    guard let selectedOverlayId else { return }
    beginEditingOverlay(selectedOverlayId)
  }

  @objc private func handleSelectedDeletePress() {
    guard let selectedOverlayId else { return }
    deleteOverlay(withId: selectedOverlayId)
  }

  @objc private func handleEditorCancelPress() {
    endEditing(true)
    hideEditor()
  }

  @objc private func handleEditorDonePress() {
    let trimmed = editorTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      if let editingOverlayId {
        deleteOverlay(withId: editingOverlayId)
      } else {
        selectedOverlayId = nil
      }
      hideEditor()
      return
    }

    if let editingOverlayId, let index = overlays.firstIndex(where: { $0.id == editingOverlayId }) {
      overlays[index].text = trimmed
      overlays[index].colorHex = editorColorHex
      overlays[index].fontSize = editorFontSize
      overlays[index].font = editorFont
      overlays[index].alignment = editorAlignment
      selectedOverlayId = editingOverlayId
    } else {
      let newId = UUID().uuidString
      let overlay = NativeStoryComposerTextOverlay(
        id: newId,
        text: trimmed,
        center: CGPoint(x: overlaysContainer.bounds.midX, y: overlaysContainer.bounds.midY * 0.65),
        colorHex: editorColorHex,
        fontSize: editorFontSize,
        font: editorFont,
        alignment: editorAlignment
      )
      overlays.append(overlay)
      selectedOverlayId = newId
    }

    syncStickers()
    hideEditor()
  }

  @objc private func handleColorTogglePress() {
    editorShowsColorPicker.toggle()
    UIView.animate(withDuration: 0.2) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  @objc private func handleFontCyclePress() {
    let allFonts = NativeStoryComposerFont.allCases
    guard let currentIndex = allFonts.firstIndex(of: editorFont) else { return }
    editorFont = allFonts[(currentIndex + 1) % allFonts.count]
    updateEditorControls()
  }

  @objc private func handleAlignCyclePress() {
    switch editorAlignment {
    case .left:
      editorAlignment = .center
    case .center:
      editorAlignment = .right
    default:
      editorAlignment = .left
    }
    updateEditorControls()
  }

  @objc private func handleEditorSliderPan(_ gesture: UIPanGestureRecognizer) {
    let location = gesture.location(in: editorSliderContainer)
    updateEditorFontSize(fromSliderY: location.y)
  }

  @objc private func handlePromptSendPress() {
    let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    promptText = ""
    promptTextView.text = ""
    promptTextView.resignFirstResponder()
    updatePromptUI(animated: true)
    onEvent?( [
      "type": "aiEdit",
      "prompt": prompt,
    ])
  }

  @objc private func handlePublishCancelPress() {
    showPublishSheet(false)
  }

  @objc private func handleSaveDraftPress() {
    showPublishSheet(false)
    onEvent?(["type": "saveDraft"])
  }

  @objc private func handlePublishPress() {
    showPublishSheet(false)
    var event: [String: Any] = [
      "type": "publish",
      "audience": selectedAudience.rawValue,
      "allowScreenshots": allowScreenshotsSwitch.isOn,
      "postToProfile": postToProfileSwitch.isOn,
      "duration": selectedDuration,
    ]
    if let renderedImageURL = renderedImageURLForPublish() {
      event["renderedUri"] = renderedImageURL.absoluteString
      event["renderedMediaType"] = "image"
      event["originalUri"] = mediaUri
    }
    onEvent?(event)
  }

  private func configureView() {
    cardContainer.backgroundColor = .black
    cardContainer.layer.cornerRadius = 0.0
    cardContainer.layer.borderWidth = 0.0
    cardContainer.clipsToBounds = true
    addSubview(cardContainer)

    cardContainer.addSubview(mediaView)

    overlaysContainer.backgroundColor = .clear
    cardContainer.addSubview(overlaysContainer)

    let canvasTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap))
    canvasTap.cancelsTouchesInView = false
    overlaysContainer.addGestureRecognizer(canvasTap)

    topBar.backgroundColor = .clear
    cardContainer.addSubview(topBar)

    closeButtonGlassView = makeLiquidGlassView(cornerRadius: 22.0, capsule: true)
    topBar.addSubview(closeButtonGlassView)

    configureChromeButton(closeButton, glyph: .close)
    closeButton.accessibilityLabel = "Close"
    closeButton.backgroundColor = .clear
    closeButton.layer.borderWidth = 0.0
    closeButtonGlassView.contentView.addSubview(closeButton)

    topActionsView = makeLiquidGlassView(cornerRadius: 20.0, capsule: true)
    topBar.addSubview(topActionsView)

    configureTopActionButton(downloadButton, glyph: .download)
    downloadButton.accessibilityLabel = "Save"
    downloadButton.addTarget(self, action: #selector(handleDownloadPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(downloadButton)

    configureTopActionButton(addTextButton, glyph: .text)
    addTextButton.accessibilityLabel = "Add Text"
    addTextButton.addTarget(self, action: #selector(handleAddTextPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(addTextButton)

    configureTopActionButton(emojiButton, glyph: .emoji)
    emojiButton.accessibilityLabel = "Add Emoji"
    emojiButton.addTarget(self, action: #selector(handleEmojiPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(emojiButton)

    configureTopActionButton(musicButton, glyph: .music)
    musicButton.accessibilityLabel = "Add Music"
    musicButton.addTarget(self, action: #selector(handleMusicPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(musicButton)

    configureTopActionButton(settingsButton, glyph: .settings)
    settingsButton.accessibilityLabel = "Story Settings"
    settingsButton.addTarget(self, action: #selector(handleSettingsPress), for: .touchUpInside)
    topActionsView.contentView.addSubview(settingsButton)

    selectedActionBarGlassView = makeLiquidGlassView(cornerRadius: 18.0, capsule: true)
    selectedActionBarGlassView.isHidden = true
    cardContainer.addSubview(selectedActionBarGlassView)

    configureSmallActionButton(selectedEditButton, glyph: .edit)
    selectedEditButton.accessibilityLabel = "Edit Text"
    selectedEditButton.addTarget(self, action: #selector(handleSelectedEditPress), for: .touchUpInside)
    selectedActionBarGlassView.contentView.addSubview(selectedEditButton)

    configureSmallActionButton(selectedDeleteButton, glyph: .delete)
    selectedDeleteButton.accessibilityLabel = "Delete Text"
    selectedDeleteButton.tintColor = UIColor(red: 1.0, green: 0.36, blue: 0.32, alpha: 1.0)
    selectedDeleteButton.addTarget(self, action: #selector(handleSelectedDeletePress), for: .touchUpInside)
    selectedActionBarGlassView.contentView.addSubview(selectedDeleteButton)

    bottomBar.backgroundColor = .clear
    addSubview(bottomBar)

    promptChromeView = makeLiquidGlassView(cornerRadius: 24.0, capsule: true)
    bottomBar.addSubview(promptChromeView)

    promptTextView.backgroundColor = .clear
    promptTextView.textColor = .white
    promptTextView.tintColor = .white
    promptTextView.font = .systemFont(ofSize: 15.0, weight: .medium)
    promptTextView.textContainerInset = UIEdgeInsets(top: 8.0, left: 0.0, bottom: 8.0, right: 0.0)
    promptTextView.textContainer.lineFragmentPadding = 0.0
    promptTextView.returnKeyType = .send
    promptTextView.autocorrectionType = .yes
    promptTextView.delegate = self
    promptChromeView.contentView.addSubview(promptTextView)

    promptPlaceholderLabel.text = "Ask AI to edit..."
    promptPlaceholderLabel.textColor = UIColor.white.withAlphaComponent(0.55)
    promptPlaceholderLabel.font = .systemFont(ofSize: 15.0, weight: .medium)
    promptChromeView.contentView.addSubview(promptPlaceholderLabel)

    promptSendButton.layer.cornerRadius = 18.0
    promptSendButton.layer.cornerCurve = .continuous
    promptSendButton.tintColor = .white
    promptSendButton.setImage(UIImage.appStoryGlyph(.send, pointSize: 14.0), for: .normal)
    promptSendButton.accessibilityLabel = "Send Edit Prompt"
    promptSendButton.addTarget(self, action: #selector(handlePromptSendPress), for: .touchUpInside)
    promptChromeView.contentView.addSubview(promptSendButton)

    nextButtonGlassView = makeLiquidGlassView(
      cornerRadius: 24.0,
      capsule: true,
      tintColor: UIColor.systemBlue.withAlphaComponent(0.42)
    )
    nextButton.backgroundColor = .clear
    nextButton.setTitle("Next", for: .normal)
    nextButton.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
    nextButton.setTitleColor(.white, for: .normal)
    nextButton.addTarget(self, action: #selector(handleNextPress), for: .touchUpInside)
    nextButtonGlassView.contentView.addSubview(nextButton)
    bottomBar.addSubview(nextButtonGlassView)

    editorOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.11)
    editorOverlay.isHidden = true
    addSubview(editorOverlay)

    editorCancelGlassView = makeLiquidGlassView(cornerRadius: 22.0, capsule: true)
    editorOverlay.addSubview(editorCancelGlassView)
    editorCancelButton.setTitle("Cancel", for: .normal)
    editorCancelButton.setTitleColor(.white, for: .normal)
    editorCancelButton.titleLabel?.font = .systemFont(ofSize: 16.0, weight: .medium)
    editorCancelButton.addTarget(self, action: #selector(handleEditorCancelPress), for: .touchUpInside)
    editorCancelGlassView.contentView.addSubview(editorCancelButton)

    editorDoneGlassView = makeLiquidGlassView(cornerRadius: 22.0, capsule: true)
    editorOverlay.addSubview(editorDoneGlassView)
    editorDoneButton.setTitle("Done", for: .normal)
    editorDoneButton.setTitleColor(.white, for: .normal)
    editorDoneButton.titleLabel?.font = .systemFont(ofSize: 16.0, weight: .semibold)
    editorDoneButton.addTarget(self, action: #selector(handleEditorDonePress), for: .touchUpInside)
    editorDoneGlassView.contentView.addSubview(editorDoneButton)

    editorTextView.backgroundColor = .clear
    editorTextView.textColor = .white
    editorTextView.font = .systemFont(ofSize: editorFontSize, weight: .bold)
    editorTextView.textAlignment = editorAlignment
    editorTextView.returnKeyType = .default
    editorTextView.tintColor = .white
    editorTextView.textContainerInset = .zero
    editorTextView.textContainer.lineFragmentPadding = 0.0
    editorTextView.delegate = self
    editorOverlay.addSubview(editorTextView)

    editorSliderGlassView = makeLiquidGlassView(cornerRadius: 16.0, capsule: true)
    editorOverlay.addSubview(editorSliderGlassView)

    editorSliderContainer.backgroundColor = .clear
    let sliderPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleEditorSliderPan(_:)))
    editorSliderContainer.addGestureRecognizer(sliderPanGesture)
    editorSliderGlassView.contentView.addSubview(editorSliderContainer)

    editorSliderContainer.addSubview(editorSliderTrackView)

    editorSliderHandleView.backgroundColor = .white
    editorSliderHandleView.layer.cornerRadius = 12.0
    editorSliderHandleView.layer.cornerCurve = .continuous
    editorSliderHandleView.layer.shadowColor = UIColor.black.cgColor
    editorSliderHandleView.layer.shadowOpacity = 0.2
    editorSliderHandleView.layer.shadowRadius = 6.0
    editorSliderHandleView.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
    editorSliderContainer.addSubview(editorSliderHandleView)

    editorControlsGlassView = makeLiquidGlassView(cornerRadius: 22.0)
    editorOverlay.addSubview(editorControlsGlassView)

    configureRoundSymbolButton(colorToggleButton, glyph: .color)
    colorToggleButton.accessibilityLabel = "Text Color"
    colorToggleButton.addTarget(self, action: #selector(handleColorTogglePress), for: .touchUpInside)
    editorControlsGlassView.contentView.addSubview(colorToggleButton)

    configureRoundButton(fontCycleButton, title: editorFont.title)
    fontCycleButton.addTarget(self, action: #selector(handleFontCyclePress), for: .touchUpInside)
    editorControlsGlassView.contentView.addSubview(fontCycleButton)

    configureRoundSymbolButton(alignCycleButton, glyph: .alignCenter)
    alignCycleButton.accessibilityLabel = "Text Alignment"
    alignCycleButton.addTarget(self, action: #selector(handleAlignCyclePress), for: .touchUpInside)
    editorControlsGlassView.contentView.addSubview(alignCycleButton)

    colorsScrollView.showsHorizontalScrollIndicator = false
    editorControlsGlassView.contentView.addSubview(colorsScrollView)
    configureColorButtons()

    publishBackdropView.backgroundColor = UIColor.black.withAlphaComponent(0.48)
    publishBackdropView.alpha = 0.0
    publishBackdropView.isHidden = true
    let publishTap = UITapGestureRecognizer(target: self, action: #selector(handlePublishCancelPress))
    publishBackdropView.addGestureRecognizer(publishTap)
    addSubview(publishBackdropView)

    publishSheetGlassView = makeLiquidGlassView(cornerRadius: 28.0)
    publishSheetGlassView.contentView.backgroundColor = .clear
    publishSheetGlassView.alpha = 0.0
    publishSheetGlassView.transform = CGAffineTransform(translationX: 0.0, y: 40.0)
    publishSheetGlassView.isHidden = true
    addSubview(publishSheetGlassView)

    publishTitleLabel.text = "Publish Story"
    publishTitleLabel.textColor = .white
    publishTitleLabel.font = .systemFont(ofSize: 20.0, weight: .semibold)
    publishSheetGlassView.contentView.addSubview(publishTitleLabel)

    audienceStackView.axis = .horizontal
    audienceStackView.alignment = .fill
    audienceStackView.distribution = .fillEqually
    audienceStackView.spacing = 10.0
    publishSheetGlassView.contentView.addSubview(audienceStackView)
    configureAudienceButtons()

    durationTitleLabel.text = "Duration"
    durationTitleLabel.textColor = UIColor.white.withAlphaComponent(0.8)
    durationTitleLabel.font = .systemFont(ofSize: 14.0, weight: .medium)
    publishSheetGlassView.contentView.addSubview(durationTitleLabel)

    durationStackView.axis = .horizontal
    durationStackView.alignment = .fill
    durationStackView.distribution = .fillEqually
    durationStackView.spacing = 10.0
    publishSheetGlassView.contentView.addSubview(durationStackView)
    configureDurationButtons()

    allowScreenshotsLabel.text = "Allow Screenshots"
    allowScreenshotsLabel.textColor = .white
    allowScreenshotsLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    publishSheetGlassView.contentView.addSubview(allowScreenshotsLabel)

    allowScreenshotsSwitch.isOn = true
    publishSheetGlassView.contentView.addSubview(allowScreenshotsSwitch)

    postToProfileLabel.text = "Post To Profile"
    postToProfileLabel.textColor = .white
    postToProfileLabel.font = .systemFont(ofSize: 16.0, weight: .medium)
    publishSheetGlassView.contentView.addSubview(postToProfileLabel)

    postToProfileSwitch.isOn = true
    publishSheetGlassView.contentView.addSubview(postToProfileSwitch)

    configureSheetActionButton(publishCancelButton, title: "Cancel", fillColor: UIColor.white.withAlphaComponent(0.12))
    publishCancelButton.addTarget(self, action: #selector(handlePublishCancelPress), for: .touchUpInside)
    publishSheetGlassView.contentView.addSubview(publishCancelButton)

    configureSheetActionButton(saveDraftButton, title: "Draft", fillColor: UIColor.white.withAlphaComponent(0.16))
    saveDraftButton.addTarget(self, action: #selector(handleSaveDraftPress), for: .touchUpInside)
    publishSheetGlassView.contentView.addSubview(saveDraftButton)

    configureSheetActionButton(publishButton, title: "Publish", fillColor: UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.92))
    publishButton.addTarget(self, action: #selector(handlePublishPress), for: .touchUpInside)
    publishSheetGlassView.contentView.addSubview(publishButton)

    updateEditorControls()
    updateAudienceButtons()
    updateDurationButtons()
  }

  private func configureChromeButton(_ button: UIButton, glyph: AppStoryVectorGlyph) {
    button.backgroundColor = UIColor.black.withAlphaComponent(0.28)
    button.layer.cornerRadius = 22.0
    button.layer.cornerCurve = .continuous
    button.layer.borderWidth = 1.0
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    button.tintColor = .white
    button.setImage(UIImage.appStoryGlyph(glyph, pointSize: 18.0), for: .normal)
  }

  private func configureTopActionButton(_ button: UIButton, glyph: AppStoryVectorGlyph) {
    button.tintColor = .white
    button.setImage(UIImage.appStoryGlyph(glyph, pointSize: 18.0), for: .normal)
  }

  private func configureSmallActionButton(_ button: UIButton, glyph: AppStoryVectorGlyph) {
    button.tintColor = .white
    button.setImage(UIImage.appStoryGlyph(glyph, pointSize: 15.0), for: .normal)
  }

  private func configureRoundButton(_ button: UIButton, title: String) {
    button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    button.layer.cornerRadius = 18.0
    button.layer.cornerCurve = .continuous
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 13.0, weight: .semibold)
  }

  private func configureRoundSymbolButton(_ button: UIButton, glyph: AppStoryVectorGlyph) {
    button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    button.layer.cornerRadius = 18.0
    button.layer.cornerCurve = .continuous
    button.tintColor = .white
    button.setImage(UIImage.appStoryGlyph(glyph, pointSize: 15.0), for: .normal)
  }

  private func configureColorButtons() {
    colorButtons.forEach { $0.removeFromSuperview() }
    colorButtons.removeAll()
    for hex in composerColors {
      let button = UIButton(type: .custom)
      button.layer.cornerRadius = 15.0
      button.layer.cornerCurve = .continuous
      button.backgroundColor = UIColor.nativeStoryComposerColor(from: hex)
      button.layer.borderWidth = 2.0
      button.layer.borderColor = UIColor.clear.cgColor
      button.accessibilityLabel = hex
      button.addAction(
        UIAction { [weak self] _ in
          self?.editorColorHex = hex
          self?.updateEditorControls()
        },
        for: .touchUpInside
      )
      colorsScrollView.addSubview(button)
      colorButtons.append(button)
    }
  }

  private func configureAudienceButtons() {
    NativeStoryComposerAudience.allCases.forEach { audience in
      let button = UIButton(type: .system)
      button.layer.cornerRadius = 18.0
      button.layer.cornerCurve = .continuous
      button.titleLabel?.font = .systemFont(ofSize: 13.0, weight: .semibold)
      button.setTitle(audience.title, for: .normal)
      button.addAction(
        UIAction { [weak self] _ in
          self?.selectedAudience = audience
          self?.updateAudienceButtons()
        },
        for: .touchUpInside
      )
      audienceButtons[audience] = button
      audienceStackView.addArrangedSubview(button)
    }
  }

  private func configureDurationButtons() {
    [12, 24, 48].forEach { duration in
      let button = UIButton(type: .system)
      button.layer.cornerRadius = 18.0
      button.layer.cornerCurve = .continuous
      button.titleLabel?.font = .systemFont(ofSize: 14.0, weight: .semibold)
      button.setTitle("\(duration)h", for: .normal)
      button.addAction(
        UIAction { [weak self] _ in
          self?.selectedDuration = duration
          self?.updateDurationButtons()
        },
        for: .touchUpInside
      )
      durationButtons[duration] = button
      durationStackView.addArrangedSubview(button)
    }
  }

  private func configureSheetActionButton(_ button: UIButton, title: String, fillColor: UIColor) {
    button.backgroundColor = fillColor
    button.layer.cornerRadius = 16.0
    button.layer.cornerCurve = .continuous
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 14.0, weight: .semibold)
  }

  private func applyMedia() {
    mediaView.setMedia(uri: mediaUri, type: mediaType, mirrored: mirrored)
  }

  private func beginEditingOverlay(_ overlayId: String?) {
    editingOverlayId = overlayId
    if let overlayId, let overlay = overlays.first(where: { $0.id == overlayId }) {
      editorTextView.text = overlay.text
      editorColorHex = overlay.colorHex
      editorFontSize = overlay.fontSize
      editorFont = overlay.font
      editorAlignment = overlay.alignment
    } else {
      editorTextView.text = ""
      editorColorHex = "#FFFFFF"
      editorFontSize = 30.0
      editorFont = .system
      editorAlignment = .center
    }
    editorShowsColorPicker = false
    updateEditorControls()
    editorOverlay.isHidden = false
    bringSubviewToFront(editorOverlay)
    setNeedsLayout()
    layoutIfNeeded()
    editorTextView.becomeFirstResponder()
  }

  private func hideEditor() {
    editingOverlayId = nil
    endEditing(true)
    editorShowsColorPicker = false
    editorOverlay.isHidden = true
    updateEditorControls()
    setNeedsLayout()
  }

  private func updateEditorControls() {
    editorTextView.textColor = UIColor.nativeStoryComposerColor(from: editorColorHex)
    editorTextView.font = editorFont.font(ofSize: editorFontSize)
    editorTextView.textAlignment = editorAlignment
    fontCycleButton.setTitle(editorFont.title, for: .normal)

    colorButtons.forEach { button in
      let isSelected = button.accessibilityLabel == editorColorHex
      button.layer.borderColor = isSelected ? UIColor.white.cgColor : UIColor.clear.cgColor
    }

    let activeColor = UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
    fontCycleButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    fontCycleButton.setTitleColor(.white, for: .normal)
    colorToggleButton.tintColor = UIColor.nativeStoryComposerColor(from: editorColorHex)
    colorToggleButton.backgroundColor = editorShowsColorPicker
      ? activeColor
      : UIColor.white.withAlphaComponent(0.12)
    alignCycleButton.backgroundColor = activeColor
    alignCycleButton.tintColor = .white
    switch editorAlignment {
    case .left:
      alignCycleButton.setImage(UIImage.appStoryGlyph(.alignLeft, pointSize: 15.0), for: .normal)
    case .center:
      alignCycleButton.setImage(UIImage.appStoryGlyph(.alignCenter, pointSize: 15.0), for: .normal)
    case .right:
      alignCycleButton.setImage(UIImage.appStoryGlyph(.alignRight, pointSize: 15.0), for: .normal)
    default:
      break
    }
    updatePromptUI(animated: false)
  }

  private func syncStickers() {
    let overlayIds = Set(overlays.map(\.id))

    let removedIds = stickerViews.keys.filter { !overlayIds.contains($0) }
    for id in removedIds {
      guard let stickerView = stickerViews[id] else { continue }
      stickerView.removeFromSuperview()
      stickerViews.removeValue(forKey: id)
    }

    for overlay in overlays {
      let stickerView: NativeStoryComposerStickerView
      if let existing = stickerViews[overlay.id] {
        stickerView = existing
      } else {
        let created = NativeStoryComposerStickerView()
        created.onSelect = { [weak self] overlayId in
          self?.selectedOverlayId = overlayId
          self?.updateStickerSelection()
        }
        created.onMove = { [weak self] overlayId, center in
          self?.updateOverlayPosition(id: overlayId, center: center)
        }
        overlaysContainer.addSubview(created)
        stickerViews[overlay.id] = created
        stickerView = created
      }

      stickerView.apply(overlay: overlay, selected: selectedOverlayId == overlay.id)
      stickerView.center = clampedCenter(for: overlay.center, stickerBounds: stickerView.bounds)
    }

    updateStickerSelection()
  }

  private func updateStickerSelection() {
    for overlay in overlays {
      if let stickerView = stickerViews[overlay.id] {
        stickerView.apply(overlay: overlay, selected: selectedOverlayId == overlay.id)
        stickerView.center = clampedCenter(for: overlay.center, stickerBounds: stickerView.bounds)
      }
    }
    setNeedsLayout()
  }

  private func updateOverlayPosition(id: String, center: CGPoint) {
    guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
    overlays[index].center = clampedCenter(for: center, stickerBounds: stickerViews[id]?.bounds ?? .zero)
    if let stickerView = stickerViews[id] {
      stickerView.center = overlays[index].center
    }
    setNeedsLayout()
  }

  private func deleteOverlay(withId id: String) {
    overlays.removeAll { $0.id == id }
    stickerViews[id]?.removeFromSuperview()
    stickerViews.removeValue(forKey: id)
    if selectedOverlayId == id {
      selectedOverlayId = nil
    }
    setNeedsLayout()
  }

  private var isPromptExpanded: Bool {
    promptTextView.isFirstResponder || !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sliderHandleY(for fontSize: CGFloat) -> CGFloat {
    let handleSize: CGFloat = 24.0
    let trackHeight = max(1.0, editorSliderContainer.bounds.height - handleSize)
    let clamped = max(10.0, min(100.0, fontSize))
    let progress = 1.0 - ((clamped - 10.0) / 90.0)
    return max(0.0, min(trackHeight, progress * trackHeight))
  }

  private func updateEditorFontSize(fromSliderY y: CGFloat) {
    let handleSize: CGFloat = 24.0
    let trackHeight = max(1.0, editorSliderContainer.bounds.height - handleSize)
    let clampedY = max(0.0, min(trackHeight, y - (handleSize * 0.5)))
    let progress = 1.0 - (clampedY / trackHeight)
    editorFontSize = max(10.0, min(100.0, 10.0 + (progress * 90.0)))
    updateEditorControls()
    setNeedsLayout()
  }

  private func updatePromptUI(animated: Bool) {
    let applyChanges = {
      let trimmed = self.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasPrompt = !trimmed.isEmpty
      self.promptPlaceholderLabel.isHidden = !self.promptText.isEmpty
      self.promptSendButton.backgroundColor = hasPrompt
        ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.92)
        : UIColor.white.withAlphaComponent(0.12)
      self.promptSendButton.alpha = hasPrompt ? 1.0 : 0.82
      self.promptSendButton.isEnabled = hasPrompt
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }

    if animated {
      UIView.animate(withDuration: 0.22, animations: applyChanges)
    } else {
      applyChanges()
    }
  }

  private func clampedCenter(for center: CGPoint, stickerBounds: CGRect) -> CGPoint {
    let halfWidth = stickerBounds.width * 0.5
    let halfHeight = stickerBounds.height * 0.5
    let insetX = max(halfWidth + 12.0, 12.0)
    let insetY = max(halfHeight + 12.0, 12.0)
    return CGPoint(
      x: min(max(insetX, center.x), max(insetX, overlaysContainer.bounds.width - insetX)),
      y: min(max(insetY, center.y), max(insetY, overlaysContainer.bounds.height - insetY))
    )
  }

  private func saveCurrentMediaToLibrary() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    switch status {
    case .authorized, .limited:
      performSaveCurrentMedia()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] nextStatus in
        DispatchQueue.main.async {
          if nextStatus == .authorized || nextStatus == .limited {
            self?.performSaveCurrentMedia()
          } else {
            self?.presentInfoAlert(
              title: "Permission Needed",
              message: "Allow Photos access to save this story."
            )
          }
        }
      }
    default:
      presentInfoAlert(title: "Permission Needed", message: "Allow Photos access to save this story.")
    }
  }

  private func performSaveCurrentMedia() {
    guard let uri = mediaUri else {
      presentInfoAlert(title: "Save Failed", message: "No media is loaded.")
      return
    }
    guard let url = URL(string: uri) else {
      presentInfoAlert(title: "Save Failed", message: "The media URL is invalid.")
      return
    }

    switch mediaType {
    case .video:
      guard url.isFileURL else {
        presentInfoAlert(title: "Save Failed", message: "Video can only be saved from a local file.")
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }) { [weak self] success, _ in
        DispatchQueue.main.async {
          if success {
            self?.presentInfoAlert(title: "Saved", message: "Story saved to your gallery.")
          } else {
            self?.presentInfoAlert(title: "Save Failed", message: "Could not save this video.")
          }
        }
      }
    case .image:
      guard let image = imageForSave(from: uri) else {
        presentInfoAlert(title: "Save Failed", message: "Could not load this image.")
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }) { [weak self] success, _ in
        DispatchQueue.main.async {
          if success {
            self?.presentInfoAlert(title: "Saved", message: "Story saved to your gallery.")
          } else {
            self?.presentInfoAlert(title: "Save Failed", message: "Could not save this image.")
          }
        }
      }
    case .none:
      presentInfoAlert(title: "Save Failed", message: "No media is loaded.")
    }
  }

  private func imageForSave(from uri: String) -> UIImage? {
    if uri.hasPrefix("data:image"), let commaIndex = uri.firstIndex(of: ",") {
      let payload = String(uri[uri.index(after: commaIndex)...])
      if let data = Data(base64Encoded: payload) {
        return UIImage(data: data)
      }
    }

    guard let url = URL(string: uri) else { return nil }
    if url.isFileURL {
      return UIImage(contentsOfFile: url.path)
    }
    if let data = try? Data(contentsOf: url) {
      return UIImage(data: data)
    }
    return nil
  }

  private func renderedImageURLForPublish() -> URL? {
    guard mediaType == .image, bounds.width > 1, bounds.height > 1 else { return nil }
    let renderer = UIGraphicsImageRenderer(bounds: cardContainer.bounds)
    let image = renderer.image { context in
      mediaView.drawHierarchy(in: cardContainer.bounds, afterScreenUpdates: true)
      overlaysContainer.drawHierarchy(in: cardContainer.bounds, afterScreenUpdates: true)
      context.cgContext.flush()
    }
    guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-story-rendered-\(UUID().uuidString).jpg")
    do {
      try data.write(to: outputURL, options: [.atomic])
      return outputURL
    } catch {
      return nil
    }
  }

  private func presentInfoAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    if let controller = presentingViewController() {
      controller.present(alert, animated: true)
    }
  }

  private func showPublishSheet(_ visible: Bool) {
    if visible {
      publishBackdropView.isHidden = false
      publishSheetGlassView.isHidden = false
      bringSubviewToFront(publishBackdropView)
      bringSubviewToFront(publishSheetGlassView)
      UIView.animate(withDuration: 0.22) {
        self.publishBackdropView.alpha = 1.0
        self.publishSheetGlassView.alpha = 1.0
        self.publishSheetGlassView.transform = .identity
      }
      return
    }

    UIView.animate(withDuration: 0.18) {
      self.publishBackdropView.alpha = 0.0
      self.publishSheetGlassView.alpha = 0.0
      self.publishSheetGlassView.transform = CGAffineTransform(translationX: 0.0, y: 40.0)
    } completion: { _ in
      self.publishBackdropView.isHidden = true
      self.publishSheetGlassView.isHidden = true
    }
  }

  private func updateAudienceButtons() {
    for (audience, button) in audienceButtons {
      let active = audience == selectedAudience
      button.backgroundColor = active
        ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
        : UIColor.white.withAlphaComponent(0.1)
      button.setTitleColor(.white, for: .normal)
    }
  }

  private func updateDurationButtons() {
    for (duration, button) in durationButtons {
      let active = duration == selectedDuration
      button.backgroundColor = active
        ? UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9)
        : UIColor.white.withAlphaComponent(0.1)
      button.setTitleColor(.white, for: .normal)
    }
  }

  func textViewDidBeginEditing(_ textView: UITextView) {
    if textView === promptTextView {
      updatePromptUI(animated: true)
    }
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    if textView === promptTextView {
      updatePromptUI(animated: true)
    }
  }

  func textViewDidChange(_ textView: UITextView) {
    if textView === promptTextView {
      promptText = textView.text ?? ""
      updatePromptUI(animated: false)
    }
  }

  func textView(
    _ textView: UITextView,
    shouldChangeTextIn range: NSRange,
    replacementText text: String
  ) -> Bool {
    if textView === promptTextView, text == "\n" {
      handlePromptSendPress()
      return false
    }
    return true
  }

  private func presentingViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let controller = current as? UIViewController {
        return controller
      }
      responder = current.next
    }
    return nil
  }
}

struct AppNativeStoryComposerRepresentable: UIViewRepresentable {
  let media: AppNativeStoryCapturedMedia
  let onEvent: ([String: Any]) -> Void

  func makeUIView(context: Context) -> AppNativeStoryComposerView {
    let view = AppNativeStoryComposerView(frame: .zero)
    apply(media: media, to: view)
    view.onEvent = onEvent
    return view
  }

  func updateUIView(_ uiView: AppNativeStoryComposerView, context: Context) {
    apply(media: media, to: uiView)
    uiView.onEvent = onEvent
  }

  private func apply(media: AppNativeStoryCapturedMedia, to view: AppNativeStoryComposerView) {
    view.setMediaUri(media.url.absoluteString)
    view.setMediaType(media.kind.rawValue)
    view.setMirrored(media.mirrored)
  }
}
