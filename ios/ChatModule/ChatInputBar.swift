import AVFoundation
import CoreLocation
import PhotosUI
import Speech
import UIKit
import UniformTypeIdentifiers

private let chatGapDebugOverlayEnabled = false

// MARK: - Delegate

protocol ChatInputBarDelegate: AnyObject {
  func inputBarDidSend(text: String, attachments: [String], imageLocalURIs: [String])
  // Hold-menu Edit: composer submits new text/caption for an already-sent message.
  func inputBarDidSubmitEdit(messageId: String, text: String)
  func inputBarDidRequestStopStreaming()
  func inputBarDidSendWithAgentMention(
    text: String, agentText: String, attachments: [String], imageLocalURIs: [String]
  )
  func inputBarDidSendWithStandaloneAgentMention(
    text: String,
    agentText: String,
    agentUsername: String,
    attachments: [String],
    imageLocalURIs: [String]
  )
  func inputBarDidRequestVibeAgentBuilder()
  func inputBarDidRequestAgentPanel()
  func inputBarDidTapAttachment()
  func inputBarDidTapAction()
  func inputBarTextDidChange(text: String)
  func inputBarHeightDidChange()
  func inputBarDidRequestSelectionAction(_ action: String, payload: [String: Any]?)
  /// Pending group/channel forward: user tapped send on the forward banner composer.
  func inputBarDidConfirmForward(caption: String)
  /// User dismissed the forward banner (cancel).
  func inputBarDidCancelForward()
  // Rich attachment callbacks (mirrors AttachmentMenu.tsx)
  func inputBarDidSelectImage(
    uri: String,
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?
  )
  // Multi-select: all picked image uris (selection order) + the shared caption.
  func inputBarDidSelectImages(
    uris: [String],
    caption: String?,
    transitionCapture: ChatAttachmentTransitionCapture?
  )
  func inputBarDidSelectGif(
    id: String,
    url: String,
    previewUrl: String,
    width: Int,
    height: Int,
    localData: Data?
  )
  func inputBarDidSelectSticker(
    stickerId: String,
    packId: String,
    bundleFileName: String?,
    emoji: String?,
    width: Int,
    height: Int
  )
  func inputBarDidSelectFile(uri: String, name: String)
  func inputBarDidSelectLocation(latitude: Double, longitude: Double)
  // Recording
  func inputBarRecordingStateDidChange(isRecording: Bool, isLocked: Bool, mode: String)
  func inputBarRecordingDidCancel()
  func inputBarDidRecordVoice(uri: String, duration: Double, waveform: [Double])
  func inputBarDidRecordVideoNote(uri: String, duration: Double)
  // Reply
  func inputBarReplyDismissed()
}

// MARK: - FluidVADVisualizer

/// Classic fluid VAD: layered soft disks that pulse behind the play plate / mic.
/// Color is injected via `applyColor` (dynamic from cover art or accent).
final class FluidVADVisualizer: UIView {
  private let layers: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
  private var displayLink: CADisplayLink?
  private var time: CGFloat = 0
  var level: CGFloat = 0
  var activePushMultiplier: CGFloat = 0.4

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    clipsToBounds = false
    // Soften hard disc edges so layers read as fluid, not solid rings.
    layers.forEach {
      $0.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
      $0.opacity = 0
      layer.addSublayer($0)
    }
  }

  required init?(coder: NSCoder) { nil }

  func applyColor(_ color: UIColor) {
    // Dynamic tint (cover dominant / accent). Keep alpha moderate so the plate stays primary.
    let fill = color.withAlphaComponent(min(0.45, max(0.18, color.cgColor.alpha)))
    layers.forEach { $0.fillColor = fill.cgColor }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
    for l in layers {
      l.bounds = bounds
      l.position = center
      l.path = UIBezierPath(ovalIn: bounds).cgPath
    }
  }

  func start() {
    displayLink?.invalidate()
    time = 0
    isHidden = false
    alpha = 1
    displayLink = CADisplayLink(target: self, selector: #selector(tick))
    displayLink?.add(to: .main, forMode: .common)
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    UIView.animate(withDuration: 0.25) {
      self.alpha = 0
    }
  }

  @objc private func tick() {
    time += 0.05
    for (i, l) in layers.enumerated() {
      let idx = CGFloat(i + 1)
      let idlePulse = sin(time * 2.0 + CGFloat(i * 2)) * 0.04
      let activePush = level * activePushMultiplier * idx
      let finalScale = 1.0 + idlePulse + activePush
      l.transform = CATransform3DMakeScale(finalScale, finalScale, 1.0)
      let baseOpacity = max(0.0, 1.0 - (finalScale - 1.0) * 1.5)
      l.opacity = Float(baseOpacity * 0.55)
    }
  }
}

private final class ChatComposerTextView: UITextView {
  override func paste(_ sender: Any?) {
    if let clipboardText = UIPasteboard.general.string, !clipboardText.isEmpty {
      if let selected = selectedTextRange {
        replace(selected, withText: clipboardText)
      } else {
        insertText(clipboardText)
      }
      return
    }
    super.paste(sender)
  }
}

private final class ChatGifPanelPassthroughWindow: UIWindow {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let view = super.hitTest(point, with: event)
    return view === self || view === rootViewController?.view ? nil : view
  }
}

private final class ChatGifPanelPassthroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let view = super.hitTest(point, with: event)
    return view == self ? nil : view
  }
}

/// Vector trash with a hinged lid so cancel can open/close the door, not scale a glyph.
private final class TrashCanGlyphView: UIView {
  private let canLayer = CAShapeLayer()
  private let ribLayer = CAShapeLayer()
  private let lidWrap = UIView()
  private let lidBar = UIView()
  private let lidHandle = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    canLayer.fillColor = UIColor.clear.cgColor
    canLayer.strokeColor = UIColor.systemRed.cgColor
    canLayer.lineCap = .round
    canLayer.lineJoin = .round
    layer.addSublayer(canLayer)
    ribLayer.fillColor = UIColor.clear.cgColor
    ribLayer.strokeColor = UIColor.systemRed.cgColor
    ribLayer.lineCap = .round
    layer.addSublayer(ribLayer)
    lidWrap.clipsToBounds = false
    addSubview(lidWrap)
    lidBar.backgroundColor = .systemRed
    lidWrap.addSubview(lidBar)
    lidHandle.backgroundColor = .systemRed
    lidWrap.addSubview(lidHandle)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    let h = bounds.height
    let line = max(1.7, w * 0.10)
    canLayer.lineWidth = line
    ribLayer.lineWidth = max(1.2, line * 0.72)
    let can = CGRect(x: w * 0.24, y: h * 0.40, width: w * 0.52, height: h * 0.46)
    canLayer.path = UIBezierPath(roundedRect: can, byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: w * 0.10, height: w * 0.10)).cgPath
    let ribs = UIBezierPath()
    let ribY0 = can.minY + line
    let ribY1 = can.maxY - line
    for t in [0.33, 0.50, 0.67] as [CGFloat] {
      let x = can.minX + can.width * t
      ribs.move(to: CGPoint(x: x, y: ribY0))
      ribs.addLine(to: CGPoint(x: x, y: ribY1))
    }
    ribLayer.path = ribs.cgPath
    let lidH = max(2.2, line * 1.15)
    let lidW = w * 0.70
    lidWrap.bounds = CGRect(x: 0, y: 0, width: lidW, height: lidH + w * 0.16)
    lidWrap.center = CGPoint(x: bounds.midX, y: h * 0.30)
    lidBar.frame = CGRect(x: 0, y: lidWrap.bounds.height - lidH, width: lidW, height: lidH)
    lidBar.layer.cornerRadius = lidH * 0.5
    let handleW = w * 0.22
    lidHandle.frame = CGRect(
      x: (lidW - handleW) / 2, y: 0, width: handleW, height: max(2.0, line * 0.9))
    lidHandle.layer.cornerRadius = lidHandle.bounds.height * 0.5
  }

  func setLidOpen(_ open: Bool, animated: Bool) {
    let angle = open ? CGFloat(-0.92) : 0
    let lift = open ? CGAffineTransform(translationX: -1, y: -2).rotated(by: angle) : .identity
    if animated {
      UIView.animate(
        withDuration: open ? 0.28 : 0.18,
        delay: 0,
        usingSpringWithDamping: open ? 0.62 : 0.55,
        initialSpringVelocity: open ? 0.55 : 0.9,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.lidWrap.transform = lift
      }
    } else {
      lidWrap.transform = lift
    }
  }
}

private final class ChatGifPanelOverlayController: UIViewController {
  override func loadView() {
    let passthroughView = ChatGifPanelPassthroughView()
    passthroughView.backgroundColor = .clear
    view = passthroughView
  }
}

private final class VideoNoteRecorderViewController: UIViewController,
  AVCaptureFileOutputRecordingDelegate
{
  /// Final stop: url / total duration / shouldSend / optional release morph snapshot +
  /// circle frame in the host list view (for flight animation).
  var onFinished: ((URL?, Double, Bool, UIImage?, CGRect) -> Void)?
  /// Host view used to convert the circle frame for the release morph.
  weak var morphCoordinateView: UIView?
  /// Fired when pause settles with a draft segment available for the input preview.
  var onPaused: ((URL?, Double) -> Void)?
  /// Fired when recording resumes after pause.
  var onResumed: (() -> Void)?
  /// Live duration while recording (for input timer).
  var onDurationTick: ((Double) -> Void)?

  private(set) var isPaused = false
  private(set) var accumulatedDuration: Double = 0

  private let session = AVCaptureSession()
  private let movieOutput = AVCaptureMovieFileOutput()
  private let sessionQueue = DispatchQueue(label: "chat.video.note.session", qos: .userInitiated)
  private var previewLayer: AVCaptureVideoPreviewLayer?
  /// Full-screen BLUR backdrop (original placement — covers entire preview, including over input).
  private let backdropBlur = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let backdropTint = UIView()
  private let circleContainer = UIView()
  /// Attachment-style loading blur over the circle until camera frames are live.
  private let circleLoadingBlur = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let circleLoadingShade = UIView()
  /// Near the input (bottom), not page/circle chrome.
  private let flashGlass = UIVisualEffectView(effect: nil)
  private let flashButton = UIButton(type: .system)
  /// Single-tap flip, placed next to flash near the input.
  private let flipGlass = UIVisualEffectView(effect: nil)
  private let flipButton = UIButton(type: .system)
  /// Height of the composer so flash/flip sit just above it, not behind it.
  var bottomChromeInset: CGFloat = 96

  private var startedAt: Date?
  private var segmentStartedAt: Date?
  private var pendingSend = true
  private var stopRequested = false
  private var pauseRequested = false
  private var hasAppeared = false
  private var didFinish = false
  private var isSessionConfigured = false
  private var hasStartedFileRecording = false
  private var hasScheduledInitialRecording = false
  private var recordingStartTimeoutWorkItem: DispatchWorkItem?
  private var cameraPosition: AVCaptureDevice.Position = .front
  private var videoDeviceInput: AVCaptureDeviceInput?
  private var recordedSegments: [URL] = []

  private let progressLayer = CAShapeLayer()
  private var displayLink: CADisplayLink?
  private let maxDuration: TimeInterval = 60.0

  override var prefersStatusBarHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = true

    // Full-screen blur (not a solid black plate, not an input-cutout). Starts
    // hidden — playEntranceAnimation() fades it in once installed on screen,
    // instead of the whole overlay snapping in at full opacity.
    backdropBlur.frame = view.bounds
    backdropBlur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backdropBlur.alpha = 0.0
    view.addSubview(backdropBlur)
    backdropTint.frame = view.bounds
    backdropTint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backdropTint.backgroundColor = UIColor.black.withAlphaComponent(0.16)
    backdropTint.isUserInteractionEnabled = false
    backdropTint.alpha = 0.0
    view.addSubview(backdropTint)

    // Circle itself: no solid fill ever (only camera + loading blur — attachment
    // camera cell pattern, preview under blur until ready). It DOES scale/fade in
    // via playEntranceAnimation() rather than snapping to full size instantly.
    circleContainer.backgroundColor = .clear
    circleContainer.clipsToBounds = true
    circleContainer.alpha = 0
    circleContainer.transform = CGAffineTransform(scaleX: 0.58, y: 0.58)
    view.addSubview(circleContainer)

    circleLoadingBlur.isUserInteractionEnabled = false
    circleLoadingBlur.alpha = 1.0
    circleContainer.addSubview(circleLoadingBlur)

    circleLoadingShade.backgroundColor = UIColor.black.withAlphaComponent(0.12)
    circleLoadingShade.isUserInteractionEnabled = false
    circleLoadingShade.alpha = 1.0
    circleContainer.addSubview(circleLoadingShade)

    progressLayer.strokeColor = ChatListAppearance.brandAccentFallback.cgColor
    progressLayer.lineWidth = 4
    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.lineCap = .round
    progressLayer.strokeEnd = 0
    view.layer.addSublayer(progressLayer)

    let controlCfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    styleRecorderControlGlass(flashGlass)
    flashButton.setImage(
      UIImage(systemName: "bolt.slash.fill", withConfiguration: controlCfg), for: .normal)
    flashButton.tintColor = UIColor(white: 0.96, alpha: 1)
    flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
    flashGlass.contentView.addSubview(flashButton)
    flashGlass.alpha = 0
    view.addSubview(flashGlass)

    styleRecorderControlGlass(flipGlass)
    flipButton.setImage(
      UIImage(systemName: "arrow.triangle.2.circlepath.camera.fill", withConfiguration: controlCfg),
      for: .normal)
    flipButton.tintColor = UIColor(white: 0.96, alpha: 1)
    flipButton.addTarget(self, action: #selector(flipCameraTapped), for: .touchUpInside)
    flipGlass.contentView.addSubview(flipButton)
    flipGlass.alpha = 0
    view.addSubview(flipGlass)

    // Double-tap anywhere on the full overlay (not only the circle) → flip camera.
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(flipCameraTapped))
    doubleTap.numberOfTapsRequired = 2
    view.addGestureRecognizer(doubleTap)
  }

  deinit {
    recordingStartTimeoutWorkItem?.cancel()
    displayLink?.invalidate()
  }

  @objc private func flashTapped() {
    sessionQueue.async { [weak self] in
      guard let self, let device = self.videoDeviceInput?.device, device.hasTorch else { return }
      do {
        try device.lockForConfiguration()
        if device.torchMode == .on {
          device.torchMode = .off
        } else if device.isTorchModeSupported(.on) {
          try device.setTorchModeOn(level: 1.0)
        }
        let on = device.torchMode == .on
        device.unlockForConfiguration()
        DispatchQueue.main.async {
          let name = on ? "bolt.fill" : "bolt.slash.fill"
          let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
          self.flashButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
        }
      } catch {
        // ignore torch failures
      }
    }
  }

  @objc private func flipCameraTapped() {
    flipCamera()
  }

  @objc private func updateProgress() {
    guard !isPaused else { return }
    let segmentElapsed = Date().timeIntervalSince(segmentStartedAt ?? startedAt ?? Date())
    let total = accumulatedDuration + max(0, segmentElapsed)
    let progress = min(1.0, CGFloat(total / maxDuration))
    progressLayer.strokeEnd = progress
    onDurationTick?(total)
    if total >= maxDuration {
      stopRecording(send: true)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Full-screen blur (original placement).
    backdropBlur.frame = view.bounds
    backdropTint.frame = view.bounds

    let side = min(view.bounds.width - 52, 300)
    let circleFrame = CGRect(
      x: (view.bounds.width - side) * 0.5,
      y: (view.bounds.height - side) * 0.5 - 36,
      width: side,
      height: side
    )
    circleContainer.frame = circleFrame
    circleContainer.layer.cornerRadius = side * 0.5
    circleLoadingBlur.frame = circleContainer.bounds
    circleLoadingShade.frame = circleContainer.bounds

    let path = UIBezierPath(
      arcCenter: CGPoint(x: circleFrame.midX, y: circleFrame.midY),
      radius: (side * 0.5) + 3.0,
      startAngle: -.pi / 2,
      endAngle: (-.pi / 2) + (.pi * 2),
      clockwise: true
    )
    progressLayer.path = path.cgPath

    // Flash + flip sit just above the composer, aligned with the attach control.
    let controlSize: CGFloat = 38
    let bottomPad = max(bottomChromeInset, max(view.safeAreaInsets.bottom, 8) + 52) + 2
    let controlsY = view.bounds.height - bottomPad - controlSize
    flashGlass.frame = CGRect(x: 20, y: controlsY, width: controlSize, height: controlSize)
    flipGlass.frame = CGRect(
      x: flashGlass.frame.maxX + 4, y: controlsY, width: controlSize, height: controlSize)
    flashButton.frame = flashGlass.contentView.bounds
    flipButton.frame = flipGlass.contentView.bounds
    previewLayer?.frame = circleContainer.bounds
  }

  private func styleRecorderControlGlass(_ glass: UIVisualEffectView) {
    glass.clipsToBounds = true
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      glass.effect = effect
      glass.cornerConfiguration = .capsule()
    } else {
      glass.effect = UIBlurEffect(style: .systemMaterialDark)
      glass.layer.cornerRadius = 16
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !hasAppeared else { return }
    hasAppeared = true
    // Circle already visible; only start capture if not pre-warmed.
    if !isSessionConfigured || !session.isRunning {
      beginRecordingFlow()
    } else if !hasStartedFileRecording {
      startSessionAndRecording()
    }
  }

  /// Warm camera + attach preview BEFORE presentation (attachment-menu pattern).
  /// Preview mounts under loading blur so we never flash a solid circle.
  func prepareCameraAndStart(completion: ((Bool) -> Void)? = nil) {
    ensurePreviewLayerMounted()
    beginRecordingFlow(completion: completion)
  }

  private var didPlayEntrance = false

  /// Scale + fade the circle/chrome into view. Called explicitly by the host once
  /// our view is actually installed on screen — this child controller is added to
  /// an already-visible parent (no push/present transition), so viewDidAppear is
  /// not a reliable signal here.
  func playEntranceAnimation() {
    guard !didPlayEntrance else { return }
    didPlayEntrance = true
    view.layoutIfNeeded()
    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
      self.backdropBlur.alpha = 1.0
      self.backdropTint.alpha = 1.0
    }
    UIView.animate(
      withDuration: 0.42,
      delay: 0,
      usingSpringWithDamping: 0.76,
      initialSpringVelocity: 0.35,
      options: [.curveEaseOut, .allowUserInteraction]
    ) {
      self.circleContainer.alpha = 1
      self.circleContainer.transform = .identity
    }
    UIView.animate(withDuration: 0.22, delay: 0.10, options: [.curveEaseOut]) {
      self.flashGlass.alpha = 1
      self.flipGlass.alpha = 1
    }
  }

  private func ensurePreviewLayerMounted() {
    if previewLayer == nil {
      let preview = AVCaptureVideoPreviewLayer(session: session)
      preview.videoGravity = .resizeAspectFill
      previewLayer = preview
      // Under loading blur — camera (or empty session) always sits behind the blur.
      circleContainer.layer.insertSublayer(preview, at: 0)
    } else {
      previewLayer?.session = session
    }
    previewLayer?.frame = circleContainer.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    displayLink?.invalidate()
    displayLink = nil
    if isBeingDismissed || isMovingFromParent {
      stopSession()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Only tear down when we are truly being removed — NOT on transient
    // appearance transitions. A false finish here is what "hold → note vanishes".
    guard !didFinish else { return }
    guard isMovingFromParent || isBeingDismissed || parent == nil else { return }
    // Parent still holds us as a child → not a real teardown.
    if parent != nil, !isMovingFromParent { return }
    finish(url: nil, duration: 0.0, shouldSend: false)
  }

  /// Soft-hide camera chrome while input shows the paused draft (session stays warm).
  func setCameraChromeHidden(_ hidden: Bool, animated: Bool) {
    let apply = {
      self.circleContainer.alpha = hidden ? 0 : 1
      self.flashGlass.alpha = hidden ? 0 : 1
      self.flipGlass.alpha = hidden ? 0 : 1
      self.backdropBlur.alpha = hidden ? 0 : 1
      self.backdropTint.alpha = hidden ? 0 : 1
      self.progressLayer.opacity = hidden ? 0 : 1
    }
    if animated {
      UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: apply)
    } else {
      apply()
    }
  }

  func pauseRecording() {
    guard !didFinish, !isPaused else { return }
    pauseRequested = true
    pendingSend = false
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.movieOutput.stopRecording()
      } else {
        DispatchQueue.main.async {
          self.isPaused = true
          self.onPaused?(self.recordedSegments.last, self.accumulatedDuration)
        }
      }
    }
  }

  func resumeRecording() {
    guard !didFinish, isPaused else { return }
    guard accumulatedDuration < maxDuration - 0.35 else {
      stopRecording(send: true)
      return
    }
    isPaused = false
    pauseRequested = false
    setCameraChromeHidden(false, animated: true)
    onResumed?()
    startSegmentRecording()
  }

  func stopRecording(send: Bool) {
    guard !didFinish else { return }
    pendingSend = send
    pauseRequested = false
    isPaused = false
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.movieOutput.stopRecording()
      } else if !self.recordedSegments.isEmpty {
        DispatchQueue.main.async {
          self.completeWithSegments(shouldSend: send)
        }
      } else {
        self.stopRequested = true
        guard !send else { return }
        DispatchQueue.main.async {
          self.finish(url: nil, duration: 0.0, shouldSend: false)
        }
      }
    }
  }

  private func beginRecordingFlow(completion: ((Bool) -> Void)? = nil) {
    requestCapturePermissions { [weak self] videoGranted, audioGranted in
      guard let self else {
        completion?(false)
        return
      }
      guard videoGranted else {
        completion?(false)
        if self.hasAppeared {
          self.finish(url: nil, duration: 0.0, shouldSend: false)
        }
        return
      }
      // Never sessionQueue.sync from main — AVCapture configure/startRunning
      // can block for seconds (main-thread-stall + kevent wait).
      self.configureSessionIfNeeded(includeAudio: audioGranted) { [weak self] ok in
        guard let self else {
          completion?(false)
          return
        }
        guard ok else {
          completion?(false)
          if self.hasAppeared {
            self.finish(url: nil, duration: 0.0, shouldSend: false)
          }
          return
        }
        self.startSessionAndRecording()
        completion?(true)
      }
    }
  }

  private func requestCapturePermissions(
    completion: @escaping (_ videoGranted: Bool, _ audioGranted: Bool) -> Void
  ) {
    let completeOnMain: (Bool, Bool) -> Void = { video, audio in
      DispatchQueue.main.async { completion(video, audio) }
    }

    let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    func resolveAudio(givenVideo videoGranted: Bool) {
      if audioStatus == .authorized {
        completeOnMain(videoGranted, true)
        return
      }
      if audioStatus == .notDetermined {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          completeOnMain(videoGranted, granted)
        }
        return
      }
      completeOnMain(videoGranted, false)
    }

    if videoStatus == .authorized {
      resolveAudio(givenVideo: true)
      return
    }
    if videoStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { granted in
        guard granted else {
          completeOnMain(false, false)
          return
        }
        let refreshedAudioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if refreshedAudioStatus == .authorized {
          completeOnMain(true, true)
        } else if refreshedAudioStatus == .notDetermined {
          AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
            completeOnMain(true, audioGranted)
          }
        } else {
          completeOnMain(true, false)
        }
      }
      return
    }
    completeOnMain(false, false)
  }

  private func configureSessionIfNeeded(
    includeAudio: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    sessionQueue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      if self.isSessionConfigured {
        DispatchQueue.main.async {
          self.ensurePreviewLayerMounted()
          self.applyPreviewMirroring()
          completion(true)
        }
        return
      }

      self.session.beginConfiguration()
      if self.session.canSetSessionPreset(.vga640x480) {
        self.session.sessionPreset = .vga640x480
      }

      if let videoDevice = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: self.cameraPosition)
        ?? AVCaptureDevice.default(for: .video),
        let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
        self.session.canAddInput(videoInput)
      {
        self.session.addInput(videoInput)
        self.videoDeviceInput = videoInput
        self.cameraPosition = videoDevice.position
      }

      if includeAudio,
        let audioDevice = AVCaptureDevice.default(for: .audio),
        let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
        self.session.canAddInput(audioInput)
      {
        self.session.addInput(audioInput)
      }

      if self.session.canAddOutput(self.movieOutput) {
        self.session.addOutput(self.movieOutput)
      }
      self.movieOutput.maxRecordedDuration = CMTime(
        seconds: self.maxDuration, preferredTimescale: 600)
      self.applyMovieOutputMirroring()

      self.session.commitConfiguration()
      let ok = self.videoDeviceInput != nil
      self.isSessionConfigured = ok

      DispatchQueue.main.async {
        self.ensurePreviewLayerMounted()
        self.applyPreviewMirroring()
        self.view.setNeedsLayout()
        // Loading blur stays until recording starts / first frames (no solid plate).
        completion(ok)
      }
    }
  }

  private func applyMovieOutputMirroring() {
    if let connection = movieOutput.connection(with: .video) {
      if connection.isVideoMirroringSupported {
        connection.isVideoMirrored = (cameraPosition == .front)
      }
      if connection.isVideoStabilizationSupported {
        connection.preferredVideoStabilizationMode = .auto
      }
    }
  }

  private func applyPreviewMirroring() {
    if let conn = previewLayer?.connection, conn.isVideoMirroringSupported {
      conn.automaticallyAdjustsVideoMirroring = false
      conn.isVideoMirrored = (cameraPosition == .front)
    }
  }

  private func applyVideoConnectionMirroring() {
    applyMovieOutputMirroring()
    // previewLayer is a UI layer — only touch it on main.
    if Thread.isMainThread {
      applyPreviewMirroring()
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.applyPreviewMirroring()
      }
    }
  }

  private func flipCamera() {
    sessionQueue.async { [weak self] in
      guard let self, self.isSessionConfigured else { return }
      let next: AVCaptureDevice.Position = self.cameraPosition == .front ? .back : .front
      guard
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: next),
        let newInput = try? AVCaptureDeviceInput(device: device)
      else { return }
      self.session.beginConfiguration()
      if let current = self.videoDeviceInput {
        self.session.removeInput(current)
      }
      if self.session.canAddInput(newInput) {
        self.session.addInput(newInput)
        self.videoDeviceInput = newInput
        self.cameraPosition = next
      } else if let current = self.videoDeviceInput {
        self.session.addInput(current)
      }
      self.applyVideoConnectionMirroring()
      self.session.commitConfiguration()
      DispatchQueue.main.async {
        // Torch only on rear camera; keep flash control near input always visible.
        let rear = self.cameraPosition == .back
        self.flashButton.isEnabled = rear
        self.flashGlass.alpha = rear ? 1 : 0.4
      }
    }
  }

  private func startSessionAndRecording() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      guard self.isSessionConfigured, !self.didFinish else { return }
      guard !self.hasScheduledInitialRecording else { return }
      self.hasScheduledInitialRecording = true
      if !self.session.isRunning {
        self.session.startRunning()
      }
      if self.stopRequested && !self.pendingSend {
        DispatchQueue.main.async {
          self.finish(url: nil, duration: 0.0, shouldSend: false)
        }
        return
      }
      let beginSegment: () -> Void = { [weak self] in
        guard let self else { return }
        DispatchQueue.main.async {
          if self.startedAt == nil { self.startedAt = Date() }
          self.displayLink?.invalidate()
          self.displayLink = CADisplayLink(target: self, selector: #selector(self.updateProgress))
          self.displayLink?.add(to: .main, forMode: .common)
        }
        self.startSegmentRecordingLocked()
      }
      self.waitUntilCaptureSettled(then: beginSegment)
    }
  }

  private func waitUntilCaptureSettled(then work: @escaping () -> Void) {
    let started = Date()
    let minHold: TimeInterval = 0.45
    let timeout: TimeInterval = 1.25
    func poll() {
      let device = videoDeviceInput?.device
      let adjusting =
        device?.isAdjustingExposure == true || device?.isAdjustingWhiteBalance == true
      let elapsed = Date().timeIntervalSince(started)
      if elapsed >= timeout || (!adjusting && elapsed >= minHold) {
        work()
        return
      }
      sessionQueue.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
  }

  private func startSegmentRecording() {
    sessionQueue.async { [weak self] in
      self?.startSegmentRecordingLocked()
    }
  }

  private func startSegmentRecordingLocked() {
    guard isSessionConfigured, !didFinish, !movieOutput.isRecording else { return }
    if !session.isRunning {
      session.startRunning()
    }
    let fm = FileManager.default
    let base =
      fm.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fm.temporaryDirectory
    let dir = base.appendingPathComponent("video-notes", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let outputURL =
      dir
      .appendingPathComponent("video-note-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    DispatchQueue.main.async {
      self.segmentStartedAt = Date()
      if self.startedAt == nil { self.startedAt = Date() }
      self.armRecordingStartTimeout()
    }
    movieOutput.startRecording(to: outputURL, recordingDelegate: self)
  }

  private func stopSession() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.movieOutput.stopRecording()
      }
      if self.session.isRunning {
        self.session.stopRunning()
      }
      DispatchQueue.main.async {
        self.displayLink?.invalidate()
        self.displayLink = nil
      }
    }
  }

  /// Circle frame in a target view's coordinates (for release morph flight).
  func circleFrame(in target: UIView) -> CGRect {
    circleContainer.convert(circleContainer.bounds, to: target)
  }

  /// Last-frame snapshot of the camera circle (session teardown kills the live layer).
  func captureCircleSnapshot() -> UIImage? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = UIScreen.main.scale
    format.opaque = false
    let size = circleContainer.bounds.size
    guard size.width > 1, size.height > 1 else { return nil }
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { ctx in
      circleContainer.layer.render(in: ctx.cgContext)
    }
  }

  private func finish(url: URL?, duration: Double, shouldSend: Bool) {
    guard !didFinish else { return }
    didFinish = true
    recordingStartTimeoutWorkItem?.cancel()
    recordingStartTimeoutWorkItem = nil
    displayLink?.invalidate()
    displayLink = nil

    // Capture morph geometry while the circle is still on screen.
    let morphImage = shouldSend ? captureCircleSnapshot() : nil
    let morphFrame: CGRect = {
      guard shouldSend, let host = morphCoordinateView ?? view.superview else { return .zero }
      return circleFrame(in: host)
    }()

    let callback = {
      let cb = self.onFinished
      self.onFinished = nil
      self.onPaused = nil
      self.onResumed = nil
      self.onDurationTick = nil
      cb?(url, duration, shouldSend, morphImage, morphFrame)
    }

    // Fade the overlay (not the circle). Callback first so the list flight is
    // on-screen before this view is removed — no empty-list flash.
    if shouldSend {
      UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
        self.backdropBlur.alpha = 0
        self.backdropTint.alpha = 0
        self.flashGlass.alpha = 0
        self.flipGlass.alpha = 0
        self.progressLayer.opacity = 0
      }
    }
    callback()
    if parent != nil {
      willMove(toParent: nil)
      view.removeFromSuperview()
      removeFromParent()
    } else if presentingViewController != nil {
      dismiss(animated: false)
    }
  }

  private func completeWithSegments(shouldSend: Bool) {
    let segments = recordedSegments
    let duration = accumulatedDuration
    guard shouldSend, !segments.isEmpty else {
      stopSession()
      finish(url: nil, duration: duration, shouldSend: false)
      return
    }
    if segments.count == 1 {
      stopSession()
      finish(url: segments[0], duration: duration, shouldSend: true)
      return
    }
    mergeSegments(segments) { [weak self] merged in
      guard let self else { return }
      self.stopSession()
      self.finish(url: merged ?? segments.last, duration: duration, shouldSend: true)
    }
  }

  private func mergeSegments(_ urls: [URL], completion: @escaping (URL?) -> Void) {
    let composition = AVMutableComposition()
    guard
      let videoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let audioTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      completion(urls.last)
      return
    }
    var cursor = CMTime.zero
    for url in urls {
      let asset = AVURLAsset(url: url)
      let duration = asset.duration
      let range = CMTimeRange(start: .zero, duration: duration)
      if let srcVideo = asset.tracks(withMediaType: .video).first {
        try? videoTrack.insertTimeRange(range, of: srcVideo, at: cursor)
      }
      if let srcAudio = asset.tracks(withMediaType: .audio).first {
        try? audioTrack.insertTimeRange(range, of: srcAudio, at: cursor)
      }
      cursor = CMTimeAdd(cursor, duration)
    }
    let fm = FileManager.default
    let base =
      fm.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fm.temporaryDirectory
    let out =
      base.appendingPathComponent("video-notes", isDirectory: true)
      .appendingPathComponent("video-note-merged-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
    else {
      completion(urls.last)
      return
    }
    export.outputURL = out
    export.outputFileType = .mov
    export.exportAsynchronously {
      DispatchQueue.main.async {
        completion(export.status == .completed ? out : urls.last)
      }
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    hasStartedFileRecording = true
    DispatchQueue.main.async {
      self.recordingStartTimeoutWorkItem?.cancel()
      self.recordingStartTimeoutWorkItem = nil
      self.revealCameraPreviewIfReady(animated: true)
    }
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.stopRequested || self.pauseRequested {
        self.movieOutput.stopRecording()
      }
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    DispatchQueue.main.async {
      self.recordingStartTimeoutWorkItem?.cancel()
      self.recordingStartTimeoutWorkItem = nil
    }
    let segmentElapsed = max(
      0.0, Date().timeIntervalSince(segmentStartedAt ?? startedAt ?? Date()))
    if error == nil {
      recordedSegments.append(outputFileURL)
      accumulatedDuration += segmentElapsed
    }

    // Pause path: keep session warm and overlay visible; input shows play + cancel.
    if pauseRequested {
      pauseRequested = false
      DispatchQueue.main.async {
        self.isPaused = true
        self.segmentStartedAt = nil
        self.onPaused?(self.recordedSegments.last, self.accumulatedDuration)
      }
      return
    }

    let shouldSend = pendingSend && error == nil
    if shouldSend || !recordedSegments.isEmpty {
      DispatchQueue.main.async {
        self.completeWithSegments(shouldSend: shouldSend)
      }
    } else {
      stopSession()
      DispatchQueue.main.async {
        self.finish(url: nil, duration: self.accumulatedDuration, shouldSend: false)
      }
    }
  }

  private func armRecordingStartTimeout() {
    recordingStartTimeoutWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      guard !self.didFinish, !self.hasStartedFileRecording else { return }
      self.pendingSend = false
      self.stopRequested = true
      self.finish(url: nil, duration: 0.0, shouldSend: false)
    }
    recordingStartTimeoutWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: item)
  }

  private func revealCameraPreviewIfReady(animated: Bool) {
    // Drop the attachment-style loading blur once the camera is actually producing.
    let animations = {
      self.circleLoadingBlur.alpha = 0.0
      self.circleLoadingShade.alpha = 0.0
    }
    if animated {
      UIView.animate(
        withDuration: 0.28,
        delay: 0.02,
        options: [.curveEaseOut, .beginFromCurrentState],
        animations: animations
      )
    } else {
      animations()
    }
  }
}

// MARK: - Video note notifications

extension Notification.Name {
  /// Posted when a video note is released for send, carrying a circle snapshot + frame
  /// for the list-hosted release morph (see ChatListView).
  static let videoNoteReleaseMorph = Notification.Name("vibe.videoNoteReleaseMorph")
}

// MARK: - ChatInputBar

private func chatGifStickerGlyphImage(size: CGSize) -> UIImage {
  let format = UIGraphicsImageRendererFormat()
  format.opaque = false
  format.scale = UIScreen.main.scale
  let renderer = UIGraphicsImageRenderer(size: size, format: format)

  let image = renderer.image { _ in
    UIColor.black.setStroke()

    let scale = min(size.width, size.height) / 24.0
    let offsetX = (size.width - (24.0 * scale)) / 2.0
    let offsetY = (size.height - (24.0 * scale)) / 2.0
    let pt: (CGFloat, CGFloat) -> CGPoint = { x, y in
      CGPoint(x: offsetX + (x * scale), y: offsetY + (y * scale))
    }

    // Outer 270deg arc: M21.2 12 A9.2 9.2 0 1 1 12 2.8
    let outer = UIBezierPath()
    outer.move(to: pt(21.2, 12.0))
    let steps = 42
    for i in 1...steps {
      let t = CGFloat(i) / CGFloat(steps)
      let angle = t * (1.5 * CGFloat.pi)  // 0 -> 270deg
      let x = 12.0 + (9.2 * cos(angle))
      let y = 12.0 + (9.2 * sin(angle))
      outer.addLine(to: pt(x, y))
    }
    outer.lineWidth = 1.8 * scale
    outer.lineCapStyle = .round
    outer.lineJoinStyle = .round
    outer.stroke()

    // M12 2.8 c0 4.5 4.5 9.2 9.2 9.2
    let foldA = UIBezierPath()
    foldA.move(to: pt(12.0, 2.8))
    foldA.addCurve(
      to: pt(21.2, 12.0),
      controlPoint1: pt(12.0, 7.3),
      controlPoint2: pt(16.5, 12.0)
    )
    foldA.lineWidth = 1.8 * scale
    foldA.lineCapStyle = .round
    foldA.lineJoinStyle = .round
    foldA.stroke()

    // M12 2.8 c4.5 0 9.2 4.5 9.2 9.2
    let foldB = UIBezierPath()
    foldB.move(to: pt(12.0, 2.8))
    foldB.addCurve(
      to: pt(21.2, 12.0),
      controlPoint1: pt(16.5, 2.8),
      controlPoint2: pt(21.2, 7.3)
    )
    foldB.lineWidth = 1.8 * scale
    foldB.lineCapStyle = .round
    foldB.lineJoinStyle = .round
    foldB.stroke()
  }

  return image.withRenderingMode(.alwaysTemplate)
}

/// Video-note mark: inner circle + open rounded frame, from the 24pt SVG viewBox.
private func chatVideoNoteGlyphImage(size: CGSize) -> UIImage {
  let format = UIGraphicsImageRendererFormat()
  format.opaque = false
  format.scale = UIScreen.main.scale
  let renderer = UIGraphicsImageRenderer(size: size, format: format)
  let image = renderer.image { _ in
    let scale = min(size.width, size.height) / 24.0
    let origin = CGPoint(
      x: (size.width - 24.0 * scale) / 2.0,
      y: (size.height - 24.0 * scale) / 2.0)
    let p: (CGFloat, CGFloat) -> CGPoint = { x, y in
      CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
    UIColor.black.setStroke()
    let frame = UIBezierPath()
    frame.move(to: p(22, 12))
    frame.addCurve(to: p(20.5355, 20.5355), controlPoint1: p(22, 16.714), controlPoint2: p(22, 19.0711))
    frame.addCurve(to: p(12, 22), controlPoint1: p(19.0711, 22), controlPoint2: p(16.714, 22))
    frame.addCurve(to: p(3.46447, 20.5355), controlPoint1: p(7.28595, 22), controlPoint2: p(4.92893, 22))
    frame.addCurve(to: p(2, 12), controlPoint1: p(2, 19.0711), controlPoint2: p(2, 16.714))
    frame.addCurve(to: p(3.46447, 3.46447), controlPoint1: p(2, 7.28595), controlPoint2: p(2, 4.92893))
    frame.addCurve(to: p(12, 2), controlPoint1: p(4.92893, 2), controlPoint2: p(7.28595, 2))
    frame.addCurve(to: p(20.5355, 3.46447), controlPoint1: p(16.714, 2), controlPoint2: p(19.0711, 2))
    frame.addCurve(to: p(21.9449, 8), controlPoint1: p(21.5093, 4.43821), controlPoint2: p(21.8356, 5.80655))
    frame.lineWidth = 1.5 * scale
    frame.lineCapStyle = .round
    frame.lineJoinStyle = .round
    frame.stroke()
    let dot = UIBezierPath(
      ovalIn: CGRect(
        x: origin.x + (12 - 4) * scale,
        y: origin.y + (12 - 4) * scale,
        width: 8 * scale,
        height: 8 * scale))
    dot.lineWidth = 1.5 * scale
    dot.stroke()
  }
  return image.withRenderingMode(.alwaysTemplate)
}

final class ChatInputBar: UIView {

  weak var delegate: ChatInputBarDelegate?

  // MARK: Subviews — layered bottom-to-top:
  // No full-bar glass. Each interactive element has its own glass surface:
  //   attachBtn (glass pill) | pill (glass) | micBtn (glass pill)

  private let contentRow = UIView()  // holds all interactive elements

  private let attachButton = UIButton(type: .system)
  private let attachGlass = UIVisualEffectView(effect: nil)

  private let pillContainer = UIView()
  // Pure layout shell for the composer. This must not be a UIControl: UIKit
  // collapses an editable descendant of a UIButton in the accessibility tree.
  private let pillButton = UIView()
  private let pillGlass = UIVisualEffectView(effect: nil)
  private let textView = ChatComposerTextView()
  private let placeholderLabel = UILabel()
  private let inlineAttachButton = UIButton(type: .system)
  // Slash-command button (agent chats only): a "/" glyph at the pill's leading edge
  // that opens the provider's slash-command menu. Hidden unless a menu is supplied.
  private let slashButton = UIButton(type: .system)
  private var slashCommandMenu: UIMenu?
  private let gifButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private let sendGradient = CAGradientLayer()

  private let micButton = UIButton(type: .system)
  private let micGlass = UIVisualEffectView(effect: nil)
  private let micVADView = FluidVADVisualizer()

  // Selection UI
  private var isSelectionMode = false
  private let selectionDeleteButton = UIButton(type: .system)
  private let selectionDeleteGlass = UIVisualEffectView(effect: nil)
  private let selectionShareOutsideButton = UIButton(type: .system)
  private let selectionShareOutsideGlass = UIVisualEffectView(effect: nil)
  private let selectionShareInsideButton = UIButton(type: .system)
  private let selectionShareInsideGlass = UIVisualEffectView(effect: nil)
  /// Built only when the user opens the GIF panel. Eager creation stalled chat open
  /// (~3s on main) via Auto Layout thrash at zero height.
  private var gifPanelIfLoaded: ChatGifPanelView?
  private weak var gifPanelHostController: UIViewController?
  private var gifPanelVisible = false
  /// Open was requested while a keyboard still owned the slot; present when height hits 0.
  private var pendingGifPanelOpen = false
  private var lastGifPanelGeometrySignature: String?
  /// Only ever used before this device has measured a real keyboard even once. Every
  /// other path goes through ``matchedKeyboardPanelHeight()``.
  private let defaultGifPanelHeight: CGFloat = 336
  private var lastKnownKeyboardHeight: CGFloat = 0 {
    didSet {
      guard lastKnownKeyboardHeight > 0, lastKnownKeyboardHeight != oldValue else { return }
      Self.persistedKeyboardHeight = lastKnownKeyboardHeight
    }
  }
  /// The last keyboard height this device measured, surviving relaunch. The very first
  /// GIF-panel open of a launch happens before any keyboard has appeared, and without a
  /// remembered number that open is the one that gets the wrong height.
  private static var persistedKeyboardHeight: CGFloat {
    get { CGFloat(UserDefaults.standard.double(forKey: "vibe.inputbar.keyboardHeight")) }
    set { UserDefaults.standard.set(Double(newValue), forKey: "vibe.inputbar.keyboardHeight") }
  }
  /// True while a show/hide transition owns `panel.frame`. Layout runs on every pass and
  /// would otherwise reassign the frame from mid-animation input-bar bounds, fighting the
  /// transition — which is what the old `alpha >= 0.99` guard was working around.
  private var gifPanelTransitionInFlight = false
  private var isVideoMode: Bool = false
  // Width progress for right action morph: 0 = mic, 1 = send.
  private var sendProgress: CGFloat = 0
  private var isAgentStreaming = false
  private var agentControlMode = false
  private var agentControlTitle = "Open"
  // Bridge-agent (Claude/Codex) input control: the leading chip shows the selected
  // repository and opens a menu (Repository / Report / Permission / History). The host
  // builds the menu (it owns the repo list + presenters) and pushes it down here.
  private var agentControlMenu: UIMenu?
  private var agentControlRepoTitle = ""
  // Recording layout morph progress: 0 = regular, 1 = expanded left.
  private var recordingExpandProgress: CGFloat = 0

  // Reply banner (inside the pill, above text row)
  private let replyBanner = UIView()
  /// 3pt theme-tint rail, filled with the outgoing bubble plate color.
  private let replyAccentBar = UIView()
  private var replyChipAccent: UIColor = ChatListAppearance.brandAccentFallback
  private let replySenderLabel = UILabel()
  private let replyPreviewLabel = UILabel()
  private let replyDismissButton = UIButton(type: .system)
  private var replyBannerVisible = false
  private var replyBannerAnimatingOut = false
  private let replyBannerContentH: CGFloat = 36
  private let replyBannerGap: CGFloat = 4
  /// When the composer contains a SoundCloud/YouTube URL (and we are not already
  /// replying/editing), the same reply-banner chrome shows the music OG title/artist
  /// and we prefetch the cover so send-morph paints a full card at fixed height.
  private var draftMusicURL: URL?
  private var draftMusicBannerActive = false
  private var draftMusicPrefetchGeneration = 0

  // Bridge pending-queue strip (above composer pill): preview + Steer + close.
  // Lives inside the input bar — not a floating overlay over the chat list.
  struct PendingQueueItem {
    let messageId: String
    let text: String
  }
  private let pendingQueueStrip = UIView()
  private let pendingQueueStack = UIStackView()
  private var pendingQueueItems: [PendingQueueItem] = []
  private var pendingQueueStripVisible = false
  private let pendingQueueRowH: CGFloat = 40
  private let pendingQueueHeaderH: CGFloat = 18
  private let pendingQueueGap: CGFloat = 6
  var onPendingQueueCancel: ((String) -> Void)?
  var onPendingQueueSteer: ((String) -> Void)?

  // Recording UI
  private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))
  private let lockPill = UIVisualEffectView(effect: nil)
  private let lockHintHost = UIView()
  private let lockArrowView = UIImageView(image: UIImage(systemName: "chevron.up"))
  private let slideToCancelLabel = UILabel()
  private let slideChevronView = UIImageView(image: UIImage(systemName: "chevron.left"))
  private let recordingTimerLabel = UILabel()
  private let recordingDot = UIView()
  private var recordingStartTime: Date?
  private var recordingTimer: Timer?
  private var vadTimer: Timer?
  private var recordingGestureStartPoint: CGPoint = .zero
  /// Last raw touch location seen by `.changed` — used to detect coordinate-space
  /// glitches (see handleMicGesture) rather than trusting cumulative deltas blindly.
  private var recordingGestureLastPoint: CGPoint = .zero
  private var audioRecorder: AVAudioRecorder?
  private var recordingFileURL: URL?
  private var recordingWaveformSamples: [CGFloat] = []

  // Agent (Claude/Codex) DMs never send a voice message — the mic live-transcribes
  // into the composer text instead (the agent consumes text, not audio).
  private let dictationRecognizer = SFSpeechRecognizer(locale: Locale.current)
  private let dictationAudioEngine = AVAudioEngine()
  private var dictationRequest: SFSpeechAudioBufferRecognitionRequest?
  private var dictationTask: SFSpeechRecognitionTask?
  private var isDictating = false
  private var dictationBaseText = ""

  private let cancelOverlayButton = UIButton(type: .custom)

  // Attachment sheet
  private var attachmentSheet: ChatAttachmentMenuController?

  // Staged image attachments for Claude/Codex
  var provider: String? {
    didSet {
      updatePlusButtonMenu()
    }
  }
  private var pendingImages: [UIImage] = []
  private var pendingAttachmentBlobs: [String] = []
  /// Local file:// URIs written at stage time (send prefers these over re-materializing blobs).
  private var pendingImageLocalURIs: [String] = []

  // Attachment Preview Scroll View (inside pill, above text row)
  private let attachmentPreviewScroll = UIScrollView()
  private let attachmentPreviewContainer = UIStackView()
  private var attachmentPreviewVisible = false
  private let attachmentPreviewContentH: CGFloat = 50
  private let attachmentPreviewGap: CGFloat = 4

  // Slash commands horizontal suggestion list (inside pill, above text row)
  private let slashSuggestionScroll = UIScrollView()
  private let slashSuggestionContainer = UIStackView()
  private var slashSuggestionVisible = false
  private let slashSuggestionContentH: CGFloat = 36
  private let slashSuggestionGap: CGFloat = 4

  struct SlashCommandInfo {
    let name: String
    let description: String
  }
  private static let defaultSlashCommands: [SlashCommandInfo] = [
    .init(name: "/usage", description: "Subscription limits + this chat's tokens"),
    .init(name: "/status", description: "Account, model, and remaining usage"),
    .init(name: "/commands", description: "List every available command"),
    .init(name: "/skills", description: "Skills, agents, MCP servers, and tools"),
    .init(name: "/doctor", description: "Run the CLI health check"),
    .init(name: "/compact", description: "Summarize this conversation to free context"),
    .init(name: "/model", description: "Show or set the model for this chat"),
    .init(name: "/plan", description: "Plan only — analyze without editing"),
    .init(name: "/reasoning", description: "Thinking / speed for this chat"),
    .init(name: "/code-review", description: "Review the diff for bugs and cleanups"),
    .init(name: "/simplify", description: "Cleanup-only review; apply fixes"),
    .init(name: "/security-review", description: "Scan changes for security issues"),
    .init(name: "/review", description: "Review a GitHub pull request"),
    .init(name: "/batch", description: "Split a large change into parallel units"),
    .init(name: "/deep-research", description: "Web research into a cited report"),
    .init(name: "/debug", description: "Troubleshoot via the debug log"),
    .init(name: "/run", description: "Launch and drive your app"),
    .init(name: "/verify", description: "Build, run, and observe a change"),
    .init(name: "/loop", description: "Run a prompt repeatedly"),
    .init(name: "/schedule", description: "Create or run a cloud routine"),
    .init(name: "/goal", description: "Keep working until a goal is met")
  ]

  // Background Mask (for fade-out blur behind input)
  private let backgroundMaskView = UIView()
  private let backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let backgroundOverlayView = UIView()
  private let backgroundGradientLayer = CAGradientLayer()
  private let gapDebugBarOverlay = UIView()
  private let gapDebugSafeInsetBand = UIView()
  private let gapDebugLabel = UILabel()

  // Appearance
  private var appearance = ChatListAppearance.current
  var attachRecipientName: String = ""
  private var pillTint: UIColor? = ChatListAppearance.current.bubbleThemColor.withAlphaComponent(
    0.14)

  // MARK: Layout constants
  private let sideSize: CGFloat = 36
  private let sideGap: CGFloat = 6
  /// Air above the pill and how far the pill sits off the home indicator. They trade
  /// against each other so the bar's resting height — the transcript's clearance — holds.
  private let topVPad: CGFloat = 8
  private let bottomVPad: CGFloat = 5
  private let composerSafeBottomReduction: CGFloat = 12
  private let backgroundMaskTopOverlap: CGFloat = 0
  private let minPillH: CGFloat = 40
  private let maxPillH: CGFloat = 120
  private let textInsetH: CGFloat = 12
  private let textInsetV: CGFloat = 6

  // MARK: Public state
  var keyboardProgress: CGFloat = 0 {
    didSet { if abs(oldValue - keyboardProgress) > 0.01 { setNeedsLayout() } }
  }
  /// Duration and curve from the last keyboard notification. The panel animates with
  /// these, not a constant — two surfaces sharing one slot on different curves wobble.
  var keyboardAnimation: (duration: TimeInterval, options: UIView.AnimationOptions) = (
    0.25, UIView.AnimationOptions(rawValue: 7 << 16)
  )

  var keyboardHeightForPanels: CGFloat = 0 {
    didSet {
      if keyboardHeightForPanels > 0 {
        lastKnownKeyboardHeight = keyboardHeightForPanels
      }
      // Either notification settles the question of who owns the slot.
      keyboardArrivalPending = false
      // Deferred GIF open: only present after the keyboard fully yields the slot.
      if pendingGifPanelOpen, keyboardHeightForPanels <= 0 {
        pendingGifPanelOpen = false
        setGifPanelVisible(true, animated: true)
      }
      // The panel's search lift is measured from this height, and it arrives a notification
      // AFTER the field takes focus — without this the panel lifts by zero and the keys cover it.
      if gifPanelVisible, isGifPanelSearchActive, abs(oldValue - keyboardHeightForPanels) > 0.5 {
        setNeedsLayout()
        delegate?.inputBarHeightDidChange()
      }
    }
  }

  /// True between the composer taking focus and the keyboard reporting a height.
  private var keyboardArrivalPending = false
  var activeReplyToMessageId: String?
  // When set, the composer is editing this already-sent message instead of composing a
  // new one; the banner UI is shared with reply.
  var activeEditMessageId: String?
  /// True while a pending forward draft owns the reply-banner chrome.
  private(set) var activeForwardDraft = false

  // Mention suggestion banner (inside pill, above text row — like reply banner)
  private let mentionBanner = UIView()
  private let mentionAccentBar = UIView()
  private let mentionNameLabel = UILabel()
  private let mentionDescLabel = UILabel()
  private var mentionBannerVisible = false
  private let mentionBannerContentH: CGFloat = 36
  private let mentionBannerGap: CGFloat = 4
  private var mentionActive = false  // true when @vibe is confirmed in text
  private let mentionBorderGlowLayer = CALayer()
  private var readyBannerAction: ReadyBannerAction = .none

  private(set) var barHeight: CGFloat = 0

  /// Whether the composer is what the keyboard is up for.
  ///
  /// Ground truth for the list's keyboard geometry: `keyboardHeight` there is written only
  /// by notifications and so is a remembered value, which survives a chat close that the
  /// hide notification never reached.
  var isComposerFirstResponder: Bool { textView.isFirstResponder }

  var bottomSafeAreaInset: CGFloat = 0 {
    didSet { if abs(oldValue - bottomSafeAreaInset) > 0.5 { setNeedsLayout() } }
  }
  var placeholder: String = "Message" {
    didSet { placeholderLabel.text = placeholder }
  }
  var currentText: String {
    textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  var isGifPanelPresented: Bool { gifPanelVisible }
  var isGifPanelPresentationPending: Bool { pendingGifPanelOpen }
  var reservedGifPanelHeight: CGFloat {
    gifPanelVisible || pendingGifPanelOpen ? preferredGifPanelHeight() : 0
  }
  /// True while the GIF panel's OWN search field is first responder (host lifts the whole
  /// bar). Never keyed on "a keyboard is up" — that made a composer keyboard lift the panel
  /// with it and leave it stranded above the keys instead of dismissing it.
  var isGifPanelSearchActive: Bool {
    gifPanelVisible && gifPanelIfLoaded?.isSearchExpanded == true
  }
  /// Whether the keyboard or the panel owns the slot below the composer — including the
  /// handoff between them, so the composer keeps one resting height across a swap.
  var bottomSlotOccupied: Bool {
    gifPanelVisible || pendingGifPanelOpen || keyboardHeightForPanels > 0
      || keyboardProgress > 0.01 || keyboardArrivalPending
  }
  /// Height to hold the bar at while a keyboard is on its way but has not reported yet.
  /// Without it the bar falls to the bottom for the frames between focus and the first
  /// keyboard notification, then jumps back up — the dip on every panel→keyboard swap.
  var reservedKeyboardHeight: CGFloat {
    keyboardArrivalPending ? matchedKeyboardPanelHeight() : 0
  }
  var presentedBottomAccessoryHeight: CGFloat { gifPanelVisible ? preferredGifPanelHeight() : 0 }

  // Recording state
  private enum RecordingMode {
    case none
    case voice
    case video
  }

  private var isRecording = false
  private var isLocked = false
  private var recordingMode: RecordingMode = .none
  private var isVideoRecordingActive = false
  private var isVideoNotePaused = false
  private var pendingVideoStopShouldSend = true
  private var suppressNextMicTap = false
  private var isCancelZoneActive = false
  private var videoNoteDraftDuration: Double = 0
  private var videoNoteDraftThumb: UIImage?

  private var lastMeasuredTextHeight: CGFloat = -1

  private weak var videoNoteRecorderController: VideoNoteRecorderViewController?
  /// Pause control shown in the pill while a video note is actively recording (locked).
  private let videoNotePauseButton = UIButton(type: .system)
  /// Small circular preview of the paused draft inside the input pill.
  private let videoNoteDraftThumbView = UIImageView()
  private let feedback = UIImpactFeedbackGenerator(style: .medium)
  private let notificationFeedback = UINotificationFeedbackGenerator()

  private func recordingModeString(_ mode: RecordingMode? = nil) -> String {
    switch mode ?? recordingMode {
    case .voice: return "voice"
    case .video: return "video"
    case .none: return "voice"
    }
  }

  /// Enter edit mode for an already-sent message: shared banner UI with reply, the
  /// composer prefilled with the current text so the user tweaks and re-sends.
  func showEditBanner(messageId: String, text: String) {
    showReplyBanner(messageId: messageId, text: text.isEmpty ? "Add a description" : text, isMe: true)
    activeReplyToMessageId = nil
    activeEditMessageId = messageId
    replySenderLabel.text = "Editing"
    textView.text = text
    textViewDidChange(textView)
  }

  func showReplyBanner(
    messageId: String,
    text: String,
    isMe: Bool,
    senderName: String? = nil
  ) {
    replyBanner.layer.removeAllAnimations()
    restorePillGlassVisualState()
    // Real reply owns the banner chrome — drop any draft music preview state.
    draftMusicBannerActive = false
    draftMusicURL = nil
    activeForwardDraft = false
    activeEditMessageId = nil
    activeReplyToMessageId = messageId
    let name = senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if isMe {
      replySenderLabel.text = "Reply to you"
    } else if !name.isEmpty {
      replySenderLabel.text = "Reply to \(name)"
    } else {
      replySenderLabel.text = "Reply"
    }
    replyPreviewLabel.text = text
    prepareReplyChipEntrance()
    replyBannerAnimatingOut = false
    replyBannerVisible = true
    replyBanner.isHidden = false
    replyBanner.alpha = 1

    if gifPanelVisible {
      setGifPanelVisible(false, animated: true)
    }

    UIView.animate(
      withDuration: 0.34, delay: 0,
      usingSpringWithDamping: 0.92, initialSpringVelocity: 0.28,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.window != nil, !self.textView.isFirstResponder else { return }
      self.textView.becomeFirstResponder()
    }
  }

  /// Group/channel forward draft: same chrome as reply, titled "Forward Message".
  func showForwardBanner(title: String, preview: String) {
    replyBanner.layer.removeAllAnimations()
    restorePillGlassVisualState()
    draftMusicBannerActive = false
    draftMusicURL = nil
    activeEditMessageId = nil
    activeReplyToMessageId = nil
    activeForwardDraft = true
    replySenderLabel.text = title
    replyPreviewLabel.text = preview
    prepareReplyChipEntrance()
    replyBannerAnimatingOut = false
    replyBannerVisible = true
    replyBanner.isHidden = false
    replyBanner.alpha = 1

    if gifPanelVisible {
      setGifPanelVisible(false, animated: true)
    }

    UIView.animate(
      withDuration: 0.25, delay: 0,
      usingSpringWithDamping: 0.82, initialSpringVelocity: 0.5,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.window != nil, !self.textView.isFirstResponder else { return }
      self.textView.becomeFirstResponder()
    }
  }

  func dismissReplyBanner(animated: Bool) {
    guard activeReplyToMessageId != nil || activeEditMessageId != nil || activeForwardDraft
      || replyBannerVisible
    else { return }
    replyBanner.layer.removeAllAnimations()
    activeReplyToMessageId = nil
    activeEditMessageId = nil
    activeForwardDraft = false
    replyBannerVisible = false
    replyBannerAnimatingOut = false

    let applyLayout = {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    if animated {
      restorePillGlassVisualState()
      replyBannerAnimatingOut = true
      replyBanner.alpha = 1
      replyBanner.transform = .identity
      replyBanner.isHidden = false
      UIView.animate(
        withDuration: 0.14, delay: 0,
        options: [.curveEaseIn, .beginFromCurrentState]
      ) {
        // Sinks back into the pill it rose from — the chip belongs to the composer, so it
        // leaves the way it arrived rather than blinking out.
        self.replyBanner.alpha = 0
        self.replyBanner.transform = CGAffineTransform(translationX: 0, y: 8)
          .scaledBy(x: 0.97, y: 0.97)
      }
      UIView.animate(
        withDuration: 0.18, delay: 0,
        options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        applyLayout()
      } completion: { _ in
        if !self.replyBannerVisible {
          self.replyBannerAnimatingOut = false
          self.replyBanner.transform = .identity
          self.replyBanner.alpha = 0
          self.replyBanner.isHidden = true
          self.restorePillGlassVisualState()
        }
      }
    } else {
      replyBannerAnimatingOut = false
      replyBanner.transform = .identity
      replyBanner.alpha = 0
      replyBanner.isHidden = true
      UIView.performWithoutAnimation {
        applyLayout()
      }
      restorePillGlassVisualState()
    }
  }

  private func restorePillGlassVisualState() {
    pillGlass.isHidden = false
    pillGlass.alpha = 1
    pillGlass.transform = .identity

    pillButton.isHidden = false
    pillButton.alpha = 1
    pillButton.transform = .identity

    pillContainer.isHidden = false
    pillContainer.alpha = 1
    pillContainer.backgroundColor = .clear
    pillContainer.transform = .identity

    refreshGlass()
  }

  @objc private func replyDismissTapped() {
    if draftMusicBannerActive {
      // Closing a draft music preview does not clear the URL text — only the banner.
      dismissDraftMusicBanner(animated: true)
      return
    }
    if activeForwardDraft {
      // Confirm cancel vs continue for group/channel forward drafts.
      presentForwardCancelConfirmation()
      return
    }
    // Canceling an edit also discards the old message text sitting in the composer.
    let wasEditing = activeEditMessageId != nil
    dismissReplyBanner(animated: true)
    if wasEditing { clearText() }
    delegate?.inputBarReplyDismissed()
  }

  private func presentForwardCancelConfirmation() {
    guard let host = window?.rootViewController ?? findViewController() else {
      dismissReplyBanner(animated: true)
      clearText()
      delegate?.inputBarDidCancelForward()
      return
    }
    var top = host
    while let presented = top.presentedViewController { top = presented }
    let sheet = UIAlertController(
      title: "Cancel forwarding?",
      message: "You can leave this chat and keep forwarding, or cancel.",
      preferredStyle: .actionSheet
    )
    sheet.addAction(
      UIAlertAction(title: "Cancel Forwarding", style: .destructive) { [weak self] _ in
        guard let self else { return }
        self.dismissReplyBanner(animated: true)
        self.clearText()
        self.delegate?.inputBarDidCancelForward()
      })
    sheet.addAction(UIAlertAction(title: "Continue Forwarding", style: .cancel))
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = replyDismissButton
      pop.sourceRect = replyDismissButton.bounds
    }
    top.present(sheet, animated: true)
  }

  // MARK: - Draft music URL preview (composer)

  /// Detect the first SoundCloud/YouTube URL in the composer and show a reply-style
  /// preview banner + warm the cover cache for send morph.
  private func updateDraftMusicPreview(from text: String) {
    // Real reply / edit banners own the chrome — do not steal it for a draft URL.
    if activeReplyToMessageId != nil || activeEditMessageId != nil {
      if draftMusicBannerActive {
        draftMusicBannerActive = false
        draftMusicURL = nil
      }
      return
    }

    guard let url = firstMusicURL(in: text) else {
      if draftMusicBannerActive {
        dismissDraftMusicBanner(animated: true)
      }
      return
    }

    if draftMusicURL?.absoluteString == url.absoluteString, draftMusicBannerActive {
      return
    }

    draftMusicURL = url
    draftMusicPrefetchGeneration &+= 1
    let generation = draftMusicPrefetchGeneration
    showDraftMusicBanner(
      title: bubbleMusicPreviewFallbackSite(for: url),
      subtitle: "Loading preview…",
      animated: !draftMusicBannerActive
    )

    chatPrefetchMusicURLPreview(url: url) { [weak self] site, title, desc, _ in
      guard let self else { return }
      guard self.draftMusicPrefetchGeneration == generation,
        self.draftMusicURL?.absoluteString == url.absoluteString
      else { return }
      let trackTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      let artist = desc?.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayTitle = trackTitle.isEmpty ? site : trackTitle
      let displaySubtitle: String = {
        if let artist, !artist.isEmpty { return artist }
        return site
      }()
      self.showDraftMusicBanner(
        title: displayTitle,
        subtitle: displaySubtitle,
        animated: false
      )
    }
  }

  private func showDraftMusicBanner(title: String, subtitle: String, animated: Bool) {
    replyBanner.layer.removeAllAnimations()
    restorePillGlassVisualState()
    draftMusicBannerActive = true
    replyBannerVisible = true
    replyBanner.isHidden = false
    replyBanner.alpha = 1
    prepareReplyChipEntrance()
    replyBannerAnimatingOut = false
    replySenderLabel.text = title
    replyPreviewLabel.text = subtitle
    replyAccentBar.backgroundColor = replyChipAccent

    let apply = {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
    if animated {
      UIView.animate(
        withDuration: 0.22, delay: 0,
        usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        apply()
      }
    } else {
      apply()
    }
  }

  private func dismissDraftMusicBanner(animated: Bool) {
    guard draftMusicBannerActive || draftMusicURL != nil else { return }
    draftMusicBannerActive = false
    draftMusicURL = nil
    // Reuse the standard reply-banner dismiss when no real reply is active.
    if activeReplyToMessageId == nil && activeEditMessageId == nil {
      dismissReplyBanner(animated: animated)
    }
  }

  private func firstMusicURL(in text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard
      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return nil }
    let range = NSRange(trimmed.startIndex..., in: trimmed)
    for match in detector.matches(in: trimmed, options: [], range: range) {
      guard let url = match.url else { continue }
      if bubbleIsMusicPreviewURL(url) { return url }
    }
    return nil
  }

  /// The chip RISES out of the pill rather than appearing in place — the same vocabulary
  /// as the send morph, where things travel between the composer and the list instead of
  /// blinking. Self-contained so every entry point (reply, edit, forward, music draft)
  /// gets it without threading the animation through their own layout springs.
  private func prepareReplyChipEntrance() {
    replyBanner.transform = CGAffineTransform(translationX: 0, y: 5)
      .scaledBy(x: 0.995, y: 0.995)
    UIView.animate(
      withDuration: 0.34, delay: 0.0,
      usingSpringWithDamping: 0.92, initialSpringVelocity: 0.28,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.replyBanner.transform = .identity
    }
  }

  private func layoutReplyBannerContents() {
    let b = replyBanner.bounds
    guard b.width > 0, b.height > 0 else { return }
    let pad: CGFloat = 10
    let railW: CGFloat = 3
    let dismissSize: CGFloat = 26
    let railH = max(18, b.height - 16)
    replyAccentBar.frame = CGRect(
      x: pad, y: (b.height - railH) / 2, width: railW, height: railH)
    replyAccentBar.layer.cornerRadius = railW / 2
    replyAccentBar.backgroundColor = replyChipAccent

    let textX = replyAccentBar.frame.maxX + 10
    let textW = max(1, b.width - textX - dismissSize - pad - 6)
    let textBlockH: CGFloat = 29
    let textTop = (b.height - textBlockH) / 2
    replySenderLabel.frame = CGRect(x: textX, y: textTop, width: textW, height: 14)
    replyPreviewLabel.frame = CGRect(
      x: textX, y: replySenderLabel.frame.maxY + 1, width: textW, height: 14)
    replyDismissButton.frame = CGRect(
      x: b.width - dismissSize - pad,
      y: (b.height - dismissSize) / 2,
      width: dismissSize, height: dismissSize
    )
  }

  // MARK: Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    setupViews()
  }
  required init?(coder: NSCoder) { nil }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      // The panel lives in its own window ABOVE the app's, so leaving the chat does not
      // take it with you — it stayed floating over Home until something else knocked it
      // down. It belongs to this composer and to nothing else, so it goes when the
      // composer goes, the way the keyboard does: immediately, with no animation to
      // outlive the screen it belonged to.
      if gifPanelVisible || pendingGifPanelOpen {
        gifPanelVisible = false
        pendingGifPanelOpen = false
        gifButton.tintColor = gifGlyphTint(active: false)
      }
      tearDownGifPanelHostIfNeeded()
      gifPanelIfLoaded?.hostViewController = nil
      return
    }
    // Only warm the panel if it was already created (user opened GIF before).
    if gifPanelIfLoaded != nil {
      maybePrepareGifPanel()
    }
  }

  // MARK: - Setup

  private func setupViews() {
    // ── 0. Background Masked Blur ─────────────────────────────────────────
    backgroundMaskView.isUserInteractionEnabled = false
    addSubview(backgroundMaskView)

    backgroundMaskView.addSubview(backgroundBlurView)
    backgroundBlurView.contentView.addSubview(backgroundOverlayView)

    backgroundGradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.92).cgColor,
    ]
    backgroundGradientLayer.locations = [0.1, 1.0]
    backgroundMaskView.layer.mask = backgroundGradientLayer

    if chatGapDebugOverlayEnabled {
      gapDebugBarOverlay.isUserInteractionEnabled = false
      gapDebugBarOverlay.backgroundColor = UIColor.orange.withAlphaComponent(0.18)
      gapDebugBarOverlay.layer.borderColor = UIColor.orange.withAlphaComponent(0.95).cgColor
      gapDebugBarOverlay.layer.borderWidth = 1

      gapDebugSafeInsetBand.isUserInteractionEnabled = false
      gapDebugSafeInsetBand.backgroundColor = UIColor.yellow.withAlphaComponent(0.5)
      gapDebugBarOverlay.addSubview(gapDebugSafeInsetBand)

      gapDebugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
      gapDebugLabel.textColor = .white
      gapDebugLabel.backgroundColor = UIColor.orange.withAlphaComponent(0.84)
      gapDebugLabel.textAlignment = .center
      gapDebugLabel.layer.cornerRadius = 4
      gapDebugLabel.clipsToBounds = true
      gapDebugBarOverlay.addSubview(gapDebugLabel)

      addSubview(gapDebugBarOverlay)
    }

    // GIF panel is created lazily on first open (see loadGifPanelIfNeeded).

    // ── Pending queue strip (above content row; part of input chrome) ─────
    pendingQueueStrip.isHidden = true
    pendingQueueStrip.alpha = 0
    pendingQueueStrip.backgroundColor = .clear
    addSubview(pendingQueueStrip)
    pendingQueueStack.axis = .vertical
    pendingQueueStack.spacing = 6
    pendingQueueStack.translatesAutoresizingMaskIntoConstraints = false
    pendingQueueStrip.addSubview(pendingQueueStack)
    NSLayoutConstraint.activate([
      pendingQueueStack.topAnchor.constraint(equalTo: pendingQueueStrip.topAnchor),
      pendingQueueStack.leadingAnchor.constraint(equalTo: pendingQueueStrip.leadingAnchor, constant: 12),
      pendingQueueStack.trailingAnchor.constraint(equalTo: pendingQueueStrip.trailingAnchor, constant: -12),
      pendingQueueStack.bottomAnchor.constraint(equalTo: pendingQueueStrip.bottomAnchor),
    ])

    // ── 1. Content row ────────────────────────────────────────────────────
    // No full-bar glass. The bar background is transparent; each element
    // has its own glass surface.
    contentRow.backgroundColor = .clear
    contentRow.clipsToBounds = false
    addSubview(contentRow)

    // ── Attachment button (glass pill) ────────────────────────────────────
    attachGlass.isUserInteractionEnabled = true
    attachGlass.clipsToBounds = true
    attachButton.clipsToBounds = false
    attachButton.backgroundColor = .clear
    attachGlass.contentView.addSubview(attachButton)
    let plusCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    applyControlGlyph(
      button: attachButton,
      symbolName: "plus",
      symbolConfig: plusCfg,
      tintColor: UIColor(white: 0.85, alpha: 1.0)
    )
    // Default path: open full attachment sheet (agent mode switches to UIMenu).
    attachButton.accessibilityLabel = "Add attachment"
    attachButton.addTarget(self, action: #selector(attachButtonTapped), for: .touchUpInside)
    contentRow.addSubview(attachGlass)

    // ── Pill container ────────────────────────────────────────────────────
    pillContainer.backgroundColor = .clear
    pillContainer.clipsToBounds = true
    pillContainer.layer.cornerCurve = .continuous

    // glass background of pill
    pillGlass.isUserInteractionEnabled = true
    pillGlass.clipsToBounds = true
    contentRow.addSubview(pillGlass)

    pillButton.backgroundColor = .clear
    pillButton.clipsToBounds = false
    pillGlass.contentView.addSubview(pillButton)

    pillButton.addSubview(pillContainer)

    inlineAttachButton.isHidden = true
    inlineAttachButton.accessibilityLabel = "Add attachment"
    inlineAttachButton.addTarget(
      self,
      action: #selector(inlineAttachTapped),
      for: .touchUpInside
    )
    pillContainer.addSubview(inlineAttachButton)

    slashButton.isHidden = true
    slashButton.accessibilityLabel = "Slash commands"
    slashButton.showsMenuAsPrimaryAction = true
    pillContainer.addSubview(slashButton)

    // placeholder
    placeholderLabel.text = placeholder
    placeholderLabel.font = UIFont.systemFont(ofSize: 16)
    placeholderLabel.isUserInteractionEnabled = false
    pillContainer.addSubview(placeholderLabel)

    // text view
    textView.backgroundColor = .clear
    textView.font = UIFont.systemFont(ofSize: 16)
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsEditingTextAttributes = false
    textView.isScrollEnabled = false
    // Keep multiline input behavior: show "return" key instead of iOS blue "send".
    textView.returnKeyType = .default
    textView.delegate = self
    textView.showsVerticalScrollIndicator = false
    // Stable hook for XCUITest device control. Keep UITextView's native traits
    // so it remains a direct-interaction, keyboard-focusable editor.
    textView.accessibilityIdentifier = "chat.composer"
    textView.accessibilityLabel = "Message"
    pillContainer.addSubview(textView)

    // GIF button (inside pill, trailing side before Send)
    gifButton.setImage(chatGifStickerGlyphImage(size: CGSize(width: 21, height: 21)), for: .normal)
    gifButton.contentVerticalAlignment = .center
    gifButton.contentHorizontalAlignment = .center
    gifButton.imageEdgeInsets = .zero
    gifButton.addTarget(self, action: #selector(gifTapped), for: .touchUpInside)
    pillContainer.addSubview(gifButton)

    // ── Draft context chip (inside pill, above text row) ──────────────
    // Hairline theme-tint rail + two text lines; plate stays clear.
    replyBanner.clipsToBounds = true
    replyBanner.isHidden = true
    replyBanner.alpha = 0
    replyBanner.layer.cornerRadius = 12
    replyBanner.layer.cornerCurve = .continuous
    replyBanner.layer.borderWidth = 0
    pillContainer.addSubview(replyBanner)

    replyAccentBar.backgroundColor = ChatListAppearance.brandAccentFallback
    replyAccentBar.layer.cornerRadius = 1.5
    replyAccentBar.clipsToBounds = true
    replyBanner.addSubview(replyAccentBar)

    replySenderLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
    replySenderLabel.textColor = ChatListAppearance.brandAccentFallback
    replySenderLabel.lineBreakMode = .byTruncatingTail
    replyBanner.addSubview(replySenderLabel)

    replyPreviewLabel.font = .systemFont(ofSize: 12, weight: .regular)
    replyPreviewLabel.textColor = UIColor(white: 0.87, alpha: 0.72)
    replyPreviewLabel.lineBreakMode = .byTruncatingTail
    replyBanner.addSubview(replyPreviewLabel)

    // A 10pt glyph in a 24pt box was a dot to aim at. Same mark, given a real target and
    // a soft disc so it reads as a button instead of a stray SVG.
    let xCfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    replyDismissButton.setImage(UIImage(systemName: "xmark", withConfiguration: xCfg), for: .normal)
    replyDismissButton.tintColor = UIColor(white: 0.87, alpha: 0.55)
    replyDismissButton.layer.cornerRadius = 13
    replyDismissButton.layer.cornerCurve = .continuous
    replyDismissButton.backgroundColor = UIColor(white: 1.0, alpha: 0.07)
    replyDismissButton.addTarget(self, action: #selector(replyDismissTapped), for: .touchUpInside)
    replyBanner.addSubview(replyDismissButton)

    // ── Attachment preview scroll view (inside pill, above text row) ──────
    attachmentPreviewScroll.clipsToBounds = true
    attachmentPreviewScroll.isHidden = true
    attachmentPreviewScroll.alpha = 0
    attachmentPreviewScroll.showsHorizontalScrollIndicator = false
    pillContainer.addSubview(attachmentPreviewScroll)

    attachmentPreviewContainer.axis = .horizontal
    attachmentPreviewContainer.spacing = 8
    attachmentPreviewContainer.alignment = .center
    attachmentPreviewContainer.translatesAutoresizingMaskIntoConstraints = false
    attachmentPreviewScroll.addSubview(attachmentPreviewContainer)

    NSLayoutConstraint.activate([
      attachmentPreviewContainer.topAnchor.constraint(equalTo: attachmentPreviewScroll.topAnchor),
      attachmentPreviewContainer.bottomAnchor.constraint(equalTo: attachmentPreviewScroll.bottomAnchor),
      attachmentPreviewContainer.leadingAnchor.constraint(equalTo: attachmentPreviewScroll.leadingAnchor, constant: 8),
      attachmentPreviewContainer.trailingAnchor.constraint(equalTo: attachmentPreviewScroll.trailingAnchor, constant: -8),
      attachmentPreviewContainer.heightAnchor.constraint(equalTo: attachmentPreviewScroll.heightAnchor)
    ])

    // ── Slash suggestion scroll view (inside pill, above text row) ────────
    slashSuggestionScroll.clipsToBounds = true
    slashSuggestionScroll.isHidden = true
    slashSuggestionScroll.alpha = 0
    slashSuggestionScroll.showsHorizontalScrollIndicator = false
    pillContainer.addSubview(slashSuggestionScroll)

    slashSuggestionContainer.axis = .horizontal
    slashSuggestionContainer.spacing = 8
    slashSuggestionContainer.alignment = .center
    slashSuggestionContainer.translatesAutoresizingMaskIntoConstraints = false
    slashSuggestionScroll.addSubview(slashSuggestionContainer)

    NSLayoutConstraint.activate([
      slashSuggestionContainer.topAnchor.constraint(equalTo: slashSuggestionScroll.topAnchor),
      slashSuggestionContainer.bottomAnchor.constraint(equalTo: slashSuggestionScroll.bottomAnchor),
      slashSuggestionContainer.leadingAnchor.constraint(equalTo: slashSuggestionScroll.leadingAnchor, constant: 8),
      slashSuggestionContainer.trailingAnchor.constraint(equalTo: slashSuggestionScroll.trailingAnchor, constant: -8),
      slashSuggestionContainer.heightAnchor.constraint(equalTo: slashSuggestionScroll.heightAnchor)
    ])

    // ── Mention suggestion banner (INSIDE pill, above text row — like reply banner) ──
    mentionBanner.backgroundColor = .clear
    mentionBanner.clipsToBounds = true
    mentionBanner.isHidden = true
    mentionBanner.alpha = 0

    let mentionTap = UITapGestureRecognizer(target: self, action: #selector(mentionBannerTapped))
    mentionBanner.addGestureRecognizer(mentionTap)
    pillContainer.addSubview(mentionBanner)

    mentionAccentBar.backgroundColor = ChatListAppearance.brandAccentFallback
    mentionAccentBar.layer.cornerRadius = 1.5
    mentionAccentBar.layer.cornerCurve = .continuous
    mentionBanner.addSubview(mentionAccentBar)

    mentionNameLabel.text = "@vibe"
    mentionNameLabel.font = .systemFont(ofSize: 12, weight: .bold)
    mentionNameLabel.textColor = UIColor(white: 0.92, alpha: 1.0)
    mentionNameLabel.lineBreakMode = .byTruncatingTail
    mentionBanner.addSubview(mentionNameLabel)

    mentionDescLabel.text = "Ask AI"
    mentionDescLabel.font = .systemFont(ofSize: 12, weight: .regular)
    mentionDescLabel.textColor = UIColor(white: 0.87, alpha: 0.72)
    mentionDescLabel.lineBreakMode = .byTruncatingTail
    mentionBanner.addSubview(mentionDescLabel)

    // send button
    sendButton.backgroundColor = .clear
    sendButton.clipsToBounds = true
    sendButton.layer.cornerRadius = 16
    let paperplane = UIImage(
      systemName: "paperplane.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    sendButton.setImage(paperplane, for: .normal)
    sendButton.tintColor = .white
    sendGradient.startPoint = CGPoint(x: 0, y: 0)
    sendGradient.endPoint = CGPoint(x: 1, y: 1)
    sendGradient.cornerRadius = 16
    sendButton.layer.insertSublayer(sendGradient, at: 0)
    sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
    sendButton.accessibilityIdentifier = "chat.send"
    sendButton.accessibilityLabel = "Send"
    sendButton.accessibilityTraits = .button
    sendButton.isAccessibilityElement = true
    pillContainer.addSubview(sendButton)

    cancelOverlayButton.addTarget(self, action: #selector(cancelOverlayTapped), for: .touchUpInside)
    cancelOverlayButton.isHidden = true
    pillContainer.addSubview(cancelOverlayButton)

    // ── Selection Buttons (glass pills) ───────────────────────────────────────
    let selectionCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    
    [selectionDeleteGlass, selectionShareOutsideGlass, selectionShareInsideGlass].forEach {
      $0.isUserInteractionEnabled = true
      $0.clipsToBounds = true
      $0.isHidden = true
      $0.alpha = 0
      contentRow.addSubview($0)
    }
    
    selectionDeleteGlass.clipsToBounds = false
    selectionDeleteButton.clipsToBounds = false
    selectionDeleteButton.backgroundColor = .clear
    selectionDeleteButton.isHidden = true
    selectionDeleteGlass.contentView.addSubview(selectionDeleteButton)
    applyControlGlyph(
      button: selectionDeleteButton, symbolName: "trash",
      symbolConfig: selectionCfg, tintColor: UIColor(white: 0.85, alpha: 1.0)
    )
    selectionDeleteButton.addTarget(self, action: #selector(handleSelectionDelete), for: .touchUpInside)
    
    selectionShareOutsideButton.clipsToBounds = false
    selectionShareOutsideButton.backgroundColor = .clear
    selectionShareOutsideGlass.contentView.addSubview(selectionShareOutsideButton)
    applyControlGlyph(
      button: selectionShareOutsideButton, symbolName: "square.and.arrow.up",
      symbolConfig: selectionCfg, tintColor: UIColor(white: 0.85, alpha: 1.0)
    )
    selectionShareOutsideButton.addTarget(self, action: #selector(handleSelectionShareOutside), for: .touchUpInside)
    
    selectionShareInsideButton.clipsToBounds = false
    selectionShareInsideButton.backgroundColor = .clear
    selectionShareInsideGlass.contentView.addSubview(selectionShareInsideButton)
    applyControlGlyph(
      button: selectionShareInsideButton, symbolName: "arrowshape.turn.up.right",
      symbolConfig: selectionCfg, tintColor: UIColor(white: 0.85, alpha: 1.0)
    )
    selectionShareInsideButton.addTarget(self, action: #selector(handleSelectionShareInside), for: .touchUpInside)

    // ── Mic button (glass pill) ───────────────────────────────────────────
    micVADView.alpha = 0
    contentRow.addSubview(micVADView)

    micGlass.isUserInteractionEnabled = true
    micGlass.clipsToBounds = true
    micButton.clipsToBounds = false
    micGlass.contentView.addSubview(micButton)
    let micCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    applyControlGlyph(
      button: micButton,
      symbolName: "mic",
      symbolConfig: micCfg,
      tintColor: UIColor(white: 0.85, alpha: 1.0)
    )
    micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
    contentRow.addSubview(micGlass)

    // Recording UI setup
    setupRecordingUI()

    // Default colors (visible before applyAppearance)
    attachButton.tintColor = UIColor(white: 0.85, alpha: 1.0)
    gifButton.tintColor = UIColor(white: 0.58, alpha: 0.92)
    micButton.tintColor = UIColor(white: 0.85, alpha: 1.0)
    textView.textColor = UIColor(white: 0.87, alpha: 1.0)
    textView.tintColor = UIColor(white: 0.87, alpha: 0.9)
    placeholderLabel.textColor = UIColor(white: 0.87, alpha: 0.45)
    sendGradient.colors = [
      ChatListAppearance.brandAccentFallback.cgColor,
      UIColor(red: 0.42, green: 0.31, blue: 0.81, alpha: 1.0).cgColor,
    ]

    // Initial button state (no text → mic visible, send hidden)
    sendButton.alpha = 0
    sendProgress = 0
    micGlass.alpha = 1
    sendButton.isHidden = true
    micGlass.isHidden = false

    applyPlaceholder()
    refreshGlass()
  }

  // MARK: - Appearance

  func applyAppearance(_ a: ChatListAppearance) {
    appearance = a
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    textView.textColor = a.textColorThem
    textView.tintColor = a.textColorThem.withAlphaComponent(0.9)
    placeholderLabel.textColor = a.textColorThem.withAlphaComponent(0.45)
    let controlTint = a.textColorThem.withAlphaComponent(0.9)
    attachButton.tintColor = controlTint
    inlineAttachButton.tintColor = controlTint
    gifButton.tintColor = gifGlyphTint(active: gifPanelVisible)
    micButton.tintColor = controlTint
    sendGradient.colors = a.bubbleMeGradient.map(\.cgColor)
    pillTint = a.bubbleThemColor.withAlphaComponent(0.14)

    if let firstColor = a.bubbleMeGradient.first {
      micVADView.applyColor(firstColor.withAlphaComponent(0.25))
    } else {
      micVADView.applyColor(a.textColorThem.withAlphaComponent(0.15))
    }

    let chipAccent = a.outgoingBasePlateColor
    replyChipAccent = chipAccent
    replyAccentBar.backgroundColor = chipAccent
    replyBanner.backgroundColor = .clear
    replyBanner.layer.borderColor = UIColor.clear.cgColor
    replySenderLabel.textColor = chipAccent
    replyPreviewLabel.textColor = a.textColorThem.withAlphaComponent(0.55)
    replyDismissButton.tintColor = a.textColorThem.withAlphaComponent(0.48)
    replyDismissButton.backgroundColor = .clear
    slideToCancelLabel.textColor = a.textColorThem.withAlphaComponent(0.78)
    slideChevronView.tintColor = a.textColorThem.withAlphaComponent(0.78)
    recordingTimerLabel.textColor = a.textColorThem.withAlphaComponent(0.95)
    lockView.tintColor = a.textColorThem.withAlphaComponent(0.95)
    lockArrowView.tintColor = a.textColorThem.withAlphaComponent(0.95)

    // Evaluate if theme is light or dark based on textColorThem luminance roughly
    var white: CGFloat = 0
    if a.textColorThem.getWhite(&white, alpha: nil) {
      let isDark = white > 0.5
      backgroundBlurView.effect = UIBlurEffect(style: isDark ? .dark : .light)
    } else {
      backgroundBlurView.effect = UIBlurEffect(style: .regular)
    }

    let baseColor = a.wallpaperGradient.first ?? UIColor.black
    backgroundOverlayView.backgroundColor = baseColor.withAlphaComponent(0.88)

    // Mention suggestion banner (inside pill)
    mentionBanner.backgroundColor = .clear
    mentionAccentBar.backgroundColor = a.outgoingBasePlateColor
    mentionNameLabel.textColor = a.textColorThem.withAlphaComponent(0.92)
    mentionDescLabel.textColor = a.textColorThem.withAlphaComponent(0.72)

    refreshGlass()
    refreshAgentControlModeAppearance()
    applyComposerRecordGlyph(to: micButton, tintColor: controlTint)
    CATransaction.commit()
  }

  private func refreshAgentControlModeAppearance() {
    let controlTint = appearance.textColorThem.withAlphaComponent(0.9)
    let plusConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    applyControlGlyph(
      button: inlineAttachButton,
      symbolName: "plus",
      symbolConfig: plusConfiguration,
      tintColor: controlTint
    )
    slashButton.isHidden = true

    attachButton.configuration = nil
    attachButton.setTitle(nil, for: .normal)
    attachButton.contentHorizontalAlignment = .center
    applyControlGlyph(
      button: attachButton,
      symbolName: "plus",
      symbolConfig: plusConfiguration,
      tintColor: controlTint
    )

    if agentControlMode {
      // AI agent chats: keep the UIMenu (+ attach actions + agent control items).
      attachButton.accessibilityLabel = "Add to chat"
      attachButton.removeTarget(self, action: #selector(attachButtonTapped), for: .touchUpInside)
    } else {
      // Default chats: + opens the full Gallery/File/Location attachment sheet.
      attachButton.accessibilityLabel = "Add attachment"
      attachButton.menu = nil
      attachButton.showsMenuAsPrimaryAction = false
      attachButton.removeTarget(self, action: #selector(attachButtonTapped), for: .touchUpInside)
      attachButton.addTarget(self, action: #selector(attachButtonTapped), for: .touchUpInside)
    }
    updatePlusButtonMenu()
  }

  // MARK: - Input State Reset

  func setSelectionMode(_ active: Bool, animated: Bool) {
    if isSelectionMode == active {
      NSLog("[ChatShare] inputBar setSelectionMode already active=%@", active ? "Y" : "N")
      return
    }
    isSelectionMode = active
    NSLog(
      "[ChatShare] inputBar setSelectionMode active=%@ agentControl=%@",
      active ? "Y" : "N",
      agentControlMode ? "Y" : "N"
    )
    // Recompute mic/send visibility when leaving selection. The selection layout
    // drives the mic alpha to zero, so preserving the previous alpha leaves it
    // permanently hidden after deselection.
    updateButtonStates(animated: false)
    applySelectionInteractionState()
    if animated {
      UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
        self.setNeedsLayout()
        self.layoutIfNeeded()
      }
    } else {
      setNeedsLayout()
      layoutIfNeeded()
    }
  }

  /// Keep selection chrome tappable: alpha-0 controls can still steal hits on some
  /// glass effect paths; disable interaction + raise selection z-order.
  private func applySelectionInteractionState() {
    let selecting = isSelectionMode
    attachGlass.isUserInteractionEnabled = !selecting
    attachButton.isUserInteractionEnabled = !selecting
    pillGlass.isUserInteractionEnabled = !selecting
    micGlass.isUserInteractionEnabled = !selecting && micGlass.alpha > 0.01
    micButton.isUserInteractionEnabled = micGlass.isUserInteractionEnabled
    textView.isUserInteractionEnabled = !selecting
    sendButton.isUserInteractionEnabled = !selecting && sendButton.alpha > 0.01
    gifButton.isUserInteractionEnabled = !selecting
    [selectionDeleteGlass, selectionShareOutsideGlass, selectionShareInsideGlass].forEach {
      $0.isUserInteractionEnabled = selecting
      $0.isHidden = !selecting
    }
    selectionDeleteButton.isHidden = !selecting
    selectionDeleteButton.isUserInteractionEnabled = selecting
    selectionShareOutsideButton.isUserInteractionEnabled = selecting
    selectionShareInsideButton.isUserInteractionEnabled = selecting
  }

  // MARK: - Public helpers

  func clearText() {
    dismissDraftMusicBanner(animated: false)
    textView.text = ""
    setMentionBannerVisible(false, animated: false)
    updateButtonStates(animated: true)
    applyPlaceholder()
    // Animate pill shrinking back to single-line height
    UIView.animate(
      withDuration: 0.25, delay: 0,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }

  /// Load text into the composer (used when re-opening a failed message to edit
  /// and resend) and bring up the keyboard.
  func setComposerText(_ text: String, focus: Bool = true) {
    textView.text = text
    setMentionBannerVisible(false, animated: false)
    applyPlaceholder()
    updateButtonStates(animated: true)
    if focus {
      textView.becomeFirstResponder()
    }
    // Position the caret at the end of the loaded text.
    let end = textView.endOfDocument
    textView.selectedTextRange = textView.textRange(from: end, to: end)
    UIView.animate(
      withDuration: 0.25, delay: 0,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }

  func setAgentStreaming(_ streaming: Bool) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.setAgentStreaming(streaming)
      }
      return
    }
    guard isAgentStreaming != streaming else { return }
    isAgentStreaming = streaming
    updateButtonStates(animated: true)
  }

  func setAgentControlMode(_ enabled: Bool) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.setAgentControlMode(enabled)
      }
      return
    }
    guard agentControlMode != enabled else { return }
    agentControlMode = enabled
    inlineAttachButton.isHidden = !enabled
    refreshAgentControlModeAppearance()
    setNeedsLayout()
  }

  func setAgentControlTitle(_ title: String) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.setAgentControlTitle(title)
      }
      return
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let next = trimmed.isEmpty ? "Open" : trimmed
    guard agentControlTitle != next else { return }
    agentControlTitle = next
    refreshAgentControlModeAppearance()
    setNeedsLayout()
  }

  /// Repository name shown on the agent-control chip (📁 <repo>). Empty → "Repository".
  func setAgentControlRepoTitle(_ title: String) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.setAgentControlRepoTitle(title)
      }
      return
    }
    let next = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard agentControlRepoTitle != next else { return }
    agentControlRepoTitle = next
    refreshAgentControlModeAppearance()
    setNeedsLayout()
  }

  /// Host-built menu (Repository / Report / Permission / History) for the agent-control
  /// chip. Pass nil to fall back to the legacy agent-panel tap.
  func setAgentControlMenu(_ menu: UIMenu?) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.setAgentControlMenu(menu)
      }
      return
    }
    agentControlMenu = menu
    refreshAgentControlModeAppearance()
    setNeedsLayout()
  }

  /// Host-built slash-command menu shown by the "/" button at the pill's leading edge
  /// (agent chats only). Pass nil to hide the button.
  func setSlashCommandMenu(_ menu: UIMenu?) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.setSlashCommandMenu(menu)
      }
      return
    }
    slashCommandMenu = menu
    slashButton.menu = menu
    refreshAgentControlModeAppearance()
    setNeedsLayout()
  }

  /// Pending bridge sends while a run is live. Shown as compact rows inside the
  /// input bar (preview + Steer + ✕) — replaces the old floating list overlay.
  func setPendingQueueItems(_ items: [PendingQueueItem], animated: Bool = true) {
    pendingQueueItems = items
    let show = !items.isEmpty
    rebuildPendingQueueRows()
    if show == pendingQueueStripVisible {
      setNeedsLayout()
      layoutIfNeeded()
      if show { delegate?.inputBarHeightDidChange() }
      return
    }
    pendingQueueStripVisible = show
    pendingQueueStrip.isHidden = !show
    if animated, show {
      pendingQueueStrip.alpha = 0
      UIView.animate(withDuration: 0.2) {
        self.pendingQueueStrip.alpha = 1
        self.setNeedsLayout()
        self.layoutIfNeeded()
      } completion: { _ in
        self.delegate?.inputBarHeightDidChange()
      }
    } else {
      pendingQueueStrip.alpha = show ? 1 : 0
      setNeedsLayout()
      layoutIfNeeded()
      delegate?.inputBarHeightDidChange()
    }
  }

  private func rebuildPendingQueueRows() {
    pendingQueueStack.arrangedSubviews.forEach {
      pendingQueueStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    for item in pendingQueueItems {
      pendingQueueStack.addArrangedSubview(makePendingQueueRow(item))
    }
  }

  private func makePendingQueueRow(_ item: PendingQueueItem) -> UIView {
    let row = UIView()
    row.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.55)
    row.layer.cornerRadius = 12
    row.layer.cornerCurve = .continuous

    let clock = UIImageView(
      image: UIImage(
        systemName: "clock",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)))
    clock.tintColor = .secondaryLabel
    clock.translatesAutoresizingMaskIntoConstraints = false

    let label = UILabel()
    label.font = .systemFont(ofSize: 13)
    label.textColor = .label
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.text = item.text
    label.translatesAutoresizingMaskIntoConstraints = false

    var steerCfg = UIButton.Configuration.plain()
    steerCfg.image = UIImage(
      systemName: "bolt.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    steerCfg.title = "Steer"
    steerCfg.imagePadding = 2
    steerCfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
    let steer = UIButton(configuration: steerCfg)
    steer.tintColor = UIColor.systemOrange
    steer.translatesAutoresizingMaskIntoConstraints = false
    let mid = item.messageId
    steer.addAction(UIAction { [weak self] _ in self?.onPendingQueueSteer?(mid) }, for: .touchUpInside)

    let close = UIButton(type: .system)
    close.setImage(
      UIImage(
        systemName: "xmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)),
      for: .normal)
    close.tintColor = .secondaryLabel
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addAction(UIAction { [weak self] _ in self?.onPendingQueueCancel?(mid) }, for: .touchUpInside)

    row.addSubview(clock)
    row.addSubview(label)
    row.addSubview(steer)
    row.addSubview(close)
    NSLayoutConstraint.activate([
      row.heightAnchor.constraint(equalToConstant: pendingQueueRowH),
      clock.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
      clock.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: clock.trailingAnchor, constant: 8),
      label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: steer.leadingAnchor, constant: -6),
      steer.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
      steer.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      close.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
      close.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      close.widthAnchor.constraint(equalToConstant: 28),
    ])
    return row
  }

  /// Insert a chosen slash command into the composer (caret at end) so the user can add
  /// arguments before sending — mirrors typing "/name " by hand.
  func insertSlashCommand(_ name: String) {
    let token = "/\(name) "
    let existing = textView.text ?? ""
    textView.text = existing.isEmpty ? token : (existing + (existing.hasSuffix(" ") ? "" : " ") + token)
    applyPlaceholder()
    updateButtonStates(animated: true)
    textView.becomeFirstResponder()
    let end = textView.endOfDocument
    textView.selectedTextRange = textView.textRange(from: end, to: end)
    delegate?.inputBarTextDidChange(text: textView.text ?? "")
    setNeedsLayout()
  }

  func pillRect(in view: UIView) -> CGRect {
    pillContainer.convert(pillContainer.bounds, to: view)
  }

  struct SendTransitionCapture {
    let sourceContainerRect: CGRect
    let sourceBackgroundRectInContainer: CGRect
    let sourceContentRectInContainer: CGRect
    let sourceScrollOffset: CGFloat
    let sourceBackgroundSnapshotView: UIView?
    let sourceContentSnapshotView: UIView?
  }

  private func makeTextContentSnapshot() -> UIView? {
    let textBounds = textView.bounds
    guard textBounds.width > 1.0, textBounds.height > 1.0 else { return nil }

    // Never put another UITextView in the flight. Even a non-editable/non-selectable
    // UITextView owns private marked-text and selection-decoration layers; on iOS 26
    // those can survive in drawHierarchy as the dark rectangle seen behind the first
    // one-word send. Build a plain label from the committed string instead. This makes
    // it structurally impossible for caret/selection/marked-text chrome to enter the
    // morph while preserving the composer's font, color, alignment, and TextKit insets.
    let wrapper = UIView(frame: CGRect(origin: .zero, size: textBounds.size))
    wrapper.backgroundColor = .clear
    wrapper.isOpaque = false
    wrapper.isUserInteractionEnabled = false
    wrapper.clipsToBounds = true

    let committedText = textView.text ?? ""
    // Direction comes from the TEXT, not the interface: the ghost has to land on a cell
    // that shapes RTL and left-aligns the block, so it must start that way too.
    let rtlBody = ChatNativeAgentTextRenderer.isRTL(committedText)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = rtlBody ? .left : textView.textAlignment
    paragraph.lineBreakMode = textView.textContainer.lineBreakMode
    paragraph.baseWritingDirection =
      rtlBody || textView.effectiveUserInterfaceLayoutDirection == .rightToLeft
      ? .rightToLeft : .leftToRight
    let cleanText = NSAttributedString(
      string: committedText,
      attributes: [
        .font: textView.font ?? UIFont.systemFont(ofSize: 16),
        .foregroundColor: textView.textColor ?? UIColor.label,
        .paragraphStyle: paragraph,
      ])
    let label = UILabel()
    label.backgroundColor = .clear
    label.isOpaque = false
    label.isUserInteractionEnabled = false
    label.numberOfLines = textView.textContainer.maximumNumberOfLines
    label.lineBreakMode = textView.textContainer.lineBreakMode
    label.textAlignment = rtlBody ? .left : textView.textAlignment
    label.semanticContentAttribute =
      rtlBody ? .forceRightToLeft : textView.semanticContentAttribute
    label.attributedText = cleanText

    let insets = textView.textContainerInset
    let fragmentPadding = textView.textContainer.lineFragmentPadding
    let labelX = insets.left + fragmentPadding
    let labelY = insets.top - textView.contentOffset.y
    let labelWidth = max(
      1.0,
      textBounds.width - insets.left - insets.right - (fragmentPadding * 2.0))
    let measured = label.sizeThatFits(
      CGSize(width: labelWidth, height: CGFloat.greatestFiniteMagnitude))
    // The destination cell pixel-aligns its label; an unaligned ghost resamples the
    // glyphs and reads as a one-pixel slide through the crossfade.
    let pixelScale = max(1.0, wrapper.window?.screen.scale ?? UIScreen.main.scale)
    label.frame = CGRect(
      x: (labelX * pixelScale).rounded() / pixelScale,
      y: (labelY * pixelScale).rounded() / pixelScale,
      width: labelWidth,
      height: max(measured.height, textView.font?.lineHeight ?? 20.0))
    wrapper.addSubview(label)
    return wrapper
  }

  private func makeBackgroundSnapshot(captureRect: CGRect) -> UIView? {
    guard captureRect.width > 1.0, captureRect.height > 1.0 else { return nil }

    // Temporarily strip corner radius so it's not baked into the pixel data.
    // The transition clipping view's own cornerRadius animation handles the
    // visual rounding during the morph.
    let savedGlassRadius = pillGlass.layer.cornerRadius
    let savedContainerRadius = pillContainer.layer.cornerRadius
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pillGlass.layer.cornerRadius = 0
    pillContainer.layer.cornerRadius = 0
    if #available(iOS 26.0, *) {
      pillGlass.cornerConfiguration = .uniformCorners(radius: .fixed(0))
    }
    // CRITICAL: Hide contentView so we only capture the blur/glass,
    // NOT the text, gif button, mic button, etc.
    let wasHidden = pillGlass.contentView.isHidden
    pillGlass.contentView.isHidden = true
    pillGlass.setNeedsLayout()
    pillGlass.layoutIfNeeded()
    CATransaction.commit()

    let captureRectInGlass = pillContainer.convert(captureRect, to: pillGlass)

    // Screen-matched color space (P3): this capsule ghost crossfades into the
    // live-rendered bubble during the send morph — an sRGB bake tints it.
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = false
    format.scale = UIScreen.main.scale
    let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)

    // IMPORTANT: Use drawHierarchy instead of layer.render.
    // layer.render does NOT capture UIVisualEffectView blur — it produces
    // a transparent image. drawHierarchy captures what's actually on screen,
    // including blur, vibrancy, and glass effects.
    let image = renderer.image { _ in
      pillGlass.drawHierarchy(
        in: CGRect(
          x: -captureRectInGlass.minX,
          y: -captureRectInGlass.minY,
          width: pillGlass.bounds.width,
          height: pillGlass.bounds.height
        ),
        afterScreenUpdates: true
      )
    }

    // Restore corner radius and content visibility
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pillGlass.layer.cornerRadius = savedGlassRadius
    pillContainer.layer.cornerRadius = savedContainerRadius
    if #available(iOS 26.0, *) {
      pillGlass.cornerConfiguration = .uniformCorners(radius: .fixed(savedGlassRadius))
    }
    pillGlass.contentView.isHidden = wasHidden
    pillGlass.setNeedsLayout()
    pillGlass.layoutIfNeeded()
    CATransaction.commit()

    // Verify the image has actual content (not all transparent)
    if let cgImage = image.cgImage {
      let alphaInfo = cgImage.alphaInfo
      print("[SendMorph] sourceBackground captured: size=\(image.size) alpha=\(alphaInfo.rawValue) bytesPerRow=\(cgImage.bytesPerRow)")
    } else {
      print("[SendMorph] sourceBackground capture FAILED — cgImage is nil, using fallback")
      // Fallback: use the bubble gradient color as source background
      if let gradientColors = sendGradient.colors as? [CGColor], let first = gradientColors.first {
        let fallback = UIView(frame: CGRect(origin: .zero, size: captureRect.size))
        fallback.backgroundColor = UIColor(cgColor: first).withAlphaComponent(0.15)
        return fallback
      }
    }

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleToFill
    imageView.clipsToBounds = false
    return imageView
  }

  /// Captures Telegram-style transition inputs in one call:
  ///   - source container rect (host coords)
  ///   - source background rect (container-local)
  ///   - source content rect + snapshot (container-local)
  ///   - source content scroll offset
  func captureSendTransition(in view: UIView) -> SendTransitionCapture? {
    guard !textView.bounds.isEmpty, !pillContainer.bounds.isEmpty else {
      return nil
    }
    layoutIfNeeded()

    let sourceContainerRect = pillContainer.convert(pillContainer.bounds.integral, to: view)
    guard sourceContainerRect.width > 1.0, sourceContainerRect.height > 1.0 else {
      return nil
    }

    let containerBounds = pillContainer.bounds.insetBy(dx: 1, dy: 1)
    var backgroundRect = containerBounds
    if !sendButton.isHidden, sendButton.alpha > 0.01 {
      let maxX = max(backgroundRect.minX + 1.0, sendButton.frame.minX - 2.0)
      backgroundRect.size.width = max(1.0, maxX - backgroundRect.minX)
    }
    backgroundRect = backgroundRect.intersection(containerBounds)
    if backgroundRect.isNull || backgroundRect.width <= 1.0 || backgroundRect.height <= 1.0 {
      backgroundRect = containerBounds
    }

    var contentRect = textView.frame
    contentRect = contentRect.intersection(pillContainer.bounds.insetBy(dx: 1, dy: 1))
    if contentRect.isNull || contentRect.width <= 1.0 || contentRect.height <= 1.0 {
      contentRect = backgroundRect.insetBy(dx: 8, dy: 8)
    }
    let sourceBackgroundRectInContainer = backgroundRect.integral
    let sourceContentRectInContainer = contentRect.integral

    let sourceBackgroundSnapshotView: UIView? = {
      guard let imageView = makeBackgroundSnapshot(captureRect: sourceBackgroundRectInContainer)
      else { return nil }
      imageView.frame = sourceBackgroundRectInContainer
      return imageView
    }()

    let sourceContentSnapshotView: UIView? = {
      guard let imageView = makeTextContentSnapshot() else { return nil }
      imageView.frame = sourceContentRectInContainer
      imageView.backgroundColor = .clear
      imageView.isOpaque = false
      imageView.clipsToBounds = false
      return imageView
    }()

    return SendTransitionCapture(
      sourceContainerRect: sourceContainerRect,
      sourceBackgroundRectInContainer: sourceBackgroundRectInContainer,
      sourceContentRectInContainer: sourceContentRectInContainer,
      sourceScrollOffset: textView.contentOffset.y,
      sourceBackgroundSnapshotView: sourceBackgroundSnapshotView,
      sourceContentSnapshotView: sourceContentSnapshotView
    )
  }

  /// Approximate Telegram's text-input background frame (without side action icons).
  func transitionBackgroundRect(in view: UIView) -> CGRect {
    if let capture = captureSendTransition(in: view) {
      return CGRect(
        x: capture.sourceContainerRect.minX + capture.sourceBackgroundRectInContainer.minX,
        y: capture.sourceContainerRect.minY + capture.sourceBackgroundRectInContainer.minY,
        width: capture.sourceBackgroundRectInContainer.width,
        height: capture.sourceBackgroundRectInContainer.height
      )
    }
    return pillRect(in: view)
  }

  /// Deprecated path kept for compatibility with existing call sites.
  func transitionBackgroundSnapshot(in view: UIView) -> UIView? {
    guard let capture = captureSendTransition(in: view) else { return nil }
    if let snapshot = capture.sourceBackgroundSnapshotView {
      snapshot.frame = CGRect(
        x: capture.sourceContainerRect.minX + capture.sourceBackgroundRectInContainer.minX,
        y: capture.sourceContainerRect.minY + capture.sourceBackgroundRectInContainer.minY,
        width: capture.sourceBackgroundRectInContainer.width,
        height: capture.sourceBackgroundRectInContainer.height
      )
      return snapshot
    }
    return nil
  }

  /// Returns the frame of the text area in the given coordinate space (used for send transition source rect).
  func textRect(in view: UIView) -> CGRect {
    if let capture = captureSendTransition(in: view) {
      return CGRect(
        x: capture.sourceContainerRect.minX + capture.sourceContentRectInContainer.minX,
        y: capture.sourceContainerRect.minY + capture.sourceContentRectInContainer.minY,
        width: capture.sourceContentRectInContainer.width,
        height: capture.sourceContentRectInContainer.height
      )
    }
    return textView.convert(textView.bounds, to: view)
  }

  /// Captures a live snapshot of the text view content for crossfade transitions.
  /// Returns a view positioned in the coordinate space of `view`, or nil if capture fails.
  func textContentSnapshot(in view: UIView) -> UIView? {
    guard let capture = captureSendTransition(in: view) else {
      return nil
    }
    guard let snapshot = capture.sourceContentSnapshotView else {
      return nil
    }
    snapshot.frame = CGRect(
      x: capture.sourceContainerRect.minX + capture.sourceContentRectInContainer.minX,
      y: capture.sourceContainerRect.minY + capture.sourceContentRectInContainer.minY,
      width: capture.sourceContentRectInContainer.width,
      height: capture.sourceContentRectInContainer.height
    )
    return snapshot
  }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    guard w > 0 else { return }

    // Keep the composer slightly closer to the bottom while still respecting
    // the home indicator area.
    // Same reduction whichever surface owns the bottom slot. The panel used to take the
    // full inset while the keyboard took inset−6, so the composer sat 6pt lower over the
    // panel — visible as a dip on every keyboard↔panel swap.
    let safeBottom = max(0, bottomSafeAreaInset - composerSafeBottomReduction)
    let clampedSendProgress = max(0.0, min(1.0, sendProgress))
    let clampedRecordingExpand = max(0.0, min(1.0, recordingExpandProgress))
    let micVisibility = max(0.0, min(1.0, 1.0 - clampedSendProgress))

    // Keep horizontal geometry stable when swapping keyboard <-> GIF panel.
    let layoutKeyboardProgress = accessoryLayoutProgress()
    let dynamicHPad = accessoryHorizontalPadding()

    // Measure text height
    let leftControlWidth: CGFloat = sideSize
    let leftSideGap: CGFloat = sideGap
    let recordingLeftExpansion = (leftControlWidth + leftSideGap) * clampedRecordingExpand
    let pillX = dynamicHPad + leftControlWidth + leftSideGap - recordingLeftExpansion
    let pillRight = w - dynamicHPad - (sideSize * micVisibility) - (sideGap * micVisibility)
    let sendW: CGFloat = 44
    let sendH: CGFloat = 32
    let gifButtonSize: CGFloat = 26
    let gifTextReserve: CGFloat =
      isRecording ? 0 : max(24, gifButtonSize - (8 * clampedSendProgress))
    let pillW = max(1, pillRight - pillX)
    let sendActionReserve = (sendW + 10) * clampedSendProgress
    let slashVisible = false
    let inlineAttachReserve: CGFloat = 0.0
    let textW = max(
      1,
      pillW - textInsetH * 2 - inlineAttachReserve - sendActionReserve - gifTextReserve
    )
    let textH = textView.sizeThatFits(CGSize(width: textW, height: .greatestFiniteMagnitude)).height
    let clampedTextH = max(minPillH - textInsetV * 2, min(maxPillH - textInsetV * 2, textH))
    let replyBannerExtra: CGFloat = replyBannerVisible ? (replyBannerContentH + replyBannerGap) : 0
    let mentionBannerExtra: CGFloat =
      mentionBannerVisible ? (mentionBannerContentH + mentionBannerGap) : 0
    let attachmentPreviewExtra: CGFloat = attachmentPreviewVisible ? (attachmentPreviewContentH + attachmentPreviewGap) : 0
    let slashSuggestionExtra: CGFloat = slashSuggestionVisible ? (slashSuggestionContentH + slashSuggestionGap) : 0
    let bannerExtra: CGFloat = replyBannerExtra + mentionBannerExtra + attachmentPreviewExtra + slashSuggestionExtra
    let pillH = clampedTextH + textInsetV * 2 + bannerExtra

    // Queue strip sits above the pill row (still part of the input bar height).
    let queueCount = pendingQueueItems.count
    let pendingQueueExtra: CGFloat =
      pendingQueueStripVisible && queueCount > 0
      ? (CGFloat(min(queueCount, 3)) * pendingQueueRowH
        + CGFloat(max(0, min(queueCount, 3) - 1)) * pendingQueueStack.spacing
        + pendingQueueGap)
      : 0

    // The panel stands in for the keyboard, so the composer keeps the SAME gap above
    // either one. `bottomSlotOccupied` stays true across a keyboard↔panel swap, so the
    // gap never flips back to the resting value for the frames in between.
    let composerBottomVPad: CGFloat = bottomSlotOccupied ? 6.0 : bottomVPad
    let composerHeight = topVPad + pendingQueueExtra + pillH + composerBottomVPad + safeBottom
    let panelHeight = gifPanelVisible ? preferredGifPanelHeight() : 0
    let totalH = composerHeight + panelHeight
    let prevH = barHeight
    barHeight = totalH

    // Enable/disable scroll when text exceeds max height
    textView.isScrollEnabled = textH > maxPillH - textInsetV * 2

    // ── View frames (CAN animate when triggered from UIView.animate) ──
    let blurExtraY = backgroundMaskTopOverlap
    let blurTotalH = composerHeight + blurExtraY
    backgroundMaskView.frame = CGRect(x: 0, y: -blurExtraY, width: w, height: blurTotalH)
    backgroundBlurView.frame = backgroundMaskView.bounds
    backgroundOverlayView.frame = backgroundBlurView.bounds

    if chatGapDebugOverlayEnabled {
      gapDebugBarOverlay.isHidden = false
      gapDebugBarOverlay.frame = CGRect(x: 0, y: 0, width: w, height: composerHeight)

      let safeBandHeight = max(0, safeBottom)
      gapDebugSafeInsetBand.isHidden = safeBandHeight <= 0.5
      gapDebugSafeInsetBand.frame = CGRect(
        x: 0,
        y: max(0, composerHeight - safeBandHeight),
        width: w,
        height: safeBandHeight
      )

      let labelWidth = min(max(220, w * 0.72), max(220, w - 16))
      let labelBandHeight = max(safeBandHeight, 22)
      let labelY = max(4, composerHeight - labelBandHeight + 2)
      gapDebugLabel.frame = CGRect(x: 8, y: labelY, width: labelWidth, height: 18)
      gapDebugLabel.text = String(
        format: "BAR %.0f SAFE %.0f RAW %.0f KB %.0f PNL %.0f",
        barHeight,
        safeBottom,
        bottomSafeAreaInset,
        keyboardHeightForPanels,
        presentedBottomAccessoryHeight
      )
      bringSubviewToFront(gapDebugBarOverlay)
    } else {
      gapDebugBarOverlay.isHidden = true
    }

    if pendingQueueExtra > 0 {
      pendingQueueStrip.isHidden = false
      pendingQueueStrip.frame = CGRect(
        x: 0, y: topVPad, width: w, height: pendingQueueExtra - pendingQueueGap)
    } else {
      pendingQueueStrip.isHidden = true
      pendingQueueStrip.frame = .zero
    }

    let rowY = topVPad + pendingQueueExtra
    let rowH = pillH
    contentRow.frame = CGRect(x: 0, y: rowY, width: w, height: rowH)

    if let panel = gifPanelIfLoaded {
      // When the panel lives in the overlay window, NEVER set frame relative to the
      // composer (y ≈ pill height). That coordinate system is the input bar's, but
      // the overlay is full-screen — so y=composerHeight pins the panel near the
      // TOP of the viewport. Overlay frames are owned by updateGifPanelOverlayFrame.
      if panel.superview === self {
        setGifPanelFrameKeepingTransform(
          panel, CGRect(x: 0, y: composerHeight, width: w, height: panelHeight))
      } else if gifPanelVisible, gifPanelHostController != nil {
        updateGifPanelOverlayFrame()
      }
      // Hiding slides on transform and leaves alpha at 1, so the alpha test re-showed a
      // dismissed panel on the next layout — that is the panel stranded under the keyboard.
      panel.isHidden = !gifPanelVisible && !gifPanelTransitionInFlight
    }

    // Side buttons are perfectly circular
    // Pin them to the bottom of the pill, aligned with the text input box,
    // so they don't float up when text expands or banners are added.
    let textRowH = clampedTextH + textInsetV * 2
    let textRowBottom = bannerExtra + textRowH
    let controlBottomInset = max(0.0, (minPillH - sideSize) * 0.5)
    let btnCenterY = textRowBottom - (sideSize / 2.0) - controlBottomInset
    let squareBounds = CGRect(origin: .zero, size: CGSize(width: sideSize, height: sideSize))

    let selectionYOffset: CGFloat = isSelectionMode ? 0.0 : 100.0
    let normalYOffset: CGFloat = isSelectionMode ? 100.0 : 0.0

    attachGlass.bounds = CGRect(
      origin: .zero,
      size: CGSize(width: leftControlWidth, height: sideSize)
    )
    attachGlass.center = CGPoint(
      x: dynamicHPad + (leftControlWidth / 2) - (recordingLeftExpansion * 0.85),
      y: btnCenterY + normalYOffset
    )
    attachButton.frame = attachGlass.contentView.bounds

    let micBaseCenterX = w - dynamicHPad - (sideSize / 2)
    let micPushOutX = (sideSize + sideGap) * clampedSendProgress

    // Position Mic Button (use center/bounds to preserve transforms)
    micGlass.bounds = squareBounds
    micGlass.center = CGPoint(x: micBaseCenterX + micPushOutX, y: btnCenterY + normalYOffset)
    micButton.frame = micGlass.contentView.bounds
    micVADView.bounds = squareBounds
    micVADView.center = CGPoint(x: micGlass.center.x, y: btnCenterY) // Keep VAD untouched or slide it too?
    // Layout check: Initial visibility handled by updateButtonStates

    let actualPillW = max(1, pillRight - pillX)
    pillGlass.frame = CGRect(x: pillX, y: normalYOffset, width: actualPillW, height: pillH)
    pillButton.frame = pillGlass.bounds
    pillContainer.frame = pillGlass.bounds
    // Corner radius: use the text-row height for capsule feel, capped for tall pills
    let cornerBase = (clampedTextH + textInsetV * 2)
    pillGlass.layer.cornerRadius = min(cornerBase / 2, 22)
    pillContainer.layer.cornerRadius = min(cornerBase / 2, 22)

    // Position Send Button inside pill (inline with text area)
    let sendBottomInset = max(5.0, (minPillH - sendH) * 0.5)
    let sendCenterY = textRowBottom - (sendH / 2.0) - sendBottomInset
    let sendCenterX = actualPillW - 4 - (sendW / 2)
    sendButton.bounds = CGRect(origin: .zero, size: CGSize(width: sendW, height: sendH))
    sendButton.center = CGPoint(x: sendCenterX, y: sendCenterY)
    sendButton.layer.cornerRadius = 16

    // ── Mention banner layout (inside pill, top section) ──
    if mentionBannerVisible {
      let mBannerY: CGFloat = 6
      let mBannerW = max(1, actualPillW - 16)
      mentionBanner.frame = CGRect(
        x: 8, y: mBannerY, width: mBannerW, height: mentionBannerContentH)
      layoutMentionBannerContents()
    }

    // ── Reply banner layout (inside pill, below mention if present) ──
    if replyBannerVisible || replyBannerAnimatingOut || !replyBanner.isHidden {
      let replyBannerY: CGFloat = 6 + mentionBannerExtra
      let bannerW = max(1, actualPillW - 16)
      replyBanner.frame = CGRect(x: 8, y: replyBannerY, width: bannerW, height: replyBannerContentH)
      layoutReplyBannerContents()
    }

    // ── Attachment preview layout (inside pill, below reply banner if present) ──
    if attachmentPreviewVisible {
      let attachmentPreviewY: CGFloat = 6 + mentionBannerExtra + replyBannerExtra
      let bannerW = max(1, actualPillW - 16)
      attachmentPreviewScroll.frame = CGRect(x: 8, y: attachmentPreviewY, width: bannerW, height: attachmentPreviewContentH)
    }

    // ── Slash suggestion layout (inside pill, below attachment preview if present) ──
    if slashSuggestionVisible {
      let slashSuggestionY: CGFloat = 6 + mentionBannerExtra + replyBannerExtra + attachmentPreviewExtra
      let bannerW = max(1, actualPillW - 16)
      slashSuggestionScroll.frame = CGRect(x: 8, y: slashSuggestionY, width: bannerW, height: slashSuggestionContentH)
    }

    let tfX = textInsetH + inlineAttachReserve
    let tfW = max(
      1,
      actualPillW - textInsetH * 2 - inlineAttachReserve - sendActionReserve - gifTextReserve
    )
    let tfY = bannerExtra + (clampedTextH + textInsetV * 2 - clampedTextH) / 2
    let minimumTextContentH = ceil(textView.font?.lineHeight ?? 0)
    let fittedTextH = min(clampedTextH, max(minimumTextContentH, textH))
    let textCenterOffsetY = max(0, (clampedTextH - fittedTextH) / 2)
    textView.frame = CGRect(
      x: tfX, y: tfY + textCenterOffsetY, width: tfW, height: fittedTextH)
    placeholderLabel.frame = CGRect(x: tfX + 2, y: tfY, width: tfW - 4, height: clampedTextH)
    let inlineButtonY = textRowBottom - 36.0 - max(2.0, (minPillH - 36.0) * 0.5)
    inlineAttachButton.frame = CGRect(
      x: 4.0,
      y: inlineButtonY,
      width: 36.0,
      height: 36.0
    )
    inlineAttachButton.isHidden = true
    // Slash-command button is removed in the new UI.
    slashButton.isHidden = true
    let gifTrailingInsetCollapsed: CGFloat = 6
    let gifTrailingInsetExpanded: CGFloat = 2
    let gifTrailingInset =
      gifTrailingInsetCollapsed
      - ((gifTrailingInsetCollapsed - gifTrailingInsetExpanded) * clampedSendProgress)
    let gifX = actualPillW - gifTrailingInset - sendActionReserve - gifButtonSize
    let textRowTop = bannerExtra
    let gifY = textRowTop + (textRowH - gifButtonSize) * 0.5
    gifButton.frame = CGRect(
      x: gifX,
      y: gifY,
      width: gifButtonSize,
      height: gifButtonSize
    )
    gifButton.isHidden = isRecording

    if isRecording, recordingMode == .video {
      let inset = bounds.height
      if let recorder = videoNoteRecorderController, abs(recorder.bottomChromeInset - inset) > 0.5 {
        recorder.bottomChromeInset = inset
        recorder.view.setNeedsLayout()
      }
    }

    // Recording UI Layout
    if isRecording {
      let isVideo = recordingMode == .video
      let showVideoTrash = isVideo && isLocked
      let trashSide: CGFloat = showVideoTrash ? 32 : 0
      let thumbSide: CGFloat = isVideoNotePaused ? 30 : 0
      let pauseSide: CGFloat = (isVideo && isLocked) ? 36 : 0
      let leadingChrome: CGFloat =
        16 + trashSide + (trashSide > 0 ? 8 : 0) + (thumbSide > 0 ? thumbSide + 8 : 0)

      if isVideoNotePaused, !videoNoteDraftThumbView.isHidden {
        videoNoteDraftThumbView.frame = CGRect(
          x: 8 + trashSide + (trashSide > 0 ? 8 : 0),
          y: (pillH - thumbSide) / 2,
          width: thumbSide,
          height: thumbSide
        )
        videoNoteDraftThumbView.layer.cornerRadius = thumbSide / 2
        recordingDot.frame = .zero
      } else {
        videoNoteDraftThumbView.frame = .zero
        let dotSize: CGFloat = 6
        recordingDot.frame = CGRect(
          x: trashSide > 0 ? (8 + trashSide + 8) : 16,
          y: (pillH - dotSize) / 2, width: dotSize, height: dotSize)
        recordingDot.layer.cornerRadius = dotSize / 2
      }

      let timerSize = recordingTimerLabel.sizeThatFits(CGSize(width: actualPillW, height: pillH))
      recordingTimerLabel.frame = CGRect(
        x: max(28, leadingChrome),
        y: (pillH - timerSize.height) / 2,
        width: timerSize.width,
        height: timerSize.height
      )

      if pauseSide > 0 {
        videoNotePauseButton.frame = CGRect(
          x: recordingTimerLabel.frame.maxX + 10,
          y: (pillH - pauseSide) / 2,
          width: pauseSide,
          height: pauseSide
        )
      } else {
        videoNotePauseButton.frame = .zero
      }

      let cancelSize = slideToCancelLabel.sizeThatFits(CGSize(width: actualPillW, height: pillH))
      slideToCancelLabel.frame = CGRect(
        x: (actualPillW - cancelSize.width) / 2 + 20,
        y: (pillH - cancelSize.height) / 2,
        width: cancelSize.width,
        height: cancelSize.height
      )
      let chevronSize = CGSize(width: 12, height: 12)
      slideChevronView.frame = CGRect(
        x: slideToCancelLabel.frame.minX - chevronSize.width - 4,
        y: (pillH - chevronSize.height) / 2,
        width: chevronSize.width,
        height: chevronSize.height
      )
      if isLocked, isVideo {
        slideToCancelLabel.frame = .zero
        slideChevronView.frame = .zero
      }

      if !isLocked {
        let lockW: CGFloat = 40
        let lockH: CGFloat = 90
        lockHintHost.frame = CGRect(
          x: micGlass.center.x - (lockW / 2),
          y: micGlass.center.y - lockH - 40,
          width: lockW,
          height: lockH
        )
        lockPill.frame = lockHintHost.bounds
        lockPill.layer.cornerRadius = lockW / 2
        lockPill.clipsToBounds = true
        lockArrowView.frame = CGRect(x: (lockW - 12) / 2, y: 14, width: 12, height: 14)
        lockView.frame = CGRect(x: (lockW - 13) / 2, y: 52, width: 13, height: 17)
      }
    } else {
      videoNotePauseButton.frame = .zero
      videoNoteDraftThumbView.frame = .zero
      lockHintHost.isHidden = true
    }

    // Visible trash when a video note is locked/paused; full-pill hit for voice cancel.
    if isRecording, isLocked, recordingMode == .video {
      let trash: CGFloat = 32
      cancelOverlayButton.frame = CGRect(
        x: 8, y: (pillH - trash) / 2, width: trash, height: trash)
      let trashCfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
      cancelOverlayButton.setImage(
        UIImage(systemName: "trash.fill", withConfiguration: trashCfg), for: .normal)
      cancelOverlayButton.tintColor = .systemRed
      cancelOverlayButton.isUserInteractionEnabled = true
    } else {
      cancelOverlayButton.setImage(nil, for: .normal)
      cancelOverlayButton.frame = pillContainer.bounds
    }

    // ── Mention banner is now inside the pill — no floating layout needed ──

    // ── Pill border glow when @vibe mention is active ──
    updateMentionBorderGlow(pillFrame: pillContainer.frame)

    // ── View frame updates that should inherit UIView animations ──
    attachButton.frame = attachGlass.contentView.bounds
    micButton.frame = micGlass.contentView.bounds
    
    // Position Selection controls
    let selectionSideSize: CGFloat = 48.0
    let selectionBounds = CGRect(origin: .zero, size: CGSize(width: selectionSideSize, height: selectionSideSize))
    
    selectionDeleteGlass.bounds = selectionBounds
    selectionDeleteGlass.center = CGPoint(x: dynamicHPad + (selectionSideSize / 2), y: btnCenterY + selectionYOffset)
    selectionDeleteButton.frame = selectionDeleteGlass.contentView.bounds
    
    selectionShareOutsideGlass.bounds = selectionBounds
    selectionShareOutsideGlass.center = CGPoint(x: w / 2, y: btnCenterY + selectionYOffset)
    selectionShareOutsideButton.frame = selectionShareOutsideGlass.contentView.bounds
    
    selectionShareInsideGlass.bounds = selectionBounds
    selectionShareInsideGlass.center = CGPoint(x: w - dynamicHPad - (selectionSideSize / 2), y: btnCenterY + selectionYOffset)
    selectionShareInsideButton.frame = selectionShareInsideGlass.contentView.bounds
    
    let activeAlpha: CGFloat = isSelectionMode ? 1 : 0
    let normalAlpha: CGFloat = isSelectionMode ? 0 : 1
    
    [selectionDeleteGlass, selectionShareOutsideGlass, selectionShareInsideGlass].forEach {
      $0.alpha = activeAlpha
      $0.isHidden = !isSelectionMode && $0.alpha == 0
    }
    selectionDeleteButton.alpha = activeAlpha
    selectionDeleteButton.isHidden = !isSelectionMode && activeAlpha == 0
    
    attachGlass.alpha = normalAlpha
    pillGlass.alpha = normalAlpha
    micGlass.alpha = isSelectionMode ? 0 : micGlass.alpha // respect existing mic alpha logic if not selection mode

    if #available(iOS 26.0, *) {
      // Use native cornerConfiguration for liquid glass shapes
      attachGlass.cornerConfiguration = .capsule()
      micGlass.cornerConfiguration = .capsule()
      // Use uniformCorners for the pill instead of capsule, so it doesn't break banner layout
      pillGlass.cornerConfiguration = .uniformCorners(radius: .fixed(pillContainer.layer.cornerRadius))
      pillContainer.layer.cornerCurve = .continuous
      lockPill.cornerConfiguration = .capsule()
      [selectionDeleteGlass, selectionShareOutsideGlass, selectionShareInsideGlass].forEach {
        $0.cornerConfiguration = .capsule()
      }
    } else {
      attachGlass.layer.cornerRadius = attachGlass.bounds.height / 2
      micGlass.layer.cornerRadius = sideSize / 2
      pillGlass.layer.cornerRadius = pillContainer.layer.cornerRadius
      lockPill.layer.cornerRadius = lockPill.bounds.width / 2
      [selectionDeleteGlass, selectionShareOutsideGlass, selectionShareInsideGlass].forEach {
        $0.layer.cornerRadius = $0.bounds.height / 2
      }
    }

    // ── Layer-only updates (no implicit animation wanted) ──
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    sendGradient.frame = sendButton.bounds
    sendGradient.cornerRadius = 16

    backgroundGradientLayer.frame = backgroundMaskView.bounds

    refreshGlass()
    // Ensure icons render above per-button glass surfaces.
    if let attachImage = attachButton.imageView { attachButton.bringSubviewToFront(attachImage) }
    if let gifImage = gifButton.imageView { gifButton.bringSubviewToFront(gifImage) }
    if let micImage = micButton.imageView { micButton.bringSubviewToFront(micImage) }
    if let sendImage = sendButton.imageView { sendButton.bringSubviewToFront(sendImage) }
    if let cancelImage = cancelOverlayButton.imageView {
      cancelOverlayButton.bringSubviewToFront(cancelImage)
    }
    CATransaction.commit()

    if abs(prevH - barHeight) > 0.5 {
      delegate?.inputBarHeightDidChange()
    }

    if chatGapDebugOverlayEnabled {
      bringSubviewToFront(gapDebugBarOverlay)
    }
    bringSubviewToFront(contentRow)
    contentRow.bringSubviewToFront(attachGlass)
    contentRow.bringSubviewToFront(pillGlass)
    // Mic / hold affordance MUST sit above the input pill text (was behind it).
    contentRow.bringSubviewToFront(micVADView)
    contentRow.bringSubviewToFront(micGlass)
    if isRecording, !isLocked {
      contentRow.bringSubviewToFront(lockHintHost)
    }
    pillContainer.bringSubviewToFront(sendButton)
    pillContainer.bringSubviewToFront(gifButton)
    pillContainer.bringSubviewToFront(videoNotePauseButton)
    pillContainer.bringSubviewToFront(videoNoteDraftThumbView)
    pillContainer.bringSubviewToFront(cancelOverlayButton)
    if mentionBannerVisible || !mentionBanner.isHidden {
      pillContainer.bringSubviewToFront(mentionBanner)
    }
    if replyBannerVisible || replyBannerAnimatingOut || !replyBanner.isHidden {
      pillContainer.bringSubviewToFront(replyBanner)
    }
    // Selection actions must sit above attach/pill/mic or taps never land
    // (esp. agent control mode + iOS 26 glass).
    if isSelectionMode {
      contentRow.bringSubviewToFront(selectionDeleteGlass)
      contentRow.bringSubviewToFront(selectionShareOutsideGlass)
      contentRow.bringSubviewToFront(selectionShareInsideGlass)
      selectionDeleteGlass.contentView.bringSubviewToFront(selectionDeleteButton)
      if let deleteImage = selectionDeleteButton.imageView {
        selectionDeleteButton.bringSubviewToFront(deleteImage)
      }
      applySelectionInteractionState()
    }

  }

  // MARK: - Glass

  /// Each interactive element (attach button, pill, mic button) has its own
  /// glass surface. On iOS 26+ we use UIGlassEffect for native liquid glass;
  /// on older iOS we fall back to UIBlurEffect(style: .systemMaterial).
  private func refreshGlass() {
    if #available(iOS 26.0, *) {
      // Clear glass, same family as the header chips: a plate tint reads as flat gray.
      func makeGlassEffect() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        effect.tintColor = .clear
        return effect
      }
      attachGlass.effect = makeGlassEffect()
      micGlass.effect = makeGlassEffect()
      pillGlass.effect = makeGlassEffect()
      pillGlass.contentView.backgroundColor = .clear

      let lockEffect = UIGlassEffect()
      lockEffect.isInteractive = true
      lockPill.effect = lockEffect
      lockPill.contentView.backgroundColor = UIColor(white: 0.1, alpha: 0.2)
      
      [selectionDeleteGlass, selectionShareOutsideGlass, selectionShareInsideGlass].forEach {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        $0.effect = effect
      }
    } else {
      attachGlass.effect = UIBlurEffect(style: .systemMaterial)
      micGlass.effect = UIBlurEffect(style: .systemMaterial)
      pillGlass.effect = UIBlurEffect(style: .systemMaterial)
      pillGlass.contentView.backgroundColor = pillTint
      lockPill.effect = UIBlurEffect(style: .systemMaterialDark)
      lockPill.contentView.backgroundColor = UIColor(white: 0.1, alpha: 0.2)
      
      [selectionDeleteGlass, selectionShareOutsideGlass, selectionShareInsideGlass].forEach {
        $0.effect = UIBlurEffect(style: .systemMaterial)
      }
    }
  }

  private func applyControlGlyph(
    button: UIButton,
    symbolName: String,
    symbolConfig: UIImage.SymbolConfiguration,
    tintColor: UIColor
  ) {
    let image = UIImage(systemName: symbolName, withConfiguration: symbolConfig)

    button.setImage(image, for: .normal)
    button.tintColor = tintColor
  }

  private func gifGlyphTint(active: Bool) -> UIColor {
    UIColor(white: active ? 0.72 : 0.58, alpha: 0.92)
  }

  private func applyComposerRecordGlyph(to button: UIButton, tintColor: UIColor) {
    if isVideoMode {
      let image = chatVideoNoteGlyphImage(size: CGSize(width: 22, height: 22))
      button.setImage(image, for: .normal)
      button.tintColor = tintColor
    } else {
      applyControlGlyph(
        button: button,
        symbolName: "mic",
        symbolConfig: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium),
        tintColor: tintColor)
    }
  }

  private func setVideoNotePauseGlyph(paused: Bool) {
    let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let name = paused ? "play.fill" : "pause.fill"
    videoNotePauseButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
  }

  private func morphComposerRecordIcon() {
    let tint = appearance.textColorThem.withAlphaComponent(0.9)
    let incoming = micButton.imageView
    let outgoing = incoming?.snapshotView(afterScreenUpdates: false)
    applyComposerRecordGlyph(to: micButton, tintColor: tint)
    incoming?.transform = CGAffineTransform(translationX: 0, y: 9).scaledBy(x: 0.72, y: 0.72)
    if let outgoing, let incoming {
      outgoing.frame = incoming.frame
      micButton.addSubview(outgoing)
      UIView.animate(
        withDuration: 0.28,
        delay: 0,
        usingSpringWithDamping: 0.78,
        initialSpringVelocity: 0.4,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        outgoing.transform = CGAffineTransform(translationX: 0, y: -10).scaledBy(x: 0.7, y: 0.7)
        incoming.transform = .identity
      } completion: { _ in
        outgoing.removeFromSuperview()
      }
    } else {
      UIView.animate(
        withDuration: 0.24,
        delay: 0,
        usingSpringWithDamping: 0.82,
        initialSpringVelocity: 0.3,
        options: [.beginFromCurrentState]
      ) {
        incoming?.transform = .identity
      }
    }
  }

  // MARK: - Button states

  private func updateButtonStates(animated: Bool = false) {
    let has = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let showSend = has || !pendingAttachmentBlobs.isEmpty || isAgentStreaming
    let sendSymbol = isAgentStreaming ? "stop.fill" : "paperplane.fill"
    let sendPointSize: CGFloat = isAgentStreaming ? 11 : 13
    sendButton.setImage(
      UIImage(
        systemName: sendSymbol,
        withConfiguration: UIImage.SymbolConfiguration(
          pointSize: sendPointSize,
          weight: isAgentStreaming ? .semibold : .regular
        )
      ),
      for: .normal
    )
    sendButton.accessibilityLabel = isAgentStreaming ? "Stop response" : "Send"

    // Inline send button in pill, with mic slot collapsing on the right.
    let targetProgress: CGFloat = showSend ? 1 : 0
    let hiddenSendTransform = CGAffineTransform(translationX: 10, y: 2).scaledBy(x: 0.84, y: 0.84)

    let changes = {
      self.sendProgress = targetProgress

      // Mic State
      self.micGlass.alpha = showSend ? 0 : 1
      self.micGlass.transform =
        showSend
        ? CGAffineTransform(translationX: 8, y: 0).scaledBy(x: 0.88, y: 0.88)
        : .identity
      // Selection mode owns interaction for the bottom chrome.
      if !self.isSelectionMode {
        self.micGlass.isUserInteractionEnabled = !showSend
        self.micButton.isUserInteractionEnabled = !showSend
      }

      // GIF State (moves in toward Send area while Send expands)
      self.gifButton.alpha = showSend ? 0.9 : 1.0
      // No inward slide: it walked the glyph into the send button as that one entered.
      self.gifButton.transform =
        showSend ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity

      // Send State
      self.sendButton.alpha = showSend ? 1 : 0
      self.sendButton.transform =
        showSend
        ? .identity
        : hiddenSendTransform
      if !self.isSelectionMode {
        self.sendButton.isUserInteractionEnabled = showSend
      }

      self.micGlass.isHidden = false
      self.sendButton.isHidden = false
      self.setNeedsLayout()
      self.layoutIfNeeded()
      if self.isSelectionMode {
        self.applySelectionInteractionState()
      }
    }

    if animated {
      UIView.animate(
        withDuration: 0.26,
        delay: 0,
        usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0.35,
        options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
        animations: changes
      )
    } else {
      changes()
    }
  }

  private func applyPlaceholder() {
    placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
  }

  /// Matches the keyboard intersection and aligns both surfaces to one device-pixel edge.
  private func matchedKeyboardPanelHeight() -> CGFloat {
    let scale = max(traitCollection.displayScale, 1)
    func aligned(_ height: CGFloat) -> CGFloat {
      (height * scale).rounded() / scale
    }
    if keyboardHeightForPanels > 0 { return aligned(keyboardHeightForPanels) }
    if lastKnownKeyboardHeight > 0 { return aligned(lastKnownKeyboardHeight) }
    // Nothing this launch — fall back to the last height this device actually measured.
    // Without this a cold launch has no keyboard number at all and lands on a constant
    // that matches no real keyboard, which is the state the log above was captured in.
    if Self.persistedKeyboardHeight > 0 { return aligned(Self.persistedKeyboardHeight) }
    return defaultGifPanelHeight
  }

  /// Panel height always matches the keyboard slot. Search focus does not grow the panel
  /// (that shoved the composer offscreen); the host lifts the bar via `isGifPanelSearchActive`.
  private func preferredGifPanelHeight() -> CGFloat {
    matchedKeyboardPanelHeight()
  }

  private func handleGifPanelPreferredHeightChange() {
    guard gifPanelVisible else { return }
    setNeedsLayout()
    layoutIfNeeded()
    superview?.setNeedsLayout()
    superview?.layoutIfNeeded()
    delegate?.inputBarHeightDidChange()
  }

  /// Creates the GIF panel on first use. Must only be called from present paths.
  @discardableResult
  private func loadGifPanelIfNeeded() -> ChatGifPanelView {
    if let panel = gifPanelIfLoaded { return panel }
    let panel = ChatGifPanelView()
    panel.delegate = self
    panel.onPreferredHeightChange = { [weak self] in
      self?.handleGifPanelPreferredHeightChange()
    }
    panel.isHidden = true
    panel.alpha = 0
    gifPanelIfLoaded = panel
    return panel
  }

  private func maybePrepareGifPanel() {
    guard window != nil, let panel = gifPanelIfLoaded else { return }
    // Host MUST own the panel's superview or the Giphy child controller asserts on
    // its parent. The panel is a subview of the conversation's view, so that is the host.
    panel.hostViewController = gifPanelHostController ?? findViewController()
    panel.prepareIfNeeded()
  }

  private func accessoryLayoutProgress() -> CGFloat {
    max(keyboardProgress, gifPanelVisible ? 1.0 : 0.0)
  }

  private func accessoryHorizontalPadding() -> CGFloat {
    26.0 - (16.0 * accessoryLayoutProgress())
  }


  /// Hosts the panel inside the conversation's own view.
  ///
  /// It used to live in a separate `UIWindow` above alert level, which is why it painted
  /// over Home, outlived the chat, and sat above system alerts. Containment removes all
  /// three: pop takes the panel with it.
  ///
  /// Host must be set BEFORE `prepareIfNeeded`, and must own the panel's superview — the
  /// Giphy child controller asserts on its parent otherwise.
  @discardableResult
  private func ensureGifPanelHost() -> UIViewController? {
    guard let host = findViewController() else { return nil }
    let panel = loadGifPanelIfNeeded()
    if panel.superview !== host.view {
      panel.removeFromSuperview()
      // Below the composer so the bar keeps reading on top of the panel.
      host.view.insertSubview(panel, belowSubview: self)
    }
    panel.hostViewController = host
    gifPanelHostController = host
    return host
  }

  private func tearDownGifPanelHostIfNeeded() {
    guard let panel = gifPanelIfLoaded else { return }
    panel.setPanelVisible(false)
    panel.removeFromSuperview()
    panel.isHidden = true
    panel.transform = .identity
    panel.hostViewController = nil
    gifPanelHostController = nil
  }

  private func desiredGifPanelFrame() -> CGRect {
    let panelHeight = preferredGifPanelHeight()
    guard let host = gifPanelHostController?.view else {
      // Inline: occupy the reserved bottom slice of the bar (flush, no gap).
      return CGRect(
        x: 0, y: max(0, bounds.height - panelHeight), width: max(1, bounds.width),
        height: panelHeight)
    }
    return CGRect(
      x: 0,
      y: host.bounds.maxY - (isGifPanelSearchActive ? keyboardHeightForPanels : 0) - panelHeight,
      width: host.bounds.width,
      height: panelHeight
    )
  }

  private func updateGifPanelOverlayFrame() {
    guard gifPanelVisible, ensureGifPanelHost() != nil else { return }
    let panel = loadGifPanelIfNeeded()
    // During a show/hide the transition owns the slide — see `gifPanelTransitionInFlight`.
    // Reassigning it here mid-slide is what let the panel jump between sizes on open.
    if !gifPanelTransitionInFlight {
      setGifPanelFrameKeepingTransform(panel, desiredGifPanelFrame())
    }
    panel.isHidden = false
    debugLogGifPanelGeometryIfNeeded(context: "updateGifPanelOverlayFrame")
  }

  /// `frame` is undefined while a transform is applied, so drop it, resize, put it back.
  private func setGifPanelFrameKeepingTransform(_ panel: UIView, _ frame: CGRect) {
    let transform = panel.transform
    if transform.isIdentity {
      panel.frame = frame
      return
    }
    panel.transform = .identity
    panel.frame = frame
    panel.transform = transform
  }

  private func debugLogGifPanelGeometryIfNeeded(context: String) {
    guard gifPanelVisible, let host = gifPanelHostController?.view,
      let panel = gifPanelIfLoaded
    else { return }
    let signature = [
      context,
      NSCoder.string(for: frame),
      NSCoder.string(for: bounds),
      NSCoder.string(for: safeAreaInsets),
      NSCoder.string(for: panel.frame),
      NSCoder.string(for: host.bounds),
      String(format: "%.1f", preferredGifPanelHeight()),
      String(format: "%.1f", bottomSafeAreaInset),
      String(format: "%.1f", keyboardHeightForPanels),
    ].joined(separator: "|")
    guard signature != lastGifPanelGeometrySignature else { return }
    lastGifPanelGeometrySignature = signature
    NSLog(
      "[ChatGifPanelHostDebug] context=%@ inputFrame=%@ inputBounds=%@ inputSafe=%@ panelFrame=%@ overlayFrame=%@ preferredHeight=%.1f bottomSafe=%.1f keyboardHeight=%.1f",
      context,
      NSCoder.string(for: frame),
      NSCoder.string(for: bounds),
      NSCoder.string(for: safeAreaInsets),
      NSCoder.string(for: panel.frame),
      NSCoder.string(for: host.bounds),
      preferredGifPanelHeight(),
      bottomSafeAreaInset,
      keyboardHeightForPanels
    )
  }

  private func setGifPanelVisible(_ visible: Bool, animated: Bool) {
    if !visible {
      // A second close cancels a deferred open before the keyboard finishes hiding.
      if pendingGifPanelOpen {
        pendingGifPanelOpen = false
        gifButton.tintColor = gifGlyphTint(active: false)
        if !gifPanelVisible {
          return
        }
      }
    } else if keyboardHeightForPanels > 0 {
      // Keyboard still owns the slot — dismiss it and present only after height hits zero.
      pendingGifPanelOpen = true
      window?.endEditing(true)
      gifButton.tintColor = gifGlyphTint(active: true)
      return
    } else {
      pendingGifPanelOpen = false
    }

    guard visible != gifPanelVisible else { return }
    // Hide path must not force-create the panel.
    if !visible, gifPanelIfLoaded == nil {
      gifPanelVisible = false
      return
    }
    let panel = loadGifPanelIfNeeded()
    gifPanelVisible = visible
    gifButton.tintColor = gifGlyphTint(active: visible)

    let applyChanges = {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    // The keyboard's real duration and curve, as reported by its last notification.
    let motionDuration = keyboardAnimation.duration
    let motionOptions: UIView.AnimationOptions = [
      keyboardAnimation.options, .allowUserInteraction, .beginFromCurrentState,
    ]
    let entryOptions: UIView.AnimationOptions = [
      keyboardAnimation.options, .allowUserInteraction,
    ]

    if visible {
      // Panel and keyboard share one slot — never present while a keyboard is still up.
      window?.endEditing(true)
      let shouldAnimate = animated

      // Host first, then prepare — never reverse this order.
      _ = ensureGifPanelHost()
      maybePrepareGifPanel()
      panel.setPanelVisible(true)
      panel.layer.removeAllAnimations()

      gifPanelTransitionInFlight = true
      // Slide on `transform`, never on `frame`. A freshly created panel still has a zero
      // frame, and animating that grows it out of the top-left corner instead of rising.
      // Seeded outside any ambient animation so the offset itself never animates.
      let finalFrame = desiredGifPanelFrame()
      UIView.performWithoutAnimation {
        panel.alpha = 1
        panel.isHidden = false
        panel.transform = .identity
        panel.frame = finalFrame
        panel.layoutIfNeeded()
        if shouldAnimate {
          panel.transform = CGAffineTransform(translationX: 0, y: finalFrame.height)
        }
      }

      if shouldAnimate {
        UIView.animate(
          withDuration: motionDuration, delay: 0, options: entryOptions,
          animations: {
            applyChanges()
            panel.transform = .identity
          },
          completion: { [weak self] _ in
            panel.transform = .identity
            self?.gifPanelTransitionInFlight = false
          }
        )
      } else {
        applyChanges()
        gifPanelTransitionInFlight = false
      }
      return
    }

    panel.setPanelVisible(false)
    panel.layer.removeAllAnimations()
    gifPanelTransitionInFlight = true
    let finishHide = { [weak self] in
      panel.transform = .identity
      panel.isHidden = true
      if let self {
        panel.frame = self.desiredGifPanelFrame()
      }
      self?.gifPanelTransitionInFlight = false
    }

    if animated {
      let exitTransform = CGAffineTransform(
        translationX: 0, y: max(1, panel.bounds.height))
      UIView.animate(
        withDuration: motionDuration, delay: 0, options: motionOptions,
        animations: {
          applyChanges()
          panel.transform = exitTransform
        },
        completion: { _ in finishHide() }
      )
    } else {
      applyChanges()
      finishHide()
    }
  }

  // MARK: - Actions

  @objc private func gifTapped() {
    if pendingGifPanelOpen {
      setGifPanelVisible(false, animated: true)
      return
    }
    setGifPanelVisible(!gifPanelVisible, animated: true)
  }

  /// Close the panel from outside — used the moment a pick is committed, so the panel
  /// leaves on the same beat the message appears rather than after the send round-trips.
  func dismissGifPanel(animated: Bool) {
    setGifPanelVisible(false, animated: animated)
  }


  @objc private func inlineAttachTapped() {
    presentAttachmentSheet(sourceView: inlineAttachButton)
  }

  /// Default (non-agent) chat: + opens the full attachment tab sheet.
  @objc private func attachButtonTapped() {
    guard !agentControlMode else { return }
    presentAttachmentSheet(sourceView: attachButton)
  }

  private func presentAttachmentSheet(sourceView: UIView) {
    setGifPanelVisible(false, animated: false)
    // Show native attachment sheet (Gallery | File | Location) — default chat path.
    guard let vc = findViewController() else {
      delegate?.inputBarDidTapAttachment()
      return
    }
    let sheet = ChatAttachmentMenuController(appearance: appearance)
    sheet.recipientName = attachRecipientName
    sheet.sourceButtonView = sourceView
    if let window = vc.view.window {
      sheet.sourceButtonFrameInWindow = sourceView.convert(sourceView.bounds, to: window)
    } else {
      sheet.sourceButtonFrameInWindow = sourceView.convert(sourceView.bounds, to: nil)
    }
    sheet.onSelectImage = { [weak self] uri, caption, transitionCapture in
      self?.attachmentSheet = nil
      self?.delegate?.inputBarDidSelectImage(
        uri: uri,
        caption: caption,
        transitionCapture: transitionCapture
      )
    }
    sheet.onSelectImages = { [weak self] uris, caption, transitionCapture in
      self?.attachmentSheet = nil
      self?.delegate?.inputBarDidSelectImages(
        uris: uris,
        caption: caption,
        transitionCapture: transitionCapture
      )
    }
    sheet.onSelectFile = { [weak self] uri, name in
      self?.attachmentSheet = nil
      self?.delegate?.inputBarDidSelectFile(uri: uri, name: name)
    }
    sheet.onSelectLocation = { [weak self] lat, lon in
      self?.attachmentSheet = nil
      self?.delegate?.inputBarDidSelectLocation(latitude: lat, longitude: lon)
    }
    sheet.onSelectText = { [weak self] text in
      self?.attachmentSheet = nil
      self?.delegate?.inputBarDidSend(text: text, attachments: [], imageLocalURIs: [])
    }
    attachmentSheet = sheet
    vc.present(sheet, animated: true)
  }

  @objc private func micTapped() {
    if suppressNextMicTap {
      suppressNextMicTap = false
      return
    }
    setGifPanelVisible(false, animated: true)
    // Agent DM: the mic is a dictation toggle — transcribe speech into the composer
    // text instead of recording a voice message the agent can't consume.
    if agentControlMode {
      toggleAgentDictation()
      return
    }
    // Paused video note: mic sends; tap the draft thumb to resume.
    if isRecording, isLocked, recordingMode == .video, isVideoNotePaused {
      finishActiveRecording()
      return
    }
    if isRecording && isLocked {
      finishActiveRecording()
      return
    }
    if isRecording {
      return
    }
    if isVideoRecordingActive {
      return
    }

    isVideoMode.toggle()
    morphComposerRecordIcon()
  }

  @objc private func handleSelectionDelete() {
    NSLog(
      "[ChatShare] inputBar tap delete selectionMode=%@ delegate=%@",
      isSelectionMode ? "Y" : "N",
      delegate != nil ? "Y" : "N"
    )
    let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "Delete for me", style: .destructive, handler: { _ in
      self.delegate?.inputBarDidRequestSelectionAction("delete", payload: ["forEveryone": false])
    }))
    alert.addAction(UIAlertAction(title: "Delete for both", style: .destructive, handler: { _ in
      self.delegate?.inputBarDidRequestSelectionAction("delete", payload: ["forEveryone": true])
    }))
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
    
    // Find the view controller to present the alert
    if let window = self.window, let rootVC = window.rootViewController {
      var topVC = rootVC
      while let presented = topVC.presentedViewController {
        topVC = presented
      }
      topVC.present(alert, animated: true, completion: nil)
    } else {
      NSLog("[ChatShare] inputBar delete alert FAILED: no window/rootVC")
    }
  }
  @objc private func handleSelectionShareOutside() {
    NSLog(
      "[ChatShare] inputBar tap shareOutside selectionMode=%@ delegate=%@ agentControl=%@",
      isSelectionMode ? "Y" : "N",
      delegate != nil ? "Y" : "N",
      agentControlMode ? "Y" : "N"
    )
    guard let delegate else {
      NSLog("[ChatShare] inputBar shareOutside FAILED: nil delegate")
      return
    }
    delegate.inputBarDidRequestSelectionAction("shareOutside", payload: nil)
  }
  @objc private func handleSelectionShareInside() {
    NSLog(
      "[ChatShare] inputBar tap shareInside selectionMode=%@ delegate=%@ agentControl=%@",
      isSelectionMode ? "Y" : "N",
      delegate != nil ? "Y" : "N",
      agentControlMode ? "Y" : "N"
    )
    guard let delegate else {
      NSLog("[ChatShare] inputBar shareInside FAILED: nil delegate")
      return
    }
    delegate.inputBarDidRequestSelectionAction("shareInside", payload: nil)
  }

  @objc private func sendTapped() {
    if isAgentStreaming {
      delegate?.inputBarDidRequestStopStreaming()
      return
    }

    // Forward draft: allow empty caption — just send the forwarded messages.
    if activeForwardDraft {
      let t = currentText
      setMentionBannerVisible(false, animated: false)
      delegate?.inputBarDidConfirmForward(caption: t)
      clearText()
      dismissReplyBanner(animated: true)
      return
    }

    let t = currentText
    guard !t.isEmpty || !pendingAttachmentBlobs.isEmpty else { return }

    if let editId = activeEditMessageId {
      setMentionBannerVisible(false, animated: false)
      delegate?.inputBarDidSubmitEdit(messageId: editId, text: t)
      clearText()
      dismissReplyBanner(animated: true)
      return
    }

    switch resolveMentionIntent(in: t) {
    case .builder:
      setMentionBannerVisible(false, animated: false)
      clearText()
      delegate?.inputBarDidRequestVibeAgentBuilder()

    case .group(let agentText):
      guard !agentText.isEmpty else {
        textView.becomeFirstResponder()
        return
      }
      setMentionBannerVisible(false, animated: false)
      let attachments = pendingAttachmentBlobs
      let imageURIs = pendingImageLocalURIs
      clearPendingAttachments()
      delegate?.inputBarDidSendWithAgentMention(
        text: t, agentText: agentText, attachments: attachments, imageLocalURIs: imageURIs)
      clearText()

    case .team:
      setMentionBannerVisible(false, animated: false)
      let attachments = pendingAttachmentBlobs
      let imageURIs = pendingImageLocalURIs
      clearPendingAttachments()
      delegate?.inputBarDidSend(
        text: t, attachments: attachments, imageLocalURIs: imageURIs)
      clearText()

    case .standalone(let username, let agentText):
      guard !agentText.isEmpty else {
        textView.becomeFirstResponder()
        return
      }
      setMentionBannerVisible(false, animated: false)
      let attachments = pendingAttachmentBlobs
      let imageURIs = pendingImageLocalURIs
      clearPendingAttachments()
      delegate?.inputBarDidSendWithStandaloneAgentMention(
        text: t,
        agentText: agentText,
        agentUsername: username,
        attachments: attachments,
        imageLocalURIs: imageURIs
      )
      clearText()

    case .none:
      setMentionBannerVisible(false, animated: false)
      let attachments = pendingAttachmentBlobs
      let imageURIs = pendingImageLocalURIs
      clearPendingAttachments()
      delegate?.inputBarDidSend(
        text: t, attachments: attachments, imageLocalURIs: imageURIs)
      clearText()
    }
  }

  private func clearPendingAttachments() {
    pendingImages.removeAll()
    pendingAttachmentBlobs.removeAll()
    pendingImageLocalURIs.removeAll()
    updateAttachmentPreviewVisibility()
  }

  @objc private func mentionBannerTapped() {
    switch readyBannerAction {
    case .none:
      return

    case .mention(let suggestion):
      let text = textView.text ?? ""
      if let lastAtRange = text.range(of: "@", options: .backwards) {
        let beforeAt = text[text.startIndex..<lastAtRange.lowerBound]
        textView.text = beforeAt + suggestion.insertion
      } else {
        textView.text = (text.isEmpty ? "" : text + " ") + suggestion.insertion
      }
      setMentionActive(true)

    case .slash(let suggestion):
      applySlashSuggestion(suggestion)
    }

    setReadyBannerAction(.none, animated: true)
    textViewDidChange(textView)
    textView.becomeFirstResponder()
  }

  private func setMentionBannerVisible(_ visible: Bool, animated: Bool) {
    guard mentionBannerVisible != visible else { return }
    mentionBannerVisible = visible

    if visible {
      mentionBanner.isHidden = false
      mentionBanner.alpha = 0

      if animated {
        UIView.animate(
          withDuration: 0.28, delay: 0,
          usingSpringWithDamping: 0.82, initialSpringVelocity: 0.5,
          options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
          self.mentionBanner.alpha = 1
          self.setNeedsLayout()
          self.layoutIfNeeded()
          self.superview?.setNeedsLayout()
          self.superview?.layoutIfNeeded()
        }
      } else {
        mentionBanner.alpha = 1
        setNeedsLayout()
        layoutIfNeeded()
      }
    } else {
      if animated {
        UIView.animate(
          withDuration: 0.2, delay: 0,
          options: [.curveEaseIn, .allowUserInteraction, .beginFromCurrentState]
        ) {
          self.mentionBanner.alpha = 0
          self.setNeedsLayout()
          self.layoutIfNeeded()
          self.superview?.setNeedsLayout()
          self.superview?.layoutIfNeeded()
        } completion: { _ in
          if !self.mentionBannerVisible {
            self.mentionBanner.isHidden = true
          }
        }
      } else {
        mentionBanner.alpha = 0
        mentionBanner.isHidden = true
        setNeedsLayout()
        layoutIfNeeded()
      }
    }
  }

  private func setReadyBannerAction(_ action: ReadyBannerAction, animated: Bool) {
    readyBannerAction = action

    switch action {
    case .none:
      setMentionBannerVisible(false, animated: animated)

    case .mention(let suggestion):
      mentionNameLabel.text = suggestion.token
      mentionDescLabel.text = suggestion.description
      setMentionBannerVisible(true, animated: animated)

    case .slash(let suggestion):
      mentionNameLabel.text = suggestion.command
      mentionDescLabel.text = suggestion.description
      setMentionBannerVisible(true, animated: animated)
    }
  }

  private func layoutMentionBannerContents() {
    let b = mentionBanner.bounds
    guard b.width > 0, b.height > 0 else { return }
    let pad: CGFloat = 8
    let accentW: CGFloat = 3
    mentionAccentBar.frame = CGRect(x: pad, y: (b.height - 28) / 2, width: accentW, height: 28)
    let textX = mentionAccentBar.frame.maxX + 8
    let textW = max(1, b.width - textX - pad)
    mentionNameLabel.frame = CGRect(x: textX, y: (b.height - 28) / 2, width: textW, height: 14)
    mentionDescLabel.frame = CGRect(
      x: textX, y: mentionNameLabel.frame.maxY + 1, width: textW, height: 14)
  }

  private func setMentionActive(_ active: Bool) {
    guard mentionActive != active else { return }
    mentionActive = active
    let agentColor =
      appearance.bubbleMeGradient.first ?? ChatListAppearance.brandAccentFallback
    UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      if active {
        self.pillGlass.layer.borderColor = agentColor.withAlphaComponent(0.55).cgColor
        self.pillGlass.layer.borderWidth = 1.2
      } else {
        self.pillGlass.layer.borderColor = UIColor.clear.cgColor
        self.pillGlass.layer.borderWidth = 0.0
      }
    }
  }

  private var supportsBuilderSlashCommands: Bool {
    let normalizedPlaceholder = placeholder.lowercased()
    return normalizedPlaceholder.contains("@vibeagent")
      || normalizedPlaceholder.contains("/command")
      || normalizedPlaceholder.contains("type /")
  }

  private func updateMentionBorderGlow(pillFrame: CGRect) {
    let textString = (textView.text ?? "").lowercased()
    let hasMention =
      textString.contains("@vibe") || textString.contains("@vibeagent")
      || textString.contains("@team") || textString.hasPrefix("/")
    if hasMention != mentionActive {
      setMentionActive(hasMention)
    }
  }

  private enum MentionIntent {
    case none
    case group(String)
    case team
    case builder
    case standalone(username: String, agentText: String)
  }

  private struct ReadyMentionSuggestion {
    let token: String
    let insertion: String
    let description: String
  }

  private struct ReadyCommandSuggestion {
    let command: String
    let insertion: String
    let description: String
  }

  private enum ReadyBannerAction {
    case none
    case mention(ReadyMentionSuggestion)
    case slash(ReadyCommandSuggestion)
  }

  private static let readyMentionSuggestions: [ReadyMentionSuggestion] = [
    ReadyMentionSuggestion(
      token: "@team", insertion: "@team ", description: "Coordinate all agents"
    ),
    ReadyMentionSuggestion(
      token: "@vibe", insertion: "@vibe ", description: "Ask the group agent"
    ),
  ]

  private static let builderSlashSuggestions: [ReadyCommandSuggestion] = [
    ReadyCommandSuggestion(command: "/newagent", insertion: "/newagent ", description: "Create a new agent"),
    ReadyCommandSuggestion(command: "/agents", insertion: "/agents", description: "List your agents"),
    ReadyCommandSuggestion(command: "/select", insertion: "/select ", description: "Select an existing draft"),
    ReadyCommandSuggestion(command: "/prompt", insertion: "/prompt ", description: "Set the system prompt"),
    ReadyCommandSuggestion(command: "/webhook", insertion: "/webhook ", description: "Set the callback URL"),
    ReadyCommandSuggestion(command: "/publish", insertion: "/publish", description: "Publish the active agent"),
    ReadyCommandSuggestion(command: "/secret", insertion: "/secret rotate", description: "Rotate the invoke secret"),
    ReadyCommandSuggestion(command: "/help", insertion: "/help", description: "Show builder help"),
  ]

  private func resolveMentionIntent(in text: String) -> MentionIntent {
    guard let regex = try? NSRegularExpression(
      pattern: "(?:^|\\s)@([A-Za-z0-9_]{3,30})\\b",
      options: [.caseInsensitive]
    ) else {
      return .none
    }

    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    let matches = regex.matches(in: text, options: [], range: range)
    let usernames = matches.compactMap { match -> String? in
      guard match.numberOfRanges > 1 else { return nil }
      let raw = nsText.substring(with: match.range(at: 1))
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return trimmed.isEmpty ? nil : trimmed
    }

    let unique = Array(NSOrderedSet(array: usernames)) as? [String] ?? []
    if unique.contains("vibeagent") {
      return .builder
    }

    guard unique.count == 1, let username = unique.first else {
      return .none
    }

    let stripped =
      text
      .replacingOccurrences(
        of: "@\(username)",
        with: "",
        options: [.caseInsensitive]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if username == "vibe" {
      return stripped.isEmpty ? .none : .group(stripped)
    }
    if username == "team" {
      return stripped.isEmpty ? .none : .team
    }

    return stripped.isEmpty ? .none : .standalone(username: username, agentText: stripped)
  }

  private func resolveReadyBannerAction(in text: String) -> ReadyBannerAction {
    if let suggestion = resolveSlashSuggestion(in: text) {
      return .slash(suggestion)
    }

    let mentionSuggestion: ReadyMentionSuggestion? = {
      guard !text.isEmpty else { return nil }
      guard let lastAtIndex = text.lastIndex(of: "@") else { return nil }
      let afterAt = text[text.index(after: lastAtIndex)...].lowercased()
      let isAtStart = lastAtIndex == text.startIndex
      let isPrecededBySpace = !isAtStart && text[text.index(before: lastAtIndex)] == " "
      guard isAtStart || isPrecededBySpace else { return nil }
      guard !afterAt.contains(" ") else { return nil }
      return Self.readyMentionSuggestions.first {
        let name = String($0.token.dropFirst()).lowercased()
        return name.hasPrefix(afterAt) || afterAt.isEmpty
      }
    }()

    return mentionSuggestion.map(ReadyBannerAction.mention) ?? .none
  }

  private func resolveSlashSuggestion(in text: String) -> ReadyCommandSuggestion? {
    guard supportsBuilderSlashCommands else { return nil }
    guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)(/[A-Za-z]*)$", options: []) else {
      return nil
    }

    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
      return nil
    }

    let token = nsText.substring(with: match.range(at: 1)).lowercased()
    guard token.hasPrefix("/") else { return nil }

    if token == "/" {
      return Self.builderSlashSuggestions.first
    }

    return Self.builderSlashSuggestions.first { $0.command.hasPrefix(token) }
  }

  private func applySlashSuggestion(_ suggestion: ReadyCommandSuggestion) {
    let text = textView.text ?? ""

    guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)(/[A-Za-z]*)$", options: []) else {
      textView.text = suggestion.insertion
      return
    }

    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)

    guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
      textView.text = suggestion.insertion
      return
    }

    let replacementRange = match.range(at: 1)
    let updated = nsText.replacingCharacters(in: replacementRange, with: suggestion.insertion)
    textView.text = updated
    textView.selectedRange = NSRange(location: (updated as NSString).length, length: 0)
  }

  @objc private func cancelOverlayTapped() {
    cancelActiveRecording()
  }

  private func findViewController() -> UIViewController? {
    var r: UIResponder? = self
    while let next = r?.next {
      if let vc = next as? UIViewController { return vc }
      r = next
    }
    return nil
  }

  // MARK: - Recording

  private func setupRecordingUI() {
    // Lock hint pill (hidden initially)
    lockHintHost.isHidden = true
    lockHintHost.isUserInteractionEnabled = false
    lockHintHost.clipsToBounds = false
    contentRow.addSubview(lockHintHost)
    lockPill.isHidden = false
    lockPill.isUserInteractionEnabled = false
    lockHintHost.addSubview(lockPill)
    lockArrowView.isHidden = false
    lockView.isHidden = false

    lockArrowView.tintColor = .white
    lockArrowView.contentMode = .scaleAspectFit
    lockHintHost.addSubview(lockArrowView)

    lockView.tintColor = .white
    lockView.contentMode = .scaleAspectFit
    lockHintHost.addSubview(lockView)

    // Slide To Cancel
    slideToCancelLabel.text = "Slide to cancel"
    slideToCancelLabel.font = .systemFont(ofSize: 15)
    slideToCancelLabel.textColor = .secondaryLabel
    slideToCancelLabel.isHidden = true
    pillContainer.addSubview(slideToCancelLabel)

    slideChevronView.tintColor = .secondaryLabel
    slideChevronView.contentMode = .scaleAspectFit
    slideChevronView.isHidden = true
    pillContainer.addSubview(slideChevronView)

    // Timer
    recordingTimerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    recordingTimerLabel.textColor = .label
    recordingTimerLabel.text = "0:00.00"
    recordingTimerLabel.isHidden = true
    pillContainer.addSubview(recordingTimerLabel)

    // Dot
    recordingDot.backgroundColor = .systemRed
    recordingDot.layer.cornerRadius = 3
    recordingDot.isHidden = true
    pillContainer.addSubview(recordingDot)

    // Video-note pause (inside input pill while locked + recording).
    let pauseCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    videoNotePauseButton.setImage(
      UIImage(systemName: "pause.fill", withConfiguration: pauseCfg), for: .normal)
    videoNotePauseButton.tintColor = appearance.textColorThem.withAlphaComponent(0.9)
    videoNotePauseButton.isHidden = true
    videoNotePauseButton.addTarget(
      self, action: #selector(handleVideoNotePauseTapped), for: .touchUpInside)
    pillContainer.addSubview(videoNotePauseButton)

    videoNoteDraftThumbView.contentMode = .scaleAspectFill
    videoNoteDraftThumbView.clipsToBounds = true
    videoNoteDraftThumbView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    videoNoteDraftThumbView.isHidden = true
    videoNoteDraftThumbView.layer.cornerCurve = .continuous
    videoNoteDraftThumbView.isUserInteractionEnabled = true
    let thumbTap = UITapGestureRecognizer(
      target: self, action: #selector(handleVideoNoteThumbResumeTapped))
    videoNoteDraftThumbView.addGestureRecognizer(thumbTap)
    pillContainer.addSubview(videoNoteDraftThumbView)

    // Gesture
    let longPress = UILongPressGestureRecognizer(
      target: self, action: #selector(handleMicGesture(_:)))
    longPress.minimumPressDuration = 0.2
    micButton.addGestureRecognizer(longPress)
  }

  @objc private func handleVideoNotePauseTapped() {
    guard recordingMode == .video, isRecording, isLocked else { return }
    if isVideoNotePaused {
      videoNoteRecorderController?.resumeRecording()
    } else {
      videoNoteRecorderController?.pauseRecording()
    }
  }

  @objc private func handleVideoNoteThumbResumeTapped() {
    guard recordingMode == .video, isRecording, isLocked, isVideoNotePaused else { return }
    videoNoteRecorderController?.resumeRecording()
  }

  @objc private func handleMicGesture(_ g: UILongPressGestureRecognizer) {
    // Agent DM: no hold-to-record — a plain tap toggles dictation (see micTapped).
    guard !agentControlMode else { return }
    switch g.state {
    case .began:
      suppressNextMicTap = true
      recordingGestureStartPoint = g.location(in: nil)
      recordingGestureLastPoint = recordingGestureStartPoint
      NSLog(
        "[VideoNote] longPress.began videoMode=%@ agent=%@ isRecording=%@",
        isVideoMode ? "Y" : "N",
        agentControlMode ? "Y" : "N",
        isRecording ? "Y" : "N"
      )
      if isVideoMode {
        startVideoRecording()
      } else {
        startVoiceRecording()
      }
    case .changed:
      guard isRecording, !isLocked else { return }
      if recordingMode == .video, let startedAt = recordingStartTime,
        Date().timeIntervalSince(startedAt) < 0.22
      {
        return
      }

      let point = g.location(in: nil)
      let stepDx = point.x - recordingGestureLastPoint.x
      let stepDy = point.y - recordingGestureLastPoint.y
      recordingGestureLastPoint = point
      // Inserting the full-screen video-note overlay under the finger (or a later
      // relayout while the touch is held) can make UIKit report an implausible
      // single-frame jump in touch location — a real finger never moves >120pt
      // between two consecutive .changed callbacks. Treat that as a coordinate
      // glitch and resync the baseline instead of reading it as slide-to-cancel,
      // which was silently killing recordings within ~1s of starting.
      if recordingMode == .video, hypot(stepDx, stepDy) > 120 {
        recordingGestureStartPoint = point
        return
      }

      let dy = point.y - recordingGestureStartPoint.y
      let dx = point.x - recordingGestureStartPoint.x

      lockHintHost.transform = CGAffineTransform(translationX: 0, y: min(0, (dy * 0.6) + 6))

      if dx < 0 && abs(dx) > abs(dy) {
        let stretchAmount = abs(max(-100, dx))
        self.micGlass.transform = CGAffineTransform(translationX: dx * 0.4, y: 0)
          .scaledBy(x: 1.4, y: 1.4)
        let sx = 2.4 + (stretchAmount / 36.0)
        let sy = max(1.4, 2.4 - (stretchAmount / 100.0))
        self.micVADView.transform = CGAffineTransform(translationX: (dx * 0.4) / 2.0, y: 0)
          .scaledBy(x: sx, y: sy)
      } else if dy < 0 {
        let stretchAmount = abs(max(-60, dy))
        self.micGlass.transform = CGAffineTransform(translationX: 0, y: dy * 0.6)
          .scaledBy(x: 1.4, y: 1.4)
        let sy = 2.4 + (stretchAmount / 36.0)
        let sx = max(1.4, 2.4 - (stretchAmount / 100.0))
        self.micVADView.transform = CGAffineTransform(translationX: 0, y: (dy * 0.6) / 2.0)
          .scaledBy(x: sx, y: sy)
      } else {
        self.micGlass.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        self.micVADView.transform = CGAffineTransform(scaleX: 2.4, y: 2.4)
      }

      if dy < -60 {
        lockActiveRecording()
      } else if dx < -100 {
        cancelActiveRecording()
        g.isEnabled = false  // Cancel gesture
        g.isEnabled = true
      }

    case .ended:
      if isRecording && !isLocked {
        finishActiveRecording()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.suppressNextMicTap = false
      }
    case .cancelled, .failed:
      // Inserting the video-note overlay into the hierarchy under the finger causes
      // UIKit to cancel this long-press. Do NOT treat that as "user cancelled" —
      // lock recording so trash/send stay available (Telegram-style hold→lock).
      NSLog(
        "[VideoNote] longPress.%@ mode=%@ recording=%@ locked=%@ videoActive=%@",
        g.state == .cancelled ? "cancelled" : "failed",
        recordingMode == .video ? "video" : (recordingMode == .voice ? "voice" : "none"),
        isRecording ? "Y" : "N",
        isLocked ? "Y" : "N",
        isVideoRecordingActive ? "Y" : "N"
      )
      if recordingMode == .video, isRecording || isVideoRecordingActive {
        if !isLocked {
          lockActiveRecording()
        }
        // Re-assert overlay z-order if it was installed mid-gesture.
        reassertVideoNoteOverlayZOrder()
      } else {
        cancelActiveRecording()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.suppressNextMicTap = false
      }
    default: break
    }
  }

  private func reassertVideoNoteOverlayZOrder() {
    guard let host = superview, let recorder = videoNoteRecorderController else { return }
    if let list = host as? ChatListView {
      list.installVideoNoteRecorderView(recorder.view, belowInput: self)
    } else if recorder.view.superview === host {
      host.insertSubview(recorder.view, belowSubview: self)
      host.bringSubviewToFront(self)
    }
  }

  private func startVoiceRecording() {
    recordingMode = .voice
    startRecording()
  }

  // MARK: - Agent dictation (speech → composer text)

  private func toggleAgentDictation() {
    if isDictating {
      stopAgentDictation()
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      DispatchQueue.main.async {
        guard let self, status == .authorized else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            guard granted else { return }
            self.startAgentDictation()
          }
        }
      }
    }
  }

  private func startAgentDictation() {
    guard let recognizer = dictationRecognizer, recognizer.isAvailable, !isDictating else { return }
    dictationTask?.cancel()
    dictationTask = nil

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    dictationRequest = request
    // Preserve anything already typed; append dictated text after it.
    let existing = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    dictationBaseText = existing.isEmpty ? "" : existing + " "

    let inputNode = dictationAudioEngine.inputNode
    dictationTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      // The recognition handler is called on an arbitrary queue; touch UI/audio on main.
      DispatchQueue.main.async {
        guard let self else { return }
        if let result {
          self.textView.text = self.dictationBaseText + result.bestTranscription.formattedString
          self.textViewDidChange(self.textView)
        }
        if error != nil || (result?.isFinal ?? false) {
          self.stopAgentDictation()
        }
      }
    }

    let format = inputNode.outputFormat(forBus: 0)
    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.dictationRequest?.append(buffer)
    }

    dictationAudioEngine.prepare()
    do {
      try dictationAudioEngine.start()
      isDictating = true
      updateAgentDictationAppearance()
    } catch {
      stopAgentDictation()
    }
  }

  private func stopAgentDictation() {
    if dictationAudioEngine.isRunning {
      dictationAudioEngine.stop()
      dictationAudioEngine.inputNode.removeTap(onBus: 0)
    }
    dictationRequest?.endAudio()
    dictationRequest = nil
    dictationTask?.cancel()
    dictationTask = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if isDictating {
      isDictating = false
      updateAgentDictationAppearance()
    }
  }

  private func updateAgentDictationAppearance() {
    UIView.transition(with: micButton, duration: 0.2, options: .transitionCrossDissolve) {
      let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
      self.applyControlGlyph(
        button: self.micButton,
        symbolName: self.isDictating ? "mic.fill" : "mic",
        symbolConfig: cfg,
        tintColor: self.isDictating
          ? .systemRed
          : self.appearance.textColorThem.withAlphaComponent(0.9)
      )
    }
  }

  private func startVideoRecording() {
    recordingMode = .video
    startRecording()
  }

  private func lockActiveRecording() {
    lockRecording()
  }

  private func cancelActiveRecording() {
    cancelRecording()
  }

  private func finishActiveRecording() {
    finishRecording()
  }

  @discardableResult
  private func startVideoNoteRecording() -> Bool {
    guard !isVideoRecordingActive else {
      NSLog("[VideoNote] start SKIP already active")
      return false
    }
    // Host inside ChatListView (our superview) so the input bar stays ABOVE the
    // overlay — original z-order. Full-screen modal put the composer behind.
    guard let hostView = superview else {
      NSLog("[VideoNote] start FAIL no superview")
      return false
    }
    guard let hostVC = findViewController() else {
      NSLog("[VideoNote] start FAIL no hostVC")
      return false
    }

    isVideoRecordingActive = true
    isVideoNotePaused = false
    videoNoteDraftDuration = 0
    videoNoteDraftThumb = nil

    let recorder = VideoNoteRecorderViewController()
    recorder.morphCoordinateView = hostView
    recorder.onFinished = { [weak self] url, duration, shouldSend, morphImage, morphFrame in
      guard let self else { return }
      NSLog(
        "[VideoNote] onFinished send=%@ url=%@ dur=%.2f",
        shouldSend ? "Y" : "N",
        url?.lastPathComponent ?? "nil",
        duration
      )
      self.videoNoteRecorderController = nil
      self.isVideoRecordingActive = false
      self.isVideoNotePaused = false
      self.videoNotePauseButton.isHidden = true
      self.videoNoteDraftThumbView.isHidden = true
      self.videoNoteDraftThumbView.image = nil
      if shouldSend, let url {
        // Morph first (list will hide the optimistic cell until flight ends).
        if let morphImage, morphFrame.width > 1 {
          NotificationCenter.default.post(
            name: .videoNoteReleaseMorph,
            object: nil,
            userInfo: [
              "image": morphImage,
              "frame": NSValue(cgRect: morphFrame),
              "uri": url.absoluteString,
              "duration": duration,
            ]
          )
        }
        self.delegate?.inputBarDidRecordVideoNote(
          uri: url.absoluteString,
          duration: duration
        )
      } else if self.pendingVideoStopShouldSend {
        self.delegate?.inputBarRecordingDidCancel()
      }
      self.pendingVideoStopShouldSend = true
    }
    recorder.onPaused = { [weak self] draftURL, duration in
      guard let self else { return }
      self.applyVideoNotePausedInputState(draftURL: draftURL, duration: duration)
    }
    recorder.onResumed = { [weak self] in
      self?.applyVideoNoteRecordingInputState()
    }
    recorder.onDurationTick = { [weak self] total in
      guard let self, self.recordingMode == .video, self.isRecording, !self.isVideoNotePaused else {
        return
      }
      let min = Int(total) / 60
      let sec = Int(total) % 60
      let ms = Int((total.truncatingRemainder(dividingBy: 1)) * 100)
      self.recordingTimerLabel.text = String(format: "%d:%02d.%02d", min, sec, ms)
      self.recordingDot.alpha = (Int(total * 2) % 2 == 0) ? 1 : 0
    }
    videoNoteRecorderController = recorder
    recorder.bottomChromeInset = bounds.height
    recorder.loadViewIfNeeded()
    // Warm camera before the view is inserted so the circle never flashes solid.
    recorder.prepareCameraAndStart { ok in
      NSLog("[VideoNote] prepareCamera ok=%@", ok ? "Y" : "N")
    }

    // Install immediately (not deferred). Gesture cancel is handled by locking
    // instead of cancelling — see handleMicGesture .cancelled.
    // Place ABOVE the collection (so it is visible) but BELOW the input bar.
    hostVC.addChild(recorder)
    recorder.view.frame = hostView.bounds
    recorder.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    recorder.view.isUserInteractionEnabled = true
    if let list = hostView as? ChatListView {
      // Explicit z: collection < recorder < input < transition (layout may re-pin).
      list.installVideoNoteRecorderView(recorder.view, belowInput: self)
    } else {
      hostView.insertSubview(recorder.view, belowSubview: self)
      hostView.bringSubviewToFront(self)
    }
    recorder.didMove(toParent: hostVC)
    recorder.playEntranceAnimation()
    NSLog(
      "[VideoNote] installed frame=%@ host=%@ subviews=%d",
      NSCoder.string(for: recorder.view.frame),
      String(describing: type(of: hostView)),
      hostView.subviews.count
    )
    // Re-pin after the recording expand animation lays out the list.
    DispatchQueue.main.async { [weak self] in
      self?.reassertVideoNoteOverlayZOrder()
    }
    return true
  }

  private func stopVideoNoteRecording(send: Bool) {
    guard isVideoRecordingActive else { return }
    pendingVideoStopShouldSend = send

    guard let recorder = videoNoteRecorderController else {
      isVideoRecordingActive = false
      return
    }
    recorder.stopRecording(send: send)
  }

  private func startRecording() {
    guard !isRecording else { return }
    setGifPanelVisible(false, animated: false)
    isRecording = true
    isLocked = false
    feedback.impactOccurred()

    // UI Transition
    // 1. Hide Input
    // 2. Show Timer + Cancel
    // 3. Mic scales Up

    textView.alpha = 0
    textView.isUserInteractionEnabled = false
    placeholderLabel.alpha = 0
    sendButton.isUserInteractionEnabled = false
    sendButton.alpha = 0
    slideToCancelLabel.isHidden = false
    slideChevronView.isHidden = false
    slideToCancelLabel.text = "Slide to cancel"
    recordingTimerLabel.isHidden = false
    recordingDot.isHidden = false
    lockHintHost.isHidden = false
    recordingTimerLabel.text = "0:00.00"

    recordingStartTime = Date()
    recordingWaveformSamples.removeAll(keepingCapacity: true)
    recordingFileURL = nil
    let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
      self?.updateTimer()
    }
    RunLoop.main.add(timer, forMode: .common)
    recordingTimer = timer
    updateTimer()

    startRecordingHintAnimations()
    setNeedsLayout()
    layoutIfNeeded()

    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      usingSpringWithDamping: 0.88,
      initialSpringVelocity: 0.35,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.recordingExpandProgress = 1
      self.attachGlass.transform = CGAffineTransform(translationX: -20, y: 0).scaledBy(
        x: 0.84, y: 0.84)
      self.attachGlass.alpha = 0.18
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }

    // Mic Pulse / Scale
    UIView.animate(withDuration: 0.2) {
      self.micGlass.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
      self.micVADView.transform = CGAffineTransform(scaleX: 2.4, y: 2.4)
      self.micGlass.alpha = 1
    }

    if recordingMode == .video {
      micVADView.stop()
      guard startVideoNoteRecording() else {
        isRecording = false
        isLocked = false
        recordingMode = .none
        resetUI()
        recordingTimer?.invalidate()
        recordingTimer = nil
        return
      }
    } else {
      micVADView.start()

      let fileManager = FileManager.default
      let baseCacheDirectory =
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
      let voiceCacheDirectory = baseCacheDirectory.appendingPathComponent(
        "voice-recordings", isDirectory: true)
      try? fileManager.createDirectory(
        at: voiceCacheDirectory, withIntermediateDirectories: true)

      let outputURL =
        voiceCacheDirectory
        .appendingPathComponent("voice-\(UUID().uuidString)")
        .appendingPathExtension("m4a")
      recordingFileURL = outputURL

      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        do {
          try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
          try AVAudioSession.sharedInstance().setActive(true)
          let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
          ]
          let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
          recorder.isMeteringEnabled = true
          recorder.record()

          DispatchQueue.main.async {
            guard let self = self else { return }
            if self.isRecording {
              self.audioRecorder = recorder
            } else {
              recorder.stop()
              DispatchQueue.global(qos: .userInitiated).async {
                try? AVAudioSession.sharedInstance().setActive(
                  false, options: .notifyOthersOnDeactivation)
              }
            }
          }
        } catch {
          print("Failed to start VAD audio recorder: \(error)")
        }
      }

      vadTimer?.invalidate()
      vadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self = self, self.isRecording else { return }
        if let recorder = self.audioRecorder, recorder.isRecording {
          recorder.updateMeters()
          let level = normalizedRecorderWaveformLevel(recorder)
          self.micVADView.level = level
          self.recordingWaveformSamples.append(level)
          if self.recordingWaveformSamples.count > 480 {
            self.recordingWaveformSamples.removeFirst(self.recordingWaveformSamples.count - 480)
          }
        } else {
          self.micVADView.level = 0
        }
      }
    }

    delegate?.inputBarRecordingStateDidChange(
      isRecording: true,
      isLocked: false,
      mode: recordingModeString()
    )
  }

  private func updateTimer() {
    guard let start = recordingStartTime else { return }
    let dur = Date().timeIntervalSince(start)
    let min = Int(dur) / 60
    let sec = Int(dur) % 60
    let ms = Int((dur.truncatingRemainder(dividingBy: 1)) * 100)
    recordingTimerLabel.text = String(format: "%d:%02d.%02d", min, sec, ms)

    // Blink dot
    recordingDot.alpha = (Int(dur * 2) % 2 == 0) ? 1 : 0
  }

  private func lockRecording() {
    guard isRecording, !isLocked else { return }
    isLocked = true
    notificationFeedback.notificationOccurred(.success)

    if recordingMode == .voice {
      vadTimer?.invalidate()
      micVADView.stop()
    }

    slideToCancelLabel.text = "Cancel"
    slideToCancelLabel.isHidden = recordingMode == .video
    slideChevronView.isHidden = true
    lockHintHost.isHidden = true
    cancelOverlayButton.isHidden = false

    if recordingMode == .video {
      // Trash (cancel) + pause in pill + send on mic — matches Telegram video-note hold.
      videoNotePauseButton.isHidden = false
      setVideoNotePauseGlyph(paused: false)
      videoNoteDraftThumbView.isHidden = true
      let sendTint =
        appearance.bubbleMeGradient.first
        ?? appearance.textColorThem.withAlphaComponent(0.9)
      UIView.transition(with: micButton, duration: 0.2, options: .transitionCrossDissolve) {
        self.applyControlGlyph(
          button: self.micButton,
          symbolName: "arrow.up.circle.fill",
          symbolConfig: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium),
          tintColor: sendTint
        )
      }
    } else {
      videoNotePauseButton.isHidden = true
      let sendTint =
        appearance.bubbleMeGradient.first
        ?? appearance.textColorThem.withAlphaComponent(0.9)
      UIView.transition(with: micButton, duration: 0.2, options: .transitionCrossDissolve) {
        self.applyControlGlyph(
          button: self.micButton,
          symbolName: "arrow.up.circle.fill",
          symbolConfig: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium),
          tintColor: sendTint
        )
      }
    }
    micGlass.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)

    stopRecordingHintAnimations()
    slideToCancelLabel.transform = .identity
    lockHintHost.transform = .identity
    setNeedsLayout()
    layoutIfNeeded()

    delegate?.inputBarRecordingStateDidChange(
      isRecording: true,
      isLocked: true,
      mode: recordingModeString()
    )
  }

  private func applyVideoNotePausedInputState(draftURL: URL?, duration: Double) {
    isVideoNotePaused = true
    videoNoteDraftDuration = duration
    videoNotePauseButton.isHidden = false
    setVideoNotePauseGlyph(paused: true)
    cancelOverlayButton.isHidden = false
    slideToCancelLabel.isHidden = true
    slideChevronView.isHidden = true
    lockHintHost.isHidden = true
    recordingDot.isHidden = true

    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    let ms = Int((duration.truncatingRemainder(dividingBy: 1)) * 100)
    recordingTimerLabel.isHidden = false
    recordingTimerLabel.text = String(format: "%d:%02d.%02d", mins, secs, ms)

    // Draft thumb inside the pill (shared recording chrome — not a separate element).
    if let draftURL {
      videoNoteDraftThumb = videoNoteThumbnail(from: draftURL)
    }
    videoNoteDraftThumbView.image = videoNoteDraftThumb
    videoNoteDraftThumbView.isHidden = videoNoteDraftThumb == nil

    // Mic sends the paused draft; the thumb resumes recording.
    let sendTint =
      appearance.bubbleMeGradient.first
      ?? appearance.textColorThem.withAlphaComponent(0.9)
    UIView.transition(with: micButton, duration: 0.2, options: .transitionCrossDissolve) {
      self.applyControlGlyph(
        button: self.micButton,
        symbolName: "arrow.up.circle.fill",
        symbolConfig: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium),
        tintColor: sendTint
      )
    }
    setNeedsLayout()
    layoutIfNeeded()
  }

  private func applyVideoNoteRecordingInputState() {
    isVideoNotePaused = false
    videoNotePauseButton.isHidden = !isLocked
    setVideoNotePauseGlyph(paused: false)
    videoNoteDraftThumbView.isHidden = true
    recordingDot.isHidden = false
    if isLocked {
      cancelOverlayButton.isHidden = false
      let sendTint =
        appearance.bubbleMeGradient.first
        ?? appearance.textColorThem.withAlphaComponent(0.9)
      UIView.transition(with: micButton, duration: 0.2, options: .transitionCrossDissolve) {
        self.applyControlGlyph(
          button: self.micButton,
          symbolName: "arrow.up.circle.fill",
          symbolConfig: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium),
          tintColor: sendTint
        )
      }
    }
    setNeedsLayout()
    layoutIfNeeded()
  }

  private func videoNoteThumbnail(from url: URL) -> UIImage? {
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 120, height: 120)
    let time = CMTime(seconds: 0.05, preferredTimescale: 600)
    guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
    return UIImage(cgImage: cg)
  }

  private func cancelRecording() {
    guard isRecording else { return }
    let modeString = recordingModeString()
    let isVideoRecordingMode = recordingMode == .video
    isRecording = false
    isLocked = false
    notificationFeedback.notificationOccurred(.error)

    if isVideoRecordingMode {
      stopVideoNoteRecording(send: false)
    }
    vadTimer?.invalidate()
    vadTimer = nil
    recordingTimer?.invalidate()
    recordingTimer = nil
    micVADView.stop()

    // Save dot starting point
    let dotStart = pillContainer.convert(recordingDot.center, to: self)

    // Layout updates and shrink UI immediately, hiding real dot.
    resetUI(revealAttach: false)

    // Re-calculate layout to get accurate attachButton frames back at identity
    layoutIfNeeded()

    // The dot end is the normal untranslated position of attachButton
    let attachHeight = attachGlass.bounds.height
    let dotEndX = attachGlass.frame.minX + sideSize / 2
    let dotEndY = contentRow.frame.minY + attachHeight / 2
    let dotEnd = CGPoint(x: dotEndX, y: dotEndY)

    // Create animated fake dot
    let animatedDot = UIView(frame: CGRect(x: 0, y: 0, width: 6, height: 6))
    animatedDot.backgroundColor = .systemRed
    animatedDot.layer.cornerRadius = 3
    animatedDot.center = dotStart
    addSubview(animatedDot)

    // Setup Glass Trash View replacing the plus icon
    let trashContainer = UIView(frame: CGRect(x: 0, y: 0, width: sideSize, height: attachHeight))
    trashContainer.center = dotEnd
    trashContainer.alpha = 0
    trashContainer.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
    addSubview(trashContainer)

    let glassTarget = UIVisualEffectView()
    if #available(iOS 26.0, *) {
      glassTarget.effect = UIGlassEffect()
      glassTarget.cornerConfiguration = .capsule()
    } else {
      glassTarget.effect = UIBlurEffect(style: .systemMaterial)
      glassTarget.layer.cornerRadius = sideSize / 2
      glassTarget.clipsToBounds = true
    }
    glassTarget.frame = trashContainer.bounds
    glassTarget.isUserInteractionEnabled = false
    glassTarget.clipsToBounds = false
    trashContainer.addSubview(glassTarget)
    trashContainer.clipsToBounds = false

    let trashGlyph = TrashCanGlyphView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
    trashGlyph.center = CGPoint(x: glassTarget.bounds.midX, y: glassTarget.bounds.midY)
    glassTarget.contentView.addSubview(trashGlyph)
    glassTarget.contentView.bringSubviewToFront(trashGlyph)
    bringSubviewToFront(trashContainer)
    bringSubviewToFront(animatedDot)

    UIView.animate(withDuration: 0.2, delay: 0.05, options: .curveEaseOut) {
      trashContainer.alpha = 1
      trashContainer.transform = .identity
    } completion: { _ in
      trashGlyph.setLidOpen(true, animated: true)
      let path = UIBezierPath()
      path.move(to: dotStart)
      let jumpHeight: CGFloat = 44
      let controlY = min(dotStart.y, dotEnd.y) - jumpHeight
      let controlX = (dotStart.x + dotEnd.x) / 2
      path.addQuadCurve(to: dotEnd, controlPoint: CGPoint(x: controlX, y: controlY))

      let jumpAnim = CAKeyframeAnimation(keyPath: "position")
      jumpAnim.path = path.cgPath
      jumpAnim.duration = 0.38
      jumpAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)

      CATransaction.begin()
      CATransaction.setCompletionBlock {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveLinear]) {
          animatedDot.transform = CGAffineTransform(scaleX: 0.08, y: 0.08)
          animatedDot.alpha = 0
        } completion: { _ in
          animatedDot.removeFromSuperview()
          trashGlyph.setLidOpen(false, animated: true)
          UIView.animate(
            withDuration: 0.18, delay: 0.04,
            usingSpringWithDamping: 0.55, initialSpringVelocity: 0.65,
            options: [.curveEaseOut]
          ) {
            trashGlyph.transform = CGAffineTransform(translationX: 0, y: 1.5)
          } completion: { _ in
            UIView.animate(withDuration: 0.16) {
              trashGlyph.transform = .identity
            } completion: { _ in
              UIView.animate(withDuration: 0.2, delay: 0.16, options: .curveEaseInOut) {
                trashContainer.alpha = 0
                trashContainer.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                self.attachGlass.alpha = 1
              } completion: { _ in
                trashContainer.removeFromSuperview()
              }
            }
          }
        }
      }
      animatedDot.layer.add(jumpAnim, forKey: "jump")
      animatedDot.center = dotEnd
      CATransaction.commit()
    }

    delegate?.inputBarRecordingStateDidChange(isRecording: false, isLocked: false, mode: modeString)
    delegate?.inputBarRecordingDidCancel()
    recordingMode = .none
  }

  private func finishRecording() {
    guard isRecording else { return }
    let modeString = recordingModeString()
    let isVideoRecordingMode = recordingMode == .video

    if !isVideoRecordingMode {
      let dur = Date().timeIntervalSince(recordingStartTime ?? Date())
      if audioRecorder == nil || dur <= 0.6 {
        cancelRecording()
        return
      }
    }

    isRecording = false
    isLocked = false
    notificationFeedback.notificationOccurred(.success)

    micVADView.stop()
    if isVideoRecordingMode {
      stopVideoNoteRecording(send: true)
    } else {
      let dur = Date().timeIntervalSince(recordingStartTime ?? Date())
      if let recorder = audioRecorder {
        recorder.stop()
        let waveform = downsampleWaveform(recordingWaveformSamples, targetCount: 100)
        let outputURI = recordingFileURL?.absoluteString ?? ""
        if !outputURI.isEmpty {
          delegate?.inputBarDidRecordVoice(uri: outputURI, duration: dur, waveform: waveform)
        }
      }
    }

    delegate?.inputBarRecordingStateDidChange(isRecording: false, isLocked: false, mode: modeString)
    resetUI()
    recordingTimer?.invalidate()
    recordingTimer = nil
    recordingMode = .none
  }

  private func resetUI(revealAttach: Bool = true) {
    vadTimer?.invalidate()
    vadTimer = nil
    let rec = audioRecorder
    audioRecorder = nil

    DispatchQueue.global(qos: .userInitiated).async {
      rec?.stop()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    recordingStartTime = nil
    recordingFileURL = nil
    recordingWaveformSamples.removeAll(keepingCapacity: true)
    isVideoNotePaused = false
    videoNoteDraftDuration = 0
    videoNoteDraftThumb = nil
    videoNotePauseButton.isHidden = true
    videoNoteDraftThumbView.isHidden = true
    videoNoteDraftThumbView.image = nil
    textView.alpha = 1
    textView.isUserInteractionEnabled = true
    textView.isHidden = false
    applyPlaceholder()
    placeholderLabel.alpha = 1
    slideToCancelLabel.isHidden = true
    slideChevronView.isHidden = true
    recordingTimerLabel.isHidden = true
    recordingDot.isHidden = true
    lockHintHost.isHidden = true
    slideToCancelLabel.transform = .identity
    slideChevronView.transform = .identity
    lockHintHost.transform = .identity
    stopRecordingHintAnimations()
    updateButtonStates(animated: true)
    setNeedsLayout()
    layoutIfNeeded()

    UIView.animate(
      withDuration: 0.26,
      delay: 0,
      usingSpringWithDamping: 0.9,
      initialSpringVelocity: 0.3,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.recordingExpandProgress = 0
      self.attachGlass.transform = .identity
      self.attachGlass.alpha = revealAttach ? 1 : 0
      self.micGlass.transform = .identity
      self.micVADView.transform = .identity
      self.micGlass.alpha = 1

      self.applyComposerRecordGlyph(
        to: self.micButton,
        tintColor: self.appearance.textColorThem.withAlphaComponent(0.9))

      self.cancelOverlayButton.isHidden = true

      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }

  private func normalizedRecorderWaveformLevel(_ recorder: AVAudioRecorder) -> CGFloat {
    let averageDb = recorder.averagePower(forChannel: 0)
    let peakDb = recorder.peakPower(forChannel: 0)
    let effectiveDb = max(averageDb, peakDb - 4.0)
    let amplitude = CGFloat(pow(10.0, effectiveDb / 20.0))
    let silenceFloor: CGFloat = 0.015
    let normalized = max(0.0, min(1.0, (amplitude - silenceFloor) / (1.0 - silenceFloor)))
    return pow(normalized, 0.72)
  }

  private func downsampleWaveform(_ samples: [CGFloat], targetCount: Int) -> [Double] {
    guard targetCount > 0 else { return [] }
    let silenceThreshold: CGFloat = 0.02
    let sanitized =
      samples
      .map { max(0.0, min(1.0, $0)) }
      .filter { $0.isFinite }
      .map { sample in
        guard sample > silenceThreshold else { return 0.0 }
        return (sample - silenceThreshold) / (1.0 - silenceThreshold)
      }
    guard !sanitized.isEmpty else {
      return Array(repeating: 0.0, count: targetCount)
    }

    var peakSamples = Array(repeating: CGFloat.zero, count: targetCount)
    let sourceCount = sanitized.count

    for index in 0..<sourceCount {
      let bucketIndex = min(targetCount - 1, (index * targetCount) / max(1, sourceCount))
      peakSamples[bucketIndex] = max(peakSamples[bucketIndex], sanitized[index])
    }

    let averagePeak = peakSamples.reduce(0.0, +) / CGFloat(targetCount)
    let normalizationPeak = max(0.04, averagePeak * 1.8)

    var result: [Double] = []
    result.reserveCapacity(targetCount)
    for sample in peakSamples {
      let normalized = min(sample, normalizationPeak) / normalizationPeak
      result.append(Double(max(0.0, min(1.0, normalized))))
    }

    if result.allSatisfy({ $0 <= 0.003 }) {
      return Array(repeating: 0.0, count: targetCount)
    }

    return result
  }

  private func startRecordingHintAnimations() {
    slideChevronView.layer.removeAllAnimations()
    slideToCancelLabel.layer.removeAllAnimations()
    lockArrowView.layer.removeAllAnimations()

    UIView.animate(
      withDuration: 0.55,
      delay: 0,
      options: [.allowUserInteraction, .autoreverse, .repeat, .curveEaseInOut]
    ) {
      self.slideChevronView.transform = CGAffineTransform(translationX: -8, y: 0)
      self.slideToCancelLabel.transform = CGAffineTransform(translationX: -8, y: 0)
    }

    UIView.animate(
      withDuration: 0.52,
      delay: 0,
      options: [.allowUserInteraction, .autoreverse, .repeat, .curveEaseInOut]
    ) {
      self.lockArrowView.transform = CGAffineTransform(translationX: 0, y: -6)
    }
  }

  private func stopRecordingHintAnimations() {
    slideChevronView.layer.removeAllAnimations()
    slideToCancelLabel.layer.removeAllAnimations()
    lockArrowView.layer.removeAllAnimations()
    slideChevronView.transform = .identity
    slideToCancelLabel.transform = .identity
    lockArrowView.transform = .identity
  }
}  // End Class

// MARK: - UIGestureRecognizerDelegate

extension ChatInputBar: UIGestureRecognizerDelegate {
  /// The panel swipe shares its touches with the GIF/sticker/emoji grids underneath it.
  /// Without this the pan wins outright and the grids stop scrolling.
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

// MARK: - ChatGifPanelViewDelegate

extension ChatInputBar: ChatGifPanelViewDelegate {
  func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection) {
    delegate?.inputBarDidSelectGif(
      id: gif.id,
      url: gif.url,
      previewUrl: gif.previewUrl,
      width: gif.width,
      height: gif.height,
      localData: gif.localData
    )
  }

  func chatGifPanel(_ panel: ChatGifPanelView, didSelectSticker sticker: ChatStickerSelection) {
    delegate?.inputBarDidSelectSticker(
      stickerId: sticker.stickerId,
      packId: sticker.packId,
      bundleFileName: sticker.bundleFileName,
      emoji: sticker.emoji,
      width: sticker.width,
      height: sticker.height
    )
  }

  func chatGifPanel(_ panel: ChatGifPanelView, didSelectEmoji emoji: String) {
    let currentText = textView.text ?? ""
    let selectedRange = textView.selectedRange

    if let range = Range(selectedRange, in: currentText) {
      let updated = currentText.replacingCharacters(in: range, with: emoji)
      textView.text = updated
      let cursorLocation = selectedRange.location + (emoji as NSString).length
      textView.selectedRange = NSRange(location: cursorLocation, length: 0)
    } else {
      textView.text = currentText + emoji
      textView.selectedRange = NSRange(
        location: (textView.text as NSString?)?.length ?? 0,
        length: 0
      )
    }

    textViewDidChange(textView)
    setNeedsLayout()
    layoutIfNeeded()
    superview?.setNeedsLayout()
    superview?.layoutIfNeeded()
  }

  func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView) {
    setGifPanelVisible(false, animated: true)
  }
}

// MARK: - UITextViewDelegate

extension ChatInputBar: UITextViewDelegate {
  func textViewDidBeginEditing(_ textView: UITextView) {
    // Claim the slot for the keyboard now; its height only arrives a notification later.
    if keyboardHeightForPanels <= 0 {
      keyboardArrivalPending = true
    }
    // Same slot, one occupant. Focusing the composer cancels a pending open or hides the panel.
    guard gifPanelVisible || pendingGifPanelOpen else { return }
    setGifPanelVisible(false, animated: true)
  }

  func textViewDidEndEditing(_ textView: UITextView) {
    // Focus can be dropped with no keyboard notification behind it; without this the bar
    // keeps reserving the slot and the list keeps a keyboard's worth of bottom inset.
    guard keyboardArrivalPending else { return }
    keyboardArrivalPending = false
    setNeedsLayout()
    delegate?.inputBarHeightDidChange()
  }

  func textViewDidChange(_ tv: UITextView) {
    applyPlaceholder()
    updateButtonStates(animated: true)

    let textString = tv.text ?? ""
    updateDraftMusicPreview(from: textString)
    delegate?.inputBarTextDidChange(text: textString)

    let isCloudOrCodex = provider?.lowercased().contains("claude") == true || provider?.lowercased().contains("codex") == true || provider?.lowercased().contains("grok") == true || provider?.lowercased().contains("agy") == true || provider?.lowercased().contains("antigravity") == true || agentControlMode
    if isCloudOrCodex && textString.hasPrefix("/") {
      populateSlashSuggestions(filter: textString)
      setSlashSuggestionVisible(true, animated: true)
      setReadyBannerAction(.none, animated: true)
    } else {
      setSlashSuggestionVisible(false, animated: true)
      setReadyBannerAction(resolveReadyBannerAction(in: textString), animated: true)
    }

    // Highlight @vibe and slash commands in real-time
    if let textStorage = tv.textStorage as NSTextStorage? {
      let fullRange = NSRange(location: 0, length: textStorage.length)
      let selectedRange = tv.selectedRange

      textStorage.beginEditing()
      textStorage.removeAttribute(.foregroundColor, range: fullRange)
      textStorage.removeAttribute(.font, range: fullRange)
      textStorage.addAttribute(.foregroundColor, value: appearance.textColorThem, range: fullRange)
      textStorage.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: fullRange)

      let highlightColor =
        appearance.bubbleMeGradient.last
        ?? ChatListAppearance.brandAccentFallback

      if let regex = try? NSRegularExpression(pattern: "@vibe", options: .caseInsensitive) {
        let matches = regex.matches(in: textString, options: [], range: fullRange)
        for match in matches {
          textStorage.addAttribute(.foregroundColor, value: highlightColor, range: match.range)
        }
      }
      
      if let regex = try? NSRegularExpression(pattern: "^/[A-Za-z0-9-]+", options: []) {
        let matches = regex.matches(in: textString, options: [], range: fullRange)
        for match in matches {
          textStorage.addAttribute(.foregroundColor, value: highlightColor, range: match.range)
        }
      }
      textStorage.endEditing()

      // Restore cursor position seamlessly
      tv.selectedRange = selectedRange
    }

    let newHeight = tv.contentSize.height
    if abs(newHeight - lastMeasuredTextHeight) > 1.0 {
      lastMeasuredTextHeight = newHeight
      // Animate pill height change when text wraps to new lines
      UIView.animate(
        withDuration: 0.25, delay: 0,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.setNeedsLayout()
        self.layoutIfNeeded()
        // Also animate parent (ChatListView) to adjust collection view inset
        self.superview?.setNeedsLayout()
        self.superview?.layoutIfNeeded()
      }
    }
  }

  func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String)
    -> Bool
  {
    // Allow newline insertion from keyboard return key.
    return true
  }
}

// MARK: - ChatAttachmentSheet
// Native bottom sheet matching AttachmentMenu.tsx: Gallery | File | Location | Contact tabs

final class ChatAttachmentSheet: UIViewController {

  var onSelectImage: ((String) -> Void)?
  var onSelectFile: ((String, String) -> Void)?
  var onSelectLocation: ((Double, Double) -> Void)?

  private let appearance: ChatListAppearance
  private let tabs = ["Gallery", "File", "Location", "Contact"]
  private var activeTab = 0

  private let handleBar = UIView()
  private let tabBar = UISegmentedControl()
  private let contentArea = UIView()
  private let backgroundGlass = UIVisualEffectView(effect: nil)

  init(appearance: ChatListAppearance) {
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 24
    }
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    // Glass background
    applyGlass(to: backgroundGlass)
    backgroundGlass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(backgroundGlass)

    // Handle bar
    handleBar.backgroundColor = UIColor(white: 0.5, alpha: 0.4)
    handleBar.layer.cornerRadius = 2.5
    view.addSubview(handleBar)

    // Tab bar (mirrors AttachmentMenu tabs)
    tabBar.insertSegment(withTitle: "📷 Gallery", at: 0, animated: false)
    tabBar.insertSegment(withTitle: "📄 File", at: 1, animated: false)
    tabBar.insertSegment(withTitle: "📍 Location", at: 2, animated: false)
    tabBar.insertSegment(withTitle: "👤 Contact", at: 3, animated: false)
    tabBar.selectedSegmentIndex = 0
    tabBar.backgroundColor = .clear
    tabBar.selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.16)
    tabBar.setTitleTextAttributes(
      [
        .foregroundColor: UIColor(white: 0.95, alpha: 0.84),
        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
      ],
      for: .normal
    )
    tabBar.setTitleTextAttributes(
      [
        .foregroundColor: UIColor.white,
        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
      ],
      for: .selected
    )
    tabBar.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
    view.addSubview(tabBar)

    // Content area
    contentArea.backgroundColor = .clear
    view.addSubview(contentArea)

    showTab(0)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let w = view.bounds.width
    let safeTop = view.safeAreaInsets.top

    backgroundGlass.frame = view.bounds

    handleBar.frame = CGRect(x: (w - 36) / 2, y: safeTop + 8, width: 36, height: 5)
    tabBar.frame = CGRect(x: 16, y: handleBar.frame.maxY + 16, width: w - 32, height: 36)
    contentArea.frame = CGRect(
      x: 0, y: tabBar.frame.maxY + 12,
      width: w, height: view.bounds.height - tabBar.frame.maxY - 12)
  }

  @objc private func tabChanged() {
    showTab(tabBar.selectedSegmentIndex)
  }

  private func showTab(_ index: Int) {
    activeTab = index
    contentArea.subviews.forEach { $0.removeFromSuperview() }

    switch index {
    case 0: showGalleryTab()
    case 1: pickFile()
    case 2: pickLocation()
    case 3: showContactPlaceholder()
    default: break
    }
  }

  // MARK: Gallery tab

  private func showGalleryTab() {
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 10
    config.filter = .any(of: [.images, .videos])
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    addChild(picker)
    picker.view.frame = contentArea.bounds
    picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentArea.addSubview(picker.view)
    picker.didMove(toParent: self)
  }

  // MARK: File tab

  private func pickFile() {
    let types: [UTType] = [.item]
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  // MARK: Location tab

  private func pickLocation() {
    // Simple: use device location
    let label = UILabel()
    label.text = "Fetching location…"
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.frame = contentArea.bounds
    label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentArea.addSubview(label)

    // CoreLocation fetch
    let locMgr = CLLocationManagerWrapper.shared
    locMgr.requestOnce { [weak self] coord in
      DispatchQueue.main.async {
        guard let self else { return }
        self.onSelectLocation?(coord.latitude, coord.longitude)
        self.dismiss(animated: true)
      }
    }
  }

  // MARK: Contact placeholder

  private func showContactPlaceholder() {
    let label = UILabel()
    label.text = "Contact sharing coming soon"
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.frame = contentArea.bounds
    label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentArea.addSubview(label)
  }

  // MARK: Glass helper

  private func applyGlass(to v: UIVisualEffectView) {
    if #available(iOS 26.0, *) {
      v.effect = UIGlassEffect()
    } else {
      v.effect = UIBlurEffect(style: .systemMaterial)
    }
  }
}

// MARK: PHPickerViewControllerDelegate

extension ChatAttachmentSheet: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    dismiss(animated: true)
    guard let first = results.first else { return }
    first.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
      [weak self] url, _ in
      guard let url else { return }
      DispatchQueue.main.async {
        self?.onSelectImage?(url.absoluteString)
        self?.dismiss(animated: true)
      }
    }
  }
}

// MARK: UIDocumentPickerDelegate

extension ChatAttachmentSheet: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    guard let url = urls.first else { return }
    onSelectFile?(url.absoluteString, url.lastPathComponent)
    dismiss(animated: true)
  }
}

// MARK: - CLLocationManagerWrapper (simple one-shot)

private final class CLLocationManagerWrapper: NSObject, CLLocationManagerDelegate {
  static let shared = CLLocationManagerWrapper()
  private let manager = CLLocationManager()
  private var callback: ((CLLocationCoordinate2D) -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func requestOnce(_ cb: @escaping (CLLocationCoordinate2D) -> Void) {
    callback = cb
    manager.requestWhenInUseAuthorization()
    manager.requestLocation()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.first else { return }
    callback?(loc.coordinate)
    callback = nil
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    callback = nil
  }
}

// MARK: - ChatInputBar Pickers and Custom Menus Extension
extension ChatInputBar: PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
  
  private func updatePlusButtonMenu() {
    // UIMenu on + is AI-agent chat only (attach quick actions + agent control items).
    // Default chats open the full attachment tab sheet via attachButtonTapped.
    inlineAttachButton.menu = nil
    inlineAttachButton.showsMenuAsPrimaryAction = false

    guard agentControlMode else {
      attachButton.menu = nil
      attachButton.showsMenuAsPrimaryAction = false
      return
    }

    let cameraAction = UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in
      self?.openCamera()
    }
    let photoAction = UIAction(title: "Photos", image: UIImage(systemName: "photo")) { [weak self] _ in
      self?.openPhotoLibrary()
    }
    let fileAction = UIAction(title: "Files", image: UIImage(systemName: "paperclip")) { [weak self] _ in
      self?.openFilePicker()
    }

    let attachGroup = UIMenu(
      title: "",
      options: .displayInline,
      children: [cameraAction, photoAction, fileAction]
    )
    var menuChildren: [UIMenuElement] = [attachGroup]

    if let agentMenu = agentControlMenu {
      let agentGroup = UIMenu(title: "", options: .displayInline, children: agentMenu.children)
      menuChildren.append(agentGroup)
    }

    attachButton.menu = UIMenu(title: "", children: menuChildren)
    attachButton.showsMenuAsPrimaryAction = true
  }

  private func openCamera() {
    guard let vc = findViewController() else { return }
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = ["public.image"]
    picker.delegate = self
    vc.present(picker, animated: true)
  }

  private func openPhotoLibrary() {
    guard let vc = findViewController() else { return }
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 4
    config.filter = .images
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    vc.present(picker, animated: true)
  }

  private func openFilePicker() {
    guard let vc = findViewController() else { return }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    vc.present(picker, animated: true)
  }

  private func stageImage(_ image: UIImage) {
    let scaled = ChatInputBar.scaledImage(image, maxDimension: 1024)
    guard let data = scaled.jpegData(compressionQuality: 0.55) else { return }
    let fileName = "image-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
    let object: [String: Any] = [
      "name": fileName,
      "mime": "image/jpeg",
      "dataB64": data.base64EncodedString(),
    ]
    // Always write a durable local file so send never depends only on sealed blobs
    // (decrypt/materialize can fail; agents still get blobs when present).
    let localURI: String? = {
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
      let dir = caches.appendingPathComponent("chat-local-attachments", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent("\(UUID().uuidString.lowercased())-\(fileName)")
      do {
        try data.write(to: url, options: .atomic)
        return url.absoluteString
      } catch {
        NSLog("[ChatInputBar] stageImage write failed %@", error.localizedDescription)
        return nil
      }
    }()
    let blob = AgentRuntimeCrypto.encrypt(object)

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingImages.append(image)
      if let blob { self.pendingAttachmentBlobs.append(blob) }
      if let localURI { self.pendingImageLocalURIs.append(localURI) }
      // Keep arrays aligned if encrypt fails: pad blobs with empty so URI index still works.
      while self.pendingAttachmentBlobs.count < self.pendingImageLocalURIs.count {
        self.pendingAttachmentBlobs.append("")
      }
      self.updateAttachmentPreviewVisibility()
      self.updateButtonStates(animated: true)
    }
  }

  private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxDimension, longest > 0 else { return image }
    let scale = maxDimension / longest
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: newSize)
    return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
  }

  private func updateAttachmentPreviewVisibility() {
    for subview in attachmentPreviewContainer.arrangedSubviews {
      attachmentPreviewContainer.removeArrangedSubview(subview)
      subview.removeFromSuperview()
    }

    attachmentPreviewVisible = !pendingImages.isEmpty
    attachmentPreviewScroll.isHidden = !attachmentPreviewVisible
    attachmentPreviewScroll.alpha = attachmentPreviewVisible ? 1.0 : 0.0

    for (index, image) in pendingImages.enumerated() {
      let container = UIView()
      container.translatesAutoresizingMaskIntoConstraints = false
      
      let imgView = UIImageView(image: image)
      imgView.contentMode = .scaleAspectFill
      imgView.clipsToBounds = true
      imgView.layer.cornerRadius = 8
      imgView.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(imgView)
      
      let closeBtn = UIButton(type: .custom)
      let closeCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
      closeBtn.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: closeCfg), for: .normal)
      closeBtn.tintColor = .systemGray
      closeBtn.translatesAutoresizingMaskIntoConstraints = false
      closeBtn.tag = index
      closeBtn.addTarget(self, action: #selector(removeAttachmentTapped(_:)), for: .touchUpInside)
      container.addSubview(closeBtn)
      
      NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: 44),
        container.heightAnchor.constraint(equalToConstant: 44),
        
        imgView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
        imgView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        imgView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        imgView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        
        closeBtn.topAnchor.constraint(equalTo: container.topAnchor),
        closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        closeBtn.widthAnchor.constraint(equalToConstant: 16),
        closeBtn.heightAnchor.constraint(equalToConstant: 16)
      ])
      
      attachmentPreviewContainer.addArrangedSubview(container)
    }
    
    UIView.animate(withDuration: 0.25) {
      self.setNeedsLayout()
      self.layoutIfNeeded()
      self.superview?.setNeedsLayout()
      self.superview?.layoutIfNeeded()
    }
  }

  @objc private func removeAttachmentTapped(_ sender: UIButton) {
    let index = sender.tag
    guard index < pendingImages.count else { return }
    pendingImages.remove(at: index)
    if index < pendingAttachmentBlobs.count { pendingAttachmentBlobs.remove(at: index) }
    if index < pendingImageLocalURIs.count {
      let uri = pendingImageLocalURIs.remove(at: index)
      if let url = URL(string: uri), url.isFileURL {
        try? FileManager.default.removeItem(at: url)
      }
    }
    updateAttachmentPreviewVisibility()
    updateButtonStates(animated: true)
  }

  // MARK: - Slash Suggestions Helpers
  private func populateSlashSuggestions(filter: String?) {
    for subview in slashSuggestionContainer.arrangedSubviews {
      slashSuggestionContainer.removeArrangedSubview(subview)
      subview.removeFromSuperview()
    }
    
    let commands = ChatInputBar.defaultSlashCommands
    let filtered = filter == nil ? commands : commands.filter { $0.name.hasPrefix(filter!) }
    
    guard !filtered.isEmpty else {
      setSlashSuggestionVisible(false, animated: true)
      return
    }
    
    for cmd in filtered {
      let btn = UIButton(type: .system)
      btn.setTitle(cmd.name, for: .normal)
      btn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
      btn.setTitleColor(appearance.textColorThem.withAlphaComponent(0.9), for: .normal)
      btn.backgroundColor = appearance.textColorThem.withAlphaComponent(0.08)
      btn.layer.cornerRadius = 14
      btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
      btn.addTarget(self, action: #selector(slashSuggestionTapped(_:)), for: .touchUpInside)
      
      btn.accessibilityLabel = "\(cmd.name): \(cmd.description)"
      slashSuggestionContainer.addArrangedSubview(btn)
    }
  }

  @objc private func slashSuggestionTapped(_ sender: UIButton) {
    guard let title = sender.currentTitle else { return }
    let text = textView.text ?? ""
    
    if let lastSlashRange = text.range(of: "/", options: .backwards) {
      let beforeSlash = text[text.startIndex..<lastSlashRange.lowerBound]
      textView.text = beforeSlash + title + " "
    } else {
      textView.text = title + " "
    }
    
    setSlashSuggestionVisible(false, animated: true)
    textViewDidChange(textView)
    textView.becomeFirstResponder()
  }

  private func setSlashSuggestionVisible(_ visible: Bool, animated: Bool) {
    guard slashSuggestionVisible != visible else { return }
    slashSuggestionVisible = visible
    
    if visible {
      slashSuggestionScroll.isHidden = false
      slashSuggestionScroll.alpha = 0
      
      if animated {
        UIView.animate(
          withDuration: 0.28, delay: 0,
          usingSpringWithDamping: 0.82, initialSpringVelocity: 0.5,
          options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
          self.slashSuggestionScroll.alpha = 1
          self.setNeedsLayout()
          self.layoutIfNeeded()
          self.superview?.setNeedsLayout()
          self.superview?.layoutIfNeeded()
        }
      } else {
        slashSuggestionScroll.alpha = 1
        setNeedsLayout()
        layoutIfNeeded()
      }
    } else {
      if animated {
        UIView.animate(
          withDuration: 0.22, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]
        ) {
          self.slashSuggestionScroll.alpha = 0
          self.setNeedsLayout()
          self.layoutIfNeeded()
          self.superview?.setNeedsLayout()
          self.superview?.layoutIfNeeded()
        } completion: { _ in
          if !self.slashSuggestionVisible {
            self.slashSuggestionScroll.isHidden = true
          }
        }
      } else {
        slashSuggestionScroll.alpha = 0
        slashSuggestionScroll.isHidden = true
        setNeedsLayout()
        layoutIfNeeded()
      }
    }
  }

  // MARK: - Picker delegates
  public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    for result in results {
      let provider = result.itemProvider
      if provider.canLoadObject(ofClass: UIImage.self) {
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
          guard let self, let image = object as? UIImage else { return }
          self.stageImage(image)
        }
      }
    }
  }

  public func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    if let image = info[.originalImage] as? UIImage {
      stageImage(image)
    }
  }

  public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }

  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    let isCloudOrCodex = provider?.lowercased().contains("claude") == true || provider?.lowercased().contains("codex") == true || provider?.lowercased().contains("grok") == true || provider?.lowercased().contains("agy") == true || provider?.lowercased().contains("antigravity") == true || agentControlMode
    if isCloudOrCodex {
      if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
        stageImage(image)
      } else {
        delegate?.inputBarDidSelectFile(uri: url.absoluteString, name: url.lastPathComponent)
      }
    } else {
      delegate?.inputBarDidSelectFile(uri: url.absoluteString, name: url.lastPathComponent)
    }
  }
}
