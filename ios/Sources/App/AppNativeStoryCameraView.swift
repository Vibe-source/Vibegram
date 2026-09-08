import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private func appStoryTransitionLog(_ event: String, metadata: [String: String] = [:]) {
  VibeLog.info(event, category: "story-transition", metadata: metadata)
  NSLog("[StoryTransition] %@ %@", event, metadata.description)
}

private func appStoryCameraLog(_ event: String, metadata: [String: String] = [:]) {
  VibeLog.info(event, category: "story-camera", metadata: metadata)
  NSLog("[StoryCamera] %@ %@", event, metadata.description)
}

struct AppNativeStoryCapturedMedia: Identifiable, Equatable {
  enum Kind: String {
    case image
    case video
  }

  let id = UUID()
  let url: URL
  let kind: Kind
  let mirrored: Bool
}

struct AppNativeStoryCameraPage: View {
  let onClose: () -> Void

  @State private var capturedMedia: AppNativeStoryCapturedMedia?
  @State private var statusText: String?

  var body: some View {
    ZStack {
      if let capturedMedia {
        AppNativeStoryComposerRepresentable(media: capturedMedia) { payload in
          handleComposerEvent(payload)
        }
        .ignoresSafeArea()
        .transition(.asymmetric(
          insertion: .move(edge: .trailing).combined(with: .opacity),
          removal: .opacity
        ))
      } else {
        AppNativeStoryCameraRepresentable { payload in
          handleCameraEvent(payload)
        }
        .ignoresSafeArea()
      }

      if let statusText {
        VStack {
          Spacer()
          Text(statusText)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 44)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .background(Color.black.ignoresSafeArea())
    .animation(.easeInOut(duration: 0.18), value: capturedMedia)
    .animation(.easeInOut(duration: 0.18), value: statusText)
  }

  private func handleCameraEvent(_ payload: [String: Any]) {
    guard let type = payload["type"] as? String else { return }
    switch type {
    case "close":
      onClose()
    case "capture":
      guard
        let uri = payload["uri"] as? String,
        let url = URL(string: uri),
        let mediaType = payload["mediaType"] as? String
      else {
        showStatus("Capture failed")
        return
      }
      capturedMedia = AppNativeStoryCapturedMedia(
        url: url,
        kind: mediaType == "video" ? .video : .image,
        mirrored: payload["mirrored"] as? Bool ?? false
      )
    case "error":
      showStatus(payload["message"] as? String ?? "Camera unavailable")
    default:
      break
    }
  }

  private func showStatus(_ text: String) {
    statusText = text
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
      if statusText == text {
        statusText = nil
      }
    }
  }

  private func handleComposerEvent(_ payload: [String: Any]) {
    guard let type = payload["type"] as? String else { return }
    switch type {
    case "discard":
      capturedMedia = nil
    case "saveDraft":
      showStatus("Draft saved")
    case "aiEdit":
      showStatus("AI edit queued")
    case "publish":
      guard let media = capturedMedia else { return }
      let publishMedia = mediaForPublish(baseMedia: media, payload: payload)
      showStatus("Publishing...")
      Task {
        do {
          try await AppNativeStoryService.publish(media: publishMedia, payload: payload)
          await MainActor.run {
            showStatus("Story published")
            onClose()
          }
        } catch {
          await MainActor.run {
            showStatus(error.localizedDescription)
          }
        }
      }
    default:
      break
    }
  }

  private func mediaForPublish(
    baseMedia: AppNativeStoryCapturedMedia,
    payload: [String: Any]
  ) -> AppNativeStoryCapturedMedia {
    guard
      let renderedURI = payload["renderedUri"] as? String,
      let renderedURL = URL(string: renderedURI)
    else {
      return baseMedia
    }
    let renderedType = payload["renderedMediaType"] as? String
    return AppNativeStoryCapturedMedia(
      url: renderedURL,
      kind: renderedType == "video" ? .video : .image,
      mirrored: false
    )
  }
}

/// Self-contained host for `AppNativeStoryCameraPage`; dismisses itself through the page's `onClose`.
final class AppNativeStoryViewController: UIViewController {
  private let storyTransitioningDelegate = AppNativeStoryTransitioningDelegate()
  private var hostingController: UIHostingController<AppNativeStoryCameraPage>?

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .custom
    transitioningDelegate = storyTransitioningDelegate
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    let page = AppNativeStoryCameraPage { [weak self] in
      guard let self else { return }
      let presenter = self.presentingViewController
      appStoryTransitionLog(
        "close requested",
        metadata: [
          "presenterWindow": presenter?.viewIfLoaded?.window == nil ? "N" : "Y",
          "storyWindow": self.viewIfLoaded?.window == nil ? "N" : "Y",
        ]
      )
      self.dismiss(animated: true) {
        appStoryTransitionLog(
          "close completion",
          metadata: ["presenterWindow": presenter?.viewIfLoaded?.window == nil ? "N" : "Y"]
        )
      }
    }
    let hosting = UIHostingController(rootView: page)
    hosting.view.backgroundColor = .clear
    addChild(hosting)
    hosting.view.frame = view.bounds
    hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(hosting.view)
    hosting.didMove(toParent: self)
    hostingController = hosting
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    appStoryTransitionLog("story appeared", metadata: ["window": view.window == nil ? "N" : "Y"])
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    appStoryTransitionLog(
      "story disappeared",
      metadata: [
        "dismissed": isBeingDismissed ? "Y" : "N",
        "window": view.window == nil ? "N" : "Y",
      ]
    )
  }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

private final class AppNativeStoryTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
  func animationController(
    forPresented presented: UIViewController,
    presenting: UIViewController,
    source: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    AppNativeStoryPresentAnimator()
  }

  func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    AppNativeStoryDismissAnimator()
  }

  func presentationController(
    forPresented presented: UIViewController,
    presenting: UIViewController?,
    source: UIViewController
  ) -> UIPresentationController? {
    AppNativeStoryPresentationController(presentedViewController: presented, presenting: presenting)
  }
}

private final class AppNativeStoryPresentationController: UIPresentationController {
  override var shouldRemovePresentersView: Bool { false }

  override var frameOfPresentedViewInContainerView: CGRect {
    containerView?.bounds ?? .zero
  }

  override func presentationTransitionDidEnd(_ completed: Bool) {
    super.presentationTransitionDidEnd(completed)
    appStoryTransitionLog(
      "presentation ended",
      metadata: [
        "completed": completed ? "Y" : "N",
        "presenterWindow": presentingViewController.viewIfLoaded?.window == nil ? "N" : "Y",
      ]
    )
  }

  override func dismissalTransitionDidEnd(_ completed: Bool) {
    super.dismissalTransitionDidEnd(completed)
    appStoryTransitionLog(
      "dismissal ended",
      metadata: [
        "completed": completed ? "Y" : "N",
        "presenterWindow": presentingViewController.viewIfLoaded?.window == nil ? "N" : "Y",
      ]
    )
  }
}

/// Reveals Story behind Home on the same clock as a navigation transition.
private final class AppNativeStoryPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    TimeInterval(UINavigationController.hideShowBarDuration)
  }

  func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
    guard
      let fromVC = transitionContext.viewController(forKey: .from),
      let toVC = transitionContext.viewController(forKey: .to),
      let fromView = transitionContext.view(forKey: .from) ?? fromVC.view,
      let toView = transitionContext.view(forKey: .to) ?? toVC.view
    else {
      transitionContext.completeTransition(false)
      return
    }

    let container = transitionContext.containerView
    let finalFrame = transitionContext.finalFrame(for: toVC)
    let parallax = finalFrame.width * 0.28

    toView.frame = finalFrame
    toView.transform = CGAffineTransform(translationX: -parallax, y: 0)
    var foregroundView = fromView
    var foregroundSnapshot: UIView?
    let presenterInContainer = fromView.superview === container
    if fromView.superview === container {
      container.insertSubview(toView, belowSubview: fromView)
    } else {
      container.addSubview(toView)
      if let snapshot = fromView.snapshotView(afterScreenUpdates: false) {
        snapshot.frame = container.bounds
        container.addSubview(snapshot)
        foregroundView = snapshot
        foregroundSnapshot = snapshot
      }
    }
    appStoryTransitionLog(
      "present start",
      metadata: [
        "presenterInContainer": presenterInContainer ? "Y" : "N",
        "snapshot": foregroundSnapshot == nil ? "N" : "Y",
        "subviews": String(container.subviews.count),
      ]
    )

    let animator = UIViewPropertyAnimator(
      duration: transitionDuration(using: transitionContext),
      curve: .easeInOut
    ) {
      foregroundView.transform = CGAffineTransform(translationX: finalFrame.width, y: 0)
      toView.transform = .identity
    }
    animator.addCompletion { _ in
      let cancelled = transitionContext.transitionWasCancelled
      foregroundSnapshot?.removeFromSuperview()
      if cancelled {
        fromView.transform = .identity
        toView.transform = .identity
        toView.removeFromSuperview()
      } else {
        container.bringSubviewToFront(toView)
        fromView.transform = .identity
      }
      appStoryTransitionLog(
        "present animator ended",
        metadata: [
          "cancelled": cancelled ? "Y" : "N",
          "storyWindow": toView.window == nil ? "N" : "Y",
        ]
      )
      transitionContext.completeTransition(!cancelled)
    }
    animator.startAnimation()
  }
}

/// Covers Story with the real Home hierarchy, reversing the presentation motion.
private final class AppNativeStoryDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    TimeInterval(UINavigationController.hideShowBarDuration)
  }

  func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
    guard
      let fromVC = transitionContext.viewController(forKey: .from),
      let toVC = transitionContext.viewController(forKey: .to),
      let fromView = transitionContext.view(forKey: .from) ?? fromVC.view,
      let toView = transitionContext.view(forKey: .to) ?? toVC.view
    else {
      transitionContext.completeTransition(false)
      return
    }

    let container = transitionContext.containerView
    let finalFrame = transitionContext.finalFrame(for: toVC)
    let parallax = finalFrame.width * 0.28

    let presenterInContainer = toView.superview === container
    var foregroundView = toView
    var foregroundSnapshot: UIView?
    var storyExitX = -parallax
    if presenterInContainer {
      container.bringSubviewToFront(toView)
      toView.frame = finalFrame
      toView.transform = CGAffineTransform(translationX: finalFrame.width, y: 0)
    } else if let snapshot = toView.snapshotView(afterScreenUpdates: false) {
      snapshot.frame = finalFrame
      snapshot.transform = CGAffineTransform(translationX: finalFrame.width, y: 0)
      container.addSubview(snapshot)
      foregroundView = snapshot
      foregroundSnapshot = snapshot
    } else {
      storyExitX = -finalFrame.width
    }
    fromView.transform = .identity
    appStoryTransitionLog(
      "dismiss start",
      metadata: [
        "presenterInContainer": presenterInContainer ? "Y" : "N",
        "snapshot": foregroundSnapshot == nil ? "N" : "Y",
        "presenterWindow": toView.window == nil ? "N" : "Y",
      ]
    )

    let animator = UIViewPropertyAnimator(
      duration: transitionDuration(using: transitionContext),
      curve: .easeInOut
    ) {
      foregroundView.transform = .identity
      fromView.transform = CGAffineTransform(translationX: storyExitX, y: 0)
    }
    animator.addCompletion { _ in
      let cancelled = transitionContext.transitionWasCancelled
      if cancelled {
        container.bringSubviewToFront(fromView)
      }
      fromView.transform = .identity
      if presenterInContainer {
        toView.transform = .identity
      }
      appStoryTransitionLog(
        "dismiss animator ended",
        metadata: [
          "cancelled": cancelled ? "Y" : "N",
          "presenterWindow": toView.window == nil ? "N" : "Y",
          "presenterSuperview": String(describing: toView.superview.map { type(of: $0) }),
        ]
      )
      transitionContext.completeTransition(!cancelled)
      foregroundSnapshot?.removeFromSuperview()
    }
    animator.startAnimation()
  }
}

private struct AppNativeStoryCameraRepresentable: UIViewRepresentable {
  let onEvent: ([String: Any]) -> Void

  func makeUIView(context: Context) -> AppNativeStoryCameraView {
    let view = AppNativeStoryCameraView()
    view.onEvent = onEvent
    return view
  }

  func updateUIView(_ uiView: AppNativeStoryCameraView, context: Context) {
    uiView.onEvent = onEvent
  }
}

private enum AppNativeStoryCameraMode: String {
  case picture
  case video
}

private final class AppNativeStoryCameraPreviewView: UIView {
  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }
}

/// A round icon control hosted on real Liquid Glass instead of a painted translucent fill.
private final class AppNativeStoryGlassIconButton: UIButton {
  private let glass = UIVisualEffectView(effect: nil)

  override init(frame: CGRect) {
    super.init(frame: frame)
    tintColor = .white
    glass.isUserInteractionEnabled = false
    glass.clipsToBounds = true
    insertSubview(glass, at: 0)
    if #available(iOS 26.0, *) {
      glass.cornerConfiguration = .capsule()
      let effect = UIGlassEffect()
      effect.isInteractive = true
      glass.effect = effect
    } else {
      glass.layer.cornerCurve = .continuous
      glass.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds
    if #unavailable(iOS 26.0) {
      glass.layer.cornerRadius = bounds.height * 0.5
    }
  }
}

private final class AppNativeStoryCameraView: UIView, AVCapturePhotoCaptureDelegate,
  AVCaptureFileOutputRecordingDelegate, PHPickerViewControllerDelegate
{
  var onEvent: (([String: Any]) -> Void)?

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(
    label: "vibe.native.story.camera.session",
    qos: .userInitiated
  )
  private let photoOutput = AVCapturePhotoOutput()
  private let movieOutput = AVCaptureMovieFileOutput()
  private let previewView = AppNativeStoryCameraPreviewView()
  private let closeButton = AppNativeStoryGlassIconButton(type: .system)
  private let galleryButton = AppNativeStoryGlassIconButton(type: .system)
  private let flipButton = AppNativeStoryGlassIconButton(type: .system)
  private let modeContainer = UIVisualEffectView(effect: nil)
  private let pictureModeButton = UIButton(type: .system)
  private let videoModeButton = UIButton(type: .system)
  private let shutterButton = UIButton(type: .custom)
  private let shutterRingView = UIView()
  private let shutterInnerView = UIView()
  private let permissionContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private let permissionTitleLabel = UILabel()
  private let permissionButton = UIButton(type: .system)
  private let loadingSpinner = UIActivityIndicatorView(style: .large)

  private var currentMode: AppNativeStoryCameraMode = .picture
  private var currentPosition: AVCaptureDevice.Position = .back
  private var hasConfiguredSession = false
  private var didRequestInitialPermission = false
  private var isRecording = false
  private var shouldIgnoreNextVideoCapture = false
  private var videoInput: AVCaptureDeviceInput?
  private var audioInput: AVCaptureDeviceInput?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true

    previewView.previewLayer.session = session
    previewView.previewLayer.videoGravity = .resizeAspectFill

    configureView()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    DispatchQueue.main.async { [weak self] in
      self?.refreshPermissionState(requestIfNeeded: true)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    let session = self.session
    let movieOutput = self.movieOutput
    sessionQueue.async {
      if movieOutput.isRecording {
        movieOutput.stopRecording()
      }
      if session.isRunning {
        session.stopRunning()
      }
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      stopSessionIfNeeded(ignoreCapture: true)
    } else {
      refreshPermissionState(requestIfNeeded: false)
      startSessionIfNeeded()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    previewView.frame = bounds

    let safeTop = max(safeAreaInsets.top, 12.0)
    let safeBottom = max(safeAreaInsets.bottom, 20.0)
    let horizontalMargin: CGFloat = 16.0
    let controlSize: CGFloat = 44.0
    let shutterSize: CGFloat = 74.0

    closeButton.frame = CGRect(x: horizontalMargin, y: safeTop + 6.0, width: controlSize, height: controlSize)

    let shutterY = bounds.height - safeBottom - 22.0 - shutterSize
    shutterButton.frame = CGRect(
      x: (bounds.width - shutterSize) * 0.5,
      y: shutterY,
      width: shutterSize,
      height: shutterSize
    )
    shutterRingView.frame = shutterButton.bounds
    shutterRingView.layer.cornerRadius = shutterSize * 0.5

    let innerSize: CGFloat = isRecording ? 30 : shutterSize - 12.0
    shutterInnerView.frame = CGRect(
      x: (shutterButton.bounds.width - innerSize) * 0.5,
      y: (shutterButton.bounds.height - innerSize) * 0.5,
      width: innerSize,
      height: innerSize
    )
    shutterInnerView.layer.cornerRadius = isRecording ? 10 : innerSize * 0.5

    let sideControlY = shutterY + (shutterSize - controlSize) * 0.5
    galleryButton.frame = CGRect(x: horizontalMargin, y: sideControlY, width: controlSize, height: controlSize)
    flipButton.frame = CGRect(
      x: bounds.width - horizontalMargin - controlSize,
      y: sideControlY,
      width: controlSize,
      height: controlSize
    )

    let modeWidth: CGFloat = 168.0
    let modeHeight: CGFloat = 36.0
    modeContainer.frame = CGRect(
      x: (bounds.width - modeWidth) * 0.5,
      y: shutterY - 14.0 - modeHeight,
      width: modeWidth,
      height: modeHeight
    )
    if #unavailable(iOS 26.0) {
      modeContainer.layer.cornerRadius = modeHeight * 0.5
    }
    pictureModeButton.frame = CGRect(x: 0, y: 0, width: modeWidth * 0.5, height: modeHeight)
    videoModeButton.frame = CGRect(x: modeWidth * 0.5, y: 0, width: modeWidth * 0.5, height: modeHeight)

    let permissionWidth = min(bounds.width - 44, 330)
    permissionContainer.frame = CGRect(
      x: (bounds.width - permissionWidth) * 0.5,
      y: (bounds.height - 154) * 0.5,
      width: permissionWidth,
      height: 154
    )
    permissionTitleLabel.frame = CGRect(x: 22, y: 28, width: permissionWidth - 44, height: 44)
    permissionButton.frame = CGRect(x: 22, y: 88, width: permissionWidth - 44, height: 44)
    loadingSpinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    updatePreviewOrientation()
  }

  private func configureView() {
    addSubview(previewView)

    configureCircleButton(closeButton, symbol: "xmark")
    closeButton.addTarget(self, action: #selector(handleClosePress), for: .touchUpInside)
    addSubview(closeButton)

    configureCircleButton(galleryButton, symbol: "photo.on.rectangle.angled")
    galleryButton.addTarget(self, action: #selector(handleGalleryPress), for: .touchUpInside)
    addSubview(galleryButton)

    configureCircleButton(flipButton, symbol: "arrow.triangle.2.circlepath.camera")
    flipButton.addTarget(self, action: #selector(handleFlipPress), for: .touchUpInside)
    addSubview(flipButton)

    modeContainer.clipsToBounds = true
    if #available(iOS 26.0, *) {
      modeContainer.cornerConfiguration = .capsule()
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      modeContainer.effect = effect
    } else {
      modeContainer.layer.cornerCurve = .continuous
      modeContainer.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    }
    addSubview(modeContainer)

    configureModeButton(pictureModeButton, title: "Photo")
    pictureModeButton.addTarget(self, action: #selector(handlePictureModePress), for: .touchUpInside)
    modeContainer.contentView.addSubview(pictureModeButton)

    configureModeButton(videoModeButton, title: "Video")
    videoModeButton.addTarget(self, action: #selector(handleVideoModePress), for: .touchUpInside)
    modeContainer.contentView.addSubview(videoModeButton)

    shutterRingView.isUserInteractionEnabled = false
    shutterRingView.layer.borderColor = UIColor.white.cgColor
    shutterRingView.layer.borderWidth = 4
    shutterButton.addSubview(shutterRingView)

    shutterInnerView.isUserInteractionEnabled = false
    shutterInnerView.backgroundColor = .white
    shutterButton.addSubview(shutterInnerView)
    shutterButton.addTarget(self, action: #selector(handleShutterPress), for: .touchUpInside)
    addSubview(shutterButton)

    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      permissionContainer.effect = effect
      permissionContainer.cornerConfiguration = .uniformCorners(radius: .fixed(22))
    } else {
      permissionContainer.layer.cornerRadius = 22
      permissionContainer.layer.cornerCurve = .continuous
    }
    permissionContainer.clipsToBounds = true
    permissionContainer.isHidden = true
    addSubview(permissionContainer)

    permissionTitleLabel.numberOfLines = 0
    permissionTitleLabel.textAlignment = .center
    permissionTitleLabel.textColor = .white
    permissionTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    permissionContainer.contentView.addSubview(permissionTitleLabel)

    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = .white
    configuration.baseForegroundColor = .black
    configuration.cornerStyle = .capsule
    configuration.title = "Grant Permission"
    permissionButton.configuration = configuration
    permissionButton.addTarget(self, action: #selector(handlePermissionButtonPress), for: .touchUpInside)
    permissionContainer.contentView.addSubview(permissionButton)

    loadingSpinner.color = .white
    addSubview(loadingSpinner)

    updateModeAppearance()
  }

  private func configureCircleButton(_ button: AppNativeStoryGlassIconButton, symbol: String) {
    button.setImage(UIImage(systemName: symbol), for: .normal)
  }

  private func configureModeButton(_ button: UIButton, title: String) {
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
    button.layer.cornerRadius = 18
    button.layer.cornerCurve = .continuous
  }

  @objc private func handleWillResignActive() {
    stopSessionIfNeeded(ignoreCapture: true)
  }

  @objc private func handleDidBecomeActive() {
    refreshPermissionState(requestIfNeeded: false)
    startSessionIfNeeded()
  }

  @objc private func handleClosePress() {
    stopSessionIfNeeded(ignoreCapture: true)
    onEvent?(["type": "close"])
  }

  @objc private func handlePermissionButtonPress() {
    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
      requestVideoPermission()
      return
    }
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  @objc private func handleGalleryPress() {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.selectionLimit = 1
    configuration.filter = .any(of: [.images, .videos])
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    Self.topViewController()?.present(picker, animated: true)
  }

  @objc private func handleFlipPress() {
    guard !isRecording else { return }
    let nextPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()
      self.session.beginConfiguration()
      self.replaceVideoInput(position: nextPosition)
      self.session.commitConfiguration()
      DispatchQueue.main.async {
        self.updatePreviewOrientation()
      }
    }
  }

  @objc private func handlePictureModePress() {
    setMode(.picture)
  }

  @objc private func handleVideoModePress() {
    setMode(.video)
  }

  @objc private func handleShutterPress() {
    switch currentMode {
    case .picture:
      capturePhoto()
    case .video:
      if isRecording {
        stopRecording()
      } else {
        startRecordingFlow()
      }
    }
  }

  private func refreshPermissionState(requestIfNeeded: Bool) {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      permissionContainer.isHidden = true
      if requestIfNeeded {
        requestOptionalAudioPermissionIfNeeded()
      }
      startSessionIfNeeded()
    case .notDetermined:
      permissionContainer.isHidden = false
      permissionTitleLabel.text = "Camera permission required"
      permissionButton.configuration?.title = "Grant Permission"
      if requestIfNeeded && !didRequestInitialPermission {
        didRequestInitialPermission = true
        requestVideoPermission()
      }
    default:
      permissionContainer.isHidden = false
      permissionTitleLabel.text = "Allow camera access in Settings"
      permissionButton.configuration?.title = "Open Settings"
      setLoadingVisible(false)
      stopSessionIfNeeded(ignoreCapture: true)
    }
  }

  private func requestVideoPermission() {
    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      DispatchQueue.main.async {
        self?.refreshPermissionState(requestIfNeeded: granted)
      }
    }
  }

  private func requestOptionalAudioPermissionIfNeeded() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized {
      sessionQueue.async { [weak self] in
        guard let self else { return }
        self.session.beginConfiguration()
        self.addAudioInputIfPossible()
        self.session.commitConfiguration()
      }
      return
    }
    guard status == .notDetermined else { return }
    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
      guard granted else { return }
      self?.sessionQueue.async { [weak self] in
        guard let self else { return }
        self.session.beginConfiguration()
        self.addAudioInputIfPossible()
        self.session.commitConfiguration()
      }
    }
  }

  private func startSessionIfNeeded() {
    guard window != nil else { return }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
    setLoadingVisible(true)
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.ensureSessionConfigured()
      guard self.videoInput != nil else {
        DispatchQueue.main.async {
          self.setLoadingVisible(false)
          self.emitError("Camera unavailable")
        }
        return
      }
      guard !self.session.isRunning else {
        DispatchQueue.main.async {
          self.setLoadingVisible(false)
        }
        return
      }
      self.session.startRunning()
      DispatchQueue.main.async {
        self.setLoadingVisible(false)
        self.updatePreviewOrientation()
      }
    }
  }

  private func stopSessionIfNeeded(ignoreCapture: Bool) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      if self.movieOutput.isRecording {
        self.shouldIgnoreNextVideoCapture = ignoreCapture
        self.movieOutput.stopRecording()
      }
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  private func ensureSessionConfigured() {
    guard !hasConfiguredSession else { return }
    session.beginConfiguration()
    session.sessionPreset = .high

    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
      photoOutput.maxPhotoQualityPrioritization = .quality
    }

    if session.canAddOutput(movieOutput) {
      session.addOutput(movieOutput)
      movieOutput.maxRecordedDuration = CMTime(seconds: 15, preferredTimescale: 600)
      movieOutput.movieFragmentInterval = .invalid
    }

    replaceVideoInput(position: currentPosition)
    addAudioInputIfPossible()

    session.commitConfiguration()
    hasConfiguredSession = true
  }

  private func replaceVideoInput(position: AVCaptureDevice.Position) {
    guard let device = Self.cameraDevice(for: position) else { return }
    guard let nextInput = try? AVCaptureDeviceInput(device: device) else { return }

    let previousInput = videoInput
    if let previousInput {
      session.removeInput(previousInput)
    }

    if session.canAddInput(nextInput) {
      session.addInput(nextInput)
      videoInput = nextInput
      currentPosition = position
      configurePhotoOutput(for: device)
      return
    }

    if let previousInput, session.canAddInput(previousInput) {
      session.addInput(previousInput)
      videoInput = previousInput
      configurePhotoOutput(for: previousInput.device)
    }
  }

  private func configurePhotoOutput(for device: AVCaptureDevice) {
    guard let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
      Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
    }) else { return }
    photoOutput.maxPhotoDimensions = dimensions
  }

  private func addAudioInputIfPossible() {
    guard audioInput == nil else { return }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
    guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
    guard let nextInput = try? AVCaptureDeviceInput(device: audioDevice) else { return }
    guard session.canAddInput(nextInput) else { return }
    session.addInput(nextInput)
    audioInput = nextInput
  }

  private func setMode(_ mode: AppNativeStoryCameraMode) {
    guard currentMode != mode else { return }
    currentMode = mode
    if mode == .picture, isRecording {
      shouldIgnoreNextVideoCapture = true
      stopRecording()
    }
    updateModeAppearance()
    updateShutterAppearance()
  }

  private func updateModeAppearance() {
    let selectedBackground = UIColor.white.withAlphaComponent(0.24)
    let clear = UIColor.clear
    pictureModeButton.backgroundColor = currentMode == .picture ? selectedBackground : clear
    videoModeButton.backgroundColor = currentMode == .video ? selectedBackground : clear
    pictureModeButton.setTitleColor(.white, for: .normal)
    videoModeButton.setTitleColor(.white, for: .normal)
  }

  private func updateShutterAppearance() {
    UIView.animate(withDuration: 0.18) {
      self.shutterInnerView.backgroundColor =
        self.currentMode == .video ? UIColor.systemRed : UIColor.white
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  private func updatePreviewOrientation() {
    configureOutputConnection(previewView.previewLayer.connection, mirrorFrontCamera: true)
  }

  private func capturePhoto() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      refreshPermissionState(requestIfNeeded: true)
      return
    }
    guard videoInput != nil else {
      emitError("Camera unavailable")
      return
    }
    let settings = AVCapturePhotoSettings()
    settings.photoQualityPrioritization = .quality
    if photoOutput.maxPhotoDimensions.width > 0, photoOutput.maxPhotoDimensions.height > 0 {
      settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
    }
    if let device = videoInput?.device, device.hasFlash {
      settings.flashMode = .off
    }
    configureOutputConnection(photoOutput.connection(with: .video), mirrorFrontCamera: true)
    appStoryCameraLog(
      "photo requested",
      metadata: [
        "camera": currentPosition == .front ? "front" : "back",
        "maxDimensions": "\(settings.maxPhotoDimensions.width)x\(settings.maxPhotoDimensions.height)",
        "quality": "quality",
      ]
    )
    photoOutput.capturePhoto(with: settings, delegate: self)
    flashPreview()
  }

  private func startRecordingFlow() {
    let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    if audioStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
        DispatchQueue.main.async {
          self?.sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.addAudioInputIfPossible()
            self.session.commitConfiguration()
            DispatchQueue.main.async {
              self.startRecording()
            }
          }
        }
      }
      return
    }
    startRecording()
  }

  private func startRecording() {
    guard !movieOutput.isRecording else { return }
    guard videoInput != nil else {
      emitError("Camera unavailable")
      return
    }
    let url = temporaryOutputURL(fileExtension: "mov")
    configureOutputConnection(movieOutput.connection(with: .video), mirrorFrontCamera: true)
    movieOutput.startRecording(to: url, recordingDelegate: self)
  }

  private func configureOutputConnection(
    _ connection: AVCaptureConnection?,
    mirrorFrontCamera: Bool
  ) {
    guard let connection else { return }
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = window?.windowScene?.interfaceOrientation.storyCameraOrientation ?? .portrait
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = mirrorFrontCamera && currentPosition == .front
    }
  }

  private func stopRecording() {
    guard movieOutput.isRecording else { return }
    movieOutput.stopRecording()
  }

  private func setRecording(_ recording: Bool) {
    isRecording = recording
    updateShutterAppearance()
  }

  private func setLoadingVisible(_ visible: Bool) {
    if visible {
      loadingSpinner.startAnimating()
    } else {
      loadingSpinner.stopAnimating()
    }
  }

  private func flashPreview() {
    let flash = UIView(frame: bounds)
    flash.backgroundColor = .white
    flash.alpha = 0
    addSubview(flash)
    UIView.animate(withDuration: 0.08, animations: {
      flash.alpha = 0.72
    }, completion: { _ in
      UIView.animate(withDuration: 0.16, animations: {
        flash.alpha = 0
      }, completion: { _ in
        flash.removeFromSuperview()
      })
    })
  }

  private func emitCapture(url: URL, mediaType: String, mirrored: Bool) {
    onEvent?([
      "type": "capture",
      "uri": url.absoluteString,
      "mediaType": mediaType,
      "mirrored": mirrored,
    ])
  }

  private func emitError(_ message: String) {
    onEvent?([
      "type": "error",
      "message": message,
    ])
  }

  private func temporaryOutputURL(fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-story-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if let error {
      DispatchQueue.main.async {
        self.emitError(error.localizedDescription)
      }
      return
    }

    guard let data = photo.fileDataRepresentation() else {
      DispatchQueue.main.async {
        self.emitError("Unable to save photo")
      }
      return
    }

    let outputURL = temporaryOutputURL(fileExtension: "jpg")
    do {
      try data.write(to: outputURL, options: [.atomic])
      let dimensions = photo.resolvedSettings.photoDimensions
      appStoryCameraLog(
        "photo captured",
        metadata: [
          "bytes": String(data.count),
          "dimensions": "\(dimensions.width)x\(dimensions.height)",
          "mirroredPixels": currentPosition == .front ? "Y" : "N",
        ]
      )
      DispatchQueue.main.async {
        self.emitCapture(
          url: outputURL,
          mediaType: "image",
          mirrored: false
        )
      }
    } catch {
      DispatchQueue.main.async {
        self.emitError(error.localizedDescription)
      }
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    DispatchQueue.main.async {
      self.setRecording(true)
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    DispatchQueue.main.async {
      self.setRecording(false)
    }

    if shouldIgnoreNextVideoCapture {
      shouldIgnoreNextVideoCapture = false
      try? FileManager.default.removeItem(at: outputFileURL)
      return
    }

    if let nsError = error as NSError?,
      nsError.domain != AVFoundationErrorDomain
        || nsError.code != AVError.Code.maximumDurationReached.rawValue
    {
      DispatchQueue.main.async {
        self.emitError(nsError.localizedDescription)
      }
      return
    }

    DispatchQueue.main.async {
      self.emitCapture(
        url: outputFileURL,
        mediaType: "video",
        mirrored: false
      )
    }
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = results.first else { return }

    let provider = result.itemProvider
    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, error in
        if let error {
          DispatchQueue.main.async {
            self?.emitError(error.localizedDescription)
          }
          return
        }
        guard let url else {
          DispatchQueue.main.async {
            self?.emitError("Unable to load video")
          }
          return
        }
        let destination = self?.temporaryOutputURL(fileExtension: url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        guard let destination else { return }
        do {
          try FileManager.default.copyItem(at: url, to: destination)
          DispatchQueue.main.async {
            self?.emitCapture(url: destination, mediaType: "video", mirrored: false)
          }
        } catch {
          DispatchQueue.main.async {
            self?.emitError(error.localizedDescription)
          }
        }
      }
      return
    }

    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
      if let error {
        DispatchQueue.main.async {
          self?.emitError(error.localizedDescription)
        }
        return
      }
      guard let data else {
        DispatchQueue.main.async {
          self?.emitError("Unable to load image")
        }
        return
      }
      let destination = self?.temporaryOutputURL(fileExtension: "jpg")
      guard let destination else { return }
      do {
        try data.write(to: destination, options: [.atomic])
        DispatchQueue.main.async {
          self?.emitCapture(url: destination, mediaType: "image", mirrored: false)
        }
      } catch {
        DispatchQueue.main.async {
          self?.emitError(error.localizedDescription)
        }
      }
    }
  }

  private static func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    if position == .front {
      return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(for: .video)
    }
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
      ?? AVCaptureDevice.default(for: .video)
  }

  private static func topViewController(
    base: UIViewController? = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow }?
      .rootViewController
  ) -> UIViewController? {
    if let navigation = base as? UINavigationController {
      return topViewController(base: navigation.visibleViewController)
    }
    if let tab = base as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = base?.presentedViewController {
      return topViewController(base: presented)
    }
    return base
  }
}

private enum AppNativeStoryService {
  private enum StoryServiceError: LocalizedError {
    case missingSession
    case invalidEndpoint
    case missingLocalFile
    case uploadFailed(String)
    case publishFailed(String)

    var errorDescription: String? {
      switch self {
      case .missingSession:
        return "Sign in again to publish stories."
      case .invalidEndpoint:
        return "Story endpoint is unavailable."
      case .missingLocalFile:
        return "Story media is no longer available."
      case .uploadFailed(let reason):
        return "Upload failed: \(reason)"
      case .publishFailed(let reason):
        return "Publish failed: \(reason)"
      }
    }
  }

  static func publish(media: AppNativeStoryCapturedMedia, payload: [String: Any]) async throws {
    guard let config = AppSessionConfig.current else {
      throw StoryServiceError.missingSession
    }

    let remoteMediaURL = try await upload(media: media, config: config)
    try await createStory(media: media, mediaURL: remoteMediaURL, payload: payload, config: config)
  }

  private static func upload(
    media: AppNativeStoryCapturedMedia,
    config: AppSessionConfig
  ) async throws -> String {
    guard FileManager.default.fileExists(atPath: media.url.path) else {
      throw StoryServiceError.missingLocalFile
    }
    guard let uploadURL = apiURL(base: config.apiBaseURLString, path: "/media/upload") else {
      throw StoryServiceError.invalidEndpoint
    }

    let fileData = try Data(contentsOf: media.url, options: [.mappedIfSafe])
    let boundary = "----VibeStoryBoundary\(UUID().uuidString)"
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    appendMultipartField(body: &body, boundary: boundary, name: "user_id", value: config.userID)
    appendMultipartField(body: &body, boundary: boundary, name: "type", value: media.kind.rawValue)
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName(for: media))\"\r\n"
        .data(using: .utf8) ?? Data()
    )
    body.append("Content-Type: \(mimeType(for: media))\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(fileData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())

    let (data, response) = try await VibeHTTP.shared.upload(for: request, from: body)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw StoryServiceError.uploadFailed(responseMessage(from: data))
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let remoteURL = normalizedString(json["url"] ?? json["media_url"] ?? json["mediaUrl"])
    else {
      throw StoryServiceError.uploadFailed("missing media URL")
    }
    return remoteURL
  }

  private static func createStory(
    media: AppNativeStoryCapturedMedia,
    mediaURL: String,
    payload: [String: Any],
    config: AppSessionConfig
  ) async throws {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/stories") else {
      throw StoryServiceError.invalidEndpoint
    }
    let audience = normalizedString(payload["audience"]) ?? "everyone"
    let duration = normalizedInt(payload["duration"]) ?? 24
    let visibility = audience == "close_friends" ? "close_friends" : audience
    let body: [String: Any] = [
      "user_id": config.userID,
      "media_url": mediaURL,
      "media_type": media.kind.rawValue,
      "visibility": visibility,
      "visible_to": [],
      "hidden_from": [],
      "duration": duration,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw StoryServiceError.publishFailed(responseMessage(from: data))
    }
  }

  private static func apiURL(base rawBase: String, path: String) -> URL? {
    var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api" + path)
  }

  private static func fileName(for media: AppNativeStoryCapturedMedia) -> String {
    let fallbackExtension = media.kind == .video ? "mov" : "jpg"
    let fileExtension = media.url.pathExtension.isEmpty ? fallbackExtension : media.url.pathExtension
    return "story-\(UUID().uuidString).\(fileExtension)"
  }

  private static func mimeType(for media: AppNativeStoryCapturedMedia) -> String {
    if media.kind == .video {
      return media.url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime"
    }
    return "image/jpeg"
  }

  private static func appendMultipartField(
    body: inout Data,
    boundary: String,
    name: String,
    value: String
  ) {
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
    body.append("\(value)\r\n".data(using: .utf8) ?? Data())
  }

  private static func normalizedString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let number = value as? NSNumber {
      return number.intValue
    }
    if let string = normalizedString(value) {
      return Int(string)
    }
    return nil
  }

  private static func responseMessage(from data: Data) -> String {
    if
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = normalizedString(json["error"] ?? json["message"] ?? json["reason"])
    {
      return message
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "unknown error"
  }
}

private extension UIInterfaceOrientation {
  var storyCameraOrientation: AVCaptureVideoOrientation {
    switch self {
    case .portraitUpsideDown:
      return .portraitUpsideDown
    case .landscapeLeft:
      return .landscapeRight
    case .landscapeRight:
      return .landscapeLeft
    default:
      return .portrait
    }
  }
}
