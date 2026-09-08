import ExpoModulesCore
import Foundation
import UIKit

#if canImport(WebRTC)
  import WebRTC
#elseif canImport(JitsiWebRTC)
  import JitsiWebRTC
#endif

final class VibeNativeCallUiCoordinator {
  static let shared = VibeNativeCallUiCoordinator()

  private weak var module: VibeNativeCallModule?
  private var retainedReactBridgeObject: AnyObject?
  private var overlayWindow: UIWindow?
  private weak var controller: VibeNativeCallScreenController?
  private var state: [String: Any] = [:]

  private init() {}

  func attach(module: VibeNativeCallModule) {
    NSLog("[VibeNativeCall][UiCoord] attach module")
    self.module = module
    captureReactBridgeObject(module.appContext?.reactBridge)
    captureReactBridgeObject(legacyReactBridgeObject(from: module))
  }

  func detach(module: VibeNativeCallModule) {
    if self.module === module {
      NSLog("[VibeNativeCall][UiCoord] detach module")
      self.module = nil
    }
  }

  func captureReactBridgeObject(_ bridge: AnyObject?) {
    guard let bridge else { return }
    if retainedReactBridgeObject !== bridge {
      retainedReactBridgeObject = bridge
      NSLog("[VibeNativeCall][UiCoord] captured reactBridge")
    }
  }

  func setState(_ payload: [String: Any]) {
    let mode = (payload["mode"] as? String) ?? "hidden"
    let visible = (payload["visible"] as? Bool) ?? (mode != "hidden")
    let callId = (payload["callId"] as? String) ?? (payload["call_id"] as? String) ?? "-"
    let status = (payload["callStatus"] as? String) ?? "-"
    NSLog(
      "[VibeNativeCall][UiCoord] setState mode=%@ visible=%@ callId=%@ status=%@",
      mode, visible ? "true" : "false", callId, status
    )
    state = payload
    DispatchQueue.main.async {
      self.applyStateOnMain(payload)
    }
  }

  func hide() {
    DispatchQueue.main.async {
      NSLog(
        "[VibeNativeCall][UiCoord] hide hasWindow=%@ hasController=%@",
        self.overlayWindow != nil ? "true" : "false",
        self.controller != nil ? "true" : "false"
      )
      self.overlayWindow?.rootViewController = nil
      self.overlayWindow?.isHidden = true
      self.overlayWindow = nil
      self.controller = nil
    }
  }

  func emitEvent(_ type: String, extra: [String: Any] = [:]) {
    NSLog("[VibeNativeCall][UiCoord] emitEvent type=%@", type)
    var payload = extra
    payload["type"] = type
    module?.emitCallUiEvent(payload)
  }

  func reactBridgeObject() -> AnyObject? {
    if let bridge = bridgeHolderReactBridgeObject() {
      NSLog("[VibeNativeCall][UiCoord] using bridge holder object")
      captureReactBridgeObject(bridge)
      return bridge
    }
    if let bridge = module?.appContext?.reactBridge {
      captureReactBridgeObject(bridge)
      return bridge
    }
    if let bridge = module.flatMap({ legacyReactBridgeObject(from: $0) }) {
      captureReactBridgeObject(bridge)
      return bridge
    }
    if let retainedReactBridgeObject {
      return retainedReactBridgeObject
    }
    if let currentBridge = currentReactBridgeObject() {
      captureReactBridgeObject(currentBridge)
      return currentBridge
    }
    return nil
  }

  private func currentReactBridgeObject() -> AnyObject? {
    guard let bridgeClass = NSClassFromString("RCTBridge") as? NSObject.Type else { return nil }
    let selector = NSSelectorFromString("currentBridge")
    guard bridgeClass.responds(to: selector) else { return nil }
    return bridgeClass.perform(selector)?.takeUnretainedValue() as AnyObject?
  }

  private func bridgeHolderReactBridgeObject() -> AnyObject? {
    guard let holderClass = NSClassFromString("VibeReactBridgeHolder") as? NSObject.Type else {
      return nil
    }
    let selector = NSSelectorFromString("currentBridgeObject")
    guard holderClass.responds(to: selector) else { return nil }
    return holderClass.perform(selector)?.takeUnretainedValue() as AnyObject?
  }

  private func legacyReactBridgeObject(from module: VibeNativeCallModule) -> AnyObject? {
    guard let legacyProxy = module.appContext?.legacyModulesProxy as? NSObject else { return nil }
    let bridge = legacyProxy.value(forKey: "bridge") as AnyObject?
    if bridge == nil {
      NSLog("[VibeNativeCall][UiCoord] legacy proxy bridge unavailable")
    }
    if let bridge { return bridge }
    return nil
  }

  private func applyStateOnMain(_ payload: [String: Any]) {
    let visible =
      (payload["visible"] as? Bool) ?? (((payload["mode"] as? String) ?? "hidden") != "hidden")
    guard visible else {
      NSLog("[VibeNativeCall][UiCoord] applyState hidden -> hide()")
      hide()
      return
    }

    if UIApplication.shared.applicationState != .active {
      NSLog(
        "[VibeNativeCall][UiCoord] applyState appState=%ld -> hide()",
        UIApplication.shared.applicationState.rawValue
      )
      hide()
      return
    }

    let controller = ensureController()
    NSLog("[VibeNativeCall][UiCoord] applyState forwardingToController")
    controller.applyState(payload)
  }

  private func ensureController() -> VibeNativeCallScreenController {
    if let controller {
      NSLog("[VibeNativeCall][UiCoord] ensureController reuse")
      return controller
    }

    let windowScene =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

    let window: UIWindow
    if let windowScene {
      window = UIWindow(windowScene: windowScene)
    } else {
      window = UIWindow(frame: UIScreen.main.bounds)
    }
    window.windowLevel = .alert + 1
    let root = VibeNativeCallScreenController(coordinator: self)
    NSLog(
      "[VibeNativeCall][UiCoord] ensureController create scene=%@",
      windowScene != nil ? "windowScene" : "screenBounds"
    )
    window.rootViewController = root
    window.isHidden = false
    window.makeKeyAndVisible()
    overlayWindow = window
    controller = root
    return root
  }
}

final class VibeNativeCallScreenController: UIViewController {
  private weak var coordinator: VibeNativeCallUiCoordinator?
  private var currentState: [String: Any] = [:]
  private var statusTick: Int = 0
  private var statusTicker: Timer?
  private let statusShimmerMaskLayer = CAGradientLayer()
  private var isStatusShimmerActive = false
  private var lastStatusKindKey: String = ""
  private var lastRenderedStatusText: String = ""
  private var currentAvatarImageUrl: String?
  private var avatarImageTask: URLSessionDataTask?

  private let wallpaperLayer = CAGradientLayer()
  private let wallpaperPatternLayer = CAGradientLayer()
  private let wallpaperPatternMaskLayer = CALayer()
  private let wallpaperTopScrimLayer = CAGradientLayer()
  private let wallpaperBottomScrimLayer = CAGradientLayer()
  private let videoCanvasView = UIView()
  private let remoteVideoHostView = UIView()
  private let localPreviewHostView = UIView()
  private var remoteVideoRenderer: RTCMTLVideoView?
  private var localPreviewRenderer: RTCMTLVideoView?
  private var attachedRemoteVideoTrack: RTCVideoTrack?
  private var attachedLocalVideoTrack: RTCVideoTrack?
  private var attachedRemoteStreamId: String?
  private var attachedLocalStreamId: String?
  private var localPreviewAttachRetryWorkItem: DispatchWorkItem?

  private let rootStack = UIStackView()
  private let chipLabel = NativeCallInsetLabel()
  private let chipWrap = UIView()
  private let avatarSpacerView = UIView()
  private let avatarView = UIView()
  private let avatarImageView = UIImageView()
  private let initialsLabel = UILabel()
  private let nameLabel = UILabel()
  private let statusRow = UIStackView()
  private let connectionDotHost = UIView()
  private let connectionDotGlow = UIView()
  private let connectionDotView = UIView()
  private let statusLabel = UILabel()
  private let spacer = UIView()
  private let utilityRow = UIStackView()
  private let incomingRow = UIStackView()
  private let activeBar = UIView()
  private let activeBarEffect = UIVisualEffectView()
  private let activeBarTintOverlay = UIView()
  private let activeRow = UIStackView()
  private let activeLeadingRow = UIStackView()

  private var buttons: [String: UIButton] = [:]
  private var buttonLabels: [String: UILabel] = [:]
  private var buttonStacks: [String: UIView] = [:]
  private var actionChips: [String: NativeCallActionChip] = [:]


  private static let avatarImageCache = NSCache<NSString, UIImage>()

  init(coordinator: VibeNativeCallUiCoordinator) {
    self.coordinator = coordinator
    super.init(nibName: nil, bundle: nil)
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    statusTicker?.invalidate()
    avatarImageTask?.cancel()
    localPreviewAttachRetryWorkItem?.cancel()
    detachVideoRenderers()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    NSLog("[VibeNativeCall][UiScreen] viewDidLoad")
    setupWallpaperLayers()
    setupUi()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    wallpaperLayer.frame = view.bounds
    wallpaperPatternLayer.frame = view.bounds
    wallpaperPatternMaskLayer.frame = wallpaperPatternLayer.bounds
    wallpaperTopScrimLayer.frame = view.bounds
    wallpaperBottomScrimLayer.frame = view.bounds
    statusShimmerMaskLayer.frame = statusLabel.bounds
  }

  func applyState(_ state: [String: Any]) {
    let mode = (state["mode"] as? String) ?? "hidden"
    let callId = (state["callId"] as? String) ?? (state["call_id"] as? String) ?? "-"
    let status = (state["callStatus"] as? String) ?? "-"
    NSLog("[VibeNativeCall][UiScreen] applyState mode=%@ callId=%@ status=%@", mode, callId, status)

    currentState = state
    let isDark = (state["isDark"] as? Bool) ?? true
    let palette = isDark ? Palette.dark : .light
    let callType = (state["callType"] as? String) ?? "voice"

    view.backgroundColor = palette.background
    applyWallpaperAppearance(from: state, palette: palette, preferWallpaper: callType == "voice")

    if mode == "active", status == "active" {
      chipLabel.text = "Encrypted"
    } else {
      chipLabel.text = nil
    }
    chipWrap.isHidden = (chipLabel.text == nil)
    chipLabel.textColor = palette.textSubtle
    chipLabel.backgroundColor = .clear
    chipLabel.layer.borderColor = UIColor.clear.cgColor
    chipLabel.layer.borderWidth = 0
    chipLabel.textInsets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)

    let remoteName =
      normalizedString(state["remoteUserName"])
      ?? normalizedString((state["incomingCallData"] as? [String: Any])?["fromUserName"])
      ?? "Unknown"
    nameLabel.text = remoteName
    initialsLabel.text = String(remoteName.prefix(1)).uppercased()
    nameLabel.textColor = palette.text
    initialsLabel.textColor = palette.text
    avatarView.backgroundColor = palette.avatarBg
    avatarView.layer.borderColor = palette.avatarRing.cgColor
    updateAvatarImage(from: normalizedString(state["remoteUserImage"]))

    utilityRow.isHidden = mode != "incoming"
    incomingRow.isHidden = mode != "incoming"
    activeBar.isHidden = mode != "active"

    let isMuted = (state["isMuted"] as? Bool) ?? false
    let isSpeaker = (state["isSpeakerOn"] as? Bool) ?? false
    let isVideo = (state["isVideoEnabled"] as? Bool) ?? false
    let canFlipCamera = ((state["canFlipCamera"] as? Bool) ?? false) && isVideo
    updateVideoPresentation(mode: mode, callType: callType, state: state)

    styleButton("incomingDecline", bg: palette.danger, symbol: "phone.down.fill", fg: .white)
    styleButton(
      "incomingAccept",
      bg: palette.accent,
      symbol: "phone.fill",
      fg: .white
    )
    styleButton("msg", bg: palette.controlBg, symbol: "message.fill", fg: palette.text)
    styleButton("remind", bg: palette.controlBg, symbol: "bell.fill", fg: palette.text)

    styleButton(
      "mute",
      bg: isMuted ? palette.controlActiveBg : palette.controlBg,
      symbol: isMuted ? "mic.slash.fill" : "mic.fill",
      fg: isMuted ? palette.background : palette.text,
      labelColor: isMuted ? palette.text : palette.textSubtle
    )
    styleButton(
      "video",
      bg: isVideo ? palette.controlActiveBg : palette.controlBg,
      symbol: isVideo ? "video.fill" : "video.slash.fill",
      fg: isVideo ? palette.background : palette.text,
      labelColor: isVideo ? palette.text : palette.textSubtle
    )
    styleButton(
      "speaker",
      bg: isSpeaker ? palette.controlActiveBg : palette.controlBg,
      symbol: "speaker.wave.2.fill",
      fg: isSpeaker ? palette.background : palette.text,
      labelColor: isSpeaker ? palette.text : palette.textSubtle
    )
    styleButton(
      "flip",
      bg: palette.controlBg,
      symbol: "arrow.triangle.2.circlepath.camera.fill",
      fg: palette.text,
      labelColor: palette.textSubtle
    )
    styleButton(
      "return",
      bg: palette.controlBg,
      symbol: "return",
      fg: palette.text,
      labelColor: palette.textSubtle
    )
    styleButton(
      "end", bg: palette.danger, symbol: "phone.down.fill", fg: .white, labelColor: .white)

    let canShowFlipChip = canFlipCamera && view.bounds.width >= 460
    buttonStacks["flip"]?.isHidden = !canShowFlipChip
    activeBar.backgroundColor = .clear
    activeBarEffect.backgroundColor = .clear
    activeBarEffect.contentView.backgroundColor = .clear
    activeBarTintOverlay.backgroundColor =
      palette.isDark
      ? UIColor.white.withAlphaComponent(0.06) : UIColor.black.withAlphaComponent(0.04)
    activeBar.layer.borderColor =
      palette.isDark
      ? UIColor.white.withAlphaComponent(0.08).cgColor
      : UIColor.black.withAlphaComponent(0.06).cgColor
    activeBarEffect.alpha = palette.isDark ? 0.92 : 0.78

    updateStatusPresentation(animated: true)
    setNeedsStatusBarAppearanceUpdate()
  }

  private func setupWallpaperLayers() {
    wallpaperPatternLayer.mask = wallpaperPatternMaskLayer
    wallpaperPatternMaskLayer.contentsGravity = .resizeAspectFill
    wallpaperPatternMaskLayer.contentsScale = UIScreen.main.scale

    wallpaperLayer.startPoint = CGPoint(x: 0, y: 0)
    wallpaperLayer.endPoint = CGPoint(x: 1, y: 1)

    wallpaperPatternLayer.startPoint = CGPoint(x: 0, y: 0)
    wallpaperPatternLayer.endPoint = CGPoint(x: 1, y: 1)

    wallpaperTopScrimLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    wallpaperTopScrimLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

    wallpaperBottomScrimLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    wallpaperBottomScrimLayer.endPoint = CGPoint(x: 0.5, y: 1.0)

    view.layer.insertSublayer(wallpaperLayer, at: 0)
    view.layer.insertSublayer(wallpaperPatternLayer, above: wallpaperLayer)
    view.layer.insertSublayer(wallpaperTopScrimLayer, above: wallpaperPatternLayer)
    view.layer.insertSublayer(wallpaperBottomScrimLayer, above: wallpaperTopScrimLayer)
  }

  private func setupUi() {
    view.isOpaque = true
    videoCanvasView.translatesAutoresizingMaskIntoConstraints = false
    videoCanvasView.backgroundColor = .black
    videoCanvasView.isHidden = true
    videoCanvasView.isUserInteractionEnabled = false
    view.addSubview(videoCanvasView)

    remoteVideoHostView.translatesAutoresizingMaskIntoConstraints = false
    remoteVideoHostView.backgroundColor = .black
    remoteVideoHostView.isUserInteractionEnabled = false
    videoCanvasView.addSubview(remoteVideoHostView)

    localPreviewHostView.translatesAutoresizingMaskIntoConstraints = false
    localPreviewHostView.backgroundColor = UIColor.black.withAlphaComponent(0.75)
    localPreviewHostView.layer.cornerRadius = 14
    localPreviewHostView.layer.cornerCurve = .continuous
    localPreviewHostView.layer.masksToBounds = true
    localPreviewHostView.layer.borderWidth = 1
    localPreviewHostView.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
    localPreviewHostView.isHidden = true
    localPreviewHostView.isUserInteractionEnabled = false
    videoCanvasView.addSubview(localPreviewHostView)

    NSLayoutConstraint.activate([
      videoCanvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      videoCanvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      videoCanvasView.topAnchor.constraint(equalTo: view.topAnchor),
      videoCanvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      remoteVideoHostView.leadingAnchor.constraint(equalTo: videoCanvasView.leadingAnchor),
      remoteVideoHostView.trailingAnchor.constraint(equalTo: videoCanvasView.trailingAnchor),
      remoteVideoHostView.topAnchor.constraint(equalTo: videoCanvasView.topAnchor),
      remoteVideoHostView.bottomAnchor.constraint(equalTo: videoCanvasView.bottomAnchor),

      localPreviewHostView.widthAnchor.constraint(equalToConstant: 118),
      localPreviewHostView.heightAnchor.constraint(equalToConstant: 168),
      localPreviewHostView.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
      localPreviewHostView.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 62),
    ])

    view.addSubview(rootStack)
    rootStack.axis = .vertical
    rootStack.alignment = .center
    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootStack.spacing = 12

    NSLayoutConstraint.activate([
      rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      rootStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
      rootStack.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])

    chipLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    chipLabel.textAlignment = .center
    chipLabel.numberOfLines = 1
    chipLabel.lineBreakMode = .byTruncatingTail
    chipLabel.layer.cornerRadius = 18
    chipLabel.layer.cornerCurve = .continuous
    chipLabel.layer.masksToBounds = true
    chipLabel.layer.borderWidth = 1
    chipLabel.translatesAutoresizingMaskIntoConstraints = false

    chipWrap.setContentHuggingPriority(.required, for: .horizontal)
    chipWrap.setContentCompressionResistancePriority(.required, for: .horizontal)
    chipLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    chipWrap.addSubview(chipLabel)
    NSLayoutConstraint.activate([
      chipLabel.leadingAnchor.constraint(equalTo: chipWrap.leadingAnchor),
      chipLabel.trailingAnchor.constraint(equalTo: chipWrap.trailingAnchor),
      chipLabel.topAnchor.constraint(equalTo: chipWrap.topAnchor),
      chipLabel.bottomAnchor.constraint(equalTo: chipWrap.bottomAnchor),
    ])
    rootStack.addArrangedSubview(chipWrap)

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.layer.cornerRadius = 78
    avatarView.layer.cornerCurve = .continuous
    avatarView.layer.masksToBounds = true
    avatarView.layer.borderWidth = 1
    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: 156),
      avatarView.heightAnchor.constraint(equalToConstant: 156),
    ])

    avatarImageView.translatesAutoresizingMaskIntoConstraints = false
    avatarImageView.contentMode = .scaleAspectFill
    avatarImageView.clipsToBounds = true
    avatarImageView.isHidden = true
    avatarView.addSubview(avatarImageView)
    NSLayoutConstraint.activate([
      avatarImageView.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor),
      avatarImageView.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
      avatarImageView.topAnchor.constraint(equalTo: avatarView.topAnchor),
      avatarImageView.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor),
    ])

    initialsLabel.translatesAutoresizingMaskIntoConstraints = false
    initialsLabel.font = .systemFont(ofSize: 52, weight: .bold)
    initialsLabel.textAlignment = .center
    avatarView.addSubview(initialsLabel)
    NSLayoutConstraint.activate([
      initialsLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
      initialsLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
    ])

    avatarSpacerView.addSubview(avatarView)
    avatarView.centerXAnchor.constraint(equalTo: avatarSpacerView.centerXAnchor).isActive = true
    avatarView.topAnchor.constraint(equalTo: avatarSpacerView.topAnchor, constant: 28).isActive =
      true
    avatarView.bottomAnchor.constraint(equalTo: avatarSpacerView.bottomAnchor).isActive = true
    rootStack.addArrangedSubview(avatarSpacerView)

    nameLabel.font = .systemFont(ofSize: 30, weight: .bold)
    nameLabel.textAlignment = .center
    rootStack.addArrangedSubview(nameLabel)

    statusRow.axis = .horizontal
    statusRow.alignment = .center
    statusRow.spacing = 8

    connectionDotHost.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      connectionDotHost.widthAnchor.constraint(equalToConstant: 14),
      connectionDotHost.heightAnchor.constraint(equalToConstant: 14),
    ])

    connectionDotGlow.translatesAutoresizingMaskIntoConstraints = false
    connectionDotGlow.layer.cornerRadius = 7
    connectionDotGlow.alpha = 0
    connectionDotHost.addSubview(connectionDotGlow)
    NSLayoutConstraint.activate([
      connectionDotGlow.centerXAnchor.constraint(equalTo: connectionDotHost.centerXAnchor),
      connectionDotGlow.centerYAnchor.constraint(equalTo: connectionDotHost.centerYAnchor),
      connectionDotGlow.widthAnchor.constraint(equalToConstant: 14),
      connectionDotGlow.heightAnchor.constraint(equalToConstant: 14),
    ])

    connectionDotView.translatesAutoresizingMaskIntoConstraints = false
    connectionDotView.layer.cornerRadius = 4
    connectionDotHost.addSubview(connectionDotView)
    NSLayoutConstraint.activate([
      connectionDotView.centerXAnchor.constraint(equalTo: connectionDotHost.centerXAnchor),
      connectionDotView.centerYAnchor.constraint(equalTo: connectionDotHost.centerYAnchor),
      connectionDotView.widthAnchor.constraint(equalToConstant: 8),
      connectionDotView.heightAnchor.constraint(equalToConstant: 8),
    ])

    statusLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    statusLabel.textAlignment = .center
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    statusRow.addArrangedSubview(connectionDotHost)
    statusRow.addArrangedSubview(statusLabel)
    rootStack.addArrangedSubview(statusRow)

    spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
    rootStack.addArrangedSubview(spacer)

    utilityRow.axis = .horizontal
    utilityRow.alignment = .center
    utilityRow.spacing = 14
    utilityRow.distribution = .fillEqually
    utilityRow.translatesAutoresizingMaskIntoConstraints = false
    utilityRow.addArrangedSubview(makeButtonStack(key: "msg", label: "Message", size: 52))
    utilityRow.addArrangedSubview(makeButtonStack(key: "remind", label: "Remind", size: 52))
    rootStack.addArrangedSubview(utilityRow)

    incomingRow.axis = .horizontal
    incomingRow.alignment = .center
    incomingRow.spacing = 18
    incomingRow.distribution = .fillEqually
    incomingRow.translatesAutoresizingMaskIntoConstraints = false
    incomingRow.addArrangedSubview(
      makeButtonStack(key: "incomingDecline", label: "Decline", size: 76))
    incomingRow.addArrangedSubview(
      makeButtonStack(key: "incomingAccept", label: "Accept", size: 76))
    rootStack.addArrangedSubview(incomingRow)

    activeBar.translatesAutoresizingMaskIntoConstraints = false
    activeBar.layer.cornerRadius = 34
    activeBar.layer.cornerCurve = .continuous
    activeBar.layer.masksToBounds = true
    activeBar.layer.borderWidth = 0.7

    activeBarEffect.translatesAutoresizingMaskIntoConstraints = false
    activeBarEffect.effect = makeGlassEffect()
    activeBarEffect.alpha = 1.0
    activeBarEffect.backgroundColor = .clear
    activeBarEffect.contentView.backgroundColor = .clear
    activeBarEffect.isUserInteractionEnabled = false
    activeBarEffect.layer.cornerRadius = 34
    activeBarEffect.layer.cornerCurve = .continuous
    activeBarEffect.layer.masksToBounds = true
    activeBar.addSubview(activeBarEffect)
    NSLayoutConstraint.activate([
      activeBarEffect.leadingAnchor.constraint(equalTo: activeBar.leadingAnchor),
      activeBarEffect.trailingAnchor.constraint(equalTo: activeBar.trailingAnchor),
      activeBarEffect.topAnchor.constraint(equalTo: activeBar.topAnchor),
      activeBarEffect.bottomAnchor.constraint(equalTo: activeBar.bottomAnchor),
    ])

    activeBarTintOverlay.translatesAutoresizingMaskIntoConstraints = false
    activeBarTintOverlay.isUserInteractionEnabled = false
    activeBarTintOverlay.backgroundColor = .clear
    activeBarTintOverlay.layer.cornerRadius = 39
    activeBarTintOverlay.layer.cornerCurve = .continuous
    activeBarTintOverlay.layer.masksToBounds = true
    activeBarEffect.contentView.addSubview(activeBarTintOverlay)
    NSLayoutConstraint.activate([
      activeBarTintOverlay.leadingAnchor.constraint(
        equalTo: activeBarEffect.contentView.leadingAnchor),
      activeBarTintOverlay.trailingAnchor.constraint(
        equalTo: activeBarEffect.contentView.trailingAnchor),
      activeBarTintOverlay.topAnchor.constraint(equalTo: activeBarEffect.contentView.topAnchor),
      activeBarTintOverlay.bottomAnchor.constraint(
        equalTo: activeBarEffect.contentView.bottomAnchor),
    ])

    activeRow.axis = .horizontal
    activeRow.alignment = .center
    activeRow.spacing = 10
    activeRow.distribution = .fill
    activeRow.translatesAutoresizingMaskIntoConstraints = false
    activeBar.addSubview(activeRow)
    activeRow.addArrangedSubview(
      makeButtonStack(key: "mute", label: "Mic", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "video", label: "Video", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "return", label: "Return", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "speaker", label: "Speaker", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "flip", label: "Flip", size: 48, showLabel: false))
    activeRow.addArrangedSubview(
      makeButtonStack(key: "end", label: "End", size: 56, showLabel: false))

    rootStack.addArrangedSubview(activeBar)

    NSLayoutConstraint.activate([
      activeRow.leadingAnchor.constraint(equalTo: activeBar.leadingAnchor, constant: 18),
      activeRow.trailingAnchor.constraint(equalTo: activeBar.trailingAnchor, constant: -18),
      activeRow.centerXAnchor.constraint(equalTo: activeBar.centerXAnchor),
      activeRow.topAnchor.constraint(equalTo: activeBar.topAnchor, constant: 6),
      activeRow.bottomAnchor.constraint(equalTo: activeBar.bottomAnchor, constant: -6),
      activeBar.heightAnchor.constraint(equalToConstant: 68),
    ])
  }


  private func updateAvatarImage(from urlString: String?) {
    let normalized = normalizedString(urlString)
    if normalized == currentAvatarImageUrl { return }
    currentAvatarImageUrl = normalized
    avatarImageTask?.cancel()
    avatarImageTask = nil

    guard let normalized else {
      avatarImageView.image = nil
      avatarImageView.isHidden = true
      initialsLabel.isHidden = false
      return
    }

    if let cached = Self.avatarImageCache.object(forKey: normalized as NSString) {
      avatarImageView.image = cached
      avatarImageView.isHidden = false
      initialsLabel.isHidden = true
      return
    }

    avatarImageView.image = nil
    avatarImageView.isHidden = true
    initialsLabel.isHidden = false

    guard let url = URL(string: normalized) else { return }

    let task = VibeHTTP.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard
        let self,
        let data,
        let image = UIImage(data: data)
      else { return }

      Self.avatarImageCache.setObject(image, forKey: normalized as NSString)
      DispatchQueue.main.async {
        guard self.currentAvatarImageUrl == normalized else { return }
        self.avatarImageView.image = image
        self.avatarImageView.isHidden = false
        self.initialsLabel.isHidden = true
      }
    }
    avatarImageTask = task
    task.resume()
  }

  private func updateVideoPresentation(mode: String, callType: String, state: [String: Any]) {
    let isActiveVideo = mode == "active" && callType == "video"
    videoCanvasView.isHidden = !isActiveVideo
    avatarSpacerView.isHidden = isActiveVideo
    avatarView.isHidden = isActiveVideo

    guard isActiveVideo else {
      localPreviewHostView.isHidden = true
      detachVideoRenderers()
      return
    }

    ensureVideoRenderers()

    let remoteStreamId = normalizedString(state["remoteStreamId"])
    let localStreamId = normalizedString(state["localStreamId"])
    let wantsLocalPreview = ((state["isVideoEnabled"] as? Bool) ?? false)

    attachRemoteVideo(streamId: remoteStreamId)
    attachLocalPreview(streamId: wantsLocalPreview ? localStreamId : nil)

    localPreviewHostView.isHidden = !wantsLocalPreview || localStreamId == nil
  }

  private func ensureVideoRenderers() {
    if remoteVideoRenderer == nil {
      let renderer = RTCMTLVideoView(frame: .zero)
      renderer.translatesAutoresizingMaskIntoConstraints = false
      renderer.videoContentMode = .scaleAspectFill
      renderer.isUserInteractionEnabled = false
      remoteVideoHostView.addSubview(renderer)
      NSLayoutConstraint.activate([
        renderer.leadingAnchor.constraint(equalTo: remoteVideoHostView.leadingAnchor),
        renderer.trailingAnchor.constraint(equalTo: remoteVideoHostView.trailingAnchor),
        renderer.topAnchor.constraint(equalTo: remoteVideoHostView.topAnchor),
        renderer.bottomAnchor.constraint(equalTo: remoteVideoHostView.bottomAnchor),
      ])
      remoteVideoRenderer = renderer
    }

    if localPreviewRenderer == nil {
      let renderer = RTCMTLVideoView(frame: .zero)
      renderer.translatesAutoresizingMaskIntoConstraints = false
      renderer.videoContentMode = .scaleAspectFill
      renderer.isUserInteractionEnabled = false
      renderer.transform = CGAffineTransform(scaleX: -1, y: 1)
      localPreviewHostView.addSubview(renderer)
      NSLayoutConstraint.activate([
        renderer.leadingAnchor.constraint(equalTo: localPreviewHostView.leadingAnchor),
        renderer.trailingAnchor.constraint(equalTo: localPreviewHostView.trailingAnchor),
        renderer.topAnchor.constraint(equalTo: localPreviewHostView.topAnchor),
        renderer.bottomAnchor.constraint(equalTo: localPreviewHostView.bottomAnchor),
      ])
      localPreviewRenderer = renderer
    }
  }

  private func detachVideoRenderers() {
    if let track = attachedRemoteVideoTrack, let renderer = remoteVideoRenderer {
      track.remove(renderer)
    }
    if let track = attachedLocalVideoTrack, let renderer = localPreviewRenderer {
      track.remove(renderer)
    }
    attachedRemoteVideoTrack = nil
    attachedLocalVideoTrack = nil
    attachedRemoteStreamId = nil
    attachedLocalStreamId = nil
  }

  private func attachRemoteVideo(streamId: String?) {
    guard let renderer = remoteVideoRenderer else { return }
    if attachedRemoteStreamId == streamId { return }
    if let track = attachedRemoteVideoTrack {
      track.remove(renderer)
    }
    attachedRemoteVideoTrack = nil
    attachedRemoteStreamId = streamId
    guard let track = resolveVideoTrack(streamId: streamId) else {
      NSLog("[VibeNativeCall][UiScreen] attachRemoteVideo no track streamId=%@", streamId ?? "nil")
      return
    }
    NSLog("[VibeNativeCall][UiScreen] attachRemoteVideo streamId=%@", streamId ?? "nil")
    attachedRemoteVideoTrack = track
    track.add(renderer)
  }

  private func attachLocalPreview(streamId: String?) {
    guard let renderer = localPreviewRenderer else { return }
    if attachedLocalStreamId == streamId { return }
    if let track = attachedLocalVideoTrack {
      track.remove(renderer)
    }
    attachedLocalVideoTrack = nil
    attachedLocalStreamId = streamId
    guard let track = resolveVideoTrack(streamId: streamId) else {
      NSLog("[VibeNativeCall][UiScreen] attachLocalPreview no track streamId=%@", streamId ?? "nil")
      scheduleLocalPreviewAttachRetry(streamId: streamId)
      return
    }
    NSLog("[VibeNativeCall][UiScreen] attachLocalPreview streamId=%@", streamId ?? "nil")
    localPreviewAttachRetryWorkItem?.cancel()
    localPreviewAttachRetryWorkItem = nil
    attachedLocalVideoTrack = track
    track.add(renderer)
  }

  private func scheduleLocalPreviewAttachRetry(streamId: String?) {
    localPreviewAttachRetryWorkItem?.cancel()
    guard let streamId else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      guard self.attachedLocalStreamId == streamId, self.attachedLocalVideoTrack == nil else {
        return
      }
      NSLog("[VibeNativeCall][UiScreen] retry attachLocalPreview streamId=%@", streamId)
      self.attachLocalPreview(streamId: streamId)
    }
    localPreviewAttachRetryWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
  }

  private func resolveVideoTrack(streamId: String?) -> RTCVideoTrack? {
    guard
      let streamId,
      let stream = resolveMediaStream(reactTag: streamId)
    else { return nil }
    let track = stream.videoTracks.first
    if track == nil {
      NSLog("[VibeNativeCall][UiScreen] resolveVideoTrack no video tracks streamId=%@", streamId)
    }
    return track
  }

  private func resolveMediaStream(reactTag: String) -> RTCMediaStream? {
    guard let bridgeObject = coordinator?.reactBridgeObject() as? NSObject else {
      NSLog("[VibeNativeCall][UiScreen] resolveMediaStream no reactBridge reactTag=%@", reactTag)
      return nil
    }

    let moduleObject: NSObject? = {
      let lazySelector = NSSelectorFromString("moduleForName:lazilyLoadIfNecessary:")
      if bridgeObject.responds(to: lazySelector),
        let result = bridgeObject.perform(
          lazySelector, with: "WebRTCModule", with: NSNumber(value: true))?
          .takeUnretainedValue() as? NSObject
      {
        return result
      }
      let selector = NSSelectorFromString("moduleForName:")
      if bridgeObject.responds(to: selector),
        let result = bridgeObject.perform(selector, with: "WebRTCModule")?.takeUnretainedValue()
          as? NSObject
      {
        return result
      }
      return nil
    }()

    guard let webRtcModule = moduleObject else {
      NSLog("[VibeNativeCall][UiScreen] resolveMediaStream no WebRTCModule reactTag=%@", reactTag)
      return nil
    }

    let streamSelector = NSSelectorFromString("streamForReactTag:")
    guard webRtcModule.responds(to: streamSelector) else {
      NSLog(
        "[VibeNativeCall][UiScreen] resolveMediaStream missing streamForReactTag selector reactTag=%@",
        reactTag)
      return nil
    }

    let workerQueueSelector = NSSelectorFromString("workerQueue")
    let workerQueue =
      webRtcModule.responds(to: workerQueueSelector)
      ? (webRtcModule.perform(workerQueueSelector)?.takeUnretainedValue() as? DispatchQueue)
      : nil

    var resolvedStream: RTCMediaStream?
    let resolveBlock = {
      let streamObj = webRtcModule.perform(streamSelector, with: reactTag)?.takeUnretainedValue()
      resolvedStream = streamObj as? RTCMediaStream
    }

    if let workerQueue {
      workerQueue.sync(execute: resolveBlock)
    } else {
      NSLog(
        "[VibeNativeCall][UiScreen] resolveMediaStream no workerQueue fallback main reactTag=%@",
        reactTag)
      resolveBlock()
    }

    if resolvedStream == nil {
      NSLog("[VibeNativeCall][UiScreen] resolveMediaStream miss reactTag=%@", reactTag)
    }
    return resolvedStream
  }

  private func updateStatusPresentation(animated: Bool) {
    let palette = palette(for: currentState)
    let mode = (currentState["mode"] as? String) ?? "hidden"
    let presentation = statusPresentation(mode: mode, state: currentState)
    if presentation.kindKey != lastStatusKindKey {
      lastStatusKindKey = presentation.kindKey
      statusTick = 0
    }

    let nextText = renderedStatusText(for: presentation, state: currentState)
    if nextText != lastRenderedStatusText {
      if animated, !lastRenderedStatusText.isEmpty {
        UIView.transition(
          with: statusLabel,
          duration: 0.18,
          options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
        ) {
          self.statusLabel.text = nextText
        }
      } else {
        statusLabel.text = nextText
      }
      lastRenderedStatusText = nextText
    }

    let shouldShimmer =
      presentation.kindKey == "connecting"
      || presentation.kindKey == "ringing"
      || presentation.kindKey == "reconnecting"

    statusLabel.textColor =
      shouldShimmer
      ? palette.textDim.withAlphaComponent(palette.isDark ? 0.92 : 0.84)
      : presentation.signal.statusTextColor(in: palette)
    setStatusShimmerEnabled(shouldShimmer)
    applyConnectionSignal(
      presentation.signal,
      palette: palette,
      showsDot: presentation.kindKey == "active"
    )
    setStatusTickerEnabled(false)
  }

  private func setStatusTickerEnabled(_ enabled: Bool) {
    if enabled {
      guard statusTicker == nil else { return }
      let timer = Timer.scheduledTimer(
        timeInterval: 0.42,
        target: self,
        selector: #selector(onStatusTicker),
        userInfo: nil,
        repeats: true
      )
      RunLoop.main.add(timer, forMode: .common)
      statusTicker = timer
    } else {
      statusTicker?.invalidate()
      statusTicker = nil
    }
  }

  @objc private func onStatusTicker() {
    statusTick = (statusTick + 1) % 4
    updateStatusPresentation(animated: true)
  }

  private func statusPresentation(mode: String, state: [String: Any]) -> CallStatusPresentation {
    if mode == "incoming" {
      return CallStatusPresentation(
        kindKey: "incoming",
        baseText: "Tap accept to answer",
        animatesDots: false,
        signal: .warning
      )
    }

    let status = (state["callStatus"] as? String) ?? "active"
    switch status {
    case "connecting":
      return .init(
        kindKey: "connecting", baseText: "Connecting", animatesDots: true, signal: .warning)
    case "reconnecting":
      return .init(
        kindKey: "reconnecting",
        baseText: "Recovering connection",
        animatesDots: true,
        signal: .poor
      )
    case "ringing":
      return .init(kindKey: "ringing", baseText: "Ringing", animatesDots: true, signal: .warning)
    case "failed":
      return .init(
        kindKey: "failed", baseText: "Connection lost", animatesDots: false, signal: .poor)
    case "ended":
      let reason = ((state["endReason"] as? String) ?? "").lowercased()
      let text: String
      switch reason {
      case "rejected", "declined":
        text = "Rejected"
      case "missed":
        text = "Missed"
      default:
        text = "Ended"
      }
      return .init(kindKey: "ended", baseText: text, animatesDots: false, signal: .neutral)
    case "active":
      return .init(kindKey: "active", baseText: "", animatesDots: false, signal: .good)
    default:
      return .init(
        kindKey: status.lowercased(),
        baseText: status.capitalized,
        animatesDots: false,
        signal: .neutral
      )
    }
  }

  private func renderedStatusText(for presentation: CallStatusPresentation, state: [String: Any])
    -> String
  {
    if presentation.kindKey == "active" {
      let total = (state["callDuration"] as? NSNumber)?.intValue ?? 0
      return "\(total / 60):" + String(format: "%02d", total % 60)
    }
    return presentation.baseText
  }

  private func setStatusShimmerEnabled(_ enabled: Bool) {
    guard enabled != isStatusShimmerActive else { return }
    isStatusShimmerActive = enabled

    statusShimmerMaskLayer.removeAllAnimations()

    if enabled {
      statusShimmerMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
      statusShimmerMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
      statusShimmerMaskLayer.colors = [
        UIColor.white.withAlphaComponent(0.10).cgColor,
        UIColor.white.withAlphaComponent(0.62).cgColor,
        UIColor.white.withAlphaComponent(0.10).cgColor,
      ]
      statusShimmerMaskLayer.locations = [0.0, 0.18, 0.36]
      statusShimmerMaskLayer.frame = statusLabel.bounds
      statusLabel.layer.mask = statusShimmerMaskLayer

      let animation = CABasicAnimation(keyPath: "locations")
      animation.fromValue = [-0.45, -0.2, 0.05]
      animation.toValue = [0.95, 1.2, 1.45]
      animation.duration = 1.08
      animation.repeatCount = .infinity
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      animation.isRemovedOnCompletion = false
      statusShimmerMaskLayer.add(animation, forKey: "shimmer")
    } else {
      statusLabel.layer.mask = nil
    }
  }

  private func applyConnectionSignal(
    _ signal: ConnectionSignal,
    palette: Palette,
    showsDot: Bool
  ) {
    connectionDotHost.isHidden = !showsDot
    if !showsDot {
      connectionDotGlow.layer.removeAllAnimations()
      connectionDotView.layer.removeAnimation(forKey: "dotPulse")
      connectionDotGlow.alpha = 0
      return
    }

    let color = signal.dotColor(in: palette)
    connectionDotView.backgroundColor = color
    connectionDotGlow.backgroundColor = color.withAlphaComponent(0.24)
    connectionDotView.layer.shadowColor = color.cgColor
    connectionDotView.layer.shadowOpacity = 0.35
    connectionDotView.layer.shadowRadius = 6
    connectionDotView.layer.shadowOffset = .zero

    connectionDotGlow.layer.removeAllAnimations()
    connectionDotView.layer.removeAnimation(forKey: "dotPulse")

    let pulseDuration: CFTimeInterval?
    switch signal {
    case .good:
      pulseDuration = 1.6
    case .warning:
      pulseDuration = 1.0
    case .poor:
      pulseDuration = 0.72
    case .neutral:
      pulseDuration = nil
    }

    guard let duration = pulseDuration else {
      connectionDotGlow.alpha = 0
      return
    }

    connectionDotGlow.alpha = 1

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.95
    scale.toValue = 1.9
    scale.duration = duration
    scale.repeatCount = .infinity
    scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = signal == .poor ? 0.55 : 0.4
    opacity.toValue = 0.0
    opacity.duration = duration
    opacity.repeatCount = .infinity
    opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let group = CAAnimationGroup()
    group.animations = [scale, opacity]
    group.duration = duration
    group.repeatCount = .infinity
    group.isRemovedOnCompletion = false
    connectionDotGlow.layer.add(group, forKey: "glowPulse")

    let dotPulse = CABasicAnimation(keyPath: "transform.scale")
    dotPulse.fromValue = 1.0
    dotPulse.toValue = signal == .good ? 1.08 : 1.14
    dotPulse.autoreverses = true
    dotPulse.duration = duration * 0.5
    dotPulse.repeatCount = .infinity
    dotPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    connectionDotView.layer.add(dotPulse, forKey: "dotPulse")
  }

  private func applyWallpaperAppearance(
    from state: [String: Any], palette: Palette, preferWallpaper: Bool
  ) {
    let fallbackGradient = palette.backgroundGradient
    let wallpaperGradient =
      preferWallpaper
      ? parseGradient(
        state["wallpaperGradient"] as? [String],
        fallback: fallbackGradient
      )
      : fallbackGradient

    wallpaperLayer.colors = wallpaperGradient.map(\.cgColor)
    wallpaperLayer.opacity = Float(
      max(
        0.0,
        min(
          1.0,
          preferWallpaper
            ? ((state["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0)
            : 1.0
        )
      )
    )
    wallpaperLayer.isHidden = false

    let patternGradient = parseGradient(
      state["wallpaperPatternGradient"] as? [String], fallback: [])
    let patternLocations = parseNumberArray(state["wallpaperPatternLocations"])
    let patternOpacity = CGFloat(
      (state["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? 0.0)
    let maskKey = normalizedString(state["wallpaperMaskKey"])

    let canShowPattern =
      preferWallpaper
      && patternGradient.count >= 2
      && patternOpacity > 0.001
      && (maskKey?.isEmpty == false)

    if canShowPattern,
      let maskKey,
      let maskImage = resolvedWallpaperMaskImage(for: maskKey)
    {
      wallpaperPatternLayer.colors = patternGradient.map(\.cgColor)
      wallpaperPatternLayer.locations = patternLocations
      wallpaperPatternLayer.opacity = Float(max(0.0, min(1.0, patternOpacity)))
      wallpaperPatternMaskLayer.contents = maskImage
      wallpaperPatternLayer.isHidden = false
    } else {
      wallpaperPatternLayer.isHidden = true
      wallpaperPatternLayer.colors = nil
      wallpaperPatternLayer.locations = nil
      wallpaperPatternLayer.opacity = 0
      wallpaperPatternMaskLayer.contents = nil
    }

    wallpaperTopScrimLayer.colors = [
      palette.background.withAlphaComponent(palette.isDark ? 0.34 : 0.08).cgColor,
      UIColor.clear.cgColor,
    ]
    wallpaperBottomScrimLayer.colors = [
      UIColor.clear.cgColor,
      palette.background.withAlphaComponent(palette.isDark ? 0.18 : 0.08).cgColor,
      palette.background.withAlphaComponent(palette.isDark ? 0.68 : 0.36).cgColor,
    ]
  }

  private func resolvedWallpaperMaskImage(for key: String) -> CGImage? {
    ChatWallpaperMaskStore.image(
      forKey: key,
      bundles: [Bundle.main, Bundle(for: VibeNativeCallScreenController.self)]
    )
  }

  private func makeButtonStack(key: String, label: String, size: CGFloat, showLabel: Bool = true)
    -> UIView
  {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 5

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      container.widthAnchor.constraint(equalToConstant: size),
      container.heightAnchor.constraint(equalToConstant: size),
    ])

    let glass = UIVisualEffectView()
    glass.translatesAutoresizingMaskIntoConstraints = false
    glass.layer.cornerRadius = size / 2
    glass.layer.cornerCurve = .continuous
    glass.layer.masksToBounds = true
    glass.effect = makeGlassEffect()
    glass.isUserInteractionEnabled = false
    container.addSubview(glass)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      glass.topAnchor.constraint(equalTo: container.topAnchor),
      glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.layer.cornerRadius = size / 2
    button.layer.masksToBounds = true
    button.addTarget(self, action: #selector(onButtonTap(_:)), for: .touchUpInside)
    button.accessibilityIdentifier = key
    container.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      button.topAnchor.constraint(equalTo: container.topAnchor),
      button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    stack.addArrangedSubview(container)

    if showLabel {
      let labelView = UILabel()
      labelView.text = label
      labelView.font = .systemFont(ofSize: 10, weight: .semibold)
      labelView.textAlignment = .center
      stack.addArrangedSubview(labelView)
      buttonLabels[key] = labelView
    }

    buttons[key] = button
    buttonStacks[key] = stack
    return stack
  }

  @objc private func onButtonTap(_ sender: UIControl) {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred()

    guard let key = sender.accessibilityIdentifier else { return }
    let event: String
    switch key {
    case "incomingAccept": event = "accept"
    case "incomingDecline": event = "decline"
    case "msg": event = "message"
    case "remind": event = "remind"
    case "mute": event = "toggleMute"
    case "speaker": event = "toggleSpeaker"
    case "video": event = "toggleVideo"
    case "flip": event = "flipCamera"
    case "end": event = "end"
    default: event = "noop"
    }
    NSLog("[VibeNativeCall][UiScreen] buttonTap key=%@ event=%@", key, event)
    coordinator?.emitEvent(event)
  }


  private func styleButton(
    _ key: String,
    bg: UIColor,
    symbol: String,
    fg: UIColor,
    labelColor: UIColor? = nil
  ) {
    guard let button = buttons[key] else { return }
    button.backgroundColor = bg
    button.tintColor = fg

    let config = UIImage.SymbolConfiguration(weight: .semibold)
    button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
    buttonLabels[key]?.textColor = labelColor ?? palette(for: currentState).textSubtle
  }

  private func palette(for state: [String: Any]) -> Palette {
    let isDark = (state["isDark"] as? Bool) ?? true
    return isDark ? .dark : .light
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    let isDark = (currentState["isDark"] as? Bool) ?? true
    return isDark ? .lightContent : .darkContent
  }
}

private struct CallStatusPresentation {
  let kindKey: String
  let baseText: String
  let animatesDots: Bool
  let signal: ConnectionSignal
}

private enum ConnectionSignal {
  case neutral
  case good
  case warning
  case poor

  func dotColor(in palette: Palette) -> UIColor {
    switch self {
    case .neutral: return palette.textSubtle
    case .good: return palette.connectionGood
    case .warning: return palette.connectionWarn
    case .poor: return palette.connectionBad
    }
  }

  func statusTextColor(in palette: Palette) -> UIColor {
    switch self {
    case .good: return palette.textDim
    case .warning: return palette.connectionWarnText
    case .poor: return palette.connectionBadText
    case .neutral: return palette.textSubtle
    }
  }
}

private final class NativeCallInsetLabel: UILabel {
  var textInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14) {
    didSet {
      guard oldValue != textInsets else { return }
      invalidateIntrinsicContentSize()
      setNeedsDisplay()
    }
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: textInsets))
  }

  override var intrinsicContentSize: CGSize {
    let base = super.intrinsicContentSize
    return CGSize(
      width: base.width + textInsets.left + textInsets.right,
      height: base.height + textInsets.top + textInsets.bottom
    )
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let insetSize = CGSize(
      width: max(0, size.width - textInsets.left - textInsets.right),
      height: max(0, size.height - textInsets.top - textInsets.bottom)
    )
    let base = super.sizeThatFits(insetSize)
    return CGSize(
      width: base.width + textInsets.left + textInsets.right,
      height: base.height + textInsets.top + textInsets.bottom
    )
  }
}

private final class NativeCallActionChip: UIControl {
  private let fillView = UIView()
  private let pressedOverlayView = UIView()
  private let contentStack = UIStackView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()

  init(title: String, width: CGFloat, height: CGFloat) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    layer.cornerCurve = .continuous
    layer.masksToBounds = false

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: width),
      heightAnchor.constraint(equalToConstant: height),
    ])

    fillView.translatesAutoresizingMaskIntoConstraints = false
    fillView.isUserInteractionEnabled = false
    fillView.layer.cornerCurve = .continuous
    fillView.layer.masksToBounds = true
    addSubview(fillView)
    NSLayoutConstraint.activate([
      fillView.leadingAnchor.constraint(equalTo: leadingAnchor),
      fillView.trailingAnchor.constraint(equalTo: trailingAnchor),
      fillView.topAnchor.constraint(equalTo: topAnchor),
      fillView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    pressedOverlayView.translatesAutoresizingMaskIntoConstraints = false
    pressedOverlayView.isUserInteractionEnabled = false
    pressedOverlayView.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    pressedOverlayView.layer.cornerCurve = .continuous
    pressedOverlayView.layer.masksToBounds = true
    pressedOverlayView.alpha = 0
    addSubview(pressedOverlayView)
    NSLayoutConstraint.activate([
      pressedOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pressedOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pressedOverlayView.topAnchor.constraint(equalTo: topAnchor),
      pressedOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    contentStack.axis = .horizontal
    contentStack.alignment = .center
    contentStack.distribution = .fill
    contentStack.spacing = 3
    contentStack.isUserInteractionEnabled = false
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)
    NSLayoutConstraint.activate([
      contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
      contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
      contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
    ])

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 15, weight: .semibold)
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 16),
      iconView.heightAnchor.constraint(equalToConstant: 16),
    ])
    contentStack.addArrangedSubview(iconView)

    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentStack.addArrangedSubview(titleLabel)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.height / 2
    fillView.layer.cornerRadius = bounds.height / 2
    pressedOverlayView.layer.cornerRadius = bounds.height / 2
  }

  override var isHighlighted: Bool {
    didSet {
      let isPressed = isHighlighted
      let scale: CGFloat = isPressed ? 0.97 : 1.0
      let duration: TimeInterval = isPressed ? 0.1 : 0.22
      let damping: CGFloat = isPressed ? 1.0 : 0.78

      UIView.animate(
        withDuration: duration,
        delay: 0,
        usingSpringWithDamping: damping,
        initialSpringVelocity: 0.25,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
      ) {
        self.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.alpha = isPressed ? 0.78 : 1.0
        self.pressedOverlayView.alpha = isPressed ? 1.0 : 0.0
      }
    }
  }

  func apply(
    title: String,
    symbol: String,
    fillColor: UIColor,
    iconTintColor: UIColor,
    textColor: UIColor,
    borderColor: UIColor,
    showsTitle: Bool
  ) {
    titleLabel.text = title
    titleLabel.textColor = textColor
    titleLabel.isHidden = !showsTitle
    contentStack.spacing = showsTitle ? 5 : 0
    iconView.tintColor = iconTintColor
    iconView.image = UIImage(systemName: symbol)
    fillView.backgroundColor = fillColor
    layer.borderColor = borderColor.cgColor
  }
}

private struct Palette {
  let isDark: Bool
  let background: UIColor
  let backgroundGradient: [UIColor]
  let text: UIColor
  let textSubtle: UIColor
  let textDim: UIColor
  let surfaceSoft: UIColor
  let avatarBg: UIColor
  let avatarRing: UIColor
  let controlBg: UIColor
  let controlActiveBg: UIColor
  let controlBarBg: UIColor
  let glassBorder: UIColor
  let danger: UIColor
  let accent: UIColor
  let connectionGood: UIColor
  let connectionWarn: UIColor
  let connectionBad: UIColor
  let connectionWarnText: UIColor
  let connectionBadText: UIColor

  static let dark = Palette(
    isDark: true,
    background: UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
    backgroundGradient: [
      UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
      UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1),
    ],
    text: .white,
    textSubtle: UIColor.white.withAlphaComponent(0.66),
    textDim: UIColor.white.withAlphaComponent(0.9),
    surfaceSoft: UIColor.white.withAlphaComponent(0.10),
    avatarBg: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 0.18),
    avatarRing: UIColor.white.withAlphaComponent(0.18),
    controlBg: UIColor.white.withAlphaComponent(0.12),
    controlActiveBg: UIColor.white.withAlphaComponent(0.92),
    controlBarBg: UIColor.black.withAlphaComponent(0.34),
    glassBorder: UIColor.white.withAlphaComponent(0.12),
    danger: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.92),
    accent: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 1),
    connectionGood: UIColor(red: 0.23, green: 0.84, blue: 0.44, alpha: 1),
    connectionWarn: UIColor(red: 0.96, green: 0.78, blue: 0.20, alpha: 1),
    connectionBad: UIColor(red: 0.98, green: 0.33, blue: 0.33, alpha: 1),
    connectionWarnText: UIColor(red: 0.99, green: 0.86, blue: 0.43, alpha: 0.95),
    connectionBadText: UIColor(red: 1.00, green: 0.55, blue: 0.55, alpha: 0.95)
  )

  static let light = Palette(
    isDark: false,
    background: UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1),
    backgroundGradient: [
      UIColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1),
      UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1),
    ],
    text: UIColor(white: 0.08, alpha: 1),
    textSubtle: UIColor.black.withAlphaComponent(0.58),
    textDim: UIColor.black.withAlphaComponent(0.74),
    surfaceSoft: UIColor.white.withAlphaComponent(0.44),
    avatarBg: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 0.12),
    avatarRing: UIColor.black.withAlphaComponent(0.10),
    controlBg: UIColor.white.withAlphaComponent(0.46),
    controlActiveBg: UIColor.black.withAlphaComponent(0.84),
    controlBarBg: UIColor.white.withAlphaComponent(0.28),
    glassBorder: UIColor.white.withAlphaComponent(0.42),
    danger: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 0.94),
    accent: UIColor(red: 0.17, green: 0.44, blue: 1, alpha: 1),
    connectionGood: UIColor(red: 0.16, green: 0.69, blue: 0.35, alpha: 1),
    connectionWarn: UIColor(red: 0.87, green: 0.62, blue: 0.00, alpha: 1),
    connectionBad: UIColor(red: 0.85, green: 0.24, blue: 0.24, alpha: 1),
    connectionWarnText: UIColor(red: 0.48, green: 0.33, blue: 0.00, alpha: 0.92),
    connectionBadText: UIColor(red: 0.66, green: 0.12, blue: 0.12, alpha: 0.92)
  )
}

private func makeGlassEffect() -> UIVisualEffect {
  if #available(iOS 26.0, *) {
    return UIGlassEffect()
  }
  return UIBlurEffect(style: .systemUltraThinMaterial)
}

private func normalizedString(_ value: Any?) -> String? {
  guard let raw = value as? String else { return nil }
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func parseNumberArray(_ raw: Any?) -> [NSNumber]? {
  if let array = raw as? [NSNumber] { return array }
  if let array = raw as? [Double] { return array.map { NSNumber(value: $0) } }
  if let array = raw as? [CGFloat] { return array.map { NSNumber(value: Double($0)) } }
  if let array = raw as? [Int] { return array.map { NSNumber(value: $0) } }
  if let array = raw as? [String] {
    let parsed = array.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return parsed.count == array.count ? parsed.map { NSNumber(value: $0) } : nil
  }
  return nil
}

private func parseGradient(_ values: [String]?, fallback: [UIColor]) -> [UIColor] {
  guard let values else { return fallback }
  let colors = values.compactMap(parseColor)
  return colors.count >= 2 ? colors : fallback
}

private func parseGradient(_ values: [String], fallback: [UIColor]) -> [UIColor] {
  let colors = values.compactMap(parseColor)
  return colors.count >= 2 ? colors : fallback
}

private func parseColor(_ value: String?) -> UIColor? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if trimmed.hasPrefix("#") {
    return parseHexColor(trimmed)
  }
  if trimmed.hasPrefix("rgba(") || trimmed.hasPrefix("rgb(") {
    return parseRgbColor(trimmed)
  }
  return nil
}

private func parseHexColor(_ value: String) -> UIColor? {
  var hex = value
  if hex.hasPrefix("#") { hex.removeFirst() }
  if hex.count == 3 || hex.count == 4 {
    hex = hex.map { "\($0)\($0)" }.joined()
  }
  guard hex.count == 6 || hex.count == 8 else { return nil }

  var rgba: UInt64 = 0
  guard Scanner(string: hex).scanHexInt64(&rgba) else { return nil }

  if hex.count == 6 {
    let r = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
    let g = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
    let b = CGFloat(rgba & 0x0000FF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: 1.0)
  }

  let r = CGFloat((rgba & 0xFF00_0000) >> 24) / 255.0
  let g = CGFloat((rgba & 0x00FF_0000) >> 16) / 255.0
  let b = CGFloat((rgba & 0x0000_FF00) >> 8) / 255.0
  let a = CGFloat(rgba & 0x0000_00FF) / 255.0
  return UIColor(red: r, green: g, blue: b, alpha: a)
}

private func parseRgbColor(_ value: String) -> UIColor? {
  guard
    let open = value.firstIndex(of: "("),
    let close = value.lastIndex(of: ")"),
    open < close
  else { return nil }

  let args = value[value.index(after: open)..<close].split(separator: ",").map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard args.count == 3 || args.count == 4 else { return nil }

  guard
    let r = Double(args[0]),
    let g = Double(args[1]),
    let b = Double(args[2])
  else { return nil }

  let a = args.count == 4 ? (Double(args[3]) ?? 1.0) : 1.0
  return UIColor(
    red: CGFloat(max(0.0, min(255.0, r)) / 255.0),
    green: CGFloat(max(0.0, min(255.0, g)) / 255.0),
    blue: CGFloat(max(0.0, min(255.0, b)) / 255.0),
    alpha: CGFloat(max(0.0, min(1.0, a)))
  )
}
