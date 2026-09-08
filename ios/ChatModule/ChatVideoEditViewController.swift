import AVFoundation
import Photos
import UIKit

private enum ChatVideoExportQuality: CaseIterable {
  case p1080
  case p720
  case p540

  var label: String {
    switch self {
    case .p1080:
      return "1080"
    case .p720:
      return "720"
    case .p540:
      return "540"
    }
  }

  var preferredPresets: [String] {
    switch self {
    case .p1080:
      return [
        AVAssetExportPreset1920x1080,
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPresetMediumQuality,
      ]
    case .p720:
      return [
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPresetMediumQuality,
      ]
    case .p540:
      return [
        AVAssetExportPreset960x540,
        AVAssetExportPresetMediumQuality,
      ]
    }
  }
}

private final class ChatVideoTrimTimelineView: UIView {
  private enum HandleKind {
    case left
    case right
  }

  var onSelectionChanged: ((CGFloat, CGFloat, Bool) -> Void)?
  var onScrubRequested: ((CGFloat) -> Void)?

  private let trackView = UIView()
  private let thumbnailsContainerView = UIView()
  private let leftDimView = UIView()
  private let rightDimView = UIView()
  private let selectionBorderView = UIView()
  private let leftHandleView = UIView()
  private let rightHandleView = UIView()
  private let leftGrabberView = UIView()
  private let rightGrabberView = UIView()
  private let playheadView = UIView()
  private var thumbnailViews: [UIImageView] = []

  private var activeStartRatio: CGFloat = 0.0
  private var activeEndRatio: CGFloat = 1.0
  private var playbackRatio: CGFloat = 0.0
  private var gestureStartRatio: CGFloat = 0.0
  private var gestureEndRatio: CGFloat = 1.0

  private let handleWidth: CGFloat = 18.0
  private let minimumSelectionRatio: CGFloat = 0.06

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    trackView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
    trackView.layer.cornerRadius = 20.0
    trackView.layer.cornerCurve = .continuous
    addSubview(trackView)

    thumbnailsContainerView.clipsToBounds = true
    thumbnailsContainerView.layer.cornerRadius = 16.0
    thumbnailsContainerView.layer.cornerCurve = .continuous
    trackView.addSubview(thumbnailsContainerView)

    [leftDimView, rightDimView].forEach { view in
      view.backgroundColor = UIColor.black.withAlphaComponent(0.42)
      thumbnailsContainerView.addSubview(view)
    }

    selectionBorderView.layer.cornerRadius = 18.0
    selectionBorderView.layer.cornerCurve = .continuous
    selectionBorderView.layer.borderWidth = 2.0
    selectionBorderView.layer.borderColor = UIColor.white.cgColor
    selectionBorderView.isUserInteractionEnabled = false
    trackView.addSubview(selectionBorderView)

    [leftHandleView, rightHandleView].forEach { view in
      view.backgroundColor = .white
      view.layer.cornerRadius = 9.0
      view.layer.cornerCurve = .continuous
      trackView.addSubview(view)
    }
    [leftGrabberView, rightGrabberView].forEach { view in
      view.backgroundColor = UIColor.black.withAlphaComponent(0.38)
      view.layer.cornerRadius = 1.5
      view.layer.cornerCurve = .continuous
    }
    leftHandleView.addSubview(leftGrabberView)
    rightHandleView.addSubview(rightGrabberView)

    playheadView.backgroundColor = UIColor.white.withAlphaComponent(0.92)
    playheadView.layer.cornerRadius = 1.0
    playheadView.layer.cornerCurve = .continuous
    playheadView.isUserInteractionEnabled = false
    trackView.addSubview(playheadView)

    let leftPan = UIPanGestureRecognizer(target: self, action: #selector(handleLeftPan(_:)))
    let rightPan = UIPanGestureRecognizer(target: self, action: #selector(handleRightPan(_:)))
    leftHandleView.addGestureRecognizer(leftPan)
    rightHandleView.addGestureRecognizer(rightPan)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    trackView.addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func setThumbnails(_ images: [UIImage]) {
    thumbnailViews.forEach { $0.removeFromSuperview() }
    thumbnailViews = images.map { image in
      let imageView = UIImageView(image: image)
      imageView.clipsToBounds = true
      imageView.contentMode = .scaleAspectFill
      thumbnailsContainerView.addSubview(imageView)
      return imageView
    }
    setNeedsLayout()
  }

  func setSelection(startRatio: CGFloat, endRatio: CGFloat) {
    activeStartRatio = startRatio.clamped(to: 0.0...0.94)
    activeEndRatio = endRatio.clamped(to: 0.06...1.0)
    if activeEndRatio - activeStartRatio < minimumSelectionRatio {
      activeEndRatio = min(1.0, activeStartRatio + minimumSelectionRatio)
    }
    setNeedsLayout()
  }

  func setPlaybackRatio(_ ratio: CGFloat) {
    playbackRatio = ratio.clamped(to: 0.0...1.0)
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let trackFrame = bounds.insetBy(dx: 0.0, dy: 0.0)
    trackView.frame = trackFrame

    let thumbnailsFrame = trackFrame.insetBy(dx: 12.0, dy: 8.0)
    thumbnailsContainerView.frame = thumbnailsFrame

    if !thumbnailViews.isEmpty {
      let itemWidth = thumbnailsFrame.width / CGFloat(thumbnailViews.count)
      for (index, imageView) in thumbnailViews.enumerated() {
        imageView.frame = CGRect(
          x: CGFloat(index) * itemWidth,
          y: 0.0,
          width: ceil(itemWidth) + 0.5,
          height: thumbnailsFrame.height
        )
      }
    }

    let leftX = thumbnailsFrame.minX + (thumbnailsFrame.width * activeStartRatio)
    let rightX = thumbnailsFrame.minX + (thumbnailsFrame.width * activeEndRatio)
    let selectionFrame = CGRect(
      x: leftX - (handleWidth * 0.5),
      y: thumbnailsFrame.minY - 4.0,
      width: max(handleWidth * 2.0, (rightX - leftX) + handleWidth),
      height: thumbnailsFrame.height + 8.0
    )
    selectionBorderView.frame = selectionFrame

    leftHandleView.frame = CGRect(
      x: leftX - (handleWidth * 0.5),
      y: selectionFrame.minY,
      width: handleWidth,
      height: selectionFrame.height
    )
    rightHandleView.frame = CGRect(
      x: rightX - (handleWidth * 0.5),
      y: selectionFrame.minY,
      width: handleWidth,
      height: selectionFrame.height
    )

    let grabberSize = CGSize(width: 3.0, height: 24.0)
    leftGrabberView.frame = CGRect(
      x: (leftHandleView.bounds.width - grabberSize.width) * 0.5,
      y: (leftHandleView.bounds.height - grabberSize.height) * 0.5,
      width: grabberSize.width,
      height: grabberSize.height
    )
    rightGrabberView.frame = CGRect(
      x: (rightHandleView.bounds.width - grabberSize.width) * 0.5,
      y: (rightHandleView.bounds.height - grabberSize.height) * 0.5,
      width: grabberSize.width,
      height: grabberSize.height
    )

    leftDimView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: max(0.0, leftX - thumbnailsFrame.minX),
      height: thumbnailsFrame.height
    )
    rightDimView.frame = CGRect(
      x: max(0.0, rightX - thumbnailsFrame.minX),
      y: 0.0,
      width: max(0.0, thumbnailsFrame.maxX - rightX),
      height: thumbnailsFrame.height
    )

    let playheadX = thumbnailsFrame.minX + (thumbnailsFrame.width * playbackRatio)
    let playheadVisible = playbackRatio >= activeStartRatio && playbackRatio <= activeEndRatio
    playheadView.isHidden = !playheadVisible
    playheadView.frame = CGRect(
      x: playheadX - 1.0,
      y: thumbnailsFrame.minY - 2.0,
      width: 2.0,
      height: thumbnailsFrame.height + 4.0
    )
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    let trackFrame = thumbnailsRect()
    guard trackFrame.width > 1.0 else { return }
    let location = gesture.location(in: self)
    let ratio = ((location.x - trackFrame.minX) / trackFrame.width).clamped(to: 0.0...1.0)
    onScrubRequested?(ratio)
  }

  @objc private func handleLeftPan(_ gesture: UIPanGestureRecognizer) {
    handlePan(gesture, kind: .left)
  }

  @objc private func handleRightPan(_ gesture: UIPanGestureRecognizer) {
    handlePan(gesture, kind: .right)
  }

  private func handlePan(_ gesture: UIPanGestureRecognizer, kind: HandleKind) {
    let trackFrame = thumbnailsRect()
    guard trackFrame.width > 1.0 else { return }

    switch gesture.state {
    case .began:
      gestureStartRatio = activeStartRatio
      gestureEndRatio = activeEndRatio
    case .changed, .ended:
      let deltaRatio = gesture.translation(in: self).x / trackFrame.width
      switch kind {
      case .left:
        let nextStart = (gestureStartRatio + deltaRatio).clamped(
          to: 0.0...(gestureEndRatio - minimumSelectionRatio))
        activeStartRatio = nextStart
      case .right:
        let nextEnd = (gestureEndRatio + deltaRatio).clamped(
          to: (gestureStartRatio + minimumSelectionRatio)...1.0)
        activeEndRatio = nextEnd
      }
      setNeedsLayout()
      onSelectionChanged?(activeStartRatio, activeEndRatio, gesture.state == .ended)
    default:
      break
    }
  }

  private func thumbnailsRect() -> CGRect {
    trackView.frame.insetBy(dx: 12.0, dy: 8.0)
  }
}

private final class ChatVideoDrawingCanvasView: UIView {
  private var completedPaths: [UIBezierPath] = []
  private var activePath: UIBezierPath?
  private(set) var drawingEnabled = false

  var hasStrokeContent: Bool {
    !completedPaths.isEmpty || activePath != nil
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
    clipsToBounds = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func setDrawingEnabled(_ value: Bool) {
    drawingEnabled = value
    isUserInteractionEnabled = value
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard drawingEnabled, let point = touches.first?.location(in: self) else { return }
    let path = UIBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = 3.5
    path.move(to: point)
    activePath = path
    setNeedsDisplay()
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard drawingEnabled, let point = touches.first?.location(in: self), let path = activePath
    else {
      return
    }
    path.addLine(to: point)
    setNeedsDisplay()
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard drawingEnabled, let path = activePath else { return }
    completedPaths.append(path)
    activePath = nil
    setNeedsDisplay()
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    touchesEnded(touches, with: event)
  }

  override func draw(_ rect: CGRect) {
    UIColor.white.withAlphaComponent(0.95).setStroke()
    for path in completedPaths {
      path.stroke()
    }
    activePath?.stroke()
  }
}

final class ChatVideoEditViewController: UIViewController, UITextViewDelegate,
  UIGestureRecognizerDelegate
{
  private struct LoadedVideoMetadata {
    let naturalSize: CGSize
    let durationSeconds: Double
  }

  private struct LoadedVideoExportSource {
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float
  }

  /// Mutable because an AI edit replaces the clip under the player.
  private var asset: AVAsset
  private let headerTitleText: String
  private let previewOnly: Bool
  private var captionText: String

  var onSend: ((ChatVideoEditActionPayload) -> Void)?

  private let stageView = UIView()
  private let previewView = UIView()
  private let textOverlayView = UIView()
  private let drawingView = ChatVideoDrawingCanvasView()
  private let backgroundView = UIView()
  private let topContainer = UIView()
  private let backGlassView = UIVisualEffectView(effect: nil)
  private let backButton = UIButton(type: .custom)
  private let titleGlassView = UIVisualEffectView(effect: nil)
  private let titleLabel = UILabel()
  private let menuGlassView = UIVisualEffectView(effect: nil)
  private let menuButton = UIButton(type: .custom)

  private let bottomContainer = UIView()
  private let timelineView = ChatVideoTrimTimelineView()
  private let playerProgressGlassView = UIVisualEffectView(effect: nil)
  private let playerProgressContainer = UIView()
  private let playerProgressTrackView = UIView()
  private let playerBufferedProgressView = UIView()
  private let playerPlaybackProgressView = UIView()
  private let currentTimeLabel = UILabel()
  private let remainingTimeLabel = UILabel()
  private let downloadProgressGlassView = UIVisualEffectView(effect: nil)
  private let downloadProgressContainer = UIView()
  private let downloadProgressTrackView = UIView()
  private let downloadProgressFillView = UIView()
  private let downloadStatusLabel = UILabel()
  private let captionBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
  private let captionTextView = UITextView()
  private let captionPlaceholderLabel = UILabel()
  private let bottomToolbar = UIView()
  private let replyGlassView = UIVisualEffectView(effect: nil)
  private let replyButton = UIButton(type: .custom)
  private let textGlassView = UIVisualEffectView(effect: nil)
  private let textButton = UIButton(type: .custom)
  private let drawGlassView = UIVisualEffectView(effect: nil)
  private let drawButton = UIButton(type: .custom)
  private let aiGlassView = UIVisualEffectView(effect: nil)
  private let aiButton = UIButton(type: .custom)
  private let muteGlassView = UIVisualEffectView(effect: nil)
  private let muteButton = UIButton(type: .system)
  private let qualityGlassView = UIVisualEffectView(effect: nil)
  private let qualityButton = UIButton(type: .system)
  private let sendGlassView = UIVisualEffectView(effect: nil)
  private let sendButton = UIButton(type: .system)
  private let sendSpinner = UIActivityIndicatorView(style: .medium)
  private let playbackOverlayContainer = UIView()
  private let playbackRewindGlassView = UIVisualEffectView(effect: nil)
  private let playbackRewindButton = UIButton(type: .custom)
  private let playbackToggleGlassView = UIVisualEffectView(effect: nil)
  private let playbackToggleButton = UIButton(type: .custom)
  private let playbackForwardGlassView = UIVisualEffectView(effect: nil)
  private let playbackForwardButton = UIButton(type: .custom)
  private let previewTapGesture = UITapGestureRecognizer()
  private let dismissPanGesture = UIPanGestureRecognizer()
  private let playbackSpeedHoldGesture = UILongPressGestureRecognizer()

  private let player = AVPlayer()
  private let playerLayer = AVPlayerLayer()
  private var timeObserver: Any?
  private var itemStatusObserver: NSKeyValueObservation?
  private var loadedTimeRangesObserver: NSKeyValueObservation?
  private var timeControlObserver: NSKeyValueObservation?
  private var keyboardHeight: CGFloat = 0.0
  private var isMuted = false
  private var selectedQuality: ChatVideoExportQuality = .p720
  private var trimStartRatio: CGFloat = 0.0
  private var trimEndRatio: CGFloat = 1.0
  private var isExporting = false

  // MARK: AI edit
  //
  // Gemini Omni Flash accepts at most 10 seconds of input, so AI mode clamps the
  // trim selection rather than letting the user pick a window the model will
  // reject. There is no region/mask parameter for video — prompt only.
  static let aiMaxClipSeconds: Double = 10.0
  private var isAIModeActive = false
  private var isAIWorking = false
  /// Chains refinements onto the previous result instead of re-editing the original.
  private var aiInteractionID: String?
  /// Set when an AI edit replaces the asset, so Undo can restore the original.
  private var aiOriginalAsset: AVAsset?
  private var aiTask: Task<Void, Never>?
  private let aiPromptBar = ChatVideoAIPromptBar()
  private let aiProcessingOverlay = ChatAIProcessingOverlayView()
  private var naturalVideoSize: CGSize = CGSize(width: 720.0, height: 1280.0)
  private var cachedAssetDurationSeconds: Double = 0.1
  private var bufferedProgressRatio: CGFloat = 0.0
  private var playbackProgressRatio: CGFloat = 0.0
  private var isRemoteStreamingAsset = false
  private var pendingSavedVideoCleanupURL: URL?
  private var previewSpeedHoldActive = false
  private var previewSpeedHoldWasPlaying = false
  private var suppressNextPreviewToggleTap = false

  var onReply: (() -> Void)?
  var onProtectedMediaDisplayed: ((String?, Int?) -> Void)?
  var onProtectedMediaExpired: ((String?) -> Void)?
  var zoomTransition: ChatMediaZoomTransition?
  private let zoomMessageId: String?
  private let isProtectedMedia: Bool
  private let protectedTtlSeconds: Int?
  private var didNotifyProtectedDisplay = false
  private var isProtectedExpiryCommitted = false
  private let protectedTimerHost = UIView()
  private let protectedTimerTrack = UIView()
  private let protectedTimerFill = UIView()
  private let protectedTimerIcon = UIImageView(image: UIImage(systemName: "flame.fill"))
  private let protectedTimerLabel = UILabel()
  private var protectedTimer: Timer?
  private var protectedTimerDeadline: CFTimeInterval?
  private var protectedTimerDuration: TimeInterval = 0

  init(
    asset: AVAsset,
    initialCaption: String?,
    headerTitle: String?,
    previewOnly: Bool,
    messageId: String? = nil,
    viewOnce: Bool = false,
    mediaTtlSeconds: Int? = nil
  ) {
    self.asset = asset
    self.previewOnly = previewOnly
    self.zoomMessageId = messageId?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.protectedTtlSeconds = mediaTtlSeconds
    self.isProtectedMedia = viewOnce || (mediaTtlSeconds ?? 0) > 0
    let normalizedCaption = initialCaption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.captionText = normalizedCaption
    let normalizedHeaderTitle = headerTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if normalizedHeaderTitle.isEmpty {
      self.headerTitleText = previewOnly ? "Saved Messages" : "Video"
    } else {
      self.headerTitleText = normalizedHeaderTitle
    }
    if let urlAsset = asset as? AVURLAsset,
      let scheme = urlAsset.url.scheme?.lowercased()
    {
      self.isRemoteStreamingAsset = scheme == "http" || scheme == "https"
    } else {
      self.isRemoteStreamingAsset = false
    }
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    protectedTimer?.invalidate()
    itemStatusObserver = nil
    loadedTimeRangesObserver = nil
    timeControlObserver = nil
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    backgroundView.backgroundColor = .black
    view.addSubview(backgroundView)

    stageView.backgroundColor = .clear
    stageView.clipsToBounds = true
    view.addSubview(stageView)

    previewView.backgroundColor = .black
    previewView.clipsToBounds = true
    previewTapGesture.addTarget(self, action: #selector(handlePreviewTap))
    previewTapGesture.isEnabled = previewOnly
    previewView.addGestureRecognizer(previewTapGesture)
    dismissPanGesture.addTarget(self, action: #selector(handleDismissPan(_:)))
    dismissPanGesture.delegate = self
    dismissPanGesture.maximumNumberOfTouches = 1
    view.addGestureRecognizer(dismissPanGesture)
    stageView.addSubview(previewView)
    playerLayer.videoGravity = previewOnly ? .resizeAspect : .resizeAspectFill
    previewView.layer.addSublayer(playerLayer)
    textOverlayView.backgroundColor = .clear
    textOverlayView.clipsToBounds = true
    previewView.addSubview(textOverlayView)
    previewView.addSubview(drawingView)
    playbackOverlayContainer.backgroundColor = .clear
    stageView.addSubview(playbackOverlayContainer)

    topContainer.backgroundColor = .clear
    view.addSubview(topContainer)
    [backGlassView, titleGlassView, menuGlassView].forEach {
      configureGlassView($0)
      topContainer.addSubview($0)
    }

    configureCircleButton(backButton, symbol: "chevron.left", weight: .medium, pointSize: 16.0)
    backButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    backGlassView.contentView.addSubview(backButton)

    titleLabel.text = headerTitleText
    titleLabel.textColor = UIColor.white.withAlphaComponent(0.82)
    titleLabel.font = .systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleGlassView.contentView.addSubview(titleLabel)

    configureCircleButton(menuButton, symbol: "ellipsis", weight: .medium, pointSize: 16.0)
    if #available(iOS 14.0, *) {
      menuButton.showsMenuAsPrimaryAction = true
    } else {
      menuButton.addTarget(self, action: #selector(handleLegacyMenuPress), for: .touchUpInside)
    }
    menuGlassView.contentView.addSubview(menuButton)

    bottomContainer.backgroundColor = .clear
    view.addSubview(bottomContainer)

    configureGlassView(playerProgressGlassView)
    bottomContainer.addSubview(playerProgressGlassView)
    playerProgressContainer.backgroundColor = .clear
    playerProgressGlassView.contentView.addSubview(playerProgressContainer)

    playerProgressTrackView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
    playerProgressTrackView.clipsToBounds = true
    playerProgressContainer.addSubview(playerProgressTrackView)

    playerBufferedProgressView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.58)
    playerBufferedProgressView.clipsToBounds = true
    playerProgressTrackView.addSubview(playerBufferedProgressView)

    playerPlaybackProgressView.backgroundColor = .white
    playerPlaybackProgressView.clipsToBounds = true
    playerProgressTrackView.addSubview(playerPlaybackProgressView)

    [currentTimeLabel, remainingTimeLabel].forEach {
      $0.textColor = UIColor.white.withAlphaComponent(0.82)
      $0.font = .monospacedDigitSystemFont(ofSize: 11.0, weight: .medium)
      $0.adjustsFontSizeToFitWidth = true
      $0.minimumScaleFactor = 0.8
      playerProgressContainer.addSubview($0)
    }
    currentTimeLabel.textAlignment = .left
    remainingTimeLabel.textAlignment = .right
    currentTimeLabel.text = "0:00"
    remainingTimeLabel.text = "-0:00"
    let progressTap = UITapGestureRecognizer(target: self, action: #selector(handlePlayerProgressTap(_:)))
    playerProgressContainer.addGestureRecognizer(progressTap)

    downloadProgressGlassView.isHidden = true
    downloadProgressContainer.isHidden = true

    timelineView.setSelection(startRatio: trimStartRatio, endRatio: trimEndRatio)
    timelineView.onSelectionChanged = { [weak self] start, end, finished in
      guard let self else { return }
      let (clampedStart, clampedEnd) = self.clampSelectionForAI(start: start, end: end)
      self.trimStartRatio = clampedStart
      self.trimEndRatio = clampedEnd
      if clampedStart != start || clampedEnd != end {
        self.timelineView.setSelection(startRatio: clampedStart, endRatio: clampedEnd)
      }
      self.updateAIChrome()
      let targetSeconds = self.selectedTrimStartSeconds()
      self.seekPlayer(to: targetSeconds, playAfterSeek: finished)
    }
    timelineView.onScrubRequested = { [weak self] ratio in
      guard let self else { return }
      let clamped = ratio.clamped(to: self.trimStartRatio...self.trimEndRatio)
      self.seekPlayer(to: self.seconds(for: clamped), playAfterSeek: false)
    }
    bottomContainer.addSubview(timelineView)

    captionBlurView.clipsToBounds = true
    captionBlurView.layer.cornerRadius = 22.0
    captionBlurView.layer.cornerCurve = .continuous
    bottomContainer.addSubview(captionBlurView)

    captionTextView.backgroundColor = .clear
    captionTextView.textColor = .white
    captionTextView.tintColor = .systemBlue
    captionTextView.font = .systemFont(ofSize: 16.0, weight: .regular)
    captionTextView.keyboardAppearance = .dark
    captionTextView.autocorrectionType = .yes
    captionTextView.autocapitalizationType = .sentences
    captionTextView.returnKeyType = .default
    captionTextView.isScrollEnabled = false
    captionTextView.isEditable = !previewOnly
    captionTextView.isSelectable = !previewOnly
    captionTextView.textContainerInset = UIEdgeInsets(top: 10.0, left: 14.0, bottom: 10.0, right: 14.0)
    captionTextView.delegate = self
    captionTextView.text = captionText
    captionBlurView.contentView.addSubview(captionTextView)

    captionPlaceholderLabel.text = "Add a caption..."
    captionPlaceholderLabel.textColor = UIColor.white.withAlphaComponent(0.46)
    captionPlaceholderLabel.font = .systemFont(ofSize: 16.0, weight: .regular)
    captionBlurView.contentView.addSubview(captionPlaceholderLabel)

    bottomToolbar.backgroundColor = .clear
    bottomContainer.addSubview(bottomToolbar)

    aiPromptBar.isHidden = true
    aiPromptBar.onSubmit = { [weak self] prompt in self?.runVideoAIEdit(prompt: prompt) }
    aiPromptBar.onUndo = { [weak self] in self?.handleAIUndo() }
    bottomContainer.addSubview(aiPromptBar)

    [replyGlassView, textGlassView, drawGlassView, aiGlassView, muteGlassView, qualityGlassView, sendGlassView]
      .forEach {
      configureGlassView($0)
      bottomToolbar.addSubview($0)
    }

    [playbackRewindGlassView, playbackToggleGlassView, playbackForwardGlassView].forEach {
      configureGlassView($0)
      playbackOverlayContainer.addSubview($0)
    }

    configureCircleButton(
      replyButton,
      symbol: "arrowshape.turn.up.left",
      weight: .medium,
      pointSize: 16.0
    )
    replyButton.addTarget(self, action: #selector(handleReply), for: .touchUpInside)
    replyGlassView.contentView.addSubview(replyButton)

    configureCircleButton(textButton, symbol: "textformat", weight: .medium, pointSize: 17.0)
    textButton.addTarget(self, action: #selector(handleText), for: .touchUpInside)
    textGlassView.contentView.addSubview(textButton)

    configureCircleButton(drawButton, symbol: "pencil.and.scribble", weight: .medium, pointSize: 17.0)
    drawButton.addTarget(self, action: #selector(handleDraw), for: .touchUpInside)
    drawGlassView.contentView.addSubview(drawButton)

    configureCircleButton(aiButton, symbol: "sparkles", weight: .medium, pointSize: 17.0)
    aiButton.addTarget(self, action: #selector(handleAI), for: .touchUpInside)
    aiGlassView.contentView.addSubview(aiButton)

    configureCircleButton(muteButton, symbol: "speaker.wave.2", weight: .medium, pointSize: 17.0)
    muteButton.addTarget(self, action: #selector(handleMuteToggle), for: .touchUpInside)
    muteGlassView.contentView.addSubview(muteButton)

    configureCircleButton(
      playbackRewindButton,
      symbol: "gobackward.15",
      weight: .semibold,
      pointSize: 18.0
    )
    playbackRewindButton.addTarget(self, action: #selector(handleSeekBackward), for: .touchUpInside)
    playbackRewindGlassView.contentView.addSubview(playbackRewindButton)

    configureCircleButton(
      playbackToggleButton,
      symbol: "play.fill",
      weight: .semibold,
      pointSize: 20.0
    )
    playbackToggleButton.addTarget(
      self,
      action: #selector(handlePreviewPlaybackToggle),
      for: .touchUpInside
    )
    playbackSpeedHoldGesture.minimumPressDuration = 0.22
    playbackSpeedHoldGesture.addTarget(self, action: #selector(handlePlaybackSpeedHold(_:)))
    playbackToggleButton.addGestureRecognizer(playbackSpeedHoldGesture)
    playbackToggleGlassView.contentView.addSubview(playbackToggleButton)

    configureCircleButton(
      playbackForwardButton,
      symbol: "goforward.15",
      weight: .semibold,
      pointSize: 18.0
    )
    playbackForwardButton.addTarget(self, action: #selector(handleSeekForward), for: .touchUpInside)
    playbackForwardGlassView.contentView.addSubview(playbackForwardButton)

    qualityButton.setTitle(selectedQuality.label, for: .normal)
    qualityButton.setTitleColor(.white, for: .normal)
    qualityButton.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
    qualityButton.backgroundColor = .clear
    if #available(iOS 14.0, *) {
      qualityButton.showsMenuAsPrimaryAction = true
    } else {
      qualityButton.addTarget(self, action: #selector(handleLegacyQualityPress), for: .touchUpInside)
    }
    qualityGlassView.contentView.addSubview(qualityButton)

    configureCircleButton(sendButton, symbol: "arrow.up", weight: .semibold, pointSize: 18.0)
    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    sendGlassView.contentView.addSubview(sendButton)

    sendSpinner.hidesWhenStopped = true
    sendSpinner.color = .white
    sendButton.addSubview(sendSpinner)

    refreshGlassEffects()
    refreshCaptionPlaceholder()
    rebuildQualityMenu()
    rebuildTopMenu()
    updateMuteButton()
    updatePreviewPlaybackControls()
    applyPresentationMode()
    setupProtectedMediaUI()
    configurePlayer()
    loadAssetMetadata()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    seekPlayer(to: selectedTrimStartSeconds(), playAfterSeek: true)
    beginProtectedMediaIfReady()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    player.pause()
  }

  private var isInteractiveDismissing = false

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if isInteractiveDismissing { return }

    backgroundView.frame = view.bounds
    stageView.frame = view.bounds
    previewView.frame = stageView.bounds
    playerLayer.frame = previewView.bounds
    textOverlayView.frame = previewView.bounds
    drawingView.frame = previewView.bounds

    let safe = view.safeAreaInsets
    // 44pt: the app's header control size everywhere else, and what the image
    // viewer's header and bottom bar now use.
    let headerSide: CGFloat = 44.0
    topContainer.frame = CGRect(
      x: 16.0,
      y: safe.top + 8.0,
      width: view.bounds.width - 32.0,
      height: headerSide
    )
    backGlassView.frame = CGRect(x: 0.0, y: 0.0, width: headerSide, height: headerSide)
    backButton.frame = backGlassView.bounds
    menuGlassView.frame = CGRect(
      x: max(0.0, topContainer.bounds.width - headerSide),
      y: 0.0,
      width: headerSide,
      height: headerSide
    )
    menuButton.frame = menuGlassView.bounds
    if isProtectedMedia {
      let timerWidth = min(168, max(120, view.bounds.width - 40))
      protectedTimerHost.frame = CGRect(
        x: floor((view.bounds.width - timerWidth) * 0.5),
        y: topContainer.frame.maxY + 10,
        width: timerWidth,
        height: 30)
      protectedTimerIcon.frame = CGRect(x: 10, y: 5, width: 18, height: 16)
      protectedTimerLabel.frame = CGRect(x: timerWidth - 50, y: 3, width: 40, height: 18)
      protectedTimerTrack.frame = CGRect(x: 10, y: 24, width: timerWidth - 20, height: 3)
      if let deadline = protectedTimerDeadline, protectedTimerDuration > 0 {
        let remaining = max(0, deadline - CACurrentMediaTime())
        let fraction = CGFloat(min(1, remaining / protectedTimerDuration))
        protectedTimerFill.frame = CGRect(
          x: 0, y: 0, width: protectedTimerTrack.bounds.width * fraction,
          height: protectedTimerTrack.bounds.height)
      }
    }

    let titleWidth = min(
      max(108.0, titleLabel.intrinsicContentSize.width + 28.0),
      max(108.0, topContainer.bounds.width - 136.0)
    )
    titleGlassView.frame = CGRect(
      x: (topContainer.bounds.width - titleWidth) * 0.5,
      y: 0.0,
      width: titleWidth,
      height: headerSide
    )
    titleLabel.frame = titleGlassView.bounds.insetBy(dx: 14.0, dy: 0.0)

    [backGlassView, titleGlassView, menuGlassView].forEach {
      $0.layer.cornerRadius = $0.bounds.height * 0.5
    }
    [backButton, menuButton].forEach {
      $0.layer.cornerRadius = $0.bounds.height * 0.5
    }

    let maxCaptionWidth = view.bounds.width - 32.0
    let captionSize = captionTextView.sizeThatFits(
      CGSize(width: maxCaptionWidth, height: CGFloat.greatestFiniteMagnitude)
    )
    let timelineHeight: CGFloat = 68.0
    let playerProgressHeight: CGFloat = 54.0
    let mediaControlHeight: CGFloat = previewOnly ? playerProgressHeight : timelineHeight
    let captionHeight = max(44.0, min(64.0, captionSize.height))
    // AI mode brings its own prompt field. Leaving the caption box up as well put
    // two text inputs on screen at once with no way to tell which one the model
    // reads, so the caption stands down while AI mode owns the input.
    let showsCaption = !isAIModeActive && (!previewOnly || !captionText.isEmpty)
    let toolbarHeight: CGFloat = 42.0
    let bottomInset = keyboardHeight > 0.0 ? (keyboardHeight + 6.0) : (safe.bottom + 10.0)
    let captionSectionHeight = showsCaption ? (10.0 + captionHeight) : 0.0
    let bottomHeight = mediaControlHeight + captionSectionHeight + 12.0 + toolbarHeight
    bottomContainer.frame = CGRect(
      x: 0.0,
      y: view.bounds.height - bottomInset - bottomHeight,
      width: view.bounds.width,
      height: bottomHeight
    )

    if previewOnly {
      timelineView.frame = .zero
      playerProgressGlassView.frame = CGRect(
        x: 16.0,
        y: 0.0,
        width: view.bounds.width - 32.0,
        height: playerProgressHeight
      )
      playerProgressGlassView.layer.cornerRadius = playerProgressGlassView.bounds.height * 0.5
      playerProgressContainer.frame = playerProgressGlassView.bounds.insetBy(dx: 14.0, dy: 8.0)
      let labelHeight: CGFloat = 16.0
      let measuredTimerWidth = currentTimeLabel.sizeThatFits(
        CGSize(width: playerProgressContainer.bounds.width, height: labelHeight)
      ).width
      let timerWidth = min(
        playerProgressContainer.bounds.width,
        max(52.0, ceil(measuredTimerWidth) + 2.0)
      )
      currentTimeLabel.frame = CGRect(
        x: floor((playerProgressContainer.bounds.width - timerWidth) * 0.5),
        y: 0.0,
        width: timerWidth,
        height: labelHeight
      )
      remainingTimeLabel.frame = .zero
      let trackHeight: CGFloat = 3.0
      let trackHorizontalInset: CGFloat = 4.0
      let trackTopGap: CGFloat = 8.0
      let trackX = trackHorizontalInset
      let trackWidth = max(20.0, playerProgressContainer.bounds.width - (trackHorizontalInset * 2.0))
      let trackY = currentTimeLabel.frame.maxY + trackTopGap
      playerProgressTrackView.frame = CGRect(x: trackX, y: trackY, width: trackWidth, height: trackHeight)
      playerProgressTrackView.layer.cornerRadius = trackHeight * 0.5
      playerBufferedProgressView.frame = CGRect(
        x: 0.0,
        y: 0.0,
        width: floor(trackWidth * bufferedProgressRatio.clamped(to: 0.0...1.0)),
        height: playerProgressTrackView.bounds.height
      )
      playerPlaybackProgressView.frame = CGRect(
        x: 0.0,
        y: 0.0,
        width: floor(trackWidth * playbackProgressRatio.clamped(to: 0.0...1.0)),
        height: playerProgressTrackView.bounds.height
      )

      downloadProgressGlassView.frame = .zero
      downloadProgressContainer.frame = .zero
      downloadStatusLabel.frame = .zero
      downloadProgressTrackView.frame = .zero
      downloadProgressFillView.frame = .zero

      let controlSpacing: CGFloat = 14.0
      let sideControlSize: CGFloat = 48.0
      let centerControlSize: CGFloat = 56.0
      let overlayWidth = (sideControlSize * 2.0) + centerControlSize + (controlSpacing * 2.0)
      let overlayHeight = max(sideControlSize, centerControlSize)
      let safeCenterY = max(
        safe.top + 130.0,
        min(
          previewView.bounds.midY,
          bottomContainer.frame.minY - 110.0
        )
      )
      playbackOverlayContainer.frame = CGRect(
        x: floor((view.bounds.width - overlayWidth) * 0.5),
        y: floor(safeCenterY - (overlayHeight * 0.5)),
        width: overlayWidth,
        height: overlayHeight
      )
      playbackRewindGlassView.frame = CGRect(
        x: 0.0,
        y: floor((overlayHeight - sideControlSize) * 0.5),
        width: sideControlSize,
        height: sideControlSize
      )
      playbackToggleGlassView.frame = CGRect(
        x: playbackRewindGlassView.frame.maxX + controlSpacing,
        y: floor((overlayHeight - centerControlSize) * 0.5),
        width: centerControlSize,
        height: centerControlSize
      )
      playbackForwardGlassView.frame = CGRect(
        x: playbackToggleGlassView.frame.maxX + controlSpacing,
        y: floor((overlayHeight - sideControlSize) * 0.5),
        width: sideControlSize,
        height: sideControlSize
      )
      playbackRewindButton.frame = playbackRewindGlassView.bounds
      playbackToggleButton.frame = playbackToggleGlassView.bounds
      playbackForwardButton.frame = playbackForwardGlassView.bounds
    } else {
      playerProgressGlassView.frame = .zero
      playerProgressContainer.frame = .zero
      playerProgressTrackView.frame = .zero
      playerBufferedProgressView.frame = .zero
      playerPlaybackProgressView.frame = .zero
      currentTimeLabel.frame = .zero
      remainingTimeLabel.frame = .zero
      downloadProgressGlassView.frame = .zero
      downloadProgressContainer.frame = .zero
      downloadStatusLabel.frame = .zero
      downloadProgressTrackView.frame = .zero
      downloadProgressFillView.frame = .zero
      playbackOverlayContainer.frame = .zero
      playbackRewindGlassView.frame = .zero
      playbackToggleGlassView.frame = .zero
      playbackForwardGlassView.frame = .zero
      playbackRewindButton.frame = .zero
      playbackToggleButton.frame = .zero
      playbackForwardButton.frame = .zero
      timelineView.frame = CGRect(
        x: 16.0,
        y: 0.0,
        width: view.bounds.width - 32.0,
        height: timelineHeight
      )
    }
    if showsCaption {
      captionBlurView.isHidden = false
      captionBlurView.frame = CGRect(
        x: 16.0,
        y: (previewOnly ? playerProgressGlassView.frame.maxY : timelineView.frame.maxY) + 10.0,
        width: view.bounds.width - 32.0,
        height: captionHeight
      )
      captionTextView.frame = captionBlurView.bounds
      captionPlaceholderLabel.frame = CGRect(
        x: 16.0,
        y: 0.0,
        width: captionBlurView.bounds.width - 32.0,
        height: captionBlurView.bounds.height
      )
    } else {
      captionBlurView.isHidden = true
      captionBlurView.frame = .zero
      captionTextView.frame = .zero
      captionPlaceholderLabel.frame = .zero
    }

    // AI prompt capsule sits between the caption and the tool row, and takes no
    // space at all when the AI tool is off.
    let aiTop =
      (showsCaption
        ? captionBlurView.frame.maxY
        : (previewOnly ? playerProgressGlassView.frame.maxY : timelineView.frame.maxY)) + 12.0

    if isAIModeActive {
      aiPromptBar.isHidden = false
      aiPromptBar.frame = CGRect(
        x: 16.0,
        y: aiTop,
        width: view.bounds.width - 32.0,
        height: ChatVideoAIPromptBar.preferredHeight
      )
    } else {
      aiPromptBar.isHidden = true
      aiPromptBar.frame = .zero
    }

    bottomToolbar.frame = CGRect(
      x: 16.0,
      y: (isAIModeActive ? aiPromptBar.frame.maxY : aiTop) + (isAIModeActive ? 10.0 : 0.0),
      width: view.bounds.width - 32.0,
      height: toolbarHeight
    )

    let toolSize: CGFloat = 42.0
    let toolSpacing: CGFloat = 8.0
    if previewOnly {
      textGlassView.frame = .zero
      drawGlassView.frame = .zero
      aiGlassView.frame = .zero
      qualityGlassView.frame = .zero
      sendGlassView.frame = .zero
      muteGlassView.frame = .zero
      let replySize: CGFloat = 42.0
      replyGlassView.frame = onReply == nil
        ? .zero
        : CGRect(
          x: 0.0,
          y: 0.0,
          width: replySize,
          height: replySize
        )
      replyButton.frame = replyGlassView.bounds
      muteButton.frame = .zero
      textButton.frame = .zero
      drawButton.frame = .zero
      aiButton.frame = .zero
      sendButton.frame = .zero
      sendSpinner.center = .zero
      qualityButton.frame = .zero
    } else {
      replyGlassView.frame = .zero
      replyButton.frame = .zero
      textGlassView.frame = CGRect(x: 0.0, y: 0.0, width: toolSize, height: toolSize)
      drawGlassView.frame = CGRect(
        x: textGlassView.frame.maxX + toolSpacing,
        y: 0.0,
        width: toolSize,
        height: toolSize
      )
      aiGlassView.frame = CGRect(
        x: drawGlassView.frame.maxX + toolSpacing,
        y: 0.0,
        width: toolSize,
        height: toolSize
      )
      muteGlassView.frame = CGRect(
        x: aiGlassView.frame.maxX + toolSpacing,
        y: 0.0,
        width: toolSize,
        height: toolSize
      )
      [textButton, drawButton, aiButton, muteButton].forEach {
        $0.frame = CGRect(x: 0.0, y: 0.0, width: toolSize, height: toolSize)
      }

      let sendSize: CGFloat = 42.0
      sendGlassView.frame = CGRect(
        x: bottomToolbar.bounds.width - sendSize,
        y: 0.0,
        width: sendSize,
        height: sendSize
      )
      sendButton.frame = sendGlassView.bounds
      sendSpinner.center = CGPoint(x: sendButton.bounds.midX, y: sendButton.bounds.midY)

      let qualityWidth: CGFloat = 56.0
      // Same height as every other control in the row — at 34pt it sat as a
      // short pill between 42pt circles and read as a misalignment.
      let qualityHeight: CGFloat = toolSize
      qualityGlassView.frame = CGRect(
        x: sendGlassView.frame.minX - 10.0 - qualityWidth,
        y: (toolbarHeight - qualityHeight) * 0.5,
        width: qualityWidth,
        height: qualityHeight
      )
      qualityButton.frame = qualityGlassView.bounds
    }

    [
      replyGlassView,
      textGlassView,
      drawGlassView,
      aiGlassView,
      muteGlassView,
      sendGlassView,
      qualityGlassView,
      playbackRewindGlassView,
      playbackToggleGlassView,
      playbackForwardGlassView,
    ].forEach {
      $0.layer.cornerRadius = $0.bounds.height * 0.5
    }
    [
      replyButton,
      textButton,
      drawButton,
      aiButton,
      muteButton,
      sendButton,
      playbackRewindButton,
      playbackToggleButton,
      playbackForwardButton,
    ].forEach {
      $0.layer.cornerRadius = $0.bounds.height * 0.5
    }
    refreshPreviewProgressFrames()
  }

  private func configureGlassView(_ glassView: UIVisualEffectView) {
    glassView.clipsToBounds = true
    glassView.layer.cornerCurve = .continuous
    glassView.contentView.backgroundColor = .clear
  }

  private func configureCircleButton(
    _ button: UIButton,
    symbol: String,
    weight: UIImage.SymbolWeight,
    pointSize: CGFloat
  ) {
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
      ),
      for: .normal
    )
    button.tintColor = .white
    button.backgroundColor = .clear
    button.clipsToBounds = true
  }

  private func refreshGlassEffects() {
    let glassViews = [
      backGlassView,
      titleGlassView,
      menuGlassView,
      playerProgressGlassView,
      downloadProgressGlassView,
      replyGlassView,
      textGlassView,
      drawGlassView,
      aiGlassView,
      muteGlassView,
      qualityGlassView,
      sendGlassView,
      playbackRewindGlassView,
      playbackToggleGlassView,
      playbackForwardGlassView,
    ]
    if #available(iOS 26.0, *) {
      for glassView in glassViews {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        glassView.effect = effect
      }
    } else {
      for glassView in glassViews {
        glassView.effect = UIBlurEffect(style: .systemMaterial)
      }
    }
    updateChromeAppearance()
  }

  private func setupProtectedMediaUI() {
    guard isProtectedMedia else {
      protectedTimerHost.isHidden = true
      return
    }
    protectedTimerHost.backgroundColor = UIColor.black.withAlphaComponent(0.48)
    protectedTimerHost.layer.cornerRadius = 15
    protectedTimerHost.isUserInteractionEnabled = false
    protectedTimerHost.isHidden = true
    protectedTimerTrack.backgroundColor = UIColor.white.withAlphaComponent(0.20)
    protectedTimerTrack.layer.cornerRadius = 1.5
    protectedTimerFill.backgroundColor = .systemOrange
    protectedTimerFill.layer.cornerRadius = 1.5
    protectedTimerIcon.tintColor = .systemOrange
    protectedTimerIcon.contentMode = .scaleAspectFit
    protectedTimerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    protectedTimerLabel.textColor = .white
    protectedTimerLabel.textAlignment = .right
    protectedTimerHost.addSubview(protectedTimerIcon)
    protectedTimerHost.addSubview(protectedTimerLabel)
    protectedTimerHost.addSubview(protectedTimerTrack)
    protectedTimerTrack.addSubview(protectedTimerFill)
    view.addSubview(protectedTimerHost)
  }

  private func beginProtectedMediaIfReady() {
    guard isProtectedMedia, view.window != nil, player.currentItem?.status == .readyToPlay else {
      return
    }
    if !didNotifyProtectedDisplay {
      didNotifyProtectedDisplay = true
      onProtectedMediaDisplayed?(zoomMessageId, protectedTtlSeconds)
    }
    guard protectedTimer == nil, let seconds = protectedTtlSeconds, seconds > 0 else { return }
    protectedTimerDuration = TimeInterval(seconds)
    protectedTimerDeadline = CACurrentMediaTime() + protectedTimerDuration
    protectedTimerHost.isHidden = false
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.tickProtectedMediaTimer()
    }
    protectedTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    tickProtectedMediaTimer()
  }

  private func tickProtectedMediaTimer() {
    guard let deadline = protectedTimerDeadline, protectedTimerDuration > 0 else { return }
    let remaining = max(0, deadline - CACurrentMediaTime())
    let fraction = CGFloat(min(1, remaining / protectedTimerDuration))
    protectedTimerLabel.text = "\(max(0, Int(ceil(remaining))))s"
    protectedTimerFill.frame = CGRect(
      x: 0, y: 0, width: protectedTimerTrack.bounds.width * fraction,
      height: protectedTimerTrack.bounds.height)
    if remaining <= 0 { expireProtectedMedia() }
  }

  private func expireProtectedMedia() {
    guard !isProtectedExpiryCommitted else { return }
    isProtectedExpiryCommitted = true
    protectedTimer?.invalidate()
    protectedTimer = nil
    protectedTimerDeadline = nil
    protectedTimerHost.isHidden = true
    player.pause()
    onProtectedMediaExpired?(zoomMessageId)
    dismiss(animated: false)
  }

  private func applyPresentationMode() {
    if previewOnly {
      timelineView.isHidden = true
      playerProgressGlassView.isHidden = false
      playerProgressContainer.isHidden = false
      downloadProgressGlassView.isHidden = true
      downloadProgressContainer.isHidden = true
      replyGlassView.isHidden = isProtectedMedia || onReply == nil
      textGlassView.isHidden = true
      drawGlassView.isHidden = true
      aiGlassView.isHidden = true
      muteGlassView.isHidden = true
      qualityGlassView.isHidden = true
      sendGlassView.isHidden = true
      playbackOverlayContainer.isHidden = false
      captionPlaceholderLabel.isHidden = true
      captionTextView.keyboardAppearance = .dark
      menuGlassView.isHidden = isProtectedMedia
      menuButton.isHidden = isProtectedMedia
    } else {
      timelineView.isHidden = false
      playerProgressGlassView.isHidden = true
      playerProgressContainer.isHidden = true
      downloadProgressGlassView.isHidden = true
      downloadProgressContainer.isHidden = true
      replyGlassView.isHidden = true
      textGlassView.isHidden = false
      drawGlassView.isHidden = false
      aiGlassView.isHidden = false
      muteGlassView.isHidden = false
      qualityGlassView.isHidden = false
      sendGlassView.isHidden = false
      playbackOverlayContainer.isHidden = true
      refreshCaptionPlaceholder()
    }
  }

  private func updateChromeAppearance() {
    let neutralFill = UIColor.black.withAlphaComponent(0.16)
    let accentFill = UIColor.systemBlue.withAlphaComponent(0.28)
    // Header pills carry no fill: a wash over the material is what made them read
    // grey rather than as glass. The scrim behind them already keeps the glyphs
    // legible over a bright frame.
    backGlassView.contentView.backgroundColor = .clear
    titleGlassView.contentView.backgroundColor = .clear
    menuGlassView.contentView.backgroundColor = .clear
    playerProgressGlassView.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.22)
    replyGlassView.contentView.backgroundColor = neutralFill
    textGlassView.contentView.backgroundColor = neutralFill
    drawGlassView.contentView.backgroundColor = neutralFill
    muteGlassView.contentView.backgroundColor = neutralFill
    qualityGlassView.contentView.backgroundColor = neutralFill
    sendGlassView.contentView.backgroundColor = accentFill
    playbackRewindGlassView.contentView.backgroundColor = neutralFill
    playbackForwardGlassView.contentView.backgroundColor = neutralFill
    playbackToggleGlassView.contentView.backgroundColor =
      (player.timeControlStatus == .playing || player.rate > 0.01)
      ? accentFill
      : neutralFill
    drawButton.tintColor = drawingView.drawingEnabled ? .systemBlue : .white
    aiButton.tintColor = isAIModeActive ? .systemBlue : .white
    muteButton.tintColor = isMuted ? .systemBlue : .white
    replyButton.tintColor = .white
    playbackRewindButton.tintColor = .white
    playbackToggleButton.tintColor = .white
    playbackForwardButton.tintColor = .white
    if previewSpeedHoldActive {
      playbackToggleGlassView.contentView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.36)
    }
    updatePreviewPlaybackControls()
  }

  private func configurePlayer() {
    let item = AVPlayerItem(asset: asset)
    player.replaceCurrentItem(with: item)
    player.isMuted = isMuted
    player.actionAtItemEnd = .none
    playerLayer.player = player
    observePlayerItem(item)
    updateBufferedProgress()

    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      self?.handlePlayerTick(time)
    }
  }

  private func handlePlayerTick(_ time: CMTime) {
    let currentSeconds = CMTimeGetSeconds(time)
    guard currentSeconds.isFinite else { return }
    let endSeconds = selectedTrimEndSeconds()
    if currentSeconds >= endSeconds {
      seekPlayer(to: selectedTrimStartSeconds(), playAfterSeek: true)
      return
    }
    let ratio = CGFloat(currentSeconds / max(0.1, assetDurationSeconds()))
    timelineView.setPlaybackRatio(ratio)
    updatePlaybackChrome(currentSeconds: currentSeconds)
  }

  private func observePlayerItem(_ item: AVPlayerItem) {
    itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      guard let self else { return }
      let statusText: String
      switch item.status {
      case .unknown:
        statusText = "unknown"
      case .readyToPlay:
        statusText = "ready"
      case .failed:
        statusText = "failed"
      @unknown default:
        statusText = "future"
      }
      NSLog(
        "[ChatVideoPlayer] item status=%@ remote=%@ error=%@",
        statusText,
        self.isRemoteStreamingAsset ? "Y" : "N",
        item.error?.localizedDescription ?? "nil"
      )
      self.updateBufferedProgress()
      self.view.setNeedsLayout()
      if item.status == .readyToPlay {
        self.beginProtectedMediaIfReady()
      }
    }
    loadedTimeRangesObserver = item.observe(\.loadedTimeRanges, options: [.initial, .new]) {
      [weak self] _, _ in
      self?.updateBufferedProgress()
    }
    timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
      [weak self] player, _ in
      guard let self else { return }
      let reason = player.reasonForWaitingToPlay?.rawValue ?? "nil"
      NSLog(
        "[ChatVideoPlayer] timeControl=%ld remote=%@ reason=%@",
        player.timeControlStatus.rawValue,
        self.isRemoteStreamingAsset ? "Y" : "N",
        reason
      )
      self.updateBufferedProgress()
      self.updatePreviewPlaybackControls()
    }
  }

  private func updateBufferedProgress() {
    guard let item = player.currentItem else {
      bufferedProgressRatio = 0.0
      updatePlaybackChrome(currentSeconds: 0.0)
      return
    }
    let duration = max(0.1, assetDurationSeconds())
    if !isRemoteStreamingAsset {
      bufferedProgressRatio = 1.0
      updatePlaybackChrome(currentSeconds: CMTimeGetSeconds(item.currentTime()))
      return
    }
    let loadedEnd = item.loadedTimeRanges
      .compactMap { $0.timeRangeValue }
      .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
      .filter { $0.isFinite && $0 >= 0.0 }
      .max() ?? 0.0
    bufferedProgressRatio = CGFloat(min(1.0, max(0.0, loadedEnd / duration)))
    updatePlaybackChrome(currentSeconds: CMTimeGetSeconds(item.currentTime()))
  }

  private func updatePlaybackChrome(currentSeconds: Double) {
    let duration = max(0.1, assetDurationSeconds())
    let safeCurrent = currentSeconds.isFinite ? max(0.0, currentSeconds) : 0.0
    playbackProgressRatio = CGFloat(min(1.0, max(0.0, safeCurrent / duration)))
    let remainingText = formattedPlayerTime(seconds: max(0.0, duration - safeCurrent))
    if previewOnly {
      currentTimeLabel.text = remainingText
      remainingTimeLabel.text = nil
    } else {
      currentTimeLabel.text = formattedPlayerTime(seconds: safeCurrent)
      remainingTimeLabel.text = "-\(remainingText)"
    }
    let isBuffering = shouldShowDownloadProgressUI()
    playerBufferedProgressView.backgroundColor = isBuffering
      ? UIColor.systemBlue.withAlphaComponent(0.58)
      : UIColor.white.withAlphaComponent(0.34)
    refreshPreviewProgressFrames()
  }

  private func refreshPreviewProgressFrames() {
    guard playerProgressTrackView.bounds.width > 0.0 else { return }
    let trackWidth = playerProgressTrackView.bounds.width
    playerBufferedProgressView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: floor(trackWidth * bufferedProgressRatio.clamped(to: 0.0...1.0)),
      height: playerProgressTrackView.bounds.height
    )
    playerPlaybackProgressView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: floor(trackWidth * playbackProgressRatio.clamped(to: 0.0...1.0)),
      height: playerProgressTrackView.bounds.height
    )
  }

  private func formattedPlayerTime(seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0.0 else { return "0:00" }
    let totalSeconds = Int(seconds.rounded(.down))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }

  private func loadAssetMetadata() {
    if #available(iOS 16.0, *) {
      Task { [weak self] in
        guard let self else { return }
        do {
          let duration = try await self.asset.load(.duration)
          let videoTracks = try await self.asset.loadTracks(withMediaType: .video)
          guard let videoTrack = videoTracks.first else { return }
          let naturalSize = try await videoTrack.load(.naturalSize)
          let preferredTransform = try await videoTrack.load(.preferredTransform)
          let transformedSize = naturalSize.applying(preferredTransform)
          let metadata = LoadedVideoMetadata(
            naturalSize: CGSize(
              width: abs(transformedSize.width),
              height: abs(transformedSize.height)
            ),
            durationSeconds: max(0.1, CMTimeGetSeconds(duration))
          )
          await MainActor.run {
            self.applyLoadedMetadata(metadata)
          }
        } catch {
          await MainActor.run {
            if let metadata = self.loadLegacyVideoMetadata() {
              self.applyLoadedMetadata(metadata)
            }
          }
        }
      }
      return
    }

    if let metadata = loadLegacyVideoMetadata() {
      applyLoadedMetadata(metadata)
    }
  }

  private func applyLoadedMetadata(_ metadata: LoadedVideoMetadata) {
    naturalVideoSize = metadata.naturalSize
    cachedAssetDurationSeconds = metadata.durationSeconds.isFinite ? metadata.durationSeconds : 0.1
    if !previewOnly {
      loadThumbnails()
    } else {
      updatePlaybackChrome(currentSeconds: 0.0)
    }
    view.setNeedsLayout()
  }

  @available(iOS, introduced: 13.0, deprecated: 16.0, message: "Legacy AVFoundation fallback")
  private func loadLegacyVideoMetadata() -> LoadedVideoMetadata? {
    guard let videoTrack = asset.tracks(withMediaType: .video).first else { return nil }
    let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
    let durationSeconds = max(0.1, CMTimeGetSeconds(asset.duration))
    return LoadedVideoMetadata(
      naturalSize: CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height)),
      durationSeconds: durationSeconds
    )
  }

  private func loadThumbnails() {
    let duration = assetDurationSeconds()
    let frameCount = 14
    DispatchQueue.global(qos: .userInitiated).async {
      let generator = AVAssetImageGenerator(asset: self.asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 180.0, height: 180.0)
      var images: [UIImage] = []
      images.reserveCapacity(frameCount)
      for index in 0..<frameCount {
        let progress = Double(index) / Double(max(1, frameCount - 1))
        let time = CMTime(seconds: duration * progress, preferredTimescale: 600)
        if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
          images.append(UIImage(cgImage: cgImage))
        }
      }
      DispatchQueue.main.async {
        self.timelineView.setThumbnails(images)
      }
    }
  }

  private func hasOverlayContent() -> Bool {
    drawingView.hasStrokeContent || !textOverlayView.subviews.isEmpty
  }

  private func overlaySnapshotImage() -> UIImage? {
    guard hasOverlayContent(), previewView.bounds.width > 1.0, previewView.bounds.height > 1.0 else {
      return nil
    }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = max(UIScreen.main.scale, 2.0)
    let renderer = UIGraphicsImageRenderer(size: previewView.bounds.size, format: format)
    return renderer.image { context in
      textOverlayView.layer.render(in: context.cgContext)
      drawingView.layer.render(in: context.cgContext)
    }
  }

  private func overlayFrameInRenderSpace(renderSize: CGSize) -> CGRect {
    let previewSize = previewView.bounds.size
    guard renderSize.width > 1.0, renderSize.height > 1.0, previewSize.width > 1.0, previewSize.height > 1.0
    else {
      return CGRect(origin: .zero, size: renderSize)
    }
    let scale = max(previewSize.width / renderSize.width, previewSize.height / renderSize.height)
    let displayedSize = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
    let offset = CGPoint(
      x: (previewSize.width - displayedSize.width) * 0.5,
      y: (previewSize.height - displayedSize.height) * 0.5
    )
    return CGRect(
      x: -offset.x / scale,
      y: -offset.y / scale,
      width: previewSize.width / scale,
      height: previewSize.height / scale
    )
  }

  private func makeTransitionCapture() -> ChatAttachmentTransitionCapture? {
    guard let window = view.window else { return nil }
    let frameInWindow = previewView.convert(previewView.bounds, to: window)
    let backgroundSnapshot =
      previewView.snapshotView(afterScreenUpdates: false)
      ?? previewView.resizableSnapshotView(
        from: previewView.bounds,
        afterScreenUpdates: false,
        withCapInsets: .zero
      )
    let contentSnapshot =
      previewView.snapshotView(afterScreenUpdates: false)
      ?? previewView.resizableSnapshotView(
        from: previewView.bounds,
        afterScreenUpdates: false,
        withCapInsets: .zero
      )
    return ChatAttachmentTransitionCapture(
      sourceContainerFrameInWindow: frameInWindow,
      sourceBackgroundSnapshotView: backgroundSnapshot,
      sourceContentSnapshotView: contentSnapshot
    )
  }

  private func applyOverlayCompositionIfNeeded(
    to videoComposition: AVMutableVideoComposition,
    renderSize: CGSize
  ) {
    guard let overlayImage = overlaySnapshotImage(), let overlayCGImage = overlayImage.cgImage else {
      return
    }
    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: renderSize)
    let videoLayer = CALayer()
    videoLayer.frame = parentLayer.bounds
    parentLayer.addSublayer(videoLayer)

    let overlayLayer = CALayer()
    overlayLayer.contents = overlayCGImage
    overlayLayer.contentsScale = overlayImage.scale
    overlayLayer.contentsGravity = .resize
    overlayLayer.frame = overlayFrameInRenderSpace(renderSize: renderSize)
    parentLayer.addSublayer(overlayLayer)

    videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parentLayer
    )
  }


  private func refreshCaptionPlaceholder() {
    captionText = captionTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    captionPlaceholderLabel.isHidden = !captionText.isEmpty
  }

  private func rebuildQualityMenu() {
    qualityButton.setTitle(selectedQuality.label, for: .normal)
    guard #available(iOS 14.0, *) else { return }

    qualityButton.menu = UIMenu(
      children: ChatVideoExportQuality.allCases.map { quality in
        UIAction(
          title: quality.label,
          state: quality == selectedQuality ? .on : .off
        ) { [weak self] _ in
          self?.selectedQuality = quality
          self?.rebuildQualityMenu()
        }
      }
    )
  }

  private func rebuildTopMenu() {
    guard #available(iOS 14.0, *) else { return }
    menuButton.menu = UIMenu(
      children: [
        UIAction(
          title: "Save to Photos",
          image: UIImage(systemName: "square.and.arrow.down")
        ) { [weak self] _ in
          self?.saveVideoToPhotos()
        }
      ]
    )
  }

  private func updateMuteButton() {
    let symbol = isMuted ? "speaker.slash" : "speaker.wave.2"
    muteButton.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .medium)
      ),
      for: .normal
    )
    player.isMuted = isMuted
    updateChromeAppearance()
  }

  private func updatePreviewPlaybackControls() {
    let isPlaying = player.timeControlStatus == .playing || player.rate > 0.01
    let symbol = isPlaying ? "pause.fill" : "play.fill"
    let config = UIImage.SymbolConfiguration(pointSize: 20.0, weight: .semibold)
    playbackToggleButton.setImage(
      UIImage(systemName: symbol, withConfiguration: config),
      for: .normal
    )
    currentTimeLabel.textAlignment = previewOnly ? .center : .left
    remainingTimeLabel.isHidden = previewOnly
  }

  private func shouldShowDownloadProgressUI() -> Bool {
    isRemoteStreamingAsset && bufferedProgressRatio < 0.995
  }

  @objc private func handlePreviewTap() {
    guard previewOnly else { return }
    togglePreviewPlayback()
  }

  private func togglePreviewPlayback() {
    if player.timeControlStatus == .playing || player.rate > 0.01 {
      player.pause()
    } else {
      player.play()
    }
    updatePreviewPlaybackControls()
  }

  @objc private func handlePlayerProgressTap(_ gesture: UITapGestureRecognizer) {
    guard previewOnly else { return }
    let location = gesture.location(in: playerProgressTrackView)
    guard playerProgressTrackView.bounds.width > 1.0 else { return }
    let ratio = (location.x / playerProgressTrackView.bounds.width).clamped(to: 0.0...1.0)
    seekPlayer(to: assetDurationSeconds() * Double(ratio), playAfterSeek: player.timeControlStatus == .playing)
  }

  private func assetDurationSeconds() -> Double {
    cachedAssetDurationSeconds.isFinite ? max(0.1, cachedAssetDurationSeconds) : 0.1
  }

  private func seconds(for ratio: CGFloat) -> Double {
    assetDurationSeconds() * Double(ratio.clamped(to: 0.0...1.0))
  }

  private func selectedTrimStartSeconds() -> Double {
    seconds(for: trimStartRatio)
  }

  private func selectedTrimEndSeconds() -> Double {
    max(selectedTrimStartSeconds() + 0.05, seconds(for: trimEndRatio))
  }

  private func seekPlayer(to seconds: Double, playAfterSeek: Bool) {
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      guard let self else { return }
      if playAfterSeek, !self.isExporting {
        if self.previewSpeedHoldActive {
          self.player.playImmediately(atRate: 2.0)
        } else {
          self.player.play()
        }
      }
      let ratio = CGFloat(seconds / max(0.1, self.assetDurationSeconds()))
      self.timelineView.setPlaybackRatio(ratio)
      self.updatePlaybackChrome(currentSeconds: seconds)
      self.updatePreviewPlaybackControls()
    }
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  private func beginVideoDragEffects() {
    zoomTransition?.sourceProvider?.chatMediaZoomSetSourceHidden(
      true, forMessageId: zoomMessageId, pageIndex: 0)
  }

  private func endVideoDragEffects() {
    zoomTransition?.sourceProvider?.chatMediaZoomSetSourceHidden(
      false, forMessageId: zoomMessageId, pageIndex: 0)
  }

  private func dismissGestureProgress(for translation: CGPoint) -> CGFloat {
    let vertical = max(0.0, translation.y)
    let travelDistance = max(220.0, view.bounds.height * 0.46)
    return min(1.0, vertical / travelDistance)
  }

  private func applyInteractiveDismissState(
    translation: CGPoint,
    progress: CGFloat,
    backgroundAlpha: CGFloat? = nil
  ) {
    let vertical = max(0.0, translation.y)
    let transform = CGAffineTransform(translationX: 0.0, y: vertical)
    stageView.transform = transform
    topContainer.transform = transform
    bottomContainer.transform = transform
    topContainer.alpha = max(0.0, 1.0 - (progress * 0.45))
    bottomContainer.alpha = max(0.0, 1.0 - (progress * 0.52))
    backgroundView.alpha = backgroundAlpha ?? max(0.0, 1.0 - (progress * 0.65))
  }

  private func resetInteractiveDismissState(animated: Bool) {
    let updates = {
      self.stageView.transform = .identity
      self.topContainer.transform = .identity
      self.bottomContainer.transform = .identity
      self.topContainer.alpha = 1.0
      self.bottomContainer.alpha = 1.0
      self.backgroundView.alpha = 1.0
    }
    if animated {
      UIView.animate(
        withDuration: 0.25,
        delay: 0.0,
        usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0.0,
        options: [.curveEaseOut, .beginFromCurrentState],
        animations: updates,
        completion: { _ in
          self.isInteractiveDismissing = false
          self.view.setNeedsLayout()
        }
      )
    } else {
      updates()
      isInteractiveDismissing = false
      view.setNeedsLayout()
    }
  }

  @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
    guard previewOnly, !captionTextView.isFirstResponder else { return }

    let translation = gesture.translation(in: view)
    if zoomTransition != nil {
      switch gesture.state {
      case .began:
        isInteractiveDismissing = true
      case .changed:
        if !isInteractiveDismissing { isInteractiveDismissing = true }
        beginVideoDragEffects()
        let reach = max(1, view.bounds.height * 0.5)
        let progress = min(1, max(0, abs(translation.y) / reach))
        let scale = 1 - progress * 0.35
        stageView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
          .scaledBy(x: scale, y: scale)
        topContainer.alpha = max(0.0, 1.0 - progress * 0.7)
        bottomContainer.alpha = max(0.0, 1.0 - progress * 0.7)
        backgroundView.alpha = max(0.0, 1.0 - progress * 0.65)
      case .ended, .cancelled, .failed:
        let velocity = gesture.velocity(in: view)
        let committed =
          gesture.state == .ended
          && (abs(translation.y) > 110 || abs(velocity.y) > 900)
        if committed {
          dismiss(animated: true)
          return
        }
        endVideoDragEffects()
        resetInteractiveDismissState(animated: true)
      default:
        break
      }
      return
    }

    let vertical = max(0.0, translation.y)
    let progress = dismissGestureProgress(for: translation)

    switch gesture.state {
    case .began:
      isInteractiveDismissing = true
      applyInteractiveDismissState(translation: translation, progress: progress)
    case .changed:
      applyInteractiveDismissState(translation: translation, progress: progress)
    case .ended, .cancelled, .failed:
      if gesture.state == .cancelled || gesture.state == .failed {
        resetInteractiveDismissState(animated: true)
        return
      }
      let velocityY = gesture.velocity(in: view).y
      let shouldDismiss =
        vertical > 112.0
        || velocityY > 820.0
        || (progress > 0.18 && velocityY > 480.0)
      if shouldDismiss {
        let targetTranslation = CGPoint(
          x: 0.0,
          y: max(vertical + (velocityY * 0.10), view.bounds.height * 0.34)
        )
        UIView.animate(
          withDuration: 0.18,
          delay: 0.0,
          options: [.curveEaseIn, .beginFromCurrentState]
        ) {
          self.applyInteractiveDismissState(
            translation: targetTranslation,
            progress: 1.0,
            backgroundAlpha: 0.0
          )
          self.topContainer.alpha = 0.0
          self.bottomContainer.alpha = 0.0
        } completion: { _ in
          self.dismiss(animated: false)
        }
      } else {
        resetInteractiveDismissState(animated: true)
      }
    default:
      break
    }
  }

  @objc private func handleLegacyMenuPress() {
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: "Save to Photos", style: .default) { [weak self] _ in
        self?.saveVideoToPhotos()
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    sheet.popoverPresentationController?.sourceView = menuButton
    sheet.popoverPresentationController?.sourceRect = menuButton.bounds
    present(sheet, animated: true)
  }

  private func saveVideoToPhotos() {
    guard let urlAsset = asset as? AVURLAsset else {
      presentInfoAlert(title: "Unable to Save", message: "This video source is unavailable.")
      return
    }
    let sourceURL = urlAsset.url
    if sourceURL.isFileURL {
      persistVideoToPhotos(from: sourceURL, cleanupAfterSave: false)
      return
    }

    requestPhotoLibraryAddAccess { [weak self] granted in
      guard let self else { return }
      guard granted else {
        DispatchQueue.main.async {
          self.presentInfoAlert(
            title: "Photos Access Needed",
            message: "Allow photo access to save this video."
          )
        }
        return
      }

      var request = URLRequest(url: sourceURL)
      request.timeoutInterval = 120
      request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
      if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
      }

      VibeHTTP.shared.downloadTask(with: request) { [weak self] tempURL, _, error in
        guard let self else { return }
        if let error {
          DispatchQueue.main.async {
            self.presentInfoAlert(title: "Save Failed", message: error.localizedDescription)
          }
          return
        }
        guard let tempURL else {
          DispatchQueue.main.async {
            self.presentInfoAlert(title: "Save Failed", message: "The video download did not finish.")
          }
          return
        }

        let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
        let localURL = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: localURL)
        do {
          try FileManager.default.moveItem(at: tempURL, to: localURL)
          DispatchQueue.main.async {
            self.persistVideoToPhotos(from: localURL, cleanupAfterSave: true)
          }
        } catch {
          DispatchQueue.main.async {
            self.presentInfoAlert(title: "Save Failed", message: error.localizedDescription)
          }
        }
      }.resume()
    }
  }

  private func persistVideoToPhotos(from localURL: URL, cleanupAfterSave: Bool) {
    requestPhotoLibraryAddAccess { [weak self] granted in
      DispatchQueue.main.async {
        guard let self else { return }
        guard granted else {
          self.presentInfoAlert(
            title: "Photos Access Needed",
            message: "Allow photo access to save this video."
          )
          return
        }
        self.pendingSavedVideoCleanupURL = cleanupAfterSave ? localURL : nil
        UISaveVideoAtPathToSavedPhotosAlbum(
          localURL.path,
          self,
          #selector(ChatVideoEditViewController.video(_:didFinishSavingWithError:contextInfo:)),
          nil
        )
      }
    }
  }

  private func requestPhotoLibraryAddAccess(completion: @escaping (Bool) -> Void) {
    let currentStatus: PHAuthorizationStatus
    if #available(iOS 14.0, *) {
      currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    } else {
      currentStatus = PHPhotoLibrary.authorizationStatus()
    }

    switch currentStatus {
    case .authorized, .limited:
      completion(true)
    case .notDetermined:
      if #available(iOS 14.0, *) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
          completion(status == .authorized || status == .limited)
        }
      } else {
        PHPhotoLibrary.requestAuthorization { status in
          completion(status == .authorized)
        }
      }
    default:
      completion(false)
    }
  }

  private func presentInfoAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  @objc
  private func video(
    _ videoPath: String,
    didFinishSavingWithError error: Error?,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    if let cleanupURL = pendingSavedVideoCleanupURL {
      try? FileManager.default.removeItem(at: cleanupURL)
      pendingSavedVideoCleanupURL = nil
    }
    if let error {
      presentInfoAlert(title: "Save Failed", message: error.localizedDescription)
    } else {
      presentInfoAlert(title: "Saved", message: "Saved to Photos.")
    }
  }

  @objc private func handleMuteToggle() {
    isMuted.toggle()
    updateMuteButton()
  }

  @objc private func handleReply() {
    guard previewOnly else { return }
    player.pause()
    dismiss(animated: true) { [onReply] in
      onReply?()
    }
  }

  @objc private func handlePreviewPlaybackToggle() {
    guard previewOnly else { return }
    if suppressNextPreviewToggleTap {
      suppressNextPreviewToggleTap = false
      return
    }
    togglePreviewPlayback()
  }

  @objc private func handleSeekBackward() {
    seekPreview(by: -15.0)
  }

  @objc private func handleSeekForward() {
    seekPreview(by: 15.0)
  }

  private func seekPreview(by deltaSeconds: Double) {
    guard previewOnly else { return }
    let currentSeconds = CMTimeGetSeconds(player.currentTime())
    let target = (currentSeconds + deltaSeconds).clamped(
      to: selectedTrimStartSeconds()...selectedTrimEndSeconds()
    )
    let shouldResume = player.timeControlStatus == .playing || player.rate > 0.01
    seekPlayer(to: target, playAfterSeek: shouldResume)
  }

  @objc private func handlePlaybackSpeedHold(_ gesture: UILongPressGestureRecognizer) {
    guard previewOnly else { return }
    switch gesture.state {
    case .began:
      previewSpeedHoldWasPlaying = player.timeControlStatus == .playing || player.rate > 0.01
      previewSpeedHoldActive = true
      player.playImmediately(atRate: 2.0)
      updateChromeAppearance()
    case .ended, .cancelled, .failed:
      guard previewSpeedHoldActive else { return }
      previewSpeedHoldActive = false
      suppressNextPreviewToggleTap = true
      if previewSpeedHoldWasPlaying {
        player.playImmediately(atRate: 1.0)
      } else {
        player.pause()
      }
      updateChromeAppearance()
    default:
      break
    }
  }

  @objc private func handleText() {
    let alert = UIAlertController(title: "Add Text", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "Text"
      field.autocapitalizationType = .sentences
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Add", style: .default) { [weak self] _ in
        guard let self else { return }
        let text =
          alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }

        let label = UILabel()
        label.text = text
        label.font = .boldSystemFont(ofSize: 26.0)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.38)
        label.layer.cornerRadius = 12.0
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.sizeToFit()
        label.frame = label.frame.insetBy(dx: -14.0, dy: -8.0)
        label.center = CGPoint(
          x: self.textOverlayView.bounds.midX, y: self.textOverlayView.bounds.midY)
        label.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(
          target: self, action: #selector(self.handleTextLabelPan(_:)))
        label.addGestureRecognizer(pan)
        self.textOverlayView.addSubview(label)
      })
    present(alert, animated: true)
  }

  @objc private func handleDraw() {
    drawingView.setDrawingEnabled(!drawingView.drawingEnabled)
    updateChromeAppearance()
  }

  @objc private func handleLegacyQualityPress() {
    let currentIndex = ChatVideoExportQuality.allCases.firstIndex(of: selectedQuality) ?? 1
    let nextIndex = (currentIndex + 1) % ChatVideoExportQuality.allCases.count
    selectedQuality = ChatVideoExportQuality.allCases[nextIndex]
    rebuildQualityMenu()
  }

  @objc private func handleSend() {
    guard !previewOnly else { return }
    guard !isExporting else { return }
    setExporting(true)
    player.pause()
    let transitionCapture = makeTransitionCapture()
    let presentingController = presentingViewController
    let retainedSelf = self
    let dismissTarget = presentingController ?? self
    dismissTarget.dismiss(animated: true) {
      retainedSelf.exportEditedVideo { result in
        DispatchQueue.main.async {
          retainedSelf.setExporting(false)
          switch result {
          case .success(let url):
            retainedSelf.refreshCaptionPlaceholder()
            retainedSelf.onSend?(
              ChatVideoEditActionPayload(
                videoURL: url,
                caption: retainedSelf.captionText.isEmpty ? nil : retainedSelf.captionText,
                isMuted: retainedSelf.isMuted,
                qualityLabel: retainedSelf.selectedQuality.label,
                transitionCapture: transitionCapture
              )
            )
          case .failure(let error):
            if let presenter = retainedSelf.topVisiblePresenter() {
              let alert = UIAlertController(
                title: "Video Export Failed",
                message: error.localizedDescription,
                preferredStyle: .alert
              )
              alert.addAction(UIAlertAction(title: "OK", style: .default))
              presenter.present(alert, animated: true)
            }
          }
        }
      }
    }
  }

  private func topVisiblePresenter() -> UIViewController? {
    var controller = view.window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }

  private func setExporting(_ exporting: Bool) {
    isExporting = exporting
    sendButton.isEnabled = !exporting
    backButton.isEnabled = !exporting
    replyButton.isEnabled = !exporting
    textButton.isEnabled = !exporting
    drawButton.isEnabled = !exporting
    aiButton.isEnabled = !exporting && !isAIWorking
    muteButton.isEnabled = !exporting
    playbackRewindButton.isEnabled = !exporting
    playbackToggleButton.isEnabled = !exporting
    playbackForwardButton.isEnabled = !exporting
    qualityButton.isEnabled = !exporting
    captionTextView.isEditable = !exporting
    timelineView.isUserInteractionEnabled = !exporting
    textOverlayView.isUserInteractionEnabled = !exporting
    drawingView.isUserInteractionEnabled = !exporting && drawingView.drawingEnabled
    if exporting {
      sendButton.imageView?.alpha = 0.0
      sendSpinner.startAnimating()
    } else {
      sendButton.imageView?.alpha = 1.0
      sendSpinner.stopAnimating()
    }
  }

  // MARK: - AI edit

  @objc private func handleAI() {
    guard !isAIWorking else { return }

    if isAIModeActive {
      setAIMode(false)
      return
    }

    ChatAIMediaConsent.ensureConsent(for: .google, from: self) { [weak self] accepted in
      guard let self, accepted else { return }
      self.setAIMode(true)
    }
  }

  private func setAIMode(_ active: Bool) {
    isAIModeActive = active

    if active {
      // Snap the current window down to something the model will actually take.
      let (start, end) = clampSelectionForAI(start: trimStartRatio, end: trimEndRatio)
      trimStartRatio = start
      trimEndRatio = end
      timelineView.setSelection(startRatio: start, endRatio: end)
      seekPlayer(to: selectedTrimStartSeconds(), playAfterSeek: false)
    } else {
      _ = aiPromptBar.resignFirstResponder()
    }

    updateAIChrome()
    updateChromeAppearance()

    UIView.animate(
      withDuration: 0.28, delay: 0.0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.0,
      options: [.curveEaseInOut]
    ) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    } completion: { _ in
      if active { self.aiPromptBar.focus() }
    }
  }

  /// Keeps the trim window within the model's 10-second input ceiling. Returns
  /// the pair unchanged when AI mode is off, so normal trimming is unaffected.
  private func clampSelectionForAI(start: CGFloat, end: CGFloat) -> (CGFloat, CGFloat) {
    guard isAIModeActive else { return (start, end) }

    let duration = assetDurationSeconds()
    guard duration > 0 else { return (start, end) }

    let maxRatio = CGFloat(min(1.0, Self.aiMaxClipSeconds / duration))
    guard (end - start) > maxRatio else { return (start, end) }

    // Anchor on whichever edge the user was not dragging: if the start moved,
    // pull the end in, otherwise push the start forward.
    if start != trimStartRatio {
      return (start, min(1.0, start + maxRatio))
    }
    return (max(0.0, end - maxRatio), end)
  }

  private func updateAIChrome() {
    guard isAIModeActive else { return }
    let seconds = max(0.0, selectedTrimEndSeconds() - selectedTrimStartSeconds())
    aiPromptBar.setHint(
      String(format: "%.1fs selected · %.0fs max", seconds, Self.aiMaxClipSeconds))
    aiPromptBar.setCanUndo(aiOriginalAsset != nil)
  }

  private func runVideoAIEdit(prompt: String) {
    guard !isAIWorking else { return }

    isAIWorking = true
    aiPromptBar.setWorking(true)
    setExporting(true)
    player.pause()
    view.endEditing(true)

    // The frame the user is looking at carries the wait, under a travelling
    // Metal blur — a spinner over a frozen sheet said nothing about which clip
    // was being worked on.
    aiProcessingOverlay.onCancel = { [weak self] in self?.cancelVideoAIEdit() }
    aiProcessingOverlay.setCaption("Editing with AI")
    // Over the clip, not over the screen: the trim bar and the prompt stay
    // readable, and the blur lands on the thing being edited.
    aiProcessingOverlay.present(
      in: view,
      over: previewView.convert(previewView.bounds, to: view),
      shape: .rect(cornerRadius: previewView.layer.cornerRadius),
      frame: currentPlayerFrameImage(),
      detail: "Sent to Google · this step is not end-to-end encrypted"
    )

    // Export exactly the selected ≤10s window, then hand those bytes over.
    exportEditedVideo { [weak self] result in
      guard let self else { return }
      // Cancel can land while the export is still running. Without this the
      // export would finish afterwards and start the paid upload anyway.
      guard self.isAIWorking else { return }

      switch result {
      case .failure(let error):
        self.finishVideoAIEdit(asset: nil, interactionID: nil, error: error)

      case .success(let url):
        self.aiTask?.cancel()
        self.aiTask = Task { [weak self] in
          guard let self else { return }
          do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let edited = try await ChatAIMediaEditService.editVideo(
              video: data,
              prompt: prompt,
              previousInteractionID: self.aiInteractionID,
              aspectRatio: self.naturalVideoSize.width > self.naturalVideoSize.height
                ? "16:9" : "9:16"
            )
            guard !Task.isCancelled else { return }

            let destination = FileManager.default.temporaryDirectory
              .appendingPathComponent("vibe-ai-\(UUID().uuidString).mp4")
            try edited.data.write(to: destination)

            await MainActor.run {
              self.finishVideoAIEdit(
                asset: AVURLAsset(url: destination),
                interactionID: edited.interactionID,
                error: nil)
            }
          } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
              self.finishVideoAIEdit(asset: nil, interactionID: nil, error: error)
            }
          }
        }
      }
    }
  }

  private func finishVideoAIEdit(
    asset editedAsset: AVAsset?, interactionID: String?, error: Error?
  ) {
    isAIWorking = false
    aiPromptBar.setWorking(false)
    setExporting(false)
    aiProcessingOverlay.dismiss()

    guard let editedAsset else {
      let message =
        (error as? LocalizedError)?.errorDescription ?? "That edit didn't go through."
      let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
      return
    }

    if aiOriginalAsset == nil { aiOriginalAsset = asset }
    aiInteractionID = interactionID
    aiPromptBar.clearPrompt()

    adoptAIEditedAsset(editedAsset)
  }

  /// Stops the in-flight edit and takes the overlay down. The export that may
  /// still be running writes to a temp file nobody reads, so there is nothing to
  /// unwind beyond the task itself.
  private func cancelVideoAIEdit() {
    guard isAIWorking else { return }
    aiTask?.cancel()
    aiTask = nil
    isAIWorking = false
    aiPromptBar.setWorking(false)
    setExporting(false)
    aiProcessingOverlay.dismiss()
  }

  /// Still of the frame currently under the playhead, for the processing
  /// overlay to blur. `AVPlayerLayer` contents cannot be snapshotted by the
  /// view hierarchy, so this goes back to the asset for the pixels.
  private func currentPlayerFrameImage() -> UIImage? {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
    // Downscale: this only ever feeds a heavy blur, so full resolution would be
    // decode cost with nothing to show for it.
    generator.maximumSize = CGSize(width: 720.0, height: 720.0)

    let time = player.currentTime()
    let requested = CMTIME_IS_NUMERIC(time) ? time : .zero
    guard let cgImage = try? generator.copyCGImage(at: requested, actualTime: nil) else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }

  private func handleAIUndo() {
    guard let original = aiOriginalAsset else { return }
    aiOriginalAsset = nil
    aiInteractionID = nil
    adoptAIEditedAsset(original)
  }

  /// Swaps the asset under the player and resets the trim window to the whole
  /// (now short) clip, since the returned video *is* the selection.
  private func adoptAIEditedAsset(_ newAsset: AVAsset) {
    asset = newAsset
    trimStartRatio = 0.0
    trimEndRatio = 1.0

    let item = AVPlayerItem(asset: newAsset)
    player.replaceCurrentItem(with: item)
    observePlayerItem(item)

    cachedAssetDurationSeconds = max(0.1, CMTimeGetSeconds(newAsset.duration))
    timelineView.setSelection(startRatio: 0.0, endRatio: 1.0)
    loadThumbnails()
    updateAIChrome()

    player.seek(to: .zero)
    player.play()

    view.setNeedsLayout()
  }

  private func exportEditedVideo(
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    loadExportSource { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let source):
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
          completion(
            .failure(
              NSError(
                domain: "ChatVideoEditViewController",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Could not create video track"]
              ))
          )
          return
        }

        let timeRange = CMTimeRange(
          start: CMTime(seconds: self.selectedTrimStartSeconds(), preferredTimescale: 600),
          end: CMTime(seconds: self.selectedTrimEndSeconds(), preferredTimescale: 600)
        )

        do {
          try compositionVideoTrack.insertTimeRange(timeRange, of: source.videoTrack, at: .zero)
          compositionVideoTrack.preferredTransform = .identity

          if !self.isMuted, let sourceAudioTrack = source.audioTrack,
            let compositionAudioTrack = composition.addMutableTrack(
              withMediaType: .audio,
              preferredTrackID: kCMPersistentTrackID_Invalid)
          {
            try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
          }
        } catch {
          completion(.failure(error))
          return
        }

        let transformSpec = self.exportTransformSpec(for: source.videoTrack)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = transformSpec.renderSize
        let timescale = Int32(max(24.0, source.nominalFrameRate > 0 ? source.nominalFrameRate : 30.0))
        videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: timeRange.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transformSpec.transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        self.applyOverlayCompositionIfNeeded(to: videoComposition, renderSize: transformSpec.renderSize)
        NSLog(
          "[ChatVideoEditExport] prepare trimStart=%.3f trimEnd=%.3f render=%@ fps=%.3f transform=%@ quality=%@",
          CMTimeGetSeconds(timeRange.start),
          CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange)),
          NSCoder.string(for: CGRect(origin: .zero, size: transformSpec.renderSize)),
          source.nominalFrameRate,
          NSCoder.string(for: transformSpec.transform),
          self.selectedQuality.label
        )

        let primaryPresets = self.selectedQuality.preferredPresets + [AVAssetExportPresetMediumQuality]
        self.exportEditedComposition(
          composition: composition,
          videoComposition: videoComposition,
          presetCandidates: primaryPresets,
          preferredOutputTypes: [.mp4, .mov],
          logContext: "primary"
        ) { primaryResult in
          switch primaryResult {
          case .success(let url):
            completion(.success(url))
          case .failure(let primaryError):
            NSLog(
              "[ChatVideoEditExport] primary failed error=%@ retrying safer fallback",
              primaryError.localizedDescription
            )
            self.exportEditedComposition(
              composition: composition,
              videoComposition: videoComposition,
              presetCandidates: [AVAssetExportPresetMediumQuality, AVAssetExportPresetHighestQuality],
              preferredOutputTypes: [.mov, .mp4],
              logContext: "fallback"
            ) { fallbackResult in
              switch fallbackResult {
              case .success(let url):
                completion(.success(url))
              case .failure:
                completion(.failure(primaryError))
              }
            }
          }
        }
      }
    }
  }

  private func exportTransformSpec(for track: AVAssetTrack) -> (transform: CGAffineTransform, renderSize: CGSize) {
    let naturalSize = track.naturalSize
    let preferredTransform = track.preferredTransform
    let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    let normalizedTransform = preferredTransform.translatedBy(
      x: -transformedRect.origin.x,
      y: -transformedRect.origin.y
    )
    return (normalizedTransform, renderSize)
  }

  private func selectExportPreset(for asset: AVAsset, candidates: [String]) -> String? {
    let compatiblePresets = Set(AVAssetExportSession.exportPresets(compatibleWith: asset))
    for candidate in candidates where compatiblePresets.contains(candidate) {
      return candidate
    }
    if compatiblePresets.contains(AVAssetExportPresetMediumQuality) {
      return AVAssetExportPresetMediumQuality
    }
    return compatiblePresets.first
  }

  private func validateExportedVideo(url: URL, logContext: String) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let byteSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    guard byteSize > 0 else {
      NSLog("[ChatVideoEditExport] %@ invalid empty path=%@", logContext, url.path)
      return false
    }
    let asset = AVURLAsset(url: url)
    let videoTracks = asset.tracks(withMediaType: .video)
    let playable = asset.isPlayable
    if playable && !videoTracks.isEmpty {
      NSLog(
        "[ChatVideoEditExport] %@ validated path=%@ bytes=%lld tracks=%d playable=Y",
        logContext,
        url.path,
        byteSize,
        videoTracks.count
      )
      return true
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640.0, height: 640.0)
    let probeTimes: [Double] = [0.0, 0.05, 0.12, 0.25, 0.5]
    var lastErrorDescription = "unknown"
    for seconds in probeTimes {
      do {
        _ = try generator.copyCGImage(
          at: CMTime(seconds: seconds, preferredTimescale: 600),
          actualTime: nil
        )
        NSLog(
          "[ChatVideoEditExport] %@ validated by frame path=%@ bytes=%lld tracks=%d playable=%@ frame=%.2f",
          logContext,
          url.path,
          byteSize,
          videoTracks.count,
          playable ? "Y" : "N",
          seconds
        )
        return true
      } catch {
        lastErrorDescription = error.localizedDescription
      }
    }
    NSLog(
      "[ChatVideoEditExport] %@ invalid path=%@ bytes=%lld tracks=%d playable=%@ error=%@",
      logContext,
      url.path,
      byteSize,
      videoTracks.count,
      playable ? "Y" : "N",
      lastErrorDescription
    )
    return false
  }

  private func exportEditedComposition(
    composition: AVAsset,
    videoComposition: AVMutableVideoComposition,
    presetCandidates: [String],
    preferredOutputTypes: [AVFileType],
    logContext: String,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard
      let presetName = selectExportPreset(for: composition, candidates: presetCandidates),
      let exportSession = AVAssetExportSession(asset: composition, presetName: presetName)
    else {
      completion(
        .failure(
          NSError(
            domain: "ChatVideoEditViewController",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Could not create export session"]
          ))
      )
      return
    }

    exportSession.videoComposition = videoComposition
    exportSession.shouldOptimizeForNetworkUse = true
    let outputFileType =
      preferredOutputTypes.first(where: { exportSession.supportedFileTypes.contains($0) })
      ?? exportSession.supportedFileTypes.first
      ?? .mov
    let fileExtension = outputFileType == .mov ? "mov" : "mp4"
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("video-edit-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try? FileManager.default.removeItem(at: outputURL)
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = outputFileType
    NSLog(
      "[ChatVideoEditExport] %@ start preset=%@ fileType=%@ output=%@",
      logContext,
      presetName,
      outputFileType.rawValue,
      outputURL.lastPathComponent
    )

    exportSession.exportAsynchronously { [weak self] in
      guard let self else { return }
      switch exportSession.status {
      case .completed:
        if self.validateExportedVideo(url: outputURL, logContext: logContext) {
          completion(.success(outputURL))
        } else {
          completion(
            .failure(
              NSError(
                domain: "ChatVideoEditViewController",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "Video export produced an unreadable file"]
              ))
          )
        }
      case .failed:
        completion(
          .failure(
            exportSession.error
              ?? NSError(
                domain: "ChatVideoEditViewController",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Video export failed"]
              ))
        )
      case .cancelled:
        completion(
          .failure(
            NSError(
              domain: "ChatVideoEditViewController",
              code: 15,
              userInfo: [NSLocalizedDescriptionKey: "Video export cancelled"]
            ))
        )
      default:
        completion(
          .failure(
            NSError(
              domain: "ChatVideoEditViewController",
              code: 16,
              userInfo: [NSLocalizedDescriptionKey: "Video export incomplete"]
            ))
        )
      }
    }
  }

  private func loadExportSource(
    completion: @escaping (Result<LoadedVideoExportSource, Error>) -> Void
  ) {
    if #available(iOS 16.0, *) {
      Task { [weak self] in
        guard let self else { return }
        do {
          let videoTracks = try await self.asset.loadTracks(withMediaType: .video)
          guard let videoTrack = videoTracks.first else {
            throw NSError(
              domain: "ChatVideoEditViewController",
              code: 11,
              userInfo: [NSLocalizedDescriptionKey: "Missing video track"]
            )
          }
          let audioTrack = (try await self.asset.loadTracks(withMediaType: .audio)).first
          let naturalSize = try await videoTrack.load(.naturalSize)
          let preferredTransform = try await videoTrack.load(.preferredTransform)
          let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
          let transformedSize = naturalSize.applying(preferredTransform)
          let source = LoadedVideoExportSource(
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            naturalSize: CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height)),
            preferredTransform: preferredTransform,
            nominalFrameRate: nominalFrameRate
          )
          await MainActor.run {
            completion(.success(source))
          }
        } catch {
          await MainActor.run {
            completion(self.loadLegacyExportSource())
          }
        }
      }
      return
    }

    completion(loadLegacyExportSource())
  }

  @available(iOS, introduced: 13.0, deprecated: 16.0, message: "Legacy AVFoundation fallback")
  private func loadLegacyExportSource() -> Result<LoadedVideoExportSource, Error> {
    guard let sourceVideoTrack = asset.tracks(withMediaType: .video).first else {
      return .failure(
        NSError(
          domain: "ChatVideoEditViewController",
          code: 11,
          userInfo: [NSLocalizedDescriptionKey: "Missing video track"]
        ))
    }
    let sourceAudioTrack = asset.tracks(withMediaType: .audio).first
    let transformedSize = sourceVideoTrack.naturalSize.applying(sourceVideoTrack.preferredTransform)
    return .success(
      LoadedVideoExportSource(
        videoTrack: sourceVideoTrack,
        audioTrack: sourceAudioTrack,
        naturalSize: CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height)),
        preferredTransform: sourceVideoTrack.preferredTransform,
        nominalFrameRate: sourceVideoTrack.nominalFrameRate
      )
    )
  }

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard
      let info = notification.userInfo,
      let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else {
      return
    }

    let localFrame = view.convert(endFrame, from: nil)
    keyboardHeight = max(0.0, view.bounds.maxY - localFrame.minY)
    UIView.animate(
      withDuration: 0.24,
      delay: 0.0,
      options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  @objc private func handleTextLabelPan(_ gesture: UIPanGestureRecognizer) {
    guard let label = gesture.view else { return }
    let translation = gesture.translation(in: textOverlayView)
    label.center = CGPoint(x: label.center.x + translation.x, y: label.center.y + translation.y)
    gesture.setTranslation(.zero, in: textOverlayView)
  }

  func textViewDidChange(_ textView: UITextView) {
    guard textView === captionTextView else { return }
    refreshCaptionPlaceholder()
    UIView.animate(
      withDuration: 0.12,
      delay: 0.0,
      options: [.curveEaseInOut, .beginFromCurrentState]
    ) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === dismissPanGesture else { return true }
    guard previewOnly, !captionTextView.isFirstResponder else { return false }
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: view)
    return abs(velocity.y) > abs(velocity.x) && velocity.y > 0.0
  }
}

extension ChatVideoEditViewController: ChatMediaZoomTransitionTarget {
  var zoomTransitionImage: UIImage? {
    guard previewView.bounds.width > 1, previewView.bounds.height > 1 else { return nil }
    let renderer = UIGraphicsImageRenderer(bounds: previewView.bounds)
    return renderer.image { ctx in
      previewView.layer.render(in: ctx.cgContext)
    }
  }

  var zoomTransitionMessageId: String? { zoomMessageId }

  var zoomTransitionPageIndex: Int { 0 }

  func zoomTransitionTargetFrame(for image: UIImage?) -> CGRect {
    zoomTransitionCurrentFrame
  }

  var zoomTransitionCurrentFrame: CGRect {
    previewView.convert(previewView.bounds, to: nil)
  }

  func setZoomTransitionContentHidden(_ hidden: Bool) {
    previewView.isHidden = hidden
    playerLayer.isHidden = hidden
  }

  func installZoomTransitionFlightView(_ flightView: UIView, frameInWindow: CGRect) -> UIView {
    view.insertSubview(flightView, belowSubview: topContainer)
    flightView.frame = view.convert(frameInWindow, from: nil)
    return view
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
