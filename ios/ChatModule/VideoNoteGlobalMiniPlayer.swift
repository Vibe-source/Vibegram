import AVFoundation
import UIKit

/// Window-level floating video-note player (Telegram-style).
/// Only appears on the **root** window when the user leaves the chat while a note
/// is still playing — never while the chat list is visible.
final class VideoNoteGlobalMiniPlayer: NSObject {
  static let shared = VideoNoteGlobalMiniPlayer()

  private enum Corner: Int, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
  }

  private weak var hostList: UIView?
  private var hostWindow: UIWindow?
  private let circle = UIView()
  private let imageView = UIImageView()
  private let playerLayer = AVPlayerLayer()
  private let closeButton = UIButton(type: .system)
  private var player: AVPlayer?
  private var readyForDisplayObservation: NSKeyValueObservation?
  private var messageId: String?
  private var mediaURL: String?
  private var mediaKey: String?
  private var seedImage: UIImage?
  private var corner: Corner = .bottomRight
  private var displayLink: CADisplayLink?
  private var isVisible = false

  private override init() {
    super.init()
    circle.isHidden = true
    circle.backgroundColor = .black
    circle.clipsToBounds = true
    circle.layer.shadowColor = UIColor.black.cgColor
    circle.layer.shadowOpacity = 0.35
    circle.layer.shadowRadius = 10
    circle.layer.shadowOffset = CGSize(width: 0, height: 4)

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    circle.addSubview(imageView)

    playerLayer.videoGravity = .resizeAspectFill
    circle.layer.addSublayer(playerLayer)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    circle.addGestureRecognizer(pan)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    circle.addGestureRecognizer(tap)

    // Always-visible dismiss control — sits outside the clipped circle so it never
    // gets cropped by circle.clipsToBounds, but travels with it as a subview.
    closeButton.isHidden = true
    let closeConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: closeConfig), for: .normal)
    closeButton.tintColor = .white
    closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    closeButton.layer.cornerRadius = 11
    closeButton.layer.shadowColor = UIColor.black.cgColor
    closeButton.layer.shadowOpacity = 0.4
    closeButton.layer.shadowRadius = 3
    closeButton.layer.shadowOffset = CGSize(width: 0, height: 1)
    closeButton.addTarget(self, action: #selector(handleCloseTapped), for: .touchUpInside)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  /// Register an in-chat playback session. Does **not** show the floating circle.
  func registerPlayback(
    messageId: String?,
    mediaURL: String,
    mediaKey: String?,
    seedImage: UIImage?,
    hostList: UIView
  ) {
    if self.messageId != messageId {
      // A different note than whatever this singleton last tracked — drop the old
      // player so takeOverPlayback() builds a fresh one instead of resuming stale
      // (or already-finished) playback for the wrong message.
      readyForDisplayObservation?.invalidate()
      readyForDisplayObservation = nil
      player?.pause()
      player = nil
      playerLayer.player = nil
      imageView.isHidden = false
    }
    self.messageId = messageId
    self.mediaURL = mediaURL
    self.mediaKey = mediaKey
    self.seedImage = seedImage
    self.hostList = hostList
    imageView.image = seedImage
    // Stay hidden while the chat list is on screen.
    hideFloatingUI()
    startWatchingHost()
    NSLog(
      "[VideoNoteMini] register msg=%@ hostWindow=%@ — floating hidden until leave chat",
      messageId ?? "-",
      hostList.window != nil ? "Y" : "N"
    )
  }

  func detachIfMessage(_ messageId: String?) {
    if messageId == nil || messageId == self.messageId {
      stopAndHide()
    }
  }

  /// Call when chat list is torn down / pops — promote live playback to root.
  func promoteIfPlayingAwayFromChat() {
    guard messageId != nil, let host = hostList else { return }
    if host.window == nil {
      takeOverPlayback()
    }
  }

  private func startWatchingHost() {
    displayLink?.invalidate()
    let link = CADisplayLink(target: self, selector: #selector(tickHostVisibility))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 10, preferred: 5)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func tickHostVisibility() {
    guard messageId != nil else {
      displayLink?.invalidate()
      displayLink = nil
      return
    }
    guard let host = hostList else {
      takeOverPlayback()
      return
    }
    // Chat still visible → keep floating UI off.
    if host.window != nil {
      if isVisible { hideFloatingUI() }
      return
    }
    // Left the chat while note still registered → show on root and play video.
    takeOverPlayback()
  }

  @objc private func appDidBecomeActive() {
    tickHostVisibility()
  }

  private func ensureHosted() {
    guard
      let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive })
        ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { return }
    let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
    hostWindow = window
    guard let window else { return }
    if circle.superview !== window {
      circle.removeFromSuperview()
      window.addSubview(circle)
    }
    if closeButton.superview !== window {
      closeButton.removeFromSuperview()
      window.addSubview(closeButton)
    }
  }

  private func takeOverPlayback() {
    ensureHosted()
    layoutToCorner(animated: !isVisible)
    circle.isHidden = false
    closeButton.isHidden = false
    isVisible = true
    imageView.isHidden = false

    // Prefer live video; keep seed image under the layer until first frame is
    // actually ready to paint (isReadyForDisplay), so we never show an empty/black
    // layer over the seed image while the player is still buffering.
    if player == nil, let mediaURL {
      let url: URL?
      if mediaURL.hasPrefix("file://") {
        url = URL(string: mediaURL)
      } else if mediaURL.hasPrefix("/") {
        url = URL(fileURLWithPath: mediaURL)
      } else {
        url = URL(string: mediaURL)
      }
      if let url {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = false
        player = p
        playerLayer.player = p
        playerLayer.isHidden = false
        readyForDisplayObservation = playerLayer.observe(
          \.isReadyForDisplay, options: [.new]
        ) { [weak self] layer, _ in
          guard let self, layer.isReadyForDisplay else { return }
          DispatchQueue.main.async {
            self.imageView.isHidden = true
          }
        }
        p.play()
        NSLog("[VideoNoteMini] takeOver VIDEO url=%@", url.lastPathComponent)
      } else {
        NSLog("[VideoNoteMini] takeOver failed to parse url=%@", mediaURL)
      }
    } else {
      player?.play()
      playerLayer.isHidden = false
    }
  }

  private func hideFloatingUI() {
    isVisible = false
    circle.isHidden = true
    closeButton.isHidden = true
    player?.pause()
  }

  private func stopAndHide() {
    displayLink?.invalidate()
    displayLink = nil
    readyForDisplayObservation?.invalidate()
    readyForDisplayObservation = nil
    player?.pause()
    player = nil
    playerLayer.player = nil
    messageId = nil
    mediaURL = nil
    hostList = nil
    hideFloatingUI()
    circle.removeFromSuperview()
    closeButton.removeFromSuperview()
    hostWindow = nil
  }

  private func cornerRect(in bounds: CGRect, safe: UIEdgeInsets) -> CGRect {
    let side: CGFloat = 88
    let pad: CGFloat = 14
    let xLeft = safe.left + pad
    let xRight = bounds.width - safe.right - pad - side
    let yTop = safe.top + pad + 8
    let yBottom = bounds.height - safe.bottom - pad - side - 56
    switch corner {
    case .topLeft: return CGRect(x: xLeft, y: yTop, width: side, height: side)
    case .topRight: return CGRect(x: xRight, y: yTop, width: side, height: side)
    case .bottomLeft: return CGRect(x: xLeft, y: yBottom, width: side, height: side)
    case .bottomRight: return CGRect(x: xRight, y: yBottom, width: side, height: side)
    }
  }

  /// Close button center relative to the circle's own frame (top-right, straddling
  /// the rim like a standard dismiss badge).
  private func closeButtonCenter(for circleFrame: CGRect) -> CGPoint {
    CGPoint(x: circleFrame.maxX - 6, y: circleFrame.minY + 6)
  }

  private func layoutToCorner(animated: Bool) {
    guard let window = hostWindow ?? circle.window else { return }
    let dest = cornerRect(in: window.bounds, safe: window.safeAreaInsets)
    let apply = {
      self.circle.frame = dest
      self.circle.layer.cornerRadius = dest.width * 0.5
      self.imageView.frame = self.circle.bounds
      self.imageView.layer.cornerRadius = dest.width * 0.5
      self.playerLayer.frame = self.circle.bounds
      self.playerLayer.cornerRadius = dest.width * 0.5
      self.closeButton.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
      self.closeButton.center = self.closeButtonCenter(for: dest)
    }
    if animated {
      UIView.animate(
        withDuration: 0.32,
        delay: 0,
        usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0.2,
        options: [.beginFromCurrentState],
        animations: apply
      )
    } else {
      apply()
    }
  }

  @objc private func handlePan(_ g: UIPanGestureRecognizer) {
    guard let window = circle.window else { return }
    let translation = g.translation(in: window)
    if g.state == .changed {
      circle.center = CGPoint(
        x: circle.center.x + translation.x,
        y: circle.center.y + translation.y
      )
      closeButton.center = closeButtonCenter(for: circle.frame)
      g.setTranslation(.zero, in: window)
    } else if g.state == .ended || g.state == .cancelled {
      let velocity = g.velocity(in: window)
      let projected = CGPoint(
        x: circle.center.x + velocity.x * 0.12,
        y: circle.center.y + velocity.y * 0.12
      )
      corner = nearestCorner(to: projected, in: window.bounds, safe: window.safeAreaInsets)
      layoutToCorner(animated: true)
    }
  }

  @objc private func handleCloseTapped() {
    NSLog("[VideoNoteMini] close tapped msg=%@", messageId ?? "-")
    stopAndHide()
  }

  private func nearestCorner(to point: CGPoint, in bounds: CGRect, safe: UIEdgeInsets) -> Corner {
    var best: Corner = .bottomRight
    var bestDist = CGFloat.greatestFiniteMagnitude
    for c in Corner.allCases {
      let prev = corner
      corner = c
      let r = cornerRect(in: bounds, safe: safe)
      corner = prev
      let center = CGPoint(x: r.midX, y: r.midY)
      let d = hypot(center.x - point.x, center.y - point.y)
      if d < bestDist {
        bestDist = d
        best = c
      }
    }
    return best
  }

  @objc private func handleTap() {
    if player?.timeControlStatus == .playing {
      player?.pause()
    } else {
      player?.play()
    }
  }
}
