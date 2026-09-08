import CoreImage
import UIKit

struct NativeMusicPlayerTheme {
  var isDark = true
  var surface = UIColor(white: 0.08, alpha: 1.0)
  var text = UIColor.white
  var secondaryText = UIColor(white: 1.0, alpha: 0.68)
  var primary = UIColor.systemBlue
}

private struct NativeMusicPlayerViewState {
  let currentTrack: NativeMusicPlayerTrack?
  let isPlaying: Bool
  let progressMs: Double
  let durationMs: Double
  let artworkImage: UIImage?
  let playbackRate: Double

  static let empty = NativeMusicPlayerViewState(
    currentTrack: nil,
    isPlaying: false,
    progressMs: 0.0,
    durationMs: 0.0,
    artworkImage: nil,
    playbackRate: 1.0
  )

  static func from(payload: [String: Any]) -> NativeMusicPlayerViewState {
    let currentTrack = (payload["currentTrack"] as? [String: Any]).flatMap(NativeMusicPlayerTrack.init)
    let rate =
      (payload["playbackRate"] as? NSNumber)?.doubleValue
      ?? (payload["playbackRate"] as? Double)
      ?? 1.0
    return NativeMusicPlayerViewState(
      currentTrack: currentTrack,
      isPlaying: (payload["isPlaying"] as? Bool) ?? false,
      progressMs: (payload["progress"] as? NSNumber)?.doubleValue ?? (payload["progress"] as? Double) ?? 0.0,
      durationMs: (payload["duration"] as? NSNumber)?.doubleValue ?? (payload["duration"] as? Double) ?? 0.0,
      artworkImage: nil,
      playbackRate: rate
    )
  }

  static func from(voiceSnapshot: VoiceBubblePlaybackSnapshot) -> NativeMusicPlayerViewState {
    guard let messageId = voiceSnapshot.messageId else { return .empty }
    let durationMs = max(0.0, voiceSnapshot.duration * 1000.0)
    let progressMs = durationMs * max(0.0, min(1.0, Double(voiceSnapshot.progress)))
    // Carry cover URL from the known playing row / store so banner + hero keep artwork
    // even when the snapshot only supplies a direct UIImage (or neither).
    let coverURL = Self.resolveCoverURL(forTrackId: messageId, chatId: voiceSnapshot.chatId)
    var links: [String: String] = [:]
    if let chatId = voiceSnapshot.chatId { links["chat_id"] = chatId }
    let track = NativeMusicPlayerTrack(
      trackId: messageId,
      videoId: nil,
      id: messageId,
      source: "chat-music",
      title: voiceSnapshot.title ?? "Audio",
      artist: voiceSnapshot.subtitle ?? "Vibegram",
      album: nil,
      duration: nil,
      durationSeconds: voiceSnapshot.duration > 0.0 ? voiceSnapshot.duration : nil,
      cover: coverURL,
      previewURL: nil,
      streamURL: nil,
      localURI: nil,
      cachedAt: nil,
      playCount: 0,
      lastPlayedAt: nil,
      links: links
    )
    return NativeMusicPlayerViewState(
      currentTrack: track,
      isPlaying: voiceSnapshot.isPlaying,
      progressMs: progressMs,
      durationMs: durationMs,
      artworkImage: voiceSnapshot.artwork,
      playbackRate: voiceSnapshot.playbackRate
    )
  }

  /// Prefer store / registry cover for a chat-music track id.
  fileprivate static func resolveCoverURL(forTrackId trackId: String, chatId: String?) -> String? {
    func clean(_ raw: String?) -> String? {
      raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    if let trimmed = clean(NativeMusicPlayerStore.shared.getTrack(trackId: trackId)?.cover) {
      return trimmed
    }
    if let chatId {
      if let trimmed = clean(
        NativeMusicPlayerStore.shared.tracks(forChatId: chatId)
          .first(where: { $0.trackId == trackId })?.cover
      ) {
        return trimmed
      }
      if let trimmed = clean(
        ChatAudioQueueRegistry.shared.tracks(for: chatId)
          .first(where: { $0.trackId == trackId })?.cover
      ) {
        return trimmed
      }
    }
    // Fall back to scanning the live voice queue.
    if let trimmed = clean(
      VoiceBubblePlaybackCoordinator.shared.displayQueueTracks()
        .first(where: { $0.trackId == trackId })?.cover
    ) {
      return trimmed
    }
    return nil
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

// MARK: - Native Music Player Banner (Pill)
// This is strictly the floating pill banner.
// It does NOT handle the expanded modal state itself.
//
// Liquid Glass rule (match ChatPinnedBannerView): ONE UIGlassEffect shell;
// ALL chrome lives inside blurView.contentView — never sibling overlays or nested glass.
final class NativeMusicPlayerBannerView: UIView, UIGestureRecognizerDelegate {
  /// Matches `ChatPinnedBannerView.preferredHeight`.
  static let miniHeight: CGFloat = 44.0
  /// Gap below the safe-area inset. Matches the home search bar's clearance below the
  /// header so the pill sits well under the nav chrome rather than crowding it.
  static let collapsedTopGap: CGFloat = 64.0

  private let miniBlurView = UIVisualEffectView(effect: nil)
  /// Content host inside the single glass shell (native UIGlassEffect interactive tab only).
  private let contentContainer = UIView()
  private let miniArtworkView = UIImageView()
  private let miniArtworkFallbackView = UIImageView()
  private let miniTitleLabel = UILabel()
  private let miniSubtitleLabel = UILabel()
  private let miniProgressTrackView = UIView()
  private let miniProgressFillView = UIView()
  private let miniProgressImageView = UIImageView()
  private let miniProgressTintView = UIView()
  private let miniSpeedButton = UIButton(type: .system)
  private let miniPlayButton = UIButton(type: .system)
  private let miniCloseButton = UIButton(type: .system)
  private let miniTextTapTarget = UIControl()

  private var theme = NativeMusicPlayerTheme()
  private var state = NativeMusicPlayerViewState.empty
  private var topInset: CGFloat = 0.0
  private var coverImageTask: URLSessionDataTask?
  private var miniDragOffset = CGPoint.zero
  private var miniDragStartOffset = CGPoint.zero
  /// Extra downward slide applied only while the pill is animating in. Drives a
  /// purely vertical (top→bottom) entrance through layout — no horizontal motion,
  /// so the capsule width never changes while it appears.
  private var entranceOffset: CGFloat = 0.0
  /// Tracks the last presented visibility so the entrance runs once per show.
  private var isBannerPresented = false
  /// What the pill is currently showing, so a republish that changes nothing is free.
  private var lastAppliedBannerSignature: String?
  private var lastPlayButtonSymbol: String?
  private var renderedCoverTrackId: String?
  private var renderedCoverURL: String?
  private var renderedArtworkIdentifier: ObjectIdentifier?
  private var renderedPlaybackRate: Double?

  private lazy var miniPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleMiniPan(_:)))

  var onTogglePlayback: (() -> Void)?
  var onClose: (() -> Void)?
  var onOpenModal: (() -> Void)?
  var onCyclePlaybackRate: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false

    // Single glass shell — capsule matches preferred height.
    miniBlurView.layer.cornerCurve = .continuous
    miniBlurView.layer.cornerRadius = Self.miniHeight / 2.0
    miniBlurView.clipsToBounds = true
    miniBlurView.contentView.clipsToBounds = true
    miniBlurView.contentView.backgroundColor = .clear
    addSubview(miniBlurView)

    // All chrome lives INSIDE the glass contentView (not external siblings).
    miniBlurView.contentView.addSubview(contentContainer)
    contentContainer.clipsToBounds = true
    contentContainer.backgroundColor = .clear

    // Progress fill is clipped by the glass shell only — no extra corner radius on the art.
    miniProgressTrackView.clipsToBounds = true
    miniProgressTrackView.isUserInteractionEnabled = false
    contentContainer.addSubview(miniProgressTrackView)

    // Soft full-banner art (blurred) — not a high-contrast photo strip.
    miniProgressImageView.contentMode = .scaleAspectFill
    miniProgressImageView.clipsToBounds = true
    miniProgressImageView.isUserInteractionEnabled = false
    miniProgressImageView.alpha = 0.55
    miniProgressFillView.addSubview(miniProgressImageView)

    // Appearance-driven soft scrim over art (never systemBlue / high-contrast).
    miniProgressTintView.isUserInteractionEnabled = false
    miniProgressFillView.addSubview(miniProgressTintView)

    miniProgressFillView.clipsToBounds = true
    miniProgressFillView.isUserInteractionEnabled = false
    miniProgressTrackView.addSubview(miniProgressFillView)

    // Leading cover: square, no corner radius (capsule glass already softens the shell).
    miniArtworkView.contentMode = .scaleAspectFill
    miniArtworkView.clipsToBounds = true
    miniArtworkView.layer.cornerRadius = 0
    miniArtworkView.isUserInteractionEnabled = false
    contentContainer.addSubview(miniArtworkView)

    miniArtworkFallbackView.contentMode = .scaleAspectFit
    miniArtworkFallbackView.image = UIImage(systemName: "music.note")
    miniArtworkFallbackView.isUserInteractionEnabled = false
    contentContainer.addSubview(miniArtworkFallbackView)

    miniTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    miniTitleLabel.numberOfLines = 1
    miniTitleLabel.isUserInteractionEnabled = false
    contentContainer.addSubview(miniTitleLabel)

    miniSubtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
    miniSubtitleLabel.numberOfLines = 1
    miniSubtitleLabel.isUserInteractionEnabled = false
    contentContainer.addSubview(miniSubtitleLabel)

    miniSpeedButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
    miniSpeedButton.addTarget(self, action: #selector(handleCycleSpeed), for: .touchUpInside)
    contentContainer.addSubview(miniSpeedButton)

    miniPlayButton.addTarget(self, action: #selector(handleTogglePlayback), for: .touchUpInside)
    contentContainer.addSubview(miniPlayButton)

    miniCloseButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    contentContainer.addSubview(miniCloseButton)

    // Open-modal + drag target. No custom press-scale — native UIGlassEffect.isInteractive only.
    miniTextTapTarget.backgroundColor = .clear
    miniTextTapTarget.addTarget(self, action: #selector(handleOpenModalClick), for: .touchUpInside)
    miniTextTapTarget.addGestureRecognizer(miniPanGesture)
    contentContainer.addSubview(miniTextTapTarget)
    contentContainer.sendSubviewToBack(miniTextTapTarget)
    contentContainer.bringSubviewToFront(miniSpeedButton)
    contentContainer.bringSubviewToFront(miniPlayButton)
    contentContainer.bringSubviewToFront(miniCloseButton)

    isHidden = true
    applyTheme(theme)
  }

  required init?(coder: NSCoder) { nil }

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    // One glass shell only — never nest another effect or opaque fill under it.
    applyGlassMaterial(to: miniBlurView, interactive: true, isDark: theme.isDark)

    // Appearance-system labels (not hard-coded white / blue).
    miniArtworkView.backgroundColor = UIColor.secondarySystemFill
    miniArtworkFallbackView.tintColor = UIColor.secondaryLabel
    miniTitleLabel.textColor = UIColor.label
    miniSubtitleLabel.textColor = UIColor.secondaryLabel

    miniProgressTrackView.backgroundColor = .clear
    miniProgressFillView.backgroundColor = .clear
    // Soft scrim over artwork — image color shows through, no systemBlue wash.
    miniProgressTintView.backgroundColor =
      theme.isDark
      ? UIColor.black.withAlphaComponent(0.18)
      : UIColor.white.withAlphaComponent(0.22)
    miniProgressImageView.alpha = theme.isDark ? 0.50 : 0.42
    miniPlayButton.tintColor = UIColor.label
    miniCloseButton.tintColor = UIColor.secondaryLabel
    miniSpeedButton.tintColor = UIColor.label
    miniSpeedButton.setTitleColor(UIColor.label.withAlphaComponent(0.92), for: .normal)

    applyMiniControlButtonStyle(button: miniPlayButton, systemName: state.isPlaying ? "pause.fill" : "play.fill")
    applyMiniControlButtonStyle(button: miniCloseButton, systemName: "xmark")
    applySpeedButton(rate: state.playbackRate)

    setNeedsLayout()
  }

  func setTopInset(_ value: CGFloat) {
    if abs(topInset - value) <= 0.5 { return }
    topInset = value
    setNeedsLayout()
  }

  func applyStatePayload(_ payload: [String: Any]) {
    applyState(NativeMusicPlayerViewState.from(payload: payload))
  }

  func applyVoiceSnapshot(_ snapshot: VoiceBubblePlaybackSnapshot) {
    applyState(NativeMusicPlayerViewState.from(voiceSnapshot: snapshot))
  }

  private func applyState(_ nextState: NativeMusicPlayerViewState) {
    state = nextState
    let shouldShow = nextState.currentTrack != nil
    let wasPresented = isBannerPresented
    isBannerPresented = shouldShow
    isHidden = !shouldShow
    guard shouldShow, let track = nextState.currentTrack else {
      // Reset entrance state so the next appearance animates fresh.
      lastAppliedBannerSignature = nil
      entranceOffset = 0.0
      alpha = 1.0
      return
    }

    let title = track.title
    let detail = playbackDetailText(for: nextState, track: track)
    // The playback source republishes on a timer for as long as anything is playing, and
    // the elapsed readout only ticks once a second — so almost every call arrives with
    // nothing to show. Re-laying out the pill anyway put avoidable work in every scroll.
    let signature = [
      track.trackId, title, detail,
      nextState.isPlaying ? "1" : "0",
      String(format: "%.2f", nextState.playbackRate),
      nextState.artworkImage.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "-",
    ].joined(separator: "|")
    guard signature != lastAppliedBannerSignature || !wasPresented else { return }
    lastAppliedBannerSignature = signature

    miniTitleLabel.text = title
    miniSubtitleLabel.text = detail

    updateCoverImageIfNeeded(for: track, directImage: nextState.artworkImage)
    applyPlaybackButtons(for: nextState)
    applySpeedButton(rate: nextState.playbackRate)

    setNeedsLayout()

    // First appearance for this playback session → animate the pill in vertically.
    if !wasPresented {
      animateBannerEntrance()
    }
  }

  /// Vertical-only entrance: the pill drops in from just above its resting spot and
  /// fades up. Driven through layout (frames, not transforms) so it never fights the
  /// frame the layout pass assigns — and never moves horizontally, keeping the
  /// capsule width fixed as it appears.
  private func animateBannerEntrance() {
    entranceOffset = -18.0
    alpha = 0.0
    setNeedsLayout()
    layoutIfNeeded()
    UIView.animate(
      withDuration: 0.4,
      delay: 0.0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: 0.3,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.entranceOffset = 0.0
      self.alpha = 1.0
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let collapsedY = max(12.0, topInset + Self.collapsedTopGap)
    let collapsedInset: CGFloat = 16.0
    let collapsedWidth = bounds.width - (collapsedInset * 2.0)
    let baseMiniFrame = CGRect(
      x: collapsedInset,
      y: collapsedY,
      width: max(0.0, collapsedWidth),
      height: Self.miniHeight
    )

    miniDragOffset = clampedMiniOffset(miniDragOffset, for: baseMiniFrame)
    // Horizontal position is fixed (centered); only the vertical drag + entrance
    // slide move the pill.
    let miniFrame = baseMiniFrame.offsetBy(dx: 0.0, dy: miniDragOffset.y + entranceOffset)

    miniBlurView.frame = miniFrame
    miniBlurView.layer.cornerRadius = Self.miniHeight / 2.0
    contentContainer.frame = miniBlurView.contentView.bounds

    let host = contentContainer.bounds
    // Progress track fills the capsule; image is full-width so the fill only
    // reveals more of the same soft art as progress grows (not a static stamp).
    miniProgressTrackView.frame = host
    miniProgressTrackView.layer.cornerRadius = 0

    let duration = max(state.durationMs, (state.currentTrack?.durationSeconds ?? 0.0) * 1000.0, 1.0)
    let progress = CGFloat(max(0.0, min(1.0, state.progressMs / duration)))

    let trackW = miniProgressTrackView.bounds.width
    let trackH = miniProgressTrackView.bounds.height
    let miniProgressWidth = trackW * progress
    miniProgressFillView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: max(0.0, min(trackW, miniProgressWidth)),
      height: trackH
    )
    miniProgressFillView.layer.cornerRadius = 0
    // Full banner width art inside the fill so cropping reveals continuous image.
    miniProgressImageView.frame = CGRect(x: 0.0, y: 0.0, width: trackW, height: trackH)
    miniProgressTintView.frame = miniProgressImageView.bounds

    let artworkSide: CGFloat = 24.0
    miniArtworkView.frame = CGRect(
      x: 12.0,
      y: (host.height - artworkSide) / 2.0,
      width: artworkSide,
      height: artworkSide
    )
    miniArtworkView.layer.cornerRadius = 0
    miniArtworkFallbackView.frame = miniArtworkView.frame.insetBy(dx: 5.0, dy: 5.0)

    let controlSide: CGFloat = 24.0
    let speedWidth: CGFloat = 34.0
    miniCloseButton.frame = CGRect(
      x: host.width - 10.0 - controlSide,
      y: (host.height - controlSide) * 0.5,
      width: controlSide,
      height: controlSide
    )
    miniPlayButton.frame = CGRect(
      x: miniCloseButton.frame.minX - 28.0,
      y: (host.height - controlSide) * 0.5,
      width: controlSide,
      height: controlSide
    )
    miniSpeedButton.frame = CGRect(
      x: miniPlayButton.frame.minX - 4.0 - speedWidth,
      y: (host.height - controlSide) * 0.5,
      width: speedWidth,
      height: controlSide
    )

    let textX = miniArtworkView.frame.maxX + 10.0
    let textRight = miniSpeedButton.frame.minX - 8.0
    let textTop: CGFloat = 6.0
    miniTitleLabel.frame = CGRect(
      x: textX,
      y: textTop,
      width: max(0.0, textRight - textX),
      height: 15.0
    )
    miniSubtitleLabel.frame = CGRect(
      x: textX,
      y: miniTitleLabel.frame.maxY + 1.0,
      width: miniTitleLabel.frame.width,
      height: 13.0
    )
    // Full-width open target; controls sit above via bringSubviewToFront.
    miniTextTapTarget.frame = host
  }

  func containsInteractivePoint(_ point: CGPoint) -> Bool {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return false }
    let hitInset: CGFloat = 10.0
    return miniBlurView.frame.insetBy(dx: -hitInset, dy: -hitInset).contains(point)
  }

  private func clampedMiniOffset(_ proposedOffset: CGPoint, for baseFrame: CGRect) -> CGPoint {
    let minY = -baseFrame.minY + max(12.0, topInset + 10.0)
    let maxY = max(minY, bounds.height - baseFrame.maxY - 24.0)
    // Horizontal offset is pinned to 0 so the capsule stays centered; only vertical
    // repositioning is allowed.
    return CGPoint(
      x: 0.0,
      y: min(max(proposedOffset.y, minY), maxY)
    )
  }

  @objc private func handleMiniPan(_ gesture: UIPanGestureRecognizer) {
    guard !isHidden else { return }
    let collapsedY = max(12.0, topInset + Self.collapsedTopGap)
    let collapsedInset: CGFloat = 16.0
    let baseMiniFrame = CGRect(
      x: collapsedInset,
      y: collapsedY,
      width: max(0.0, bounds.width - (collapsedInset * 2.0)),
      height: Self.miniHeight
    )
    switch gesture.state {
    case .began:
      miniDragStartOffset = miniDragOffset
    case .changed, .ended:
      let t = gesture.translation(in: self)
      // Vertical drag only — the banner stays horizontally centered.
      miniDragOffset = clampedMiniOffset(
        CGPoint(x: 0.0, y: miniDragStartOffset.y + t.y),
        for: baseMiniFrame
      )
      setNeedsLayout()
    default: break
    }
  }

  @objc private func handleTogglePlayback() { onTogglePlayback?() }
  @objc private func handleClose() { onClose?() }
  @objc private func handleOpenModalClick() { onOpenModal?() }
  @objc private func handleCycleSpeed() { onCyclePlaybackRate?() }

  /// Mirror `ChatPinnedBannerView.applyTheme` glass material.
  private func applyGlassMaterial(to blurView: UIVisualEffectView, interactive: Bool, isDark: Bool) {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = interactive
      blurView.effect = glass
      blurView.contentView.backgroundColor = .clear
    } else {
      blurView.effect = UIBlurEffect(style: .systemThinMaterial)
      blurView.contentView.backgroundColor = theme.surface.withAlphaComponent(isDark ? 0.16 : 0.10)
    }
    backgroundColor = .clear
    blurView.alpha = 1.0
  }

  private func applyMiniControlButtonStyle(button: UIButton, systemName: String) {
    button.setImage(
      UIImage(
        systemName: systemName,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
      ),
      for: .normal
    )
  }

  private func applySpeedButton(rate: Double) {
    renderedPlaybackRate = rate
    miniSpeedButton.setTitle(Self.formatPlaybackRate(rate), for: .normal)
  }

  private static func formatPlaybackRate(_ rate: Double) -> String {
    let rounded = (rate * 10.0).rounded() / 10.0
    if abs(rounded - rounded.rounded()) < 0.05 {
      return "\(Int(rounded.rounded()))×"
    }
    // Trim trailing zero for 1.5 → "1.5×"
    let text = String(format: "%.1f", rounded)
    return "\(text)×"
  }

  private func updateCoverImageIfNeeded(for track: NativeMusicPlayerTrack, directImage: UIImage?) {
    let normalizedCoverURL = track.cover?.trimmingCharacters(in: .whitespacesAndNewlines)
    let imageIdentifier = directImage.map(ObjectIdentifier.init)
    guard
      renderedCoverTrackId != track.trackId
        || renderedCoverURL != normalizedCoverURL
        || renderedArtworkIdentifier != imageIdentifier
    else {
      return
    }

    renderedCoverTrackId = track.trackId
    renderedCoverURL = normalizedCoverURL
    renderedArtworkIdentifier = imageIdentifier
    updateCoverImage(urlString: normalizedCoverURL, directImage: directImage)
  }

  private func updateCoverImage(urlString: String?, directImage: UIImage?) {
    coverImageTask?.cancel()
    coverImageTask = nil
    if let directImage {
      applyBannerArtwork(directImage)
      return
    }
    // Keep prior image until the cached load returns (avoids banner artwork flash).
    if miniArtworkView.image == nil {
      miniArtworkFallbackView.isHidden = false
    }
    guard let urlStr = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !urlStr.isEmpty
    else {
      miniArtworkView.image = nil
      miniProgressImageView.image = nil
      miniArtworkFallbackView.isHidden = false
      return
    }
    let expectedURL = urlStr
    let expectedTrackId = renderedCoverTrackId
    coverImageTask = chatLoadMusicCover(urlString: urlStr) { [weak self] image in
      guard let self else { return }
      guard self.renderedCoverURL == expectedURL, self.renderedCoverTrackId == expectedTrackId else {
        return
      }
      self.applyBannerArtwork(image)
    }
  }

  /// Sharp thumbnail + soft (blurred, low-contrast) progress wash from the same art.
  private func applyBannerArtwork(_ image: UIImage) {
    miniArtworkView.image = image
    miniProgressImageView.image = Self.softProgressArtwork(from: image) ?? image
    miniArtworkFallbackView.isHidden = true
    setNeedsLayout()
  }

  /// Blurred, slightly darkened art for the progress fill — not a high-contrast photo.
  private static func softProgressArtwork(from image: UIImage) -> UIImage? {
    guard let ciImage = CIImage(image: image) else { return nil }
    let extent = ciImage.extent
    guard extent.width > 1, extent.height > 1 else { return nil }
    let clamp = CIFilter(name: "CIAffineClamp")
    clamp?.setValue(ciImage, forKey: kCIInputImageKey)
    clamp?.setValue(NSValue(cgAffineTransform: .identity), forKey: kCIInputTransformKey)
    let blur = CIFilter(name: "CIGaussianBlur")
    blur?.setValue(clamp?.outputImage ?? ciImage, forKey: kCIInputImageKey)
    blur?.setValue(18.0, forKey: kCIInputRadiusKey)
    guard let blurred = blur?.outputImage?.cropped(to: extent) else { return nil }
    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let cg = context.createCGImage(blurred, from: extent) else { return nil }
    return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
  }

  private func playbackDetailText(for state: NativeMusicPlayerViewState, track: NativeMusicPlayerTrack) -> String {
    let dur = max(state.durationMs, (track.durationSeconds ?? 0.0) * 1000.0)
    if dur > 0 {
      return "\(NativeMusicPlayerModalView.format(ms: state.progressMs)) / \(NativeMusicPlayerModalView.format(ms: dur))"
    }
    return track.artist
  }

  private func applyPlaybackButtons(for state: NativeMusicPlayerViewState) {
    let name = state.isPlaying ? "pause.fill" : "play.fill"
    guard name != lastPlayButtonSymbol else { return }
    lastPlayButtonSymbol = name
    // Plain setImage — no crossfade (matches modal play button polish).
    miniPlayButton.setImage(
      UIImage(
        systemName: name,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
      ),
      for: .normal
    )
  }
}

// MARK: - Root overlay coordinator
//
// Lead installs this on `AppRootNavigationController.view` so the mini player
// survives pushes/tabs. Touch handling is pass-through outside the pill.

/// Full-screen host that only intercepts hits inside the visible music banner.
private final class NativeMusicPlayerOverlayHostView: UIView {
  weak var bannerView: NativeMusicPlayerBannerView?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let bannerView, !bannerView.isHidden, bannerView.alpha > 0.01 else {
      return nil
    }
    let pointInBanner = convert(point, to: bannerView)
    guard bannerView.containsInteractivePoint(pointInBanner) else {
      return nil
    }
    return bannerView.hitTest(pointInBanner, with: event)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard let bannerView, !bannerView.isHidden, bannerView.alpha > 0.01 else {
      return false
    }
    let pointInBanner = convert(point, to: bannerView)
    return bannerView.containsInteractivePoint(pointInBanner)
  }
}

/// Root-level music/voice mini-player presenter.
///
/// Integration (lead → `AppRootNavigationController`):
/// ```
/// NativeMusicPlayerRootOverlay.shared.install(on: view)
/// // in viewDidLayoutSubviews / trait updates:
/// NativeMusicPlayerRootOverlay.shared.updateLayout()
/// // after push/pop if needed:
/// NativeMusicPlayerRootOverlay.shared.bringToFront()
/// ```
final class NativeMusicPlayerRootOverlay {
  static let shared = NativeMusicPlayerRootOverlay()

  private weak var rootView: UIView?
  private let hostView = NativeMusicPlayerOverlayHostView(frame: .zero)
  private let bannerView = NativeMusicPlayerBannerView(frame: .zero)
  private var modalController: NativeMusicPlayerModalView?
  private var cachedStoreChatTracks: [NativeMusicPlayerTrack] = []
  private var cachedStoreChatTracksKey = ""
  private var musicObserver: NSObjectProtocol?
  private var voiceObserver: NSObjectProtocol?
  private var themeObserver: NSObjectProtocol?

  private var lastMusicPayload: [String: Any] = [:]
  private var lastVoiceSnapshot = VoiceBubblePlaybackSnapshot.empty
  private var activeSource: ActiveSource = .none
  /// The last source that actually had something playing. `activeSource` drops to
  /// `.none` the moment playback stops or fails — and every control in the still-open
  /// sheet used to switch on it, so a failed track left the whole sheet alive but
  /// completely inert: no row select, no next, no play. Controls route on this.
  private var lastActiveSource: ActiveSource = .none
  private var controlSource: ActiveSource {
    activeSource != .none ? activeSource : lastActiveSource
  }

  private enum ActiveSource {
    case none
    case music
    case voice
  }

  private init() {
    hostView.backgroundColor = .clear
    hostView.isOpaque = false
    hostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostView.bannerView = bannerView

    bannerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    bannerView.onTogglePlayback = { [weak self] in self?.handleTogglePlayback() }
    bannerView.onClose = { [weak self] in self?.handleClose() }
    bannerView.onOpenModal = { [weak self] in self?.handleOpenModal() }
    bannerView.onCyclePlaybackRate = { [weak self] in self?.handleCyclePlaybackRate() }
  }

  deinit {
    tearDownObservers()
  }

  /// Installs (or re-parents) the overlay on a root view. Safe to call repeatedly.
  func install(on rootView: UIView) {
    self.rootView = rootView
    if hostView.superview !== rootView {
      hostView.removeFromSuperview()
      hostView.frame = rootView.bounds
      rootView.addSubview(hostView)
    }
    if bannerView.superview !== hostView {
      bannerView.removeFromSuperview()
      bannerView.frame = hostView.bounds
      hostView.addSubview(bannerView)
    }
    ensureObservers()
    lastMusicPayload = NativeMusicPlayerEngine.shared.getStatePayload()
    lastVoiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
    updateLayout()
    refreshFromActiveSources()
    bringToFront()
  }

  /// Updates frame, safe-area inset, and theme from the current root view.
  func updateLayout() {
    guard let rootView else { return }
    hostView.frame = rootView.bounds
    bannerView.frame = hostView.bounds
    let topInset = rootView.safeAreaInsets.top
    bannerView.setTopInset(topInset)
    applyTheme(from: rootView)
    hostView.setNeedsLayout()
    bannerView.setNeedsLayout()
  }

  /// Alias for hosts that prefer an `layout` name.
  func layout() {
    updateLayout()
  }

  /// Keeps the overlay above pushed content when the lead re-layouts.
  /// No-op when `hostView` is already the root's last (frontmost) subview.
  func bringToFront() {
    guard let rootView, hostView.superview === rootView else { return }
    if rootView.subviews.last === hostView { return }
    rootView.bringSubviewToFront(hostView)
  }

  /// Places the music host immediately below a sibling on the same root view.
  /// No-op when already immediately below `siblingView`, or when either view is
  /// not a subview of the stored root. Lead uses this so toast stays above music
  /// without thrashing z-order every layout pass.
  func placeImmediatelyBelow(_ siblingView: UIView) {
    guard let rootView,
          hostView.superview === rootView,
          siblingView.superview === rootView
    else { return }
    let subviews = rootView.subviews
    guard let hostIndex = subviews.firstIndex(of: hostView),
          let siblingIndex = subviews.firstIndex(of: siblingView)
    else { return }
    // Already immediately below (host one step behind sibling in z-order).
    if hostIndex == siblingIndex - 1 { return }
    rootView.insertSubview(hostView, belowSubview: siblingView)
  }

  // MARK: - Observers

  private func ensureObservers() {
    if musicObserver == nil {
      musicObserver = NotificationCenter.default.addObserver(
        forName: .nativeMusicPlayerStateDidChange,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let payload =
          (notification.userInfo?["payload"] as? [String: Any])
          ?? NativeMusicPlayerEngine.shared.getStatePayload()
        self?.lastMusicPayload = payload
        self?.refreshFromActiveSources()
      }
    }
    if voiceObserver == nil {
      voiceObserver = NotificationCenter.default.addObserver(
        forName: .voiceBubblePlaybackDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        // Posted without userInfo — always read the coordinator snapshot.
        self?.lastVoiceSnapshot = VoiceBubblePlaybackCoordinator.shared.currentSnapshot
        self?.refreshFromActiveSources()
      }
    }
    if themeObserver == nil {
      themeObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.updateLayout()
      }
    }
  }

  private func tearDownObservers() {
    if let musicObserver {
      NotificationCenter.default.removeObserver(musicObserver)
      self.musicObserver = nil
    }
    if let voiceObserver {
      NotificationCenter.default.removeObserver(voiceObserver)
      self.voiceObserver = nil
    }
    if let themeObserver {
      NotificationCenter.default.removeObserver(themeObserver)
      self.themeObserver = nil
    }
  }

  private func refreshFromActiveSources() {
    // Prefer live voice global player when it is presenting; otherwise native music.
    let voiceActive =
      lastVoiceSnapshot.presentsGlobalPlayer
      && lastVoiceSnapshot.messageId != nil
    let musicTrack = (lastMusicPayload["currentTrack"] as? [String: Any])
      .flatMap(NativeMusicPlayerTrack.init)
    let musicActive = musicTrack != nil

    if voiceActive {
      activeSource = .voice
      lastActiveSource = .voice
      bannerView.applyVoiceSnapshot(lastVoiceSnapshot)
    } else if musicActive {
      activeSource = .music
      lastActiveSource = .music
      bannerView.applyStatePayload(lastMusicPayload)
    } else {
      activeSource = .none
      bannerView.applyStatePayload([:])
    }

    // Play only shows the mini banner (already applied above). The full sheet
    // opens exclusively via banner tap → handleOpenModal → presentModalIfNeeded.
    syncModalIfNeeded()
  }

  private func applyTheme(from rootView: UIView) {
    let style = rootView.traitCollection.userInterfaceStyle
    let isDark = style != .light
    var theme = NativeMusicPlayerTheme()
    theme.isDark = isDark
    // Dynamic system colors resolve against the current trait collection.
    theme.surface = UIColor.secondarySystemBackground
    theme.text = UIColor.label
    theme.secondaryText = UIColor.secondaryLabel
    theme.primary = UIColor.tintColor
    bannerView.applyTheme(theme)
    modalController?.applyTheme(theme)
  }

  // MARK: - Controls

  private func handleTogglePlayback() {
    switch controlSource {
    case .music:
      let isPlaying = (lastMusicPayload["isPlaying"] as? Bool) ?? false
      NativeMusicPlayerEngine.shared.setIsPlaying(!isPlaying)
    case .voice:
      VoiceBubblePlaybackCoordinator.shared.toggleCurrentPlayback()
    case .none:
      break
    }
  }

  private func handleCyclePlaybackRate() {
    switch controlSource {
    case .music:
      NativeMusicPlayerEngine.shared.cyclePlaybackRate()
    case .voice:
      VoiceBubblePlaybackCoordinator.shared.cyclePlaybackRate()
    case .none:
      break
    }
  }

  private func handleClose() {
    switch controlSource {
    case .music:
      NativeMusicPlayerEngine.shared.reset()
    case .voice:
      VoiceBubblePlaybackCoordinator.shared.stopCurrentPlayback()
    case .none:
      break
    }
    modalController?.dismiss(animated: true)
    modalController = nil
    NativeMusicPlayerEngine.shared.setIsExpanded(false)
  }

  private func handleOpenModal() {
    guard activeSource != .none else { return }
    presentModalIfNeeded()
  }

  private func handleReorderQueue(_ orderedTrackIds: [String]) {
    switch controlSource {
    case .voice:
      // Frozen API: trackIds == messageIds, full displayed order.
      VoiceBubblePlaybackCoordinator.shared.setManualQueueOrder(orderedTrackIds)
    case .music:
      let payloads: [[String: Any]] = orderedTrackIds.compactMap { trackId in
        if let payload = NativeMusicPlayerEngine.shared.getTrack(trackId) {
          return payload
        }
        if let track = NativeMusicPlayerStore.shared.getTrack(trackId: trackId) {
          return track.toPayload()
        }
        // Keep a minimal payload so setQueue still records the id order.
        return [
          "track_id": trackId,
          "title": "Audio",
          "artist": "Vibegram",
        ]
      }
      NativeMusicPlayerEngine.shared.setQueue(payloads)
    case .none:
      break
    }
  }

  private func handleRemoveTrack(_ trackId: String) {
    switch controlSource {
    case .music:
      NativeMusicPlayerEngine.shared.removeTrack(trackId)
    case .voice:
      // Persist order minus the removed id (forward play skips it at the end /
      // the modal already filters it from the displayed Next-Up list).
      let remaining = VoiceBubblePlaybackCoordinator.shared.displayQueueTracks()
        .map(\.trackId)
        .filter { $0 != trackId }
      VoiceBubblePlaybackCoordinator.shared.setManualQueueOrder(remaining)
    case .none:
      break
    }
  }

  private func handlePlayNext() {
    switch controlSource {
    case .music:
      NativeMusicPlayerEngine.shared.playNext()
    case .voice:
      VoiceBubblePlaybackCoordinator.shared.playNextTrack()
    case .none:
      break
    }
  }

  private func handlePlayPrevious() {
    switch controlSource {
    case .music:
      NativeMusicPlayerEngine.shared.playPrev()
    case .voice:
      VoiceBubblePlaybackCoordinator.shared.playPreviousTrack()
    case .none:
      break
    }
  }

  private func presentModalIfNeeded() {
    if modalController != nil {
      syncModalIfNeeded()
      return
    }

    let modal = NativeMusicPlayerModalView()
    modal.onTogglePlayback = { [weak self] in self?.handleTogglePlayback() }
    modal.onPlayNext = { [weak self] in self?.handlePlayNext() }
    modal.onPlayPrev = { [weak self] in self?.handlePlayPrevious() }
    modal.onDismiss = { [weak self] in
      guard let self else { return }
      self.modalController = nil
      NativeMusicPlayerEngine.shared.setIsExpanded(false)
    }
    modal.onReorderQueue = { [weak self] orderedTrackIds in
      self?.handleReorderQueue(orderedTrackIds)
    }
    modal.onRemoveTrack = { [weak self] trackId in
      self?.handleRemoveTrack(trackId)
    }
    modal.onToggleQueueOrder = { [weak self] in
      guard let self else { return }
      switch self.controlSource {
      case .music:
        NativeMusicPlayerEngine.shared.toggleQueueOrderMode()
      case .voice:
        VoiceBubblePlaybackCoordinator.shared.toggleQueueOrderMode()
      case .none:
        break
      }
    }
    modal.onToggleRepeat = { [weak self] in
      guard let self else { return }
      switch self.controlSource {
      case .music:
        NativeMusicPlayerEngine.shared.toggleRepeatEnabled()
      case .voice:
        VoiceBubblePlaybackCoordinator.shared.toggleRepeatEnabled()
      case .none:
        break
      }
    }
    modal.onSeek = { [weak self] milliseconds in
      guard let self else { return }
      switch self.controlSource {
      case .music:
        NativeMusicPlayerEngine.shared.seek(toMilliseconds: milliseconds)
      case .voice:
        VoiceBubblePlaybackCoordinator.shared.seek(toSeconds: milliseconds / 1000.0)
      case .none:
        break
      }
    }
    modal.onSelectTrack = { [weak self] trackId in
      guard let self else { return }
      switch self.controlSource {
      case .music:
        NativeMusicPlayerEngine.shared.selectTrack(trackId)
      case .voice:
        VoiceBubblePlaybackCoordinator.shared.selectQueuedTrack(trackId)
      case .none:
        break
      }
    }

    // Guarantee the native sheet controller exists (the old configureSheet set this).
    modal.modalPresentationStyle = .pageSheet
    if let sheet = modal.sheetPresentationController {
      // Compact detent is taller than .medium() so the now-playing hero has room;
      // .large() is the queue-browsing mode.
      let compact = NativeMusicPlayerModalView.compactDetent()
      sheet.detents = [compact, .large()]
      sheet.selectedDetentIdentifier = NativeMusicPlayerModalView.compactDetentIdentifier
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28.0
      // Keep the chat interactive behind the compact player.
      sheet.largestUndimmedDetentIdentifier = NativeMusicPlayerModalView.compactDetentIdentifier
      sheet.delegate = modal
    }

    if let rootView {
      applyTheme(from: rootView)
    }

    modalController = modal
    NativeMusicPlayerEngine.shared.setIsExpanded(true)
    syncModalIfNeeded()

    guard let presenter = topMostViewController() else { return }
    presenter.present(modal, animated: true)
  }

  /// `tracks(forChatId:)` filters the whole library and sorts it with a locale-aware
  /// comparator; `syncModalIfNeeded` runs on every playback tick. Memoised on the
  /// store's revision so it only actually runs when the library changed.
  private func storeChatTracks(forChatId chatId: String) -> [NativeMusicPlayerTrack] {
    let key = "\(chatId)#\(NativeMusicPlayerStore.shared.revision)"
    guard key != cachedStoreChatTracksKey else { return cachedStoreChatTracks }
    cachedStoreChatTracksKey = key
    cachedStoreChatTracks = NativeMusicPlayerStore.shared.tracks(forChatId: chatId)
    return cachedStoreChatTracks
  }

  private func syncModalIfNeeded() {
    guard let modal = modalController else { return }

    // State mirrors reality, so this one stays on `activeSource` — only the controls
    // fall back to `controlSource`.
    switch activeSource {
    case .music:
      let track = (lastMusicPayload["currentTrack"] as? [String: Any])
        .flatMap(NativeMusicPlayerTrack.init)
      let queuePayloads = (lastMusicPayload["queue"] as? [[String: Any]]) ?? []
      let libraryPayloads = (lastMusicPayload["library"] as? [[String: Any]]) ?? []
      // Prefer store chat tracks (incl. not-downloaded) as the primary list source.
      var queue: [NativeMusicPlayerTrack] = []
      var seen = Set<String>()
      var seenTitleArtist = Set<String>()
      func appendMusicTrack(_ candidate: NativeMusicPlayerTrack) {
        guard seen.insert(candidate.trackId).inserted else { return }
        let key =
          candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          + "|"
          + candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.hasPrefix("|"), !seenTitleArtist.insert(key).inserted { return }
        queue.append(candidate)
      }
      if let chatId = track?.links["chat_id"] ?? track?.links["chatId"] {
        for chatTrack in storeChatTracks(forChatId: chatId) {
          appendMusicTrack(chatTrack)
        }
        for chatTrack in ChatAudioQueueRegistry.shared.tracks(for: chatId) {
          appendMusicTrack(chatTrack)
        }
      }
      for engineTrack in queuePayloads.compactMap(NativeMusicPlayerTrack.init) {
        appendMusicTrack(engineTrack)
      }
      // Append only — never hoist the playing track to the top. Re-sorting the list
      // around whatever is playing means every Next press shuffles the rows under
      // the reader's finger; the active row is already marked by accent + bars.
      if let track { appendMusicTrack(track) }
      let library = libraryPayloads.compactMap(NativeMusicPlayerTrack.init)
      let isPlaying = (lastMusicPayload["isPlaying"] as? Bool) ?? false
      let progressMs =
        (lastMusicPayload["progress"] as? NSNumber)?.doubleValue
        ?? (lastMusicPayload["progress"] as? Double)
        ?? 0.0
      let durationMs =
        (lastMusicPayload["duration"] as? NSNumber)?.doubleValue
        ?? (lastMusicPayload["duration"] as? Double)
        ?? 0.0
      let orderRaw = (lastMusicPayload["queueOrderMode"] as? String) ?? "forward"
      let queueOrderMode = NativeMusicPlayerQueueOrderMode(rawValue: orderRaw) ?? .forward
      let isRepeatEnabled = (lastMusicPayload["isRepeatEnabled"] as? Bool) ?? false
      modal.updateState(
        track: track,
        queue: queue,
        library: library,
        isPlaying: isPlaying,
        progressMs: progressMs,
        durationMs: durationMs,
        queueOrderMode: queueOrderMode,
        isRepeatEnabled: isRepeatEnabled,
        artworkImage: nil,
        voiceSnapshot: nil
      )

    case .voice:
      let snapshot = lastVoiceSnapshot
      var links: [String: String] = [:]
      if let chatId = snapshot.chatId { links["chat_id"] = chatId }
      let track: NativeMusicPlayerTrack? = {
        guard let messageId = snapshot.messageId else { return nil }
        let coverURL = NativeMusicPlayerViewState.resolveCoverURL(
          forTrackId: messageId, chatId: snapshot.chatId)
          ?? NativeMusicPlayerStore.shared.getTrack(trackId: messageId)?.cover
        return NativeMusicPlayerTrack(
          trackId: messageId,
          videoId: nil,
          id: messageId,
          source: "chat-music",
          title: snapshot.title ?? "Audio",
          artist: snapshot.subtitle ?? "Vibegram",
          album: nil,
          duration: nil,
          durationSeconds: snapshot.duration > 0 ? snapshot.duration : nil,
          cover: coverURL,
          previewURL: nil,
          streamURL: nil,
          localURI: nil,
          cachedAt: nil,
          playCount: 0,
          lastPlayedAt: nil,
          links: links
        )
      }()
      // Store chat tracks first (incl. not-downloaded stream URLs), then coordinator queue.
      // Dedup by trackId AND exact title+artist so the list never doubles a song.
      var queue: [NativeMusicPlayerTrack] = []
      var seen = Set<String>()
      var seenTitleArtist = Set<String>()
      func appendTrack(_ chatTrack: NativeMusicPlayerTrack) {
        guard seen.insert(chatTrack.trackId).inserted else { return }
        let key =
          chatTrack.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          + "|"
          + chatTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.hasPrefix("|"), !seenTitleArtist.insert(key).inserted { return }
        queue.append(chatTrack)
      }
      if let chatId = snapshot.chatId {
        for chatTrack in storeChatTracks(forChatId: chatId) {
          appendTrack(chatTrack)
        }
        for chatTrack in ChatAudioQueueRegistry.shared.tracks(for: chatId) {
          appendTrack(chatTrack)
        }
      }
      for queued in VoiceBubblePlaybackCoordinator.shared.displayQueueTracks() {
        appendTrack(queued)
      }
      // Append only — see the music branch: hoisting the playing track re-sorts the
      // whole list on every track change, which is the shift under the finger.
      if let track { appendTrack(track) }
      let progressMs = max(0.0, snapshot.duration * Double(snapshot.progress) * 1000.0)
      let durationMs = max(0.0, snapshot.duration * 1000.0)
      modal.updateState(
        track: track,
        queue: queue,
        library: queue,
        isPlaying: snapshot.isPlaying,
        progressMs: progressMs,
        durationMs: durationMs,
        queueOrderMode: snapshot.queueOrderMode,
        isRepeatEnabled: snapshot.isRepeatEnabled,
        artworkImage: snapshot.artwork,
        voiceSnapshot: snapshot
      )

    case .none:
      modal.updateState(
        track: nil,
        queue: [],
        library: [],
        isPlaying: false,
        progressMs: 0,
        durationMs: 0,
        queueOrderMode: .forward,
        isRepeatEnabled: false,
        artworkImage: nil,
        voiceSnapshot: nil
      )
    }
  }

  private func topMostViewController() -> UIViewController? {
    let root =
      rootView?.window?.rootViewController
      ?? UIApplication.shared.connectedScenes
      .compactMap { scene -> UIViewController? in
        guard let windowScene = scene as? UIWindowScene else { return nil }
        return windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
      }
      .first
    guard var top = root else { return nil }
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
}
