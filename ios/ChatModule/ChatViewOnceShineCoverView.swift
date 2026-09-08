import CoreImage
import MetalKit
import UIKit

private let chatViewOnceBlurCache = NSCache<NSString, UIImage>()
private let chatViewOnceSealedCache = NSCache<NSString, UIImage>()

func chatViewOnceCacheSealed(_ image: UIImage, key: String) {
  let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return }
  chatViewOnceSealedCache.setObject(image, forKey: trimmed as NSString)
}

func chatViewOnceSealedImage(key: String) -> UIImage? {
  let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return chatViewOnceSealedCache.object(forKey: trimmed as NSString)
}

func chatViewOnceConcealedStill(from image: UIImage, cacheKey: String) -> UIImage {
  let ns = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
  if ns.length > 0, let hit = chatViewOnceBlurCache.object(forKey: ns) { return hit }
  let blurred = ChatViewOnceShineCoverView.makeConcealedStill(from: image)
  if ns.length > 0 { chatViewOnceBlurCache.setObject(blurred, forKey: ns) }
  return blurred
}

func chatViewOnceEvictCached(key: String) {
  let ns = key.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
  guard ns.length > 0 else { return }
  chatViewOnceBlurCache.removeObject(forKey: ns)
  chatViewOnceSealedCache.removeObject(forKey: ns)
}

/// View-once cover: concealed still plus free-float particles. No left-right sheen.
/// The list never paints the sharp original; particles sit on the blur, not over it.
final class ChatViewOnceShineCoverView: UIView {
  private let blurredImageView = UIImageView()
  private let dimView = UIView()
  private let particleRenderer: MetalKeyMaskView.Coordinator
  private let particleView: SecureParticleMaskView
  private let badgeView = UIView()
  private let badgeLabel = UILabel()

  private var lastCacheKey = ""
  private var isCircular = false
  private var isActive = false
  private var badgeWidth: CGFloat = 22

  override init(frame: CGRect) {
    let renderer = MetalKeyMaskView.Coordinator(appearance: .freeFloat)
    let metal = SecureParticleMaskView(frame: .zero, device: renderer.device)
    metal.delegate = renderer
    metal.prepareAsMediaOverlay()
    metal.preferredFramesPerSecond = 60
    metal.isPaused = true
    metal.isUserInteractionEnabled = false
    renderer.setConcealed(true, animated: false)
    particleRenderer = renderer
    particleView = metal
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    isOpaque = false
    backgroundColor = .clear

    blurredImageView.contentMode = .scaleAspectFill
    blurredImageView.clipsToBounds = true
    addSubview(blurredImageView)

    dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.12)
    addSubview(dimView)

    addSubview(particleView)

    badgeView.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    badgeView.isUserInteractionEnabled = false
    addSubview(badgeView)

    badgeLabel.text = "1"
    badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    badgeLabel.textColor = .white
    badgeLabel.textAlignment = .center
    badgeView.addSubview(badgeLabel)
  }

  required init?(coder: NSCoder) { fatalError() }

  func apply(
    image: UIImage?,
    cacheKey: String,
    count: Int,
    circular: Bool,
    timerSeconds: Int? = nil
  ) {
    isCircular = circular
    if let timerSeconds, timerSeconds > 0 {
      badgeLabel.text = "\(timerSeconds)s"
      badgeWidth = 38
    } else {
      badgeLabel.text = count <= 1 ? "1" : "\(min(count, 9))"
      badgeWidth = 22
    }
    layer.cornerCurve = circular ? .circular : .continuous
    layer.cornerRadius = circular ? floor(min(bounds.width, bounds.height) * 0.5) : 0
    updateBlurredImage(image, cacheKey: cacheKey)
    setNeedsLayout()
  }

  func setActive(_ active: Bool) {
    guard isActive != active else {
      if active { particleView.isPaused = false }
      return
    }
    isActive = active
    particleView.isPaused = !active
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurredImageView.frame = bounds
    dimView.frame = bounds
    particleView.frame = bounds

    let badgeSide: CGFloat = 22
    let badgeX: CGFloat = 10
    let badgeY: CGFloat =
      isCircular
      ? floor((bounds.height - badgeSide) * 0.5)
      : 10
    badgeView.frame = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeSide)
    badgeView.layer.cornerRadius = badgeSide * 0.5
    badgeLabel.frame = badgeView.bounds

    if layer.cornerCurve == .circular {
      layer.cornerRadius = floor(min(bounds.width, bounds.height) * 0.5)
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    setActive(window != nil && !isHidden)
  }

  override var isHidden: Bool {
    didSet {
      if isHidden {
        setActive(false)
      } else if window != nil {
        setActive(true)
      }
    }
  }

  private func updateBlurredImage(_ image: UIImage?, cacheKey: String) {
    guard let image else {
      lastCacheKey = ""
      blurredImageView.image = nil
      return
    }
    let key = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !key.isEmpty, key == lastCacheKey, blurredImageView.image != nil { return }
    lastCacheKey = key
    blurredImageView.image = chatViewOnceConcealedStill(from: image, cacheKey: key)
  }

  static func makeConcealedStill(from image: UIImage) -> UIImage {
    guard let cg = image.cgImage else { return Self.darkFallback(size: image.size) }
    let ci = CIImage(cgImage: cg)
    let maxEdge = max(ci.extent.width, ci.extent.height)
    let scale = maxEdge > 280 ? 280 / maxEdge : 1
    let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let blur = CIFilter(name: "CIGaussianBlur")
    blur?.setValue(scaled.clampedToExtent(), forKey: kCIInputImageKey)
    blur?.setValue(22.0, forKey: kCIInputRadiusKey)
    let controls = CIFilter(name: "CIColorControls")
    controls?.setValue(blur?.outputImage?.cropped(to: scaled.extent), forKey: kCIInputImageKey)
    controls?.setValue(0.48, forKey: kCIInputSaturationKey)
    controls?.setValue(-0.04, forKey: kCIInputBrightnessKey)
    controls?.setValue(0.94, forKey: kCIInputContrastKey)
    guard let output = controls?.outputImage?.cropped(to: scaled.extent),
      let outCG = ciContext.createCGImage(output, from: scaled.extent)
    else { return Self.darkFallback(size: image.size) }
    return UIImage(cgImage: outCG, scale: 1, orientation: .up)
  }

  private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  private static func darkFallback(size: CGSize) -> UIImage {
    let side = CGSize(width: max(8, size.width), height: max(8, size.height))
    let format = UIGraphicsImageRendererFormat()
    format.opaque = true
    format.scale = 1
    return UIGraphicsImageRenderer(size: side, format: format).image { ctx in
      UIColor(white: 0.12, alpha: 1).setFill()
      ctx.fill(CGRect(origin: .zero, size: side))
    }
  }
}
