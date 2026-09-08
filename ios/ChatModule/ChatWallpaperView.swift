import UIKit

/// The chat wallpaper. All of it, in one place.
///
/// There used to be two owners painting the same thing: a plain gradient sublayer on
/// `ChatMainView`, and a gradient + pattern pair inside `ChatListView` installed as the
/// collection view's `backgroundView`. They were sized by different systems on different
/// passes, so on every chat open the host's copy appeared first and the list's copy
/// arrived late and moved — the reported "solid background, then the wallpaper fades in"
/// and "wallpaper jumps between frames". Neither was a scroll bug, which is why none of
/// the scroll work ever touched them.
///
/// Three rules hold this together:
///
/// 1. **One owner.** This view. `ChatListView` no longer has wallpaper layers at all; it
///    reads `snapshot` for the frosted backdrop behind bubbles and nothing else.
/// 2. **No implicit animation.** A `CALayer` that is not a view's own backing layer
///    animates every geometry write over 0.25s. These layers are re-framed from
///    `layoutSubviews`, and the first pass of a chat open runs at 0x0 — so the wallpaper
///    was literally animating itself in from nothing. Null actions makes every write
///    immediate.
/// 3. **The wallpaper does not move.** It is a function of theme and size, never of
///    `contentOffset`. The previous pattern layer interpolated its gradient stops against
///    scroll position, so every programmatic jump — open, restore, jump-to-latest,
///    keyboard — snapped it to a new phase. That effect is gone.
final class ChatWallpaperView: UIView {

  // MARK: - Snapshot cache

  /// Bounded and purged under pressure; the live `snapshot` is retained separately, so an
  /// eviction can never blank the wallpaper — worst case is one re-render at a settle.
  private static let snapshotCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 6
    cache.totalCostLimit = 96 * 1024 * 1024
    return cache
  }()
  private static let prewarmQueue = DispatchQueue(
    label: "chat.wallpaper.snapshot-prewarm", qos: .utility)
  private static let prewarmLock = NSLock()
  private static var prewarmKeys: Set<String> = []

  // MARK: - Layers

  private let gradientLayer = CAGradientLayer()
  private let patternLayer = CAGradientLayer()
  private let patternMaskLayer = CALayer()

  // MARK: - State

  private var appearance = ChatListAppearance.current
  private var hasPainted = false

  /// Flat raster of the current wallpaper, used by cells for the frosted backdrop behind
  /// bubbles. Sampling the live layers per cell per frame is what this replaces.
  private(set) var snapshot: CGImage?
  private(set) var snapshotSize: CGSize = .zero
  private var snapshotCacheKey = ""

  /// Fires when `snapshot` changes identity, so the list can rebind visible cells.
  var onSnapshotChanged: (() -> Void)?

  // MARK: - Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    // See rule 2 in the type comment. Without this every frame/bounds/colors write below
    // is a quarter-second animation.
    let immediate: [String: CAAction] = [
      "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
      "contents": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
      "colors": NSNull(), "locations": NSNull(),
      "startPoint": NSNull(), "endPoint": NSNull(),
    ]
    for target in [gradientLayer, patternLayer, patternMaskLayer] as [CALayer] {
      target.actions = immediate
    }
    patternMaskLayer.contentsGravity = .resizeAspectFill
    patternMaskLayer.contentsScale = UIScreen.main.scale
    patternLayer.mask = patternMaskLayer
    layer.addSublayer(gradientLayer)
    layer.addSublayer(patternLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let box = CGRect(origin: .zero, size: bounds.size)
    guard gradientLayer.frame != box else { return }
    gradientLayer.frame = box
    patternLayer.frame = box
    patternMaskLayer.frame = box
    // Size is part of the cache key, so a real resize (rotation, split view) invalidates.
    refreshSnapshotIfNeeded()
  }

  // MARK: - Theme

  func apply(_ appearance: ChatListAppearance) {
    // `appearance` starts at a real value, so an identical first apply left the layers
    // colourless — a transparent wallpaper over the host's plain fill.
    guard !hasPainted || self.appearance.visualKey != appearance.visualKey else { return }
    hasPainted = true
    self.appearance = appearance

    let transparent = appearance.backgroundMode == "transparent"
    gradientLayer.colors = appearance.wallpaperGradient.map(\.cgColor)
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    gradientLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperOpacity)))
    gradientLayer.isHidden = transparent

    // NEVER the rasterising `image(forKey:)` here. That renders a full-screen vector on
    // a miss — 0.43s of blocked main thread, sampled directly out of a `[mainhang]`
    // stack — and `apply` runs inside the navigation push.
    //
    // `cachedImage` is memory-then-disk, so after the first ever render this hits and
    // the pattern is live on the first frame. Only a genuinely first run falls through
    // to the branch below, which paints the plain gradient now and re-applies one turn
    // later — that path is what the user saw as "solid background, then the wallpaper
    // appears", and it used to run on EVERY launch because both tiers were `NSCache`.
    let maskKey = appearance.wallpaperMaskKey
    let maskImage = maskKey.flatMap { ChatWallpaperMaskStore.cachedImage(forKey: $0) }
    let canShowPattern =
      !transparent
      && appearance.wallpaperPatternGradient.count >= 2
      && appearance.wallpaperPatternOpacity > 0.001
      && maskImage != nil

    if maskImage == nil, let maskKey, !maskKey.isEmpty, !transparent,
      appearance.wallpaperPatternGradient.count >= 2,
      appearance.wallpaperPatternOpacity > 0.001
    {
      let wantedVisualKey = appearance.visualKey
      ChatWallpaperMaskStore.prewarm(
        key: maskKey, bundles: [Bundle.main, Bundle(for: ChatWallpaperView.self)]
      ) { [weak self] ok in
        guard ok else { return }
        DispatchQueue.main.async {
          guard let self, self.appearance.visualKey == wantedVisualKey else { return }
          // `apply` early-returns on an unchanged visualKey, so re-drive the pattern
          // directly rather than re-entering it.
          self.applyCachedPatternMask()
        }
      }
    }

    guard canShowPattern, let maskImage else {
      patternLayer.isHidden = true
      patternLayer.colors = nil
      patternLayer.locations = nil
      patternMaskLayer.contents = nil
      snapshotCacheKey = ""
      refreshSnapshotIfNeeded()
      return
    }

    patternLayer.colors = appearance.wallpaperPatternGradient.map(\.cgColor)
    patternLayer.locations = appearance.wallpaperPatternLocations
    patternLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    patternLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    patternLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperPatternOpacity)))
    patternMaskLayer.contents = maskImage
    patternLayer.isHidden = false
    snapshotCacheKey = ""
    refreshSnapshotIfNeeded()
  }

  /// Second half of `apply`'s pattern branch, for when the mask decode finishes after
  /// the push has already painted the plain gradient.
  private func applyCachedPatternMask() {
    guard appearance.backgroundMode != "transparent",
      appearance.wallpaperPatternGradient.count >= 2,
      appearance.wallpaperPatternOpacity > 0.001,
      let maskKey = appearance.wallpaperMaskKey,
      let maskImage = ChatWallpaperMaskStore.cachedImage(forKey: maskKey)
    else { return }
    patternLayer.colors = appearance.wallpaperPatternGradient.map(\.cgColor)
    patternLayer.locations = appearance.wallpaperPatternLocations
    patternLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
    patternLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
    patternLayer.opacity = Float(max(0.0, min(1.0, appearance.wallpaperPatternOpacity)))
    patternMaskLayer.contents = maskImage
    patternLayer.isHidden = false
    setNeedsLayout()
    layoutIfNeeded()
    snapshotCacheKey = ""
    refreshSnapshotIfNeeded(force: true)
  }

  // MARK: - Snapshot

  private func cacheKey(scale: CGFloat) -> String {
    "\(appearance.visualKey)|\(Int((bounds.width * scale).rounded()))x\(Int((bounds.height * scale).rounded()))"
  }

  func refreshSnapshotIfNeeded(force: Bool = false) {
    guard
      appearance.backgroundMode != "transparent",
      bounds.width > 1.0, bounds.height > 1.0,
      !gradientLayer.isHidden
    else {
      guard snapshot != nil else { return }
      snapshot = nil
      snapshotSize = .zero
      snapshotCacheKey = ""
      onSnapshotChanged?()
      return
    }

    let scale = max(window?.screen.scale ?? UIScreen.main.scale, 1.0)
    let key = cacheKey(scale: scale)
    if !force, snapshotCacheKey == key, snapshot != nil { return }

    // `force` means the INPUTS changed (the mask finished decoding), so the entry under
    // this key is stale by definition. Adopting it here is how a gradient-only raster
    // captured during a mask miss used to become the cells' backdrop for the rest of
    // the session, even after the pattern was on screen.
    if !force, let cached = Self.snapshotCache.object(forKey: key as NSString)?.cgImage {
      snapshot = cached
      snapshotSize = bounds.size
      snapshotCacheKey = key
      onSnapshotChanged?()
      return
    }

    // NEVER rasterise here. This runs from `layoutSubviews`, and compositing a
    // full-screen masked gradient through `CALayer.render(in:)` is 43–222ms warm —
    // and 3.38s of blocked main thread when the home hold-preview drives it repeatedly
    // at fresh sizes (`refreshSnapshotIfNeeded ← layoutSubviews ← prewarmLayout`,
    // straight out of a `[mainhang]` stack).
    //
    // Nothing on screen is waiting for this. The visible wallpaper is `gradientLayer` +
    // `patternLayer`, which are live and already correct; `snapshot` only feeds the
    // frosted backdrop behind bubbles, which rebinds via `onSnapshotChanged`.
    let size = bounds.size
    let appearance = self.appearance
    let maskImage = appearance.wallpaperMaskKey.flatMap {
      ChatWallpaperMaskStore.cachedImage(forKey: $0)
    }
    Self.renderCompositeOffMain(
      appearance: appearance, size: size, scale: scale, maskImage: maskImage, key: key
    ) { [weak self] cgImage in
      guard let self, self.snapshotCacheKey != key || self.snapshot == nil else { return }
      // Bounds or theme may have moved on while the worker ran; that turn scheduled its
      // own render, so drop this one rather than publish a mismatched image.
      guard self.cacheKey(scale: max(self.window?.screen.scale ?? UIScreen.main.scale, 1.0))
        == key
      else { return }
      self.snapshot = cgImage
      self.snapshotSize = size
      self.snapshotCacheKey = key
      self.onSnapshotChanged?()
    }
  }

  /// Composites the wallpaper from DETACHED layers on a worker.
  ///
  /// Detached is not an optimisation — `self`'s layers belong to the render server and
  /// may not be read off the main thread. Building throwaway copies from the same
  /// appearance is what lets this leave main at all, and is why `prewarm` already
  /// worked this way.
  private static func renderCompositeOffMain(
    appearance: ChatListAppearance,
    size: CGSize,
    scale: CGFloat,
    maskImage: CGImage?,
    key: String,
    completion: @escaping (CGImage) -> Void
  ) {
    guard size.width > 1, size.height > 1, scale > 0 else { return }
    prewarmLock.lock()
    let inserted = prewarmKeys.insert(key).inserted
    prewarmLock.unlock()
    guard inserted else { return }

    prewarmQueue.async {
      let startedAt = ProcessInfo.processInfo.systemUptime
      let composed = composite(
        appearance: appearance, size: size, scale: scale, maskImage: maskImage)
      let renderMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
      prewarmLock.lock()
      prewarmKeys.remove(key)
      prewarmLock.unlock()
      guard let composed else { return }
      if renderMs >= 8 {
        NSLog("[Wallpaper] raster %dms key=%@ (off-main)", renderMs, key)
      }
      snapshotCache.setObject(
        UIImage(cgImage: composed, scale: scale, orientation: .up),
        forKey: key as NSString,
        cost: composed.bytesPerRow * composed.height)
      DispatchQueue.main.async { completion(composed) }
    }
  }

  /// The gradient-plus-masked-pattern composite, from detached layers. Safe off-main.
  private static func composite(
    appearance: ChatListAppearance, size: CGSize, scale: CGFloat, maskImage: CGImage?
  ) -> CGImage? {
    let box = CGRect(origin: .zero, size: size)
    // Building layers off-main opens an IMPLICIT CATransaction on this thread, which Core
    // Animation then commits from a run-loop observer — that background commit is the
    // "layout engine modified from a background thread" crash. Own it and close it here.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    let baseLayer = CAGradientLayer()
    baseLayer.frame = box
    baseLayer.colors = appearance.wallpaperGradient.map(\.cgColor)
    baseLayer.startPoint = CGPoint(x: 0, y: 0)
    baseLayer.endPoint = CGPoint(x: 1, y: 1)
    baseLayer.opacity = Float(max(0, min(1, appearance.wallpaperOpacity)))

    let pattern = CAGradientLayer()
    pattern.frame = box
    let colors = appearance.wallpaperPatternGradient
    if colors.count >= 2, appearance.wallpaperPatternOpacity > 0.001, let maskImage {
      pattern.colors = colors.map(\.cgColor)
      pattern.locations = appearance.wallpaperPatternLocations
      pattern.startPoint = CGPoint(x: 0, y: 0)
      pattern.endPoint = CGPoint(x: 1, y: 1)
      pattern.opacity = Float(max(0, min(1, appearance.wallpaperPatternOpacity)))
      let maskLayer = CALayer()
      maskLayer.frame = box
      maskLayer.contents = maskImage
      maskLayer.contentsGravity = .resizeAspectFill
      maskLayer.contentsScale = scale
      pattern.mask = maskLayer
    } else {
      pattern.isHidden = true
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      baseLayer.render(in: context.cgContext)
      if !pattern.isHidden { pattern.render(in: context.cgContext) }
    }.cgImage
  }

  /// Pre-render the wallpaper while Home is idle. A cold 3x patterned raster measured
  /// 43–222ms and used to be paid synchronously inside destination layout, directly
  /// extending tap→push. Detached layers on a utility queue, filling the same cache;
  /// it creates no cells or controllers and therefore cannot expose or shift content.
  ///
  /// This renders ONE image. It used to render two, because the pattern's gradient stops
  /// were a function of scroll offset and a chat could land on either of two phases. The
  /// wallpaper no longer moves, so there is only one.
  static func prewarm(rawAppearance: [String: Any], size: CGSize, scale: CGFloat) {
    guard size.width > 1, size.height > 1, scale > 0 else { return }
    if !Thread.isMainThread {
      DispatchQueue.main.async { prewarm(rawAppearance: rawAppearance, size: size, scale: scale) }
      return
    }

    let appearance = ChatListAppearance.from(raw: rawAppearance)
    guard appearance.backgroundMode != "transparent" else { return }
    // Take the mask from the cache only. Rasterising it here is what this whole
    // function exists to avoid, and doing it above the `prewarmQueue.async` put the
    // single most expensive step in the app back on the main thread: `renderAlphaOnly
    // ← loadVector ← image(forKey:) ← ChatWallpaperView.prewarm` sat at the top of a
    // 0.43s `[mainhang]` stack one second after launch, immediately before the open
    // that then reported `hang=0.87s`.
    let maskKey = appearance.wallpaperMaskKey
    ChatWallpaperMaskStore.primeScreenPixelSize()
    let maskImage = maskKey.flatMap { ChatWallpaperMaskStore.cachedImage(forKey: $0) }
    if maskImage == nil, let maskKey, !maskKey.isEmpty,
      appearance.wallpaperPatternGradient.count >= 2, appearance.wallpaperPatternOpacity > 0.001
    {
      // Decode off-main and come back. Building the snapshot NOW would cache a
      // pattern-less render under this appearance's key — `snapshotCache` is consulted
      // before anything else, so that wrong image would be the wallpaper for the rest
      // of the session. Skipping one prewarm turn costs nothing; the retry does it all.
      ChatWallpaperMaskStore.prewarm(
        key: maskKey, bundles: [Bundle.main, Bundle(for: ChatWallpaperView.self)]
      ) { ok in
        guard ok else { return }
        DispatchQueue.main.async {
          prewarm(rawAppearance: rawAppearance, size: size, scale: scale)
        }
      }
      return
    }
    let pixelWidth = Int((size.width * scale).rounded())
    let pixelHeight = Int((size.height * scale).rounded())
    let key = "\(appearance.visualKey)|\(pixelWidth)x\(pixelHeight)"

    guard snapshotCache.object(forKey: key as NSString) == nil else { return }
    prewarmLock.lock()
    let inserted = prewarmKeys.insert(key).inserted
    prewarmLock.unlock()
    guard inserted else { return }

    prewarmQueue.async {
      let startedAt = ProcessInfo.processInfo.systemUptime
      if let cgImage = composite(
        appearance: appearance, size: size, scale: scale, maskImage: maskImage)
      {
        snapshotCache.setObject(
          UIImage(cgImage: cgImage, scale: scale, orientation: .up),
          forKey: key as NSString,
          cost: cgImage.bytesPerRow * cgImage.height)
        NSLog(
          "[Wallpaper] prewarm ms=%d size=%dx%d",
          Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
          pixelWidth, pixelHeight)
      }
      prewarmLock.lock()
      prewarmKeys.remove(key)
      prewarmLock.unlock()
    }
  }
}
