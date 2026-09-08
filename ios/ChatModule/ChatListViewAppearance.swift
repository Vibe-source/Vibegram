import ImageIO
import SwiftUI
import UIKit

/// Shared, downsampled wallpaper pattern masks.
///
/// Bundle PNGs are ~1312×3232 (~16 MB decoded RGBA each). Loading them full-size
/// into static caches was a leading jetsam (SIGKILL) contributor when opening
/// chats / Vibe AI under memory pressure or Xcode debug.
enum ChatWallpaperMaskStore {
  private final class CGImageBox: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  private static let cache: NSCache<NSString, CGImageBox> = {
    let cache = NSCache<NSString, CGImageBox>()
    cache.countLimit = 6
    // Cap total decoded mask bytes. A device-resolution vector mask is alpha-only
    // (1 byte/px, ~4 MB) rather than RGBA (4 bytes/px, ~17 MB), so this holds two.
    cache.totalCostLimit = 24 * 1024 * 1024
    return cache
  }()

  /// Long-edge cap for RASTER pattern masks (aspect-fill backdrop, not photography).
  ///
  /// Vector masks ignore this: they rasterise at exactly the size they will be
  /// drawn, so they never upscale. The legacy PNGs are 1312x3232 and get capped
  /// here, which on a 1290pt-wide screen meant a ~416px-wide mask stretched 3.1x —
  /// that upscale, not the source art, was the visible blur.
  private static let maxPixelSize = 1024

  /// Already-rasterised mask, from memory or from disk. Never runs the vector
  /// renderer, so a caller on the main thread can ask without risking the 0.4–0.9s
  /// stall a cold render costs (measured on device: `renderAlphaOnly` at the top of
  /// three separate `[mainhang]` stacks — 0.43s, 0.51s, 0.75s).
  ///
  /// The disk tier is what makes a COLD LAUNCH paint the pattern on frame one. Both
  /// caches used to be `NSCache`, so every launch — and every memory warning, see
  /// `purge()` — threw away a completely static image and re-derived it from the SVG.
  /// The first `apply()` therefore missed, painted the bare gradient, and faded the
  /// pattern in when the off-main decode landed: the reported "solid background first,
  /// then the wallpaper appears". Reading pre-rendered bytes back is ~2–4ms, which is
  /// inside one frame, so the miss no longer exists to be seen.
  static func cachedImage(forKey key: String) -> CGImage? {
    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    if let hit = cache.object(forKey: normalized as NSString)?.image { return hit }
    guard let fromDisk = loadFromDisk(key: normalized) else { return nil }
    store(fromDisk, key: normalized)
    return fromDisk
  }

  /// Decode a mask off the main thread and leave it in the cache for the synchronous
  /// readers. Callers that must paint right now still call `image(forKey:)`; this is
  /// what turns that call into a cache hit instead of a full-screen vector rasterisation.
  static func prewarm(
    key: String, bundles: [Bundle] = [.main], completion: ((Bool) -> Void)? = nil
  ) {
    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else {
      completion?(false)
      return
    }
    if cache.object(forKey: normalized as NSString) != nil {
      completion?(true)
      return
    }
    // The render size depends on the screen, which is main-only. Resolve it here — this
    // call is cheap and usually already on main — so the worker never touches UIScreen.
    primeScreenPixelSize()
    prewarmLock.lock()
    let alreadyRunning = !prewarmingKeys.insert(normalized).inserted
    prewarmLock.unlock()
    guard !alreadyRunning else {
      completion?(false)
      return
    }
    prewarmQueue.async {
      let startedAt = ProcessInfo.processInfo.systemUptime
      let image = image(forKey: normalized, bundles: bundles)
      prewarmLock.lock()
      prewarmingKeys.remove(normalized)
      prewarmLock.unlock()
      NSLog(
        "[Wallpaper] mask prewarm key=%@ ok=%@ ms=%d (off-main)", normalized,
        image != nil ? "Y" : "N",
        Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
      completion?(image != nil)
    }
  }

  private static let prewarmQueue = DispatchQueue(
    label: "com.vibe.wallpaper-mask-prewarm", qos: .utility)
  private static let prewarmLock = NSLock()
  private static var prewarmingKeys: Set<String> = []

  static func image(forKey key: String, bundles: [Bundle] = [.main]) -> CGImage? {
    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    if let cached = cache.object(forKey: normalized as NSString) {
      return cached.image
    }
    if let fromDisk = loadFromDisk(key: normalized) {
      store(fromDisk, key: normalized)
      return fromDisk
    }
    // Everything past this point rasterises. On the main thread that is the single
    // longest stall in the app, so say so — a `[mainhang]` stack now has a matching
    // line naming the key that paid for it.
    if Thread.isMainThread {
      NSLog("[Wallpaper] MASK RENDER ON MAIN key=%@ (cache miss)", normalized)
    }

    // Prefer a vector asset when one exists for this key.
    if let vectorName = vectorName(for: normalized),
      let image = loadVector(named: vectorName, bundles: bundles)
    {
      store(image, key: normalized)
      persistToDisk(image, key: normalized)
      return image
    }

    guard let baseName = baseName(for: normalized) else { return nil }

    for bundle in bundles {
      if let path = bundle.path(forResource: baseName, ofType: "png"),
        let image = loadDownsampled(path: path)
      {
        store(image, key: normalized)
        return image
      }
      if let uiImage =
        UIImage(named: baseName, in: bundle, compatibleWith: nil)
        ?? UIImage(named: "\(baseName).png", in: bundle, compatibleWith: nil),
        let image = downsample(uiImage: uiImage)
      {
        store(image, key: normalized)
        return image
      }
    }
    return nil
  }

  /// Drops the in-memory copies only. The disk tier survives on purpose: this runs on
  /// a memory warning, and before the disk tier existed that meant the next chat open
  /// paid a fresh half-second vector render on the main thread to redraw an image that
  /// had not changed.
  static func purge() {
    cache.removeAllObjects()
  }

  // MARK: - Disk tier

  /// `VMSK` + version + width + height, then `width * height` tightly-packed alpha
  /// bytes. Raw rather than PNG because the point is to beat a decode, not to be
  /// small: the read is a memcpy into a bitmap context of exactly the shape
  /// `renderAlphaOnly` produces, so the reconstructed image is byte-identical to a
  /// freshly rendered one.
  private static let diskMagic: UInt32 = 0x564D_534B
  private static let diskVersion: UInt32 = 1
  private static let diskHeaderBytes = 16
  /// Screen-resolution alpha masks are ~3.6 MB each and there are only a handful of
  /// keys, but a user who tours the picker should not accumulate them forever.
  private static let diskFileLimit = 4
  private static let diskQueue = DispatchQueue(
    label: "com.vibe.wallpaper-mask-disk", qos: .utility)

  private static let diskDirectory: URL? = {
    guard
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let directory = caches.appendingPathComponent("WallpaperMasks", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    return directory
  }()

  private static func diskURL(key: String) -> URL? {
    // Keys are internal identifiers ("doodles", "music2"), but a path component built
    // from an untrusted string is a traversal waiting to happen.
    let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    guard !safe.isEmpty else { return nil }
    return diskDirectory?.appendingPathComponent("\(safe).vibemask8", isDirectory: false)
  }

  private static func loadFromDisk(key: String) -> CGImage? {
    guard let url = diskURL(key: key),
      let data = try? Data(contentsOf: url),
      data.count > diskHeaderBytes
    else { return nil }

    let header: (UInt32, UInt32, Int, Int) = data.withUnsafeBytes { raw in
      (
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
        Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))),
        Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
      )
    }
    let (magic, version, width, height) = header
    guard magic == diskMagic, version == diskVersion,
      width > 0, height > 0,
      data.count == diskHeaderBytes + width * height,
      let context = alphaContext(width: width, height: height),
      let destination = context.data
    else { return nil }

    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      // `alphaContext` asks for `bytesPerRow == width`, so the stored bytes are already
      // in the context's layout and this is one flat copy rather than a row loop.
      memcpy(destination, base.advanced(by: diskHeaderBytes), width * height)
    }
    return context.makeImage()
  }

  private static func persistToDisk(_ image: CGImage, key: String) {
    guard let url = diskURL(key: key),
      image.bitsPerPixel == 8,
      let pixels = image.dataProvider?.data as Data?
    else { return }
    let width = image.width
    let height = image.height
    let bytesPerRow = image.bytesPerRow
    guard width > 0, height > 0, bytesPerRow >= width,
      pixels.count >= bytesPerRow * height
    else { return }

    diskQueue.async {
      var out = Data(capacity: diskHeaderBytes + width * height)
      for value in [diskMagic, diskVersion, UInt32(width), UInt32(height)] {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
      }
      if bytesPerRow == width {
        out.append(pixels.prefix(width * height))
      } else {
        // Rows can be padded for alignment; the file format is tightly packed so that
        // the read side is a single memcpy.
        for row in 0..<height {
          let start = row * bytesPerRow
          out.append(pixels[start..<(start + width)])
        }
      }
      do {
        try out.write(to: url, options: .atomic)
        NSLog("[Wallpaper] mask persisted key=%@ %dx%d", key, width, height)
      } catch {
        NSLog("[Wallpaper] mask persist failed key=%@ err=%@", key, "\(error)")
      }
      pruneDisk()
    }
  }

  private static func pruneDisk() {
    guard let directory = diskDirectory,
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    guard entries.count > diskFileLimit else { return }
    let byAge = entries.sorted {
      let lhs =
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      let rhs =
        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      return lhs > rhs
    }
    for stale in byAge.dropFirst(diskFileLimit) {
      try? FileManager.default.removeItem(at: stale)
    }
  }

  private static func alphaContext(width: Int, height: Int) -> CGContext? {
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
  }

  private static func store(_ image: CGImage, key: String) {
    let bytesPerPixel = max(1, image.bitsPerPixel / 8)
    let cost = image.width * image.height * bytesPerPixel
    cache.setObject(CGImageBox(image), forKey: key as NSString, cost: cost)
  }

  /// Asset-catalog name for keys that ship as vector (`preserves-vector-representation`).
  ///
  /// A key listed here still falls back to its legacy PNG if the vector asset is
  /// missing, so adding a name before its artwork lands is safe.
  private static func vectorName(for key: String) -> String? {
    switch key {
    case "doodles", "hearts":
      return "DoodleWallpaper"
    case "music":
      return "MusicWallpaper"
    case "music2":
      return "Music2Wallpaper"
    case "food":
      return "FoodWallpaper"
    case "animals":
      return "AnimalsWallpaper"
    case "cosmos":
      return "CosmosWallpaper"
    default:
      return nil
    }
  }

  private static func loadVector(named name: String, bundles: [Bundle]) -> CGImage? {
    for bundle in bundles {
      guard let image = UIImage(named: name, in: bundle, compatibleWith: nil),
        image.size.width > 0, image.size.height > 0
      else { continue }

      let size = vectorRenderSize(for: image.size)
      if let alphaOnly = renderAlphaOnly(image, size: size) {
        return alphaOnly
      }
      // Fall back to a normal RGBA raster if an alpha-only context is unavailable.
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      format.opaque = false
      let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      if let cg = rendered.cgImage { return cg }
    }
    return nil
  }

  /// Screen pixel size, cached so `vectorRenderSize` can run on a worker.
  ///
  /// `UIScreen.main` is main-actor-only, and it is the ONLY main-thread dependency in
  /// the whole decode path — everything else is `UIImage(named:)`, `CGContext` and
  /// `CGImage`, all of which are safe off-main. Caching it once is what lets the
  /// rasterisation leave the main thread at all.
  private static let screenPixelSizeLock = NSLock()
  private static var cachedScreenPixelSize: CGSize?

  static func primeScreenPixelSize() {
    screenPixelSizeLock.lock()
    let known = cachedScreenPixelSize != nil
    screenPixelSizeLock.unlock()
    guard !known else { return }
    guard Thread.isMainThread else {
      DispatchQueue.main.async { primeScreenPixelSize() }
      return
    }
    let size = UIScreen.main.nativeBounds.size
    screenPixelSizeLock.lock()
    cachedScreenPixelSize = size
    screenPixelSizeLock.unlock()
  }

  private static func screenPixelSize() -> CGSize {
    screenPixelSizeLock.lock()
    let cached = cachedScreenPixelSize
    screenPixelSizeLock.unlock()
    if let cached { return cached }
    guard Thread.isMainThread else {
      // Off-main with nothing primed: fall back to the source size rather than touch
      // UIScreen. `primeScreenPixelSize` runs before every prewarm, so this is only
      // reachable if a worker races the very first main-thread turn.
      return .zero
    }
    let size = UIScreen.main.nativeBounds.size
    screenPixelSizeLock.lock()
    cachedScreenPixelSize = size
    screenPixelSizeLock.unlock()
    return size
  }

  /// Smallest size that still covers the screen, since the mask is drawn
  /// `resizeAspectFill`. Rasterising the vector here means zero upscale.
  private static func vectorRenderSize(for source: CGSize) -> CGSize {
    let screen = screenPixelSize()
    guard source.width > 0, source.height > 0, screen.width > 0, screen.height > 0 else {
      return source
    }
    let scale = max(screen.width / source.width, screen.height / source.height)
    return CGSize(
      width: max(1, (source.width * scale).rounded()),
      height: max(1, (source.height * scale).rounded())
    )
  }

  /// 8-bit alpha-only raster: a mask only ever uses its alpha, so storing RGBA
  /// would waste 4x the memory for identical output.
  ///
  /// The context shape is shared with `alphaContext` so that a mask rebuilt from the
  /// disk tier is indistinguishable from one rendered here.
  private static func renderAlphaOnly(_ image: UIImage, size: CGSize) -> CGImage? {
    let width = Int(size.width)
    let height = Int(size.height)
    guard width > 0, height > 0,
      let context = alphaContext(width: width, height: height)
    else { return nil }

    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    UIGraphicsPushContext(context)
    image.draw(in: CGRect(origin: .zero, size: size))
    UIGraphicsPopContext()
    return context.makeImage()
  }

  private static func baseName(for key: String) -> String? {
    switch key {
    case "doodles", "hearts":
      return "doodle_transparent"
    case "music":
      return "music_transparent"
    case "music2":
      return "music2_transparent"
    case "food":
      return "food_transparent"
    case "animals":
      return "animals_transparent"
    default:
      return nil
    }
  }

  private static func loadDownsampled(path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func downsample(uiImage: UIImage) -> CGImage? {
    guard let cg = uiImage.cgImage else { return nil }
    let maxDim = max(cg.width, cg.height)
    if maxDim <= maxPixelSize { return cg }
    let scale = CGFloat(maxPixelSize) / CGFloat(maxDim)
    let size = CGSize(
      width: max(1.0, CGFloat(cg.width) * scale),
      height: max(1.0, CGFloat(cg.height) * scale)
    )
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let rendered = renderer.image { _ in
      uiImage.draw(in: CGRect(origin: .zero, size: size))
    }
    return rendered.cgImage
  }
}

// MARK: - ChatAppearanceDraft (versioned edit / persistence contract)

/// Platform-neutral, hex-string appearance draft for the editor → model pipeline.
/// Colors are `#RRGGBB` / `#RRGGBBAA` strings (not `UIColor`) so the draft can
/// persist and cross the wire. Integrator maps via `ChatListAppearance.from(draft:)`.
struct ChatAppearanceDraft: Equatable, Codable {
  var version: Int = 2
  var mode: String = "system"  // "dark" | "light" | "system"
  var themeId: String? = nil

  var wallpaperKind: String = "gradient"  // "builtin" | "solid" | "gradient" | "custom"
  /// Empty means "the plate decides". These carried the dark Aurora hexes, so an
  /// unedited draft overrode the light plate with a dark wallpaper and dark bubbles.
  var wallpaperGradient: [String] = []
  var wallpaperGradientLocations: [Double] = [0.0, 1.0]
  /// Optional second pair blended in while scrolling (Telegram-style “4 color”).
  var wallpaperScrollGradient: [String] = []
  var wallpaperPatternMaskKey: String? = nil
  var wallpaperPatternOpacity: Double = -1.0  // < 0 = take the plate's

  var bubbleMeGradient: [String] = []
  var bubbleThemGradient: [String] = []

  var accent: String = ""
  /// Normalized 0…1. Points via `messageCornerRadiusPoints(normalized:)`.
  /// Telegram-matched default: (16pt - 4pt) / 22pt = 6/11.
  var messageCornerRadius: Double = 6.0 / 11.0
  /// Optional for backward-compatible decoding. nil resolves to the reference tail.
  /// 0 = compact/straight, 1 = the default Telegram-reference cubic.
  var messageTailCurvature: Double? = nil
  var textScale: Double = 1.0
  var animationsEnabled: Bool = true

  /// Empty colour fields — the theme plate decides.
  static let `default` = ChatAppearanceDraft()

  // MARK: Canonical corner mapping (single source of truth)
  //
  // normalized 0…1 → 4pt…26pt
  // radiusPt = 4 + normalized * 22
  // Editor slider, appearance model, and cells MUST all use this mapping.

  /// Maps normalized corner (0…1) to point radius (4…26). Clamp input to 0…1.
  static func messageCornerRadiusPoints(normalized: Double) -> CGFloat {
    CGFloat(4.0 + max(0.0, min(1.0, normalized)) * 22.0)
  }

  /// Default stored point radius on `ChatListAppearance` (== mapping at 6/11).
  static let defaultMessageCornerRadiusPoints: CGFloat = 16
  static let defaultMessageTailCurvature: CGFloat = 1.0

  /// v1 shipped with 0.62 as its untouched default (17.64pt / 52.92px at 3×).
  /// Move only that exact legacy default to the screenshot-matched 16pt value; preserve
  /// every deliberately customized slider position.
  static func migratingLegacyDefaults(_ draft: ChatAppearanceDraft) -> ChatAppearanceDraft {
    var migrated = draft
    if migrated.version < 2 {
      migrated.version = 2
      if abs(draft.messageCornerRadius - 0.62) < 0.000_001 {
        migrated.messageCornerRadius = 6.0 / 11.0
      }
    }
    if migrated.version < 3 {
      migrated.version = 3
      // Drafts written before colours resolved live carry a baked palette, which pinned the
      // chat to whatever appearance was active when the draft was first seeded.
      if chatAppearanceDraftPaletteIsSeeded(migrated) {
        migrated.wallpaperGradient = []
        migrated.bubbleMeGradient = []
        migrated.bubbleThemGradient = []
        migrated.wallpaperPatternMaskKey = nil
        migrated.wallpaperPatternOpacity = -1.0
        migrated.accent = ""
      }
    }
    guard migrated.version < 4 else { return migrated }
    migrated.version = 4
    // Re-seed factory outgoing tints so Telegram-deeper plates replace the old neon pairs.
    if chatAppearanceDraftPaletteIsSeeded(migrated)
      || isLegacyFactoryOutgoingPalette(migrated.bubbleMeGradient)
    {
      migrated.bubbleMeGradient = []
      migrated.accent = ""
    }
    return migrated
  }

  // MARK: Dictionary bridge (persistence / Settings)

  static func from(raw: [String: Any]?) -> ChatAppearanceDraft {
    guard let raw else { return .default }
    let base = ChatAppearanceDraft.default

    func stringArray(_ key: String) -> [String]? {
      raw[key] as? [String]
    }
    func doubleArray(_ key: String) -> [Double]? {
      if let values = raw[key] as? [Double] { return values }
      if let values = raw[key] as? [NSNumber] { return values.map(\.doubleValue) }
      return nil
    }

    var draft = base
    if let version = (raw["version"] as? NSNumber)?.intValue ?? raw["version"] as? Int {
      draft.version = version
    }
    if let mode = normalizedString(raw["mode"]) {
      draft.mode = mode.lowercased()
    }
    draft.themeId = normalizedString(raw["themeId"]) ?? normalizedString(raw["nativeThemeId"])

    if let kind = normalizedString(raw["wallpaperKind"]) {
      draft.wallpaperKind = kind.lowercased()
    }
    if let stops = stringArray("wallpaperGradient"), !stops.isEmpty {
      draft.wallpaperGradient = stops
    }
    if let locs = doubleArray("wallpaperGradientLocations"), !locs.isEmpty {
      draft.wallpaperGradientLocations = locs
    }
    if let scroll = stringArray("wallpaperScrollGradient") {
      draft.wallpaperScrollGradient = scroll
    }
    if raw.keys.contains("wallpaperPatternMaskKey") {
      draft.wallpaperPatternMaskKey = normalizedString(raw["wallpaperPatternMaskKey"])
    } else if raw.keys.contains("wallpaperMaskKey") {
      draft.wallpaperPatternMaskKey = normalizedString(raw["wallpaperMaskKey"])
    }
    if let opacity = (raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue
      ?? raw["wallpaperPatternOpacity"] as? Double
    {
      draft.wallpaperPatternOpacity = opacity
    }
    if let me = stringArray("bubbleMeGradient"), me.count >= 2 {
      draft.bubbleMeGradient = me
    }
    if let them = stringArray("bubbleThemGradient"), them.count >= 2 {
      draft.bubbleThemGradient = them
    }
    if let accent =
      normalizedString(raw["accent"])
      ?? normalizedString(raw["accentColor"])
    {
      draft.accent = accent
    }
    if let corner = (raw["messageCornerRadius"] as? NSNumber)?.doubleValue
      ?? raw["messageCornerRadius"] as? Double
    {
      // Accept either normalized 0…1 or legacy point values (>1 → re-normalize).
      if corner <= 1.0 {
        draft.messageCornerRadius = max(0.0, min(1.0, corner))
      } else {
        let clampedPt = max(4.0, min(26.0, corner))
        draft.messageCornerRadius = (clampedPt - 4.0) / 22.0
      }
    }
    if let curvature = (raw["messageTailCurvature"] as? NSNumber)?.doubleValue
      ?? raw["messageTailCurvature"] as? Double
    {
      draft.messageTailCurvature = max(0.0, min(1.0, curvature))
    }
    if let scale = (raw["textScale"] as? NSNumber)?.doubleValue ?? raw["textScale"] as? Double {
      draft.textScale = scale
    }
    if let anim = parseBool(raw["animationsEnabled"]) ?? parseBool(raw["animations"]) {
      draft.animationsEnabled = anim
    }
    return migratingLegacyDefaults(draft)
  }

  var asDictionary: [String: Any] {
    var dict: [String: Any] = [
      "version": version,
      "mode": mode,
      "wallpaperKind": wallpaperKind,
      "wallpaperGradient": wallpaperGradient,
      "wallpaperGradientLocations": wallpaperGradientLocations,
      "wallpaperScrollGradient": wallpaperScrollGradient,
      "wallpaperPatternOpacity": wallpaperPatternOpacity,
      "bubbleMeGradient": bubbleMeGradient,
      "bubbleThemGradient": bubbleThemGradient,
      "accent": accent,
      "messageCornerRadius": messageCornerRadius,
      "textScale": textScale,
      "animationsEnabled": animationsEnabled,
    ]
    if let themeId {
      dict["themeId"] = themeId
    }
    if let wallpaperPatternMaskKey {
      dict["wallpaperPatternMaskKey"] = wallpaperPatternMaskKey
    }
    if let messageTailCurvature {
      dict["messageTailCurvature"] = max(0.0, min(1.0, messageTailCurvature))
    }
    return dict
  }
}

// MARK: - ChatAppearanceDraftStore (Settings persistence → chat raw)

/// Persists the appearance editor draft and produces the raw dictionary that
/// `ChatMainView` / `ChatListView.setAppearance` already consume.
enum ChatAppearanceDraftStore {
  static let storageKey = "vibe.chat.appearanceDraft.v1"
  static let didChangeNotification = Notification.Name("ChatAppearanceDraftDidChange")

  static var current: ChatAppearanceDraft { load() }

  static func load() -> ChatAppearanceDraft {
    guard let data = UserDefaults.standard.data(forKey: storageKey) else {
      return seededDefault()
    }
    if let draft = try? JSONDecoder().decode(ChatAppearanceDraft.self, from: data) {
      return ChatAppearanceDraft.migratingLegacyDefaults(draft)
    }
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return ChatAppearanceDraft.from(raw: obj)
    }
    return seededDefault()
  }

  static func save(_ draft: ChatAppearanceDraft) {
    if let data = try? JSONEncoder().encode(draft) {
      UserDefaults.standard.set(data, forKey: storageKey)
    } else if let data = try? JSONSerialization.data(
      withJSONObject: draft.asDictionary, options: []
    ) {
      UserDefaults.standard.set(data, forKey: storageKey)
    }
    ChatListAppearance.invalidateBootstrap()
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  /// Seed from the current light/dark preference + theme plate when nothing is saved.
  ///
  /// Carries the *choice* — mode and plate — and no colours. It used to bake the resolved
  /// palette into the draft, which froze the chat at whichever appearance was active the
  /// first time it ran: switching to light afterwards left the dark hexes in place and the
  /// chat kept painting dark. Colours resolve live in `ChatListAppearance.from(draft:)`.
  static func seededDefault() -> ChatAppearanceDraft {
    var draft = ChatAppearanceDraft.default
    draft.mode =
      UserDefaults.standard.string(forKey: "vibe.app.appearance")
      ?? AppAppearanceOption.system.rawValue
    draft.themeId =
      UserDefaults.standard.string(forKey: "vibe.app.themePlate")
      ?? AppThemePlateOption.glacier.rawValue
    return draft
  }

  /// Payload for existing `setAppearance([String: Any])` call sites.
  static func chatRawAppearance(isDark: Bool) -> [String: Any] {
    var dict = load().asDictionary
    dict["theme"] = isDark ? "dark" : "light"
    dict["nativeThemeIsDark"] = isDark
    if let mask = dict["wallpaperPatternMaskKey"] as? String {
      dict["wallpaperMaskKey"] = mask
    }
    // Ensure custom draft path wins over pure nativeThemeId presets.
    dict["version"] = max(1, (dict["version"] as? Int) ?? 1)
    return dict
  }
}

// MARK: - Accent semantic tokens (media chrome)

/// Contrast-safe accent tints for voice waveform, play button, and media plates.
struct ChatAppearanceAccentTokens: Equatable {
  let accent: UIColor
  let waveform: UIColor
  let playFill: UIColor
  let mediaPlate: UIColor
}

/// Telegram-style rest→scroll wallpaper blend.
/// `rest` is the 2-stop base; optional `scroll` pair blends in as `progress` goes 0…1.
/// Progress is clamped. Empty `scroll` returns `rest` unchanged.
func interpolatedWallpaperGradient(
  rest: [UIColor],
  scroll: [UIColor],
  progress: CGFloat
) -> [UIColor] {
  let t = max(0.0, min(1.0, progress))
  guard !rest.isEmpty else {
    return scroll.isEmpty ? [] : scroll
  }
  guard !scroll.isEmpty, t > 0.0001 else {
    return rest
  }
  return rest.enumerated().map { index, restColor in
    let scrollColor: UIColor
    if index < scroll.count {
      scrollColor = scroll[index]
    } else if scroll.count == 1 {
      scrollColor = scroll[0]
    } else {
      let frac = CGFloat(index) / CGFloat(max(rest.count - 1, 1))
      let scrollIndex = min(scroll.count - 1, Int(round(frac * CGFloat(scroll.count - 1))))
      scrollColor = scroll[scrollIndex]
    }
    return blendColor(restColor, with: scrollColor, amount: t)
  }
}

/// Derive contrast-safe media-chrome tints from a chosen accent.
/// Prefers WCAG-ish contrast against typical dark/light bubble plates; falls back
/// to `ChatListAppearance.brandAccentFallback` when the accent fails.
func semanticAccentTokens(from accent: UIColor, isDark: Bool) -> ChatAppearanceAccentTokens {
  // Typical them-bubble plates used as contrast reference.
  let plate: UIColor =
    isDark
    ? UIColor(red: 0.1451, green: 0.1608, blue: 0.2118, alpha: 1.0)  // #252936
    : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)

  let minContrast: CGFloat = 3.0
  var resolved = accent
  if contrastRatio(resolved, plate) < minContrast {
    let fallback = ChatListAppearance.brandAccentFallback
    if contrastRatio(fallback, plate) >= minContrast {
      resolved = fallback
    } else {
      // Last resort: push luminance away from the plate.
      resolved =
        isDark
        ? UIColor(red: 0.35, green: 0.92, blue: 0.86, alpha: 1.0)
        : UIColor(red: 0.08, green: 0.42, blue: 0.38, alpha: 1.0)
    }
  }

  return ChatAppearanceAccentTokens(
    accent: resolved,
    waveform: colorWithAlpha(resolved, isDark ? 0.92 : 0.88),
    playFill: resolved,
    mediaPlate: colorWithAlpha(resolved, isDark ? 0.22 : 0.14)
  )
}

// MARK: - ChatListAppearance (runtime UIColor model)

struct ChatListAppearance {
  let backgroundMode: String
  let wallpaperGradient: [UIColor]
  let wallpaperOpacity: CGFloat
  let wallpaperPatternGradient: [UIColor]
  let wallpaperPatternLocations: [NSNumber]?
  let wallpaperPatternOpacity: CGFloat
  let wallpaperMaskKey: String?

  let bubbleMeGradient: [UIColor]
  let bubbleThemGradient: [UIColor]
  let bubbleThemColor: UIColor

  let textColorMe: UIColor
  let textColorThem: UIColor
  let timeColorMe: UIColor
  let timeColorThem: UIColor

  let dayTextColor: UIColor
  let dayBackgroundColor: UIColor
  let dayBorderColor: UIColor

  /// Controls the insertion animation approach:
  ///   0 = None (instant, no animation)
  ///   1 = SlideUpNewOnly (only new cells slide up)
  ///   2 = TelegramOffset (record pre/post positions, animate deltas)
  ///   3 = SpringBatch (UIView.animate with spring wrapping the batch)
  let insertionAnimationMode: Int

  /// Accent driving media/cell chrome (waveform, play, plates). Default: brand teal.
  let accent: UIColor
  /// Bubble corner radius in points. Default 18 (== mapping at normalized ~0.636).
  let messageCornerRadius: CGFloat
  /// Integrated tail interpolation. 0 = compact/straight, 1 = reference cubic.
  let messageTailCurvature: CGFloat
  /// Optional second wallpaper gradient pair blended on scroll. Empty = no scroll blend.
  let wallpaperScrollGradient: [UIColor]

  /// Shared brand accent fallback used wherever code needs an
  /// agent/accent color and no per-chat appearance is available yet — bubble tint,
  /// agent border, reply/mention bars, profile default accent, progress rings, etc.
  static let brandAccentFallback = UIColor(red: 0.1843, green: 0.6196, blue: 0.5765, alpha: 1.0)

  /// Explicit memberwise init. New fields are defaulted so existing call sites compile.
  init(
    backgroundMode: String,
    wallpaperGradient: [UIColor],
    wallpaperOpacity: CGFloat,
    wallpaperPatternGradient: [UIColor],
    wallpaperPatternLocations: [NSNumber]?,
    wallpaperPatternOpacity: CGFloat,
    wallpaperMaskKey: String?,
    bubbleMeGradient: [UIColor],
    bubbleThemGradient: [UIColor],
    bubbleThemColor: UIColor,
    textColorMe: UIColor,
    textColorThem: UIColor,
    timeColorMe: UIColor,
    timeColorThem: UIColor,
    dayTextColor: UIColor,
    dayBackgroundColor: UIColor,
    dayBorderColor: UIColor,
    insertionAnimationMode: Int,
    accent: UIColor = ChatListAppearance.brandAccentFallback,
    messageCornerRadius: CGFloat = 16,
    messageTailCurvature: CGFloat = ChatAppearanceDraft.defaultMessageTailCurvature,
    wallpaperScrollGradient: [UIColor] = []
  ) {
    self.backgroundMode = backgroundMode
    self.wallpaperGradient = wallpaperGradient
    self.wallpaperOpacity = wallpaperOpacity
    self.wallpaperPatternGradient = wallpaperPatternGradient
    self.wallpaperPatternLocations = wallpaperPatternLocations
    self.wallpaperPatternOpacity = wallpaperPatternOpacity
    self.wallpaperMaskKey = wallpaperMaskKey
    self.bubbleMeGradient = bubbleMeGradient
    self.bubbleThemGradient = bubbleThemGradient
    self.bubbleThemColor = bubbleThemColor
    self.textColorMe = textColorMe
    // A theme may not ship unreadable incoming text.
    //
    // `from(draft:)` derives this itself and always picks white-on-dark, but
    // `from(raw:)` takes `textColorThem` straight from the theme payload — so a theme
    // whose ink was authored against a lighter plate than the one it actually renders
    // produces dark text on a near-black bubble. That is the reported "some themes I
    // cannot read anything": incoming bubbles, their timestamps, and the day pills all
    // disappeared while outgoing bubbles stayed fine.
    //
    // Enforced here rather than at either call site because this is the one funnel every
    // construction path goes through, including any theme added later.
    let incomingPlate = incomingPlateReference(
      gradient: bubbleThemGradient, base: bubbleThemColor)
    let readableThem = readableForeground(textColorThem, on: incomingPlate)
    self.textColorThem = readableThem
    self.timeColorMe = timeColorMe
    // The derived colours were built from the ORIGINAL ink by `colorWithAlpha`, so
    // correcting only `textColorThem` would leave the timestamps and day pills exactly as
    // unreadable as they were. Re-tint them onto the corrected hue, keeping the alpha each
    // one was designed with.
    let themInkChanged = !colorsEqual(readableThem, textColorThem)
    self.timeColorThem = themInkChanged ? retinted(timeColorThem, to: readableThem) : timeColorThem
    self.dayTextColor = themInkChanged ? retinted(dayTextColor, to: readableThem) : dayTextColor
    self.dayBackgroundColor = dayBackgroundColor
    self.dayBorderColor = themInkChanged ? retinted(dayBorderColor, to: readableThem) : dayBorderColor
    self.insertionAnimationMode = insertionAnimationMode
    self.accent = accent
    self.messageCornerRadius = messageCornerRadius
    self.messageTailCurvature = max(0.0, min(1.0, messageTailCurvature))
    self.wallpaperScrollGradient = wallpaperScrollGradient
  }

  /// Structural defaults handed to the preset resolver — background mode, animation mode,
  /// accent and corner geometry. Its colours are placeholders: every one is replaced by the
  /// theme variant. There is no fallback palette in this type; the preset table owns colour.
  private static let structuralSeed = ChatListAppearance(
    backgroundMode: "gradient",
    wallpaperGradient: [],
    wallpaperOpacity: 1.0,
    wallpaperPatternGradient: [],
    wallpaperPatternLocations: [],
    wallpaperPatternOpacity: 0.0,
    wallpaperMaskKey: nil,
    bubbleMeGradient: [],
    bubbleThemGradient: [],
    bubbleThemColor: .clear,
    textColorMe: .clear,
    textColorThem: .clear,
    timeColorMe: .clear,
    timeColorThem: .clear,
    dayTextColor: .clear,
    dayBackgroundColor: .clear,
    dayBorderColor: .clear,
    insertionAnimationMode: 2,
    accent: brandAccentFallback,
    messageCornerRadius: ChatAppearanceDraft.defaultMessageCornerRadiusPoints,
    messageTailCurvature: ChatAppearanceDraft.defaultMessageTailCurvature,
    wallpaperScrollGradient: []
  )

  /// The palette for a theme plate in light or dark, straight from the preset table.
  ///
  /// The one colour source in the app. Unknown or missing plate resolves to the default
  /// plate rather than to a literal, so light mode can never render a dark constant.
  static func plate(themeId: String?, isDark: Bool) -> ChatListAppearance {
    let trimmed = themeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let ids = [trimmed, AppThemePlateOption.glacier.rawValue]
    for id in ids where !id.isEmpty {
      let raw: [String: Any] = [
        "nativeThemeId": id,
        "nativeThemeIsDark": isDark,
        "backgroundMode": "gradient",
        "wallpaperOpacity": 1.0,
      ]
      if let resolved = nativePresetAppearance(from: raw, fallback: structuralSeed) {
        return resolved
      }
    }
    return structuralSeed
  }

  /// The surface colour under the transcript. Always a theme colour, never a literal.
  var wallpaperBase: UIColor {
    wallpaperGradient.first ?? bubbleThemColor
  }

  /// The live appearance: the saved theme resolved against the app's effective light/dark.
  /// There is no fallback palette — every surface starts from the real theme.
  static var current: ChatListAppearance {
    bootstrap(systemStyle: resolvedSystemStyle())
  }

  private static var bootstrapCache: (style: UIUserInterfaceStyle, value: ChatListAppearance)?
  private static var lastKnownSystemStyle: UIUserInterfaceStyle = .unspecified
  private static let bootstrapLock = NSLock()

  /// The app's effective light/dark. The key window carries the explicit Light/Dark
  /// preference as `overrideUserInterfaceStyle`; `UITraitCollection.current` does not, so
  /// reading it made the first paint disagree with the appearance that landed after it.
  /// Main thread reads live and records it; other threads reuse that record.
  static func resolvedSystemStyle() -> UIUserInterfaceStyle {
    guard Thread.isMainThread else {
      bootstrapLock.lock()
      defer { bootstrapLock.unlock() }
      return lastKnownSystemStyle
    }
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let window = windows.first(where: \.isKeyWindow) ?? windows.first
    var live = window?.traitCollection.userInterfaceStyle ?? .unspecified
    if live == .unspecified {
      live = UIScreen.main.traitCollection.userInterfaceStyle
    }
    if live == .unspecified {
      live = UITraitCollection.current.userInterfaceStyle
    }
    bootstrapLock.lock()
    lastKnownSystemStyle = live
    bootstrapLock.unlock()
    return live
  }

  static func bootstrap(systemStyle: UIUserInterfaceStyle) -> ChatListAppearance {
    bootstrapLock.lock()
    if let cached = bootstrapCache, cached.style == systemStyle {
      bootstrapLock.unlock()
      return cached.value
    }
    bootstrapLock.unlock()
    let resolved = from(draft: ChatAppearanceDraftStore.current, systemStyle: systemStyle)
    bootstrapLock.lock()
    bootstrapCache = (systemStyle, resolved)
    bootstrapLock.unlock()
    return resolved
  }

  static func invalidateBootstrap() {
    bootstrapLock.lock()
    bootstrapCache = nil
    bootstrapLock.unlock()
  }

  static func from(raw: [String: Any]?) -> ChatListAppearance {
    guard let raw else { return .current }

    // Versioned editor drafts take precedence over nativeThemeId presets.
    let version =
      (raw["version"] as? NSNumber)?.intValue
      ?? raw["version"] as? Int
    if let version, version >= 1 {
      var draft = ChatAppearanceDraft.from(raw: raw)
      if draft.mode == "system" {
        let isDark: Bool
        if let flag = raw["nativeThemeIsDark"] as? Bool {
          isDark = flag
        } else if let theme = (raw["theme"] as? String)?.lowercased() {
          isDark = theme != "light"
        } else {
          isDark = resolvedSystemStyle() != .light
        }
        draft.mode = isDark ? "dark" : "light"
      }
      return from(draft: draft)
    }

    if let nativeResolved = nativePresetAppearance(from: raw, fallback: .current) {
      return nativeResolved
    }

    let fallback = ChatListAppearance.current
    let mode = (raw["backgroundMode"] as? String) ?? fallback.backgroundMode
    let gradientStrings = raw["wallpaperGradient"] as? [String]
    let patternGradientStrings = raw["wallpaperPatternGradient"] as? [String]
    let meGradientStrings = raw["bubbleMeGradient"] as? [String]
    let themGradientStrings = raw["bubbleThemGradient"] as? [String]

    let bubbleThemColor = parseColor(raw["bubbleThemColor"] as? String) ?? fallback.bubbleThemColor
    let wallpaperGradient = parseGradient(gradientStrings, fallback: fallback.wallpaperGradient)
    let wallpaperPatternGradient = parseGradient(
      patternGradientStrings, fallback: fallback.wallpaperPatternGradient)
    let bubbleMeGradient = parseGradient(meGradientStrings, fallback: fallback.bubbleMeGradient)
    let bubbleThemGradient = parseGradient(
      themGradientStrings,
      fallback: [bubbleThemColor, bubbleThemColor]
    )
    let textColorMe = parseColor(raw["textColorMe"] as? String) ?? fallback.textColorMe
    let textColorThem = parseColor(raw["textColorThem"] as? String) ?? fallback.textColorThem
    let isDark = isDarkColor(wallpaperGradient.first ?? fallback.wallpaperGradient.first ?? .black)
    let dayPlateBase = resolvedDayPlateBase(
      bubbleThemColor: bubbleThemColor,
      wallpaperGradient: wallpaperGradient,
      isDark: isDark
    )
    let accent =
      parseColor(raw["accent"] as? String)
      ?? parseColor(raw["accentColor"] as? String)
      ?? fallback.accent
    let messageCornerRadius = parseMessageCornerRadiusPoints(
      raw["messageCornerRadius"],
      fallback: fallback.messageCornerRadius
    )
    let messageTailCurvature = CGFloat(
      max(
        0.0,
        min(
          1.0,
          (raw["messageTailCurvature"] as? NSNumber)?.doubleValue
            ?? raw["messageTailCurvature"] as? Double
            ?? Double(fallback.messageTailCurvature)
        )
      )
    )
    let wallpaperScrollGradient: [UIColor] = {
      guard let strings = raw["wallpaperScrollGradient"] as? [String] else { return [] }
      return strings.compactMap(parseColor)
    }()
    return ChatListAppearance(
      backgroundMode: mode,
      wallpaperGradient: wallpaperGradient,
      wallpaperOpacity: CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0),
      wallpaperPatternGradient: wallpaperPatternGradient,
      wallpaperPatternLocations: parseNumberArray(raw["wallpaperPatternLocations"]),
      wallpaperPatternOpacity: CGFloat(
        (raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? 0.0),
      wallpaperMaskKey: normalizedString(raw["wallpaperMaskKey"]),
      bubbleMeGradient: bubbleMeGradient,
      bubbleThemGradient: bubbleThemGradient,
      bubbleThemColor: bubbleThemColor,
      textColorMe: textColorMe,
      textColorThem: textColorThem,
      timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? fallback.timeColorMe,
      timeColorThem: parseColor(raw["timeColorThem"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.62 : 0.56),
      dayTextColor: parseColor(raw["dayTextColor"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
      dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String)
        ?? colorWithAlpha(dayPlateBase, isDark ? 0.84 : 0.76),
      dayBorderColor: parseColor(raw["dayBorderColor"] as? String)
        ?? colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
      insertionAnimationMode: (raw["insertionAnimationMode"] as? NSNumber)?.intValue
        ?? fallback.insertionAnimationMode,
      accent: accent,
      messageCornerRadius: messageCornerRadius,
      messageTailCurvature: messageTailCurvature,
      wallpaperScrollGradient: wallpaperScrollGradient
    )
  }

  /// Map a hex-string `ChatAppearanceDraft` into the runtime `UIColor` model.
  /// Applies the canonical corner mapping and carries accent + scroll gradient.
  static func from(draft: ChatAppearanceDraft) -> ChatListAppearance {
    from(draft: draft, systemStyle: resolvedSystemStyle())
  }

  /// `systemStyle` resolves `mode == "system"`. It used to resolve to dark unconditionally,
  /// which is why a light-mode user saw a dark chat: "system" is the default mode.
  static func from(
    draft: ChatAppearanceDraft, systemStyle: UIUserInterfaceStyle
  ) -> ChatListAppearance {
    let modeLower = draft.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let isDark: Bool = {
      switch modeLower {
      case "light": return false
      case "dark": return true
      default: return systemStyle != .light
      }
    }()
    let fallback = plate(themeId: draft.themeId, isDark: isDark)

    // Seed from a native preset when themeId is set; draft fields then override.
    var base = fallback
    if let themeId = draft.themeId,
      let seeded = nativePresetAppearance(
        from: [
          "nativeThemeId": themeId,
          "nativeThemeIsDark": isDark,
          "backgroundMode": draft.wallpaperKind == "custom" ? "gradient" : "gradient",
          "wallpaperOpacity": 1.0,
          "insertionAnimationMode": draft.animationsEnabled ? 2 : 0,
        ],
        fallback: fallback
      )
    {
      base = seeded
    }

    let isThemePlate = draft.themeId != nil && draft.wallpaperKind != "custom"

    let wallpaperGradient: [UIColor] = {
      if isThemePlate {
        return base.wallpaperGradient
      }
      return parseGradient(
        draft.wallpaperGradient,
        fallback: base.wallpaperGradient
      )
    }()
    let wallpaperScrollGradient = draft.wallpaperScrollGradient.compactMap(parseColor)
    let bubbleMeGradient: [UIColor] = {
      if isThemePlate {
        return base.bubbleMeGradient
      }
      return parseGradient(
        draft.bubbleMeGradient,
        fallback: base.bubbleMeGradient
      )
    }()
    let bubbleThemGradient: [UIColor] = {
      if isThemePlate {
        return base.bubbleThemGradient
      }
      return parseGradient(
        draft.bubbleThemGradient,
        fallback: base.bubbleThemGradient
      )
    }()
    let bubbleThemColor = bubbleThemGradient.first ?? base.bubbleThemColor
    let accent: UIColor = {
      if isThemePlate {
        return base.accent
      }
      return parseColor(draft.accent) ?? base.accent
    }()
    let messageCornerRadius = ChatAppearanceDraft.messageCornerRadiusPoints(
      normalized: draft.messageCornerRadius
    )
    let messageTailCurvature = CGFloat(
      max(
        0.0,
        min(
          1.0,
          draft.messageTailCurvature
            ?? Double(ChatAppearanceDraft.defaultMessageTailCurvature)
        )
      )
    )

    let backgroundMode: String = {
      switch draft.wallpaperKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "solid", "gradient", "builtin", "custom":
        return "gradient"
      default:
        return base.backgroundMode
      }
    }()

    let maskKey = draft.wallpaperPatternMaskKey ?? base.wallpaperMaskKey
    // Negative means the draft never set one — take the plate's, so the pattern follows
    // the theme instead of being pinned to whatever it was when the draft was seeded.
    let patternOpacity =
      draft.wallpaperPatternOpacity < 0
      ? base.wallpaperPatternOpacity : CGFloat(draft.wallpaperPatternOpacity)
    let textColorMe = base.textColorMe
    let textColorThem = base.textColorThem
    let dayPlateBase = resolvedDayPlateBase(
      bubbleThemColor: bubbleThemColor,
      wallpaperGradient: wallpaperGradient,
      isDark: isDark
    )

    return ChatListAppearance(
      backgroundMode: backgroundMode,
      wallpaperGradient: wallpaperGradient,
      wallpaperOpacity: base.wallpaperOpacity,
      wallpaperPatternGradient: base.wallpaperPatternGradient,
      wallpaperPatternLocations: base.wallpaperPatternLocations,
      wallpaperPatternOpacity: patternOpacity,
      wallpaperMaskKey: maskKey,
      bubbleMeGradient: bubbleMeGradient,
      bubbleThemGradient: bubbleThemGradient,
      bubbleThemColor: bubbleThemColor,
      textColorMe: textColorMe,
      textColorThem: textColorThem,
      timeColorMe: colorWithAlpha(textColorMe, isDark ? 0.68 : 0.56),
      timeColorThem: colorWithAlpha(textColorThem, isDark ? 0.52 : 0.48),
      dayTextColor: colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
      dayBackgroundColor: colorWithAlpha(dayPlateBase, isDark ? 0.84 : 0.76),
      dayBorderColor: colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
      insertionAnimationMode: draft.animationsEnabled ? 2 : 0,
      accent: accent,
      messageCornerRadius: messageCornerRadius,
      messageTailCurvature: messageTailCurvature,
      wallpaperScrollGradient: wallpaperScrollGradient
    )
  }

  var visualKey: String {
    let wallpaperKey = wallpaperGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternKey = wallpaperPatternGradient.map(colorKey).joined(separator: ",")
    let wallpaperPatternLocationsKey =
      wallpaperPatternLocations?.map { String(format: "%.4f", $0.doubleValue) }.joined(
        separator: ",")
      ?? ""
    let scrollKey = wallpaperScrollGradient.map(colorKey).joined(separator: ",")
    let meKey = bubbleMeGradient.map(colorKey).joined(separator: ",")
    let themKey = bubbleThemGradient.map(colorKey).joined(separator: ",")
    return [
      backgroundMode,
      String(format: "%.4f", wallpaperOpacity),
      wallpaperKey,
      scrollKey,
      wallpaperPatternKey,
      wallpaperPatternLocationsKey,
      String(format: "%.4f", wallpaperPatternOpacity),
      wallpaperMaskKey ?? "",
      meKey,
      themKey,
      colorKey(bubbleThemColor),
      colorKey(textColorMe),
      colorKey(textColorThem),
      colorKey(timeColorMe),
      colorKey(timeColorThem),
      colorKey(dayTextColor),
      colorKey(dayBackgroundColor),
      colorKey(dayBorderColor),
      colorKey(accent),
      String(format: "%.4f", messageCornerRadius),
      String(format: "%.4f", messageTailCurvature),
    ].joined(separator: "|")
  }

  /// Derives whether this appearance is "dark" by inspecting
  /// the luminance of the primary wallpaper gradient colour.
  var isDark: Bool {
    guard let firstColor = wallpaperGradient.first else { return true }
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    if firstColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
      let luminance = 0.299 * r + 0.587 * g + 0.114 * b
      return luminance < 0.5
    }
    return true
  }

  var hasPatternWallpaper: Bool {
    backgroundMode != "transparent"
      && wallpaperPatternGradient.count >= 2
      && wallpaperPatternOpacity > 0.001
      && (wallpaperMaskKey?.isEmpty == false)
  }

  var wallpaperAnchorColor: UIColor {
    let wallFirst = wallpaperBase
    let wallLast = wallpaperGradient.last ?? wallFirst
    return blendColor(wallFirst, with: wallLast, amount: 0.42)
  }

  var incomingBasePlateColor: UIColor {
    blendColor(
      bubbleThemGradient.first ?? bubbleThemColor,
      with: bubbleThemGradient.last ?? bubbleThemColor,
      amount: 0.5
    )
  }

  var outgoingBasePlateColor: UIColor {
    blendColor(
      bubbleMeGradient.first ?? bubbleThemColor,
      with: bubbleMeGradient.last ?? bubbleThemColor,
      amount: 0.5
    )
  }

  /// Tall-bubble expand/collapse chevron — muted neutral, never theme-accented.
  /// Slight luminance shift for plate contrast only (me vs them), not a colored icon.
  func tallToggleColor(isMe: Bool) -> UIColor {
    if isDark {
      // Soft light gray on dark plates; a touch dimmer on colored me gradients.
      return UIColor(white: isMe ? 0.78 : 0.70, alpha: 0.82)
    }
    // Soft dark gray on light plates.
    return UIColor(white: isMe ? 0.38 : 0.46, alpha: 0.72)
  }

  var incomingWallpaperSampleOpacity: CGFloat {
    guard backgroundMode != "transparent" else { return 0.0 }
    // Keep wallpaper bleed very low for them plates so multi-hue pattern
    // masks never show through as different per-cell colors.
    if hasPatternWallpaper {
      return isDark ? 0.03 : 0.018
    }
    return isDark ? 0.02 : 0.015
  }

  var outgoingWallpaperSampleOpacity: CGFloat {
    guard backgroundMode != "transparent" else { return 0.0 }
    if hasPatternWallpaper {
      return isDark ? 0.045 : 0.03
    }
    return isDark ? 0.025 : 0.018
  }

  var incomingPlateFillOpacity: CGFloat {
    if hasPatternWallpaper {
      return isDark ? 0.985 : 0.99
    }
    if backgroundMode != "transparent" {
      return isDark ? 0.99 : 0.985
    }
    return isDark ? 0.92 : 0.96
  }

  var outgoingPlateFillOpacity: CGFloat {
    // Me bubbles paint via shared gradient; underfill stays transparent so the
    // gradient is not buried under an opaque plate (fillLayer sits above gradient).
    return 0.0
  }

  /// Fixed wallpaper base tint for bubble plates (wallpaper gradient only).
  /// Never samples the multi-hue pattern gradient by cell Y — that produced
  /// rainbow them/me cells (purple, teal, coral per row). Pattern stays on the
  /// wallpaper backdrop; bubbles use one shared theme plate.
  private var fixedWallpaperPlateTint: UIColor {
    blendColor(
      wallpaperAnchorColor,
      with: isDark ? UIColor.black : UIColor.white,
      amount: isDark ? 0.52 : 0.28
    )
  }

  /// Telegram-style bubble plates:
  /// - them: near-black/gray, same for every cell, tiny fixed wallpaper anchor
  /// - me: stable theme mid-tone underfill (shared list-space gradient paints on top)
  /// `sampleRect` / `containerSize` are kept for API compatibility with callers;
  /// they intentionally do not change the plate hue.
  func wallpaperPlateColor(
    isMe: Bool,
    sampleRect: CGRect,
    containerSize: CGSize
  ) -> UIColor {
    let baseColor = isMe ? outgoingBasePlateColor : incomingBasePlateColor
    guard backgroundMode != "transparent" else {
      return baseColor
    }

    let fixedTint = fixedWallpaperPlateTint
    if isMe {
      // Mild fixed tint only — continuous hue comes from the shared me gradient.
      let tinted = blendColor(
        baseColor,
        with: fixedTint,
        amount: isDark ? 0.08 : 0.05
      )
      return blendColor(
        tinted,
        with: isDark ? UIColor.black : UIColor.white,
        amount: isDark ? 0.04 : 0.06
      )
    }

    // Them: near-black plate, shared across the whole list (no per-cell color plate).
    let darkerIncomingReference = blendColor(
      bubbleThemGradient.first ?? bubbleThemColor,
      with: bubbleThemGradient.last ?? bubbleThemColor,
      amount: 0.78
    )
    let isolatedIncomingBase = blendColor(
      baseColor,
      with: darkerIncomingReference,
      amount: 0.62
    )
    if !isDark {
      let softTint = blendColor(fixedTint, with: UIColor.white, amount: 0.70)
      let tinted = blendColor(isolatedIncomingBase, with: softTint, amount: 0.06)
      return blendColor(tinted, with: UIColor.white, amount: 0.10)
    }
    let tinted = blendColor(
      isolatedIncomingBase,
      with: fixedTint,
      amount: 0.08
    )
    return blendColor(
      tinted,
      with: UIColor.black,
      amount: 0.12
    )
  }

  func agentWallpaperPlateColor(
    isMe: Bool,
    sampleRect: CGRect,
    containerSize: CGSize,
    accent: UIColor?
  ) -> UIColor {
    let baseColor = wallpaperPlateColor(
      isMe: isMe,
      sampleRect: sampleRect,
      containerSize: containerSize
    )
    guard backgroundMode != "transparent" else {
      return baseColor
    }

    let paletteAccent = blendColor(
      bubbleMeGradient.first ?? baseColor,
      with: bubbleMeGradient.last ?? baseColor,
      amount: 0.46
    )
    let agentAccent = accent ?? paletteAccent
    // Light accent wash only — keep them near the stable plate, not a second rainbow.
    let accentAmount: CGFloat = isMe ? (isDark ? 0.12 : 0.08) : (isDark ? 0.08 : 0.04)
    let balanced = blendColor(baseColor, with: agentAccent, amount: accentAmount)
    return blendColor(
      balanced,
      with: isDark ? UIColor.black : UIColor.white,
      amount: isMe ? (isDark ? 0.04 : 0.08) : (isDark ? 0.10 : 0.12)
    )
  }

  /// Maps one shared diagonal theme gradient into a bubble layer's unit space.
  ///
  /// Telegram free-theme behavior: adjacent outgoing bubbles are windows into the
  /// **same** continuous ramp (not a different solid plate per cell). The ramp is
  /// sized to a fixed visual period (~0.9–1.2× screen) so color shift is visible
  /// without stretching the full multi-stop palette across a single tall cell.
  ///
  /// `layerBounds` is the gradient layer frame in bubble-local coords (may include
  /// tail paint overhang wider than the bubble bounds).
  func sharedBubbleGradientUnitPoints(
    sampleRectInContainer: CGRect,
    containerSize: CGSize,
    layerBounds: CGRect
  ) -> (start: CGPoint, end: CGPoint)? {
    guard sampleRectInContainer.width > 1.0,
      sampleRectInContainer.height > 1.0,
      containerSize.width > 1.0,
      containerSize.height > 1.0,
      layerBounds.width > 1.0,
      layerBounds.height > 1.0
    else {
      return nil
    }

    // Vertical period of the me gradient in list coordinates. Shorter than a very
    // long thread so each bubble still shows a readable slice of the theme colors.
    let verticalSpan = max(520.0, min(containerSize.height * 1.05, 780.0))
    let horizontalSpan = max(containerSize.width * 1.05, 280.0)

    func unitPoint(forContainerPoint point: CGPoint) -> CGPoint {
      let bubbleLocalX = point.x - sampleRectInContainer.minX
      let bubbleLocalY = point.y - sampleRectInContainer.minY
      let layerLocalX = bubbleLocalX - layerBounds.minX
      let layerLocalY = bubbleLocalY - layerBounds.minY
      return CGPoint(
        x: layerLocalX / layerBounds.width,
        y: layerLocalY / layerBounds.height
      )
    }

    // Continuous diagonal across list space: (0,0) → (spanX, spanY).
    // Bubbles only differ by which slice they open onto — same palette for all.
    return (
      unitPoint(forContainerPoint: .zero),
      unitPoint(forContainerPoint: CGPoint(x: horizontalSpan, y: verticalSpan))
    )
  }
}

private struct NativeThemeVariant {
  let backgroundGradient: [String]
  let bubbleMe: String
  let bubbleMeGradient: [String]
  let bubbleThem: String
  let bubbleThemGradient: [String]
  let patternGradientColors: [String]
  let patternGradientLocations: [Double]
  let patternOpacity: Double
  let textColorMe: String
  let textColorThem: String
}

private struct NativeThemePreset {
  let id: String
  let maskedImage: String?
  let light: NativeThemeVariant
  let dark: NativeThemeVariant
}

private func nativePresetAppearance(
  from raw: [String: Any],
  fallback: ChatListAppearance
) -> ChatListAppearance? {
  guard
    let themeId = normalizedString(raw["nativeThemeId"]),
    let preset = nativePreset(for: themeId)
  else {
    return nil
  }
  let isDark = parseBool(raw["nativeThemeIsDark"]) ?? true
  let mode = (raw["backgroundMode"] as? String) ?? fallback.backgroundMode
  let wallpaperOpacity = CGFloat((raw["wallpaperOpacity"] as? NSNumber)?.doubleValue ?? 1.0)
  let insertionAnimationMode =
    (raw["insertionAnimationMode"] as? NSNumber)?.intValue ?? fallback.insertionAnimationMode

  let variant = isDark ? preset.dark : preset.light

  let wallpaperGradient = parseGradient(
    (raw["wallpaperGradient"] as? [String]) ?? variant.backgroundGradient,
    fallback: fallback.wallpaperGradient)
  let patternGradient = parseGradient(
    (raw["wallpaperPatternGradient"] as? [String]) ?? variant.patternGradientColors,
    fallback: [])
  let rawMeStops = raw["bubbleMeGradient"] as? [String]
  let meStops: [String] = {
    guard let rawMeStops, rawMeStops.count >= 2 else { return variant.bubbleMeGradient }
    if isLegacyFactoryOutgoingPalette(rawMeStops) { return variant.bubbleMeGradient }
    return rawMeStops
  }()
  let bubbleMeGradient = parseGradient(
    meStops,
    fallback: fallback.bubbleMeGradient)
  let rawThemStops = raw["bubbleThemGradient"] as? [String]
  let rawThemColor = normalizedString(raw["bubbleThemColor"])
  let hasCustomThemStops =
    rawThemStops.map { $0.count >= 2 && !isLegacyFactoryIncomingPalette($0) } ?? false
  let hasCustomThemColor =
    rawThemColor.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "#252936" }
    ?? false
  let incomingTint = bubbleMeGradient.first ?? parseColor(variant.bubbleMe) ?? fallback.accent
  let bubbleThemGradient: [UIColor] = {
    let factoryFallback = variant.bubbleThemGradient.compactMap(parseColor)
    if hasCustomThemStops {
      return parseGradient(rawThemStops, fallback: factoryFallback)
    }
    if hasCustomThemColor, let customColor = parseColor(rawThemColor) {
      return [customColor, blendColor(customColor, with: .black, amount: 0.16)]
    }
    if isDark {
      let neutral = UIColor(white: 0.12, alpha: 1.0)
      let tinted = blendColor(neutral, with: incomingTint, amount: 0.14)
      return [tinted, blendColor(tinted, with: .black, amount: 0.18)]
    }
    return factoryFallback
  }()
  let rawBubbleThemColor =
    parseColor(rawThemColor)
    ?? parseColor(variant.bubbleThemGradient.first)
    ?? parseColor(variant.bubbleThem)
    ?? fallback.bubbleThemColor
  let resolvedBubbleThemColor = bubbleThemGradient.first ?? rawBubbleThemColor
  let textColorMe = parseColor(raw["textColorMe"] as? String) ?? parseColor(variant.textColorMe)
    ?? fallback.textColorMe
  let textColorThem =
    parseColor(raw["textColorThem"] as? String) ?? parseColor(variant.textColorThem)
    ?? fallback.textColorThem
  let dayPlateBase = resolvedDayPlateBase(
    bubbleThemColor: resolvedBubbleThemColor,
    wallpaperGradient: wallpaperGradient,
    isDark: isDark
  )
  let accent =
    parseColor(raw["accent"] as? String)
    ?? parseColor(raw["accentColor"] as? String)
    ?? parseColor(variant.bubbleMe)
    ?? fallback.accent
  let messageCornerRadius = parseMessageCornerRadiusPoints(
    raw["messageCornerRadius"],
    fallback: fallback.messageCornerRadius
  )
  let messageTailCurvature = CGFloat(
    max(
      0.0,
      min(
        1.0,
        (raw["messageTailCurvature"] as? NSNumber)?.doubleValue
          ?? raw["messageTailCurvature"] as? Double
          ?? Double(fallback.messageTailCurvature)
      )
    )
  )
  let wallpaperScrollGradient: [UIColor] = {
    guard let strings = raw["wallpaperScrollGradient"] as? [String] else { return [] }
    return strings.compactMap(parseColor)
  }()
  return ChatListAppearance(
    backgroundMode: mode,
    wallpaperGradient: wallpaperGradient,
    wallpaperOpacity: wallpaperOpacity,
    wallpaperPatternGradient: patternGradient,
    wallpaperPatternLocations: parseNumberArray(raw["wallpaperPatternLocations"])
      ?? variant.patternGradientLocations.map { NSNumber(value: $0) },
    wallpaperPatternOpacity: CGFloat(
      (raw["wallpaperPatternOpacity"] as? NSNumber)?.doubleValue ?? variant.patternOpacity),
    wallpaperMaskKey: normalizedString(raw["wallpaperMaskKey"]) ?? preset.maskedImage,
    bubbleMeGradient: bubbleMeGradient,
    bubbleThemGradient: bubbleThemGradient,
    bubbleThemColor: resolvedBubbleThemColor,
    textColorMe: textColorMe,
    textColorThem: textColorThem,
    timeColorMe: parseColor(raw["timeColorMe"] as? String) ?? colorWithAlpha(textColorMe, 0.72),
    timeColorThem: parseColor(raw["timeColorThem"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.62 : 0.56),
    dayTextColor: parseColor(raw["dayTextColor"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
    dayBackgroundColor: parseColor(raw["dayBackgroundColor"] as? String)
      ?? colorWithAlpha(dayPlateBase, isDark ? 0.84 : 0.76),
    dayBorderColor: parseColor(raw["dayBorderColor"] as? String)
      ?? colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
    insertionAnimationMode: insertionAnimationMode,
    accent: accent,
    messageCornerRadius: messageCornerRadius,
    messageTailCurvature: messageTailCurvature,
    wallpaperScrollGradient: wallpaperScrollGradient
  )
}

/// Old neon/complement outgoing pairs from before the Telegram-deeper plates.
private func isLegacyFactoryOutgoingPalette(_ stops: [String]) -> Bool {
  let key = stops.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
  let legacy: [[String]] = [
    ["#6E5BFF", "#14C8B8"], ["#8B7CFF", "#08C6B4"],
    ["#9C62F0", "#4B9BFF"], ["#7F5AF0", "#1E90FF"],
    ["#38C7A5", "#73C74B"], ["#08C6B4", "#28B463"],
    ["#5A6B8C", "#4A78C2"], ["#475569", "#3B82F6"],
    ["#F051B5", "#A851F0"], ["#D946EF", "#7F5AF0"],
    ["#F0830C", "#F0413A"], ["#FF8C00", "#E82A2A"],
    ["#5DB82E", "#2EB8A3"], ["#28B463", "#1DB8A6"],
  ]
  return legacy.contains { $0.map { $0.uppercased() } == key }
}

private func isLegacyFactoryIncomingPalette(_ stops: [String]) -> Bool {
  stops.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    == ["#252936", "#1A202C"]
}

private func chatAppearanceDraftPaletteIsSeeded(_ draft: ChatAppearanceDraft) -> Bool {
  func same(_ lhs: [String], _ rhs: [String]) -> Bool {
    lhs.map { $0.uppercased() } == rhs.map { $0.uppercased() }
  }
  for option in AppThemePlateOption.allCases {
    guard let preset = nativePreset(for: option.rawValue) else { continue }
    for variant in [preset.light, preset.dark] {
      if same(draft.wallpaperGradient, variant.backgroundGradient),
        same(draft.bubbleMeGradient, variant.bubbleMeGradient),
        same(draft.bubbleThemGradient, variant.bubbleThemGradient)
      {
        return true
      }
    }
  }
  return false
}

private func nativePreset(for id: String) -> NativeThemePreset? {
  switch id {
  case "glacier":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#F7FAFF", "#EEF7F8"],
        bubbleMe: "#3B8AE8",
        bubbleMeGradient: ["#4C9AF5", "#2D7AD4"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#A88FF5", "#5AD4C7", "#E89A89"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#05050B", "#05050B"],
        bubbleMe: "#3B8AE8",
        bubbleMeGradient: ["#4A96E8", "#2E78CC"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#7F5AF0", "#1DB8A6", "#D16F58"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "zen":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#F4F8FA", "#E9F0F5"],
        bubbleMe: "#2F7FE0",
        bubbleMeGradient: ["#3D8EEC", "#1E6EC8"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#7EB6FF", "#B084F5", "#FF8DA1"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#03070C", "#03070C"],
        bubbleMe: "#2F80ED",
        bubbleMeGradient: ["#3D8EE8", "#226EC8"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#2F80ED", "#8B4CF5", "#F0516A"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "ocean":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#EAF8D8", "#EAF8D8"],
        bubbleMe: "#2E9B6E",
        bubbleMeGradient: ["#36B07C", "#248A5E"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#75D4C3", "#95D475", "#F5DD6A"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#020806", "#020806"],
        bubbleMe: "#2C9A68",
        bubbleMeGradient: ["#32A872", "#24885A"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#1DB8A6", "#2EB872", "#F0DB35"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "obsidian":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#F6F6F4", "#ECEEF1"],
        bubbleMe: "#4A6FA0",
        bubbleMeGradient: ["#5A7FB0", "#3D5F90"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#B8C0D0", "#D0B8E6", "#A3C2F0"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#030304", "#050607"],
        bubbleMe: "#3D6EA8",
        bubbleMeGradient: ["#4A7EBA", "#325E94"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#64748B", "#A64DFF", "#4287F5"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "music":
    return NativeThemePreset(
      id: id,
      maskedImage: "music",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFF5FA", "#FFF0F1"],
        bubbleMe: "#C43B88",
        bubbleMeGradient: ["#D44A96", "#A83074"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#F59AE0", "#D09AF5", "#8EE3F5"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#070306", "#070306"],
        bubbleMe: "#C43B88",
        bubbleMeGradient: ["#D24A96", "#A83074"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#E84AA8", "#8B4CF5", "#1DB8A6"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "terracotta":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#FFF7F0", "#F5ECE5"],
        bubbleMe: "#C85A28",
        bubbleMeGradient: ["#D86A32", "#B44A1E"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#F5B97A", "#F5877A", "#F57AC0"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#060302", "#060302"],
        bubbleMe: "#C85A28",
        bubbleMeGradient: ["#D86A32", "#B04A20"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#FF9A3D", "#E82A2A", "#D946EF"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  case "leaf":
    return NativeThemePreset(
      id: id,
      maskedImage: "doodles",
      light: NativeThemeVariant(
        backgroundGradient: ["#EAF7CD", "#C8E8C5"],
        bubbleMe: "#3D9B40",
        bubbleMeGradient: ["#4CAF50", "#338A3A"],
        bubbleThem: "#FFFFFF",
        bubbleThemGradient: ["#FFFFFF", "#F6F8FC"],
        patternGradientColors: ["#A9D67A", "#7AE6D2", "#7AA3F5"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.080,
        textColorMe: "#FFFFFF",
        textColorThem: "#000000"
      ),
      dark: NativeThemeVariant(
        backgroundGradient: ["#030704", "#030704"],
        bubbleMe: "#3A9B4A",
        bubbleMeGradient: ["#3FAF55", "#2E8A42"],
        bubbleThem: "#252936",
        bubbleThemGradient: ["#252936", "#1A202C"],
        patternGradientColors: ["#28B463", "#1DB8A6", "#2F80ED"],
        patternGradientLocations: [0, 0.5, 1],
        patternOpacity: 0.17,
        textColorMe: "#FFFFFF",
        textColorThem: "#FFFFFF"
      )
    )
  default:
    return nil
  }
}

private func normalizedString(_ raw: Any?) -> String? {
  guard let value = raw as? String else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func parseBool(_ raw: Any?) -> Bool? {
  if let value = raw as? Bool {
    return value
  }
  if let value = raw as? NSNumber {
    return value.boolValue
  }
  if let text = raw as? String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["1", "true", "yes"].contains(normalized) {
      return true
    }
    if ["0", "false", "no"].contains(normalized) {
      return false
    }
  }
  return nil
}

private func parseNumberArray(_ raw: Any?) -> [NSNumber]? {
  if let array = raw as? [NSNumber] {
    return array
  }
  if let array = raw as? [Double] {
    return array.map { NSNumber(value: $0) }
  }
  if let array = raw as? [Int] {
    return array.map { NSNumber(value: $0) }
  }
  if let array = raw as? [String] {
    let parsed = array.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return parsed.count == array.count ? parsed.map { NSNumber(value: $0) } : nil
  }
  return nil
}

private func resolvedDayPlateBase(
  bubbleThemColor: UIColor,
  wallpaperGradient: [UIColor],
  isDark: Bool
) -> UIColor {
  let wallFirst = wallpaperGradient.first ?? bubbleThemColor
  let wallLast = wallpaperGradient.last ?? wallFirst
  let wallpaperAnchor = blendColor(wallFirst, with: wallLast, amount: 0.38)
  return blendColor(bubbleThemColor, with: wallpaperAnchor, amount: isDark ? 0.14 : 0.08)
}


private func blendColor(_ from: UIColor, with to: UIColor, amount: CGFloat) -> UIColor {
  let t = max(0.0, min(1.0, amount))
  var fr: CGFloat = 0
  var fg: CGFloat = 0
  var fb: CGFloat = 0
  var fa: CGFloat = 0
  var tr: CGFloat = 0
  var tg: CGFloat = 0
  var tb: CGFloat = 0
  var ta: CGFloat = 0

  guard from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
    to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
  else {
    return from
  }

  let inv = 1.0 - t
  return UIColor(
    red: (fr * inv) + (tr * t),
    green: (fg * inv) + (tg * t),
    blue: (fb * inv) + (tb * t),
    alpha: (fa * inv) + (ta * t)
  )
}

private func clampUnit(_ value: CGFloat) -> CGFloat {
  min(1.0, max(0.0, value))
}



private func isDarkColor(_ color: UIColor) -> Bool {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return true }
  let luminance = 0.299 * r + 0.587 * g + 0.114 * b
  return luminance < 0.5
}

/// The plate incoming text is actually drawn on.
///
/// Mirrors `ChatListAppearance.incomingBasePlateColor`, which cannot be used from `init`
/// because it is a computed property on the very value being built. `wallpaperPlateColor`
/// darkens this further for the them side, so judging contrast against this reference is
/// conservative in the right direction: the real plate is never lighter.
private func incomingPlateReference(gradient: [UIColor], base: UIColor) -> UIColor {
  blendColor(gradient.first ?? base, with: gradient.last ?? base, amount: 0.5)
}

/// WCAG AA for body text. Below this, ink on a plate stops being text and becomes texture.
private let minimumIncomingTextContrast: CGFloat = 4.5

/// Returns `ink` when it is legible on `plate`, otherwise the nearest legible replacement.
///
/// Only two candidates, deliberately: white and near-black. A theme's ink is a design
/// choice and is left alone whenever it clears the bar; when it does not, the answer that
/// preserves the theme's intent least badly is the one that maximises contrast, not a
/// nudged version of a colour that was already wrong.
private func readableForeground(_ ink: UIColor, on plate: UIColor) -> UIColor {
  guard contrastRatio(ink, plate) < minimumIncomingTextContrast else { return ink }
  let white = UIColor.white
  let nearBlack = UIColor(white: 0.08, alpha: 1.0)
  return contrastRatio(white, plate) >= contrastRatio(nearBlack, plate) ? white : nearBlack
}

/// `color`'s alpha carried onto `hue`'s RGB — for the timestamp and day-pill inks, which
/// are the primary ink at a designed opacity and must follow it when it is corrected.
private func retinted(_ color: UIColor, to hue: UIColor) -> UIColor {
  var sourceRed: CGFloat = 0
  var sourceGreen: CGFloat = 0
  var sourceBlue: CGFloat = 0
  var alpha: CGFloat = 1.0
  guard
    color.getRed(&sourceRed, green: &sourceGreen, blue: &sourceBlue, alpha: &alpha)
  else { return hue }
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var hueAlpha: CGFloat = 0
  guard hue.getRed(&r, green: &g, blue: &b, alpha: &hueAlpha) else { return hue }
  return UIColor(red: r, green: g, blue: b, alpha: alpha)
}

private func colorsEqual(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
  var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
  var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
  guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
    rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
  else { return false }
  return abs(lr - rr) < 0.001 && abs(lg - rg) < 0.001 && abs(lb - rb) < 0.001
    && abs(la - ra) < 0.001
}

private func contrastRatio(_ c1: UIColor, _ c2: UIColor) -> CGFloat {
  let l1 = relativeLuminance(c1)
  let l2 = relativeLuminance(c2)
  let hi = max(l1, l2)
  let lo = min(l1, l2)
  return (hi + 0.05) / (lo + 0.05)
}

private func relativeLuminance(_ color: UIColor) -> CGFloat {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.0 }

  func linear(_ value: CGFloat) -> CGFloat {
    if value <= 0.03928 { return value / 12.92 }
    return pow((value + 0.055) / 1.055, 2.4)
  }

  let lr = linear(r)
  let lg = linear(g)
  let lb = linear(b)
  return (0.2126 * lr) + (0.7152 * lg) + (0.0722 * lb)
}

private func colorWithAlpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var currentAlpha: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &currentAlpha) {
    return UIColor(red: r, green: g, blue: b, alpha: max(0.0, min(1.0, alpha)))
  }
  if let converted = color.cgColor.converted(
    to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
    let components = converted.components
  {
    if components.count >= 3 {
      let r = components[0]
      let g = components.count > 1 ? components[1] : components[0]
      let b = components.count > 2 ? components[2] : components[0]
      return UIColor(red: r, green: g, blue: b, alpha: max(0.0, min(1.0, alpha)))
    }
  }
  return color.withAlphaComponent(max(0.0, min(1.0, alpha)))
}

private func colorKey(_ color: UIColor) -> String {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
    return String(format: "%.4f,%.4f,%.4f,%.4f", r, g, b, a)
  }
  if let converted = color.cgColor.converted(
    to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
    let components = converted.components
  {
    let cr: CGFloat
    let cg: CGFloat
    let cb: CGFloat
    let ca: CGFloat
    if components.count >= 4 {
      cr = components[0]
      cg = components[1]
      cb = components[2]
      ca = components[3]
    } else if components.count == 2 {
      cr = components[0]
      cg = components[0]
      cb = components[0]
      ca = components[1]
    } else {
      cr = 0
      cg = 0
      cb = 0
      ca = 1
    }
    return String(format: "%.4f,%.4f,%.4f,%.4f", cr, cg, cb, ca)
  }
  return "0,0,0,0"
}

/// Parse corner radius from raw payload.
/// Values in 0…1 are treated as normalized; values > 1 as points (clamped 4…26).
private func parseMessageCornerRadiusPoints(_ raw: Any?, fallback: CGFloat) -> CGFloat {
  let value: Double?
  if let number = raw as? NSNumber {
    value = number.doubleValue
  } else if let double = raw as? Double {
    value = double
  } else if let int = raw as? Int {
    value = Double(int)
  } else if let text = raw as? String {
    value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
  } else {
    value = nil
  }
  guard let value else { return fallback }
  if value <= 1.0 {
    return ChatAppearanceDraft.messageCornerRadiusPoints(normalized: value)
  }
  return CGFloat(max(4.0, min(26.0, value)))
}

private func parseGradient(_ values: [String]?, fallback: [UIColor]) -> [UIColor] {
  guard let values else {
    return fallback
  }
  let colors = values.compactMap(parseColor)
  return colors.count >= 2 ? colors : fallback
}

private func parseGradient(_ values: [String], fallback: [UIColor]) -> [UIColor] {
  let colors = values.compactMap(parseColor)
  return colors.count >= 2 ? colors : fallback
}

private func parseColor(_ value: String?) -> UIColor? {
  guard let value else {
    return nil
  }
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
  if hex.hasPrefix("#") {
    hex.removeFirst()
  }
  if hex.count == 3 || hex.count == 4 {
    hex = hex.map { "\($0)\($0)" }.joined()
  }
  guard hex.count == 6 || hex.count == 8 else {
    return nil
  }

  var rgba: UInt64 = 0
  guard Scanner(string: hex).scanHexInt64(&rgba) else {
    return nil
  }

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
  guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close
  else {
    return nil
  }
  let args = value[value.index(after: open)..<close].split(separator: ",").map {
    $0.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard args.count == 3 || args.count == 4 else {
    return nil
  }

  guard
    let r = Double(args[0]),
    let g = Double(args[1]),
    let b = Double(args[2])
  else {
    return nil
  }
  let a = args.count == 4 ? (Double(args[3]) ?? 1.0) : 1.0
  return UIColor(
    red: CGFloat(max(0.0, min(255.0, r)) / 255.0),
    green: CGFloat(max(0.0, min(255.0, g)) / 255.0),
    blue: CGFloat(max(0.0, min(255.0, b)) / 255.0),
    alpha: CGFloat(max(0.0, min(1.0, a)))
  )
}

// MARK: - Appearance settings contract + live preview
//
// Production appearance model (persist/consume these fields). The Settings
// integrator embeds `ChatAppearanceLivePreviewView` (SwiftUI) or
// `ChatAppearanceLivePreview` (UIKit) and pushes a new `ChatAppearancePreviewSpec`
// whenever the user adjusts controls — the surface updates live from semantic
// tokens, not hard-coded theme colors.

/// Interface style preference for appearance settings (`mode` in the contract).
enum ChatAppearancePreviewMode: String, CaseIterable, Equatable {
  case system
  case light
  case dark

  /// Resolve against the current trait collection when mode is `.system`.
  func resolvedIsDark(traitCollection: UITraitCollection) -> Bool {
    switch self {
    case .light:
      return false
    case .dark:
      return true
    case .system:
      return traitCollection.userInterfaceStyle == .dark
    }
  }
}

/// Wallpaper storage kind (`wallpaper kind` in the contract).
enum ChatAppearanceWallpaperKind: String, CaseIterable, Equatable {
  /// Built-in pattern mask identifier (e.g. doodles, music).
  case builtin
  /// Single solid color (hex in `wallpaperValue`).
  case solid
  /// Theme / free gradient (optional comma-separated hex stops in `wallpaperValue`).
  case gradient
  /// Device-local custom image path (preview falls back to gradient; image stays local).
  case custom
}

/// Persisted appearance settings + live-preview input.
///
/// Contract fields: `mode`, `themeId`, wallpaper kind/value, accent, two-stop
/// bubble gradient, text scale, message corner scale, animations enabled.
struct ChatAppearancePreviewSpec: Equatable {
  var mode: ChatAppearancePreviewMode
  var themeId: String
  var wallpaperKind: ChatAppearanceWallpaperKind
  /// Builtin mask key, solid/custom hex or path, or comma-separated gradient stops.
  var wallpaperValue: String
  var accent: UIColor
  var bubbleGradientTop: UIColor
  var bubbleGradientBottom: UIColor
  /// 1.0 = default chat text; clamped ~0.85…1.35 when resolving tokens.
  var textScale: CGFloat
  /// 1.0 = default bubble corner; clamped ~0.6…1.4 when resolving tokens.
  var messageCornerScale: CGFloat
  var animationsEnabled: Bool

  static let `default` = ChatAppearancePreviewSpec(
    mode: .system,
    themeId: "glacier",
    wallpaperKind: .builtin,
    wallpaperValue: "doodles",
    accent: ChatListAppearance.brandAccentFallback,
    bubbleGradientTop: UIColor(red: 0.5451, green: 0.4863, blue: 1.0, alpha: 1.0),
    bubbleGradientBottom: UIColor(red: 0.0314, green: 0.7765, blue: 0.7059, alpha: 1.0),
    textScale: 1.0,
    messageCornerScale: 1.0,
    animationsEnabled: true
  )

  /// Build from a portable dictionary (HTTP / UserDefaults / Settings draft).
  static func from(raw: [String: Any]?) -> ChatAppearancePreviewSpec {
    guard let raw else { return .default }
    let base = ChatAppearancePreviewSpec.default

    let modeRaw =
      (raw["mode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      ?? base.mode.rawValue
    let mode = ChatAppearancePreviewMode(rawValue: modeRaw) ?? base.mode

    let themeId =
      normalizedString(raw["themeId"])
      ?? normalizedString(raw["nativeThemeId"])
      ?? base.themeId

    let kindRaw =
      (raw["wallpaperKind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      ?? base.wallpaperKind.rawValue
    let wallpaperKind = ChatAppearanceWallpaperKind(rawValue: kindRaw) ?? base.wallpaperKind
    let wallpaperValue =
      normalizedString(raw["wallpaperValue"])
      ?? normalizedString(raw["wallpaperMaskKey"])
      ?? base.wallpaperValue

    let accent =
      parseColor(raw["accentColor"] as? String)
      ?? parseColor(raw["accent"] as? String)
      ?? base.accent

    let gradientStops: [UIColor] = {
      if let strings = raw["bubbleGradient"] as? [String] {
        let parsed = strings.compactMap(parseColor)
        if parsed.count >= 2 { return Array(parsed.prefix(2)) }
      }
      if let top = parseColor(raw["bubbleGradientTop"] as? String),
        let bottom = parseColor(raw["bubbleGradientBottom"] as? String)
      {
        return [top, bottom]
      }
      if let me = raw["bubbleMeGradient"] as? [String] {
        let parsed = me.compactMap(parseColor)
        if parsed.count >= 2 { return Array(parsed.prefix(2)) }
      }
      return [base.bubbleGradientTop, base.bubbleGradientBottom]
    }()

    let textScale = CGFloat(
      (raw["textScale"] as? NSNumber)?.doubleValue
        ?? (raw["textScale"] as? Double)
        ?? Double(base.textScale)
    )
    let messageCornerScale = CGFloat(
      (raw["messageCornerScale"] as? NSNumber)?.doubleValue
        ?? (raw["messageCornerScale"] as? Double)
        ?? Double(base.messageCornerScale)
    )
    let animationsEnabled =
      parseBool(raw["animationsEnabled"])
      ?? parseBool(raw["animations"])
      ?? base.animationsEnabled

    return ChatAppearancePreviewSpec(
      mode: mode,
      themeId: themeId,
      wallpaperKind: wallpaperKind,
      wallpaperValue: wallpaperValue,
      accent: accent,
      bubbleGradientTop: gradientStops[0],
      bubbleGradientBottom: gradientStops.count > 1 ? gradientStops[1] : gradientStops[0],
      textScale: textScale,
      messageCornerScale: messageCornerScale,
      animationsEnabled: animationsEnabled
    )
  }

  /// Portable dictionary for persistence / Settings wiring.
  var asDictionary: [String: Any] {
    [
      "mode": mode.rawValue,
      "themeId": themeId,
      "wallpaperKind": wallpaperKind.rawValue,
      "wallpaperValue": wallpaperValue,
      "accentColor": chatAppearanceColorHex(accent),
      "bubbleGradient": [
        chatAppearanceColorHex(bubbleGradientTop),
        chatAppearanceColorHex(bubbleGradientBottom),
      ],
      "textScale": Double(textScale),
      "messageCornerScale": Double(messageCornerScale),
      "animationsEnabled": animationsEnabled,
    ]
  }

  static func == (lhs: ChatAppearancePreviewSpec, rhs: ChatAppearancePreviewSpec) -> Bool {
    lhs.mode == rhs.mode
      && lhs.themeId == rhs.themeId
      && lhs.wallpaperKind == rhs.wallpaperKind
      && lhs.wallpaperValue == rhs.wallpaperValue
      && colorKey(lhs.accent) == colorKey(rhs.accent)
      && colorKey(lhs.bubbleGradientTop) == colorKey(rhs.bubbleGradientTop)
      && colorKey(lhs.bubbleGradientBottom) == colorKey(rhs.bubbleGradientBottom)
      && abs(lhs.textScale - rhs.textScale) < 0.0001
      && abs(lhs.messageCornerScale - rhs.messageCornerScale) < 0.0001
      && lhs.animationsEnabled == rhs.animationsEnabled
  }
}

/// Semantic tokens views should consume instead of hard-coded theme colors.
struct ChatAppearanceSemanticTokens: Equatable {
  let isDark: Bool
  let wallpaperGradient: [UIColor]
  let wallpaperPatternGradient: [UIColor]
  let wallpaperPatternLocations: [NSNumber]?
  let wallpaperPatternOpacity: CGFloat
  let wallpaperMaskKey: String?
  let backgroundMode: String
  let bubbleMeGradient: [UIColor]
  let bubbleThemGradient: [UIColor]
  let bubbleThemColor: UIColor
  let textColorMe: UIColor
  let textColorThem: UIColor
  let timeColorMe: UIColor
  let timeColorThem: UIColor
  let accent: UIColor
  let textScale: CGFloat
  let messageCornerRadius: CGFloat
  let animationsEnabled: Bool
  let insertionAnimationMode: Int

  /// Resolve tokens from a settings spec. Does not touch the chat engine.
  static func resolve(
    from spec: ChatAppearancePreviewSpec,
    traitCollection: UITraitCollection = UITraitCollection.current
  ) -> ChatAppearanceSemanticTokens {
    let isDark = spec.mode.resolvedIsDark(traitCollection: traitCollection)
    let base = ChatListAppearance.from(raw: [
      "nativeThemeId": spec.themeId,
      "nativeThemeIsDark": isDark,
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "insertionAnimationMode": spec.animationsEnabled ? 2 : 0,
    ])

    let bubbleMe = [spec.bubbleGradientTop, spec.bubbleGradientBottom]
    let textScale = min(1.35, max(0.85, spec.textScale))
    let cornerScale = min(1.4, max(0.6, spec.messageCornerScale))
    let baseCorner: CGFloat = 16.0
    let messageCornerRadius = baseCorner * cornerScale

    var wallpaperGradient = base.wallpaperGradient
    var wallpaperMaskKey = base.wallpaperMaskKey
    var wallpaperPatternGradient = base.wallpaperPatternGradient
    var wallpaperPatternOpacity = base.wallpaperPatternOpacity
    var wallpaperPatternLocations = base.wallpaperPatternLocations
    var backgroundMode = base.backgroundMode

    switch spec.wallpaperKind {
    case .builtin:
      let key = spec.wallpaperValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !key.isEmpty {
        wallpaperMaskKey = key
      }
      backgroundMode = "gradient"
    case .solid:
      if let solid = parseColor(spec.wallpaperValue) {
        wallpaperGradient = [solid, solid]
        wallpaperMaskKey = nil
        wallpaperPatternOpacity = 0
        wallpaperPatternGradient = []
        backgroundMode = "gradient"
      }
    case .gradient:
      let stops = spec.wallpaperValue
        .split(separator: ",")
        .compactMap { parseColor(String($0)) }
      if stops.count >= 2 {
        wallpaperGradient = stops
      }
      wallpaperMaskKey = nil
      wallpaperPatternOpacity = 0
      wallpaperPatternGradient = []
      backgroundMode = "gradient"
    case .custom:
      // Custom images remain local; preview keeps theme gradient as stand-in.
      backgroundMode = base.backgroundMode
    }

    return ChatAppearanceSemanticTokens(
      isDark: isDark,
      wallpaperGradient: wallpaperGradient,
      wallpaperPatternGradient: wallpaperPatternGradient,
      wallpaperPatternLocations: wallpaperPatternLocations,
      wallpaperPatternOpacity: wallpaperPatternOpacity,
      wallpaperMaskKey: wallpaperMaskKey,
      backgroundMode: backgroundMode,
      bubbleMeGradient: bubbleMe,
      bubbleThemGradient: base.bubbleThemGradient,
      bubbleThemColor: base.bubbleThemColor,
      textColorMe: base.textColorMe,
      textColorThem: base.textColorThem,
      timeColorMe: base.timeColorMe,
      timeColorThem: base.timeColorThem,
      accent: spec.accent,
      textScale: textScale,
      messageCornerRadius: messageCornerRadius,
      animationsEnabled: spec.animationsEnabled,
      insertionAnimationMode: spec.animationsEnabled ? 2 : 0
    )
  }

  /// Project tokens into a `ChatListAppearance` for chat surfaces / previews.
  var asChatListAppearance: ChatListAppearance {
    ChatListAppearance(
      backgroundMode: backgroundMode,
      wallpaperGradient: wallpaperGradient,
      wallpaperOpacity: 1.0,
      wallpaperPatternGradient: wallpaperPatternGradient,
      wallpaperPatternLocations: wallpaperPatternLocations,
      wallpaperPatternOpacity: wallpaperPatternOpacity,
      wallpaperMaskKey: wallpaperMaskKey,
      bubbleMeGradient: bubbleMeGradient,
      bubbleThemGradient: bubbleThemGradient,
      bubbleThemColor: bubbleThemColor,
      textColorMe: textColorMe,
      textColorThem: textColorThem,
      timeColorMe: timeColorMe,
      timeColorThem: timeColorThem,
      dayTextColor: colorWithAlpha(textColorThem, isDark ? 0.90 : 0.84),
      dayBackgroundColor: colorWithAlpha(bubbleThemColor, isDark ? 0.84 : 0.76),
      dayBorderColor: colorWithAlpha(textColorThem, isDark ? 0.08 : 0.10),
      insertionAnimationMode: insertionAnimationMode,
      accent: accent,
      messageCornerRadius: messageCornerRadius,
      wallpaperScrollGradient: []
    )
  }

  static func == (lhs: ChatAppearanceSemanticTokens, rhs: ChatAppearanceSemanticTokens) -> Bool {
    lhs.isDark == rhs.isDark
      && lhs.backgroundMode == rhs.backgroundMode
      && lhs.wallpaperMaskKey == rhs.wallpaperMaskKey
      && abs(lhs.wallpaperPatternOpacity - rhs.wallpaperPatternOpacity) < 0.0001
      && abs(lhs.textScale - rhs.textScale) < 0.0001
      && abs(lhs.messageCornerRadius - rhs.messageCornerRadius) < 0.0001
      && lhs.animationsEnabled == rhs.animationsEnabled
      && lhs.insertionAnimationMode == rhs.insertionAnimationMode
      && lhs.wallpaperGradient.map(colorKey) == rhs.wallpaperGradient.map(colorKey)
      && lhs.wallpaperPatternGradient.map(colorKey) == rhs.wallpaperPatternGradient.map(colorKey)
      && lhs.bubbleMeGradient.map(colorKey) == rhs.bubbleMeGradient.map(colorKey)
      && lhs.bubbleThemGradient.map(colorKey) == rhs.bubbleThemGradient.map(colorKey)
      && colorKey(lhs.bubbleThemColor) == colorKey(rhs.bubbleThemColor)
      && colorKey(lhs.textColorMe) == colorKey(rhs.textColorMe)
      && colorKey(lhs.textColorThem) == colorKey(rhs.textColorThem)
      && colorKey(lhs.accent) == colorKey(rhs.accent)
  }
}

extension ChatListAppearance {
  /// Resolve chat appearance from a settings preview spec (additive helper).
  static func from(
    previewSpec: ChatAppearancePreviewSpec,
    traitCollection: UITraitCollection = .current
  ) -> ChatListAppearance {
    ChatAppearanceSemanticTokens.resolve(from: previewSpec, traitCollection: traitCollection)
      .asChatListAppearance
  }
}

// MARK: Live preview surface

/// UIKit live chat preview. Push a new `ChatAppearancePreviewSpec` via `apply`
/// as the user adjusts Settings controls — wallpaper + mock bubbles update from
/// semantic tokens.
final class ChatAppearanceLivePreview: UIView {
  private(set) var spec: ChatAppearancePreviewSpec
  private var tokens: ChatAppearanceSemanticTokens

  private let wallpaperLayer = CAGradientLayer()
  private let patternLayer = CAGradientLayer()
  private let patternMaskLayer = CALayer()
  private let chatContainer = UIView()
  private let stack = UIStackView()
  private var bubbleRows: [ChatAppearancePreviewBubbleRow] = []

  private let mockMessages: [(text: String, isMe: Bool)] = [
    ("Your appearance updates live.", false),
    ("Wallpaper, bubbles, and type scale.", true),
    ("Looks good — ship it.", false),
  ]

  /// Preferred height when embedded unconstrained (width is flexible).
  var preferredHeight: CGFloat = 220 {
    didSet { invalidateIntrinsicContentSize() }
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
  }

  convenience init() {
    self.init(spec: .default)
  }

  init(spec: ChatAppearancePreviewSpec) {
    self.spec = spec
    self.tokens = ChatAppearanceSemanticTokens.resolve(from: spec)
    super.init(frame: .zero)
    commonInit()
    apply(spec, animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func commonInit() {
    clipsToBounds = true
    layer.cornerRadius = 22
    layer.cornerCurve = .continuous

    wallpaperLayer.startPoint = CGPoint(x: 0, y: 0)
    wallpaperLayer.endPoint = CGPoint(x: 1, y: 1)
    layer.insertSublayer(wallpaperLayer, at: 0)

    patternLayer.startPoint = CGPoint(x: 0, y: 0)
    patternLayer.endPoint = CGPoint(x: 1, y: 1)
    patternLayer.mask = patternMaskLayer
    patternLayer.isHidden = true
    layer.insertSublayer(patternLayer, above: wallpaperLayer)

    chatContainer.backgroundColor = .clear
    chatContainer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(chatContainer)

    stack.axis = .vertical
    stack.spacing = 8
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    chatContainer.addSubview(stack)

    NSLayoutConstraint.activate([
      chatContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      chatContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      chatContainer.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      chatContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
      stack.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: chatContainer.centerYAnchor),
    ])

    for message in mockMessages {
      let row = ChatAppearancePreviewBubbleRow()
      row.configure(text: message.text, isMe: message.isMe)
      bubbleRows.append(row)
      stack.addArrangedSubview(row)
    }

    isAccessibilityElement = true
    accessibilityTraits = .updatesFrequently
    accessibilityLabel = "Chat appearance live preview"
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    wallpaperLayer.frame = bounds
    patternLayer.frame = bounds
    patternMaskLayer.frame = patternLayer.bounds
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if spec.mode == .system {
      apply(spec, animated: false)
    }
  }

  /// Apply a new settings snapshot. No-ops when the spec is unchanged.
  /// Animation is gated by both `animated` and `spec.animationsEnabled`.
  func apply(_ next: ChatAppearancePreviewSpec, animated: Bool = true) {
    let nextTokens = ChatAppearanceSemanticTokens.resolve(
      from: next,
      traitCollection: traitCollection
    )
    if next == spec, nextTokens == tokens {
      return
    }
    let shouldAnimate = animated && next.animationsEnabled && tokens != nextTokens
    spec = next
    tokens = nextTokens
    render(animated: shouldAnimate)
  }

  /// Apply from an already-resolved chat appearance (text/corner scales optional).
  func apply(
    appearance: ChatListAppearance,
    textScale: CGFloat = 1.0,
    messageCornerScale: CGFloat = 1.0,
    animationsEnabled: Bool = true,
    accent: UIColor? = nil,
    animated: Bool = true
  ) {
    let meTop = appearance.bubbleMeGradient.first ?? ChatListAppearance.brandAccentFallback
    let meBottom = appearance.bubbleMeGradient.last ?? meTop
    let kind: ChatAppearanceWallpaperKind
    let value: String
    if let mask = appearance.wallpaperMaskKey, !mask.isEmpty {
      kind = .builtin
      value = mask
    } else {
      kind = .gradient
      value = appearance.wallpaperGradient.map { chatAppearanceColorHex($0) }.joined(separator: ",")
    }
    let bridged = ChatAppearancePreviewSpec(
      mode: appearance.isDark ? .dark : .light,
      themeId: "glacier",
      wallpaperKind: kind,
      wallpaperValue: value,
      accent: accent ?? meTop,
      bubbleGradientTop: meTop,
      bubbleGradientBottom: meBottom,
      textScale: textScale,
      messageCornerScale: messageCornerScale,
      animationsEnabled: animationsEnabled
    )
    // Prefer the provided ChatListAppearance for wallpaper/bubbles rather than
    // re-resolving a theme id.
    let nextTokens = ChatAppearanceSemanticTokens(
      isDark: appearance.isDark,
      wallpaperGradient: appearance.wallpaperGradient,
      wallpaperPatternGradient: appearance.wallpaperPatternGradient,
      wallpaperPatternLocations: appearance.wallpaperPatternLocations,
      wallpaperPatternOpacity: appearance.wallpaperPatternOpacity,
      wallpaperMaskKey: appearance.wallpaperMaskKey,
      backgroundMode: appearance.backgroundMode,
      bubbleMeGradient: appearance.bubbleMeGradient,
      bubbleThemGradient: appearance.bubbleThemGradient,
      bubbleThemColor: appearance.bubbleThemColor,
      textColorMe: appearance.textColorMe,
      textColorThem: appearance.textColorThem,
      timeColorMe: appearance.timeColorMe,
      timeColorThem: appearance.timeColorThem,
      accent: accent ?? meTop,
      textScale: min(1.35, max(0.85, textScale)),
      messageCornerRadius: 16.0 * min(1.4, max(0.6, messageCornerScale)),
      animationsEnabled: animationsEnabled,
      insertionAnimationMode: appearance.insertionAnimationMode
    )
    let shouldAnimate = animated && animationsEnabled && tokens != nextTokens
    spec = bridged
    tokens = nextTokens
    render(animated: shouldAnimate)
  }

  private func render(animated: Bool) {
    let applyVisuals = { [weak self] in
      guard let self else { return }
      self.wallpaperLayer.colors = self.tokens.wallpaperGradient.map(\.cgColor)
      self.wallpaperLayer.opacity = self.tokens.backgroundMode == "transparent" ? 0 : 1

      let canShowPattern =
        self.tokens.backgroundMode != "transparent"
        && self.tokens.wallpaperPatternGradient.count >= 2
        && self.tokens.wallpaperPatternOpacity > 0.001
        && (self.tokens.wallpaperMaskKey?.isEmpty == false)

      // Cache-only on main — a miss here would rasterise a full-screen vector inside a
      // CATransaction. Decode off-main and re-render when it lands.
      if canShowPattern, let maskKey = self.tokens.wallpaperMaskKey,
        ChatWallpaperMaskStore.cachedImage(forKey: maskKey) == nil
      {
        ChatWallpaperMaskStore.prewarm(key: maskKey) { [weak self] ok in
          guard ok else { return }
          DispatchQueue.main.async {
            guard let self, self.tokens.wallpaperMaskKey == maskKey else { return }
            self.render(animated: false)
          }
        }
      }
      if canShowPattern,
        let maskKey = self.tokens.wallpaperMaskKey,
        let mask = ChatWallpaperMaskStore.cachedImage(forKey: maskKey)
      {
        self.patternLayer.colors = self.tokens.wallpaperPatternGradient.map(\.cgColor)
        self.patternLayer.locations = self.tokens.wallpaperPatternLocations
        self.patternLayer.opacity = Float(
          max(0, min(1, self.tokens.wallpaperPatternOpacity)))
        self.patternMaskLayer.contents = mask
        self.patternMaskLayer.contentsGravity = .resizeAspectFill
        self.patternLayer.isHidden = false
      } else {
        self.patternLayer.isHidden = true
        self.patternLayer.colors = nil
        self.patternMaskLayer.contents = nil
      }

      let containerSize =
        self.bounds.width > 1
        ? self.bounds.size
        : CGSize(width: 280, height: self.preferredHeight)
      for (index, row) in self.bubbleRows.enumerated() {
        row.apply(
          tokens: self.tokens,
          containerSize: containerSize,
          sampleY: CGFloat(index) * 44
        )
      }

      self.layer.borderWidth = 1
      self.layer.borderColor =
        (self.tokens.isDark
          ? UIColor.white.withAlphaComponent(0.10)
          : UIColor.black.withAlphaComponent(0.08)).cgColor
      self.accessibilityValue =
        "Theme \(self.spec.themeId), text scale \(String(format: "%.2f", self.tokens.textScale))"
    }

    if animated {
      UIView.transition(
        with: self,
        duration: 0.28,
        options: [.transitionCrossDissolve, .allowUserInteraction],
        animations: applyVisuals
      )
    } else {
      applyVisuals()
    }
  }
}

/// SwiftUI wrapper for Settings embedding.
/// Integrator: `ChatAppearanceLivePreviewView(spec: currentSpec)`.
struct ChatAppearanceLivePreviewView: UIViewRepresentable {
  var spec: ChatAppearancePreviewSpec
  var preferredHeight: CGFloat = 220

  func makeUIView(context: Context) -> ChatAppearanceLivePreview {
    let view = ChatAppearanceLivePreview(spec: spec)
    view.preferredHeight = preferredHeight
    return view
  }

  func updateUIView(_ uiView: ChatAppearanceLivePreview, context: Context) {
    uiView.preferredHeight = preferredHeight
    uiView.apply(spec, animated: spec.animationsEnabled)
  }
}

// MARK: - Preview internals

private final class ChatAppearancePreviewBubbleRow: UIView {
  private let bubble = ChatAppearancePreviewBubbleView()
  private var isMe = false
  private var leadingConstraint: NSLayoutConstraint?
  private var trailingConstraint: NSLayoutConstraint?

  override init(frame: CGRect) {
    super.init(frame: frame)
    bubble.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bubble)
    let leading = bubble.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = bubble.trailingAnchor.constraint(equalTo: trailingAnchor)
    let maxWidth = bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78)
    NSLayoutConstraint.activate([
      bubble.topAnchor.constraint(equalTo: topAnchor),
      bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
      maxWidth,
    ])
    leadingConstraint = leading
    trailingConstraint = trailing
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(text: String, isMe: Bool) {
    self.isMe = isMe
    bubble.configure(text: text, isMe: isMe)
    leadingConstraint?.isActive = !isMe
    trailingConstraint?.isActive = isMe
  }

  func apply(
    tokens: ChatAppearanceSemanticTokens,
    containerSize: CGSize,
    sampleY: CGFloat
  ) {
    leadingConstraint?.isActive = !isMe
    trailingConstraint?.isActive = isMe
    bubble.apply(
      tokens: tokens,
      isMe: isMe,
      containerSize: containerSize,
      sampleY: sampleY
    )
  }
}

private final class ChatAppearancePreviewBubbleView: UIView {
  private let gradientLayer = CAGradientLayer()
  private let label = UILabel()
  private var isMe = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    layer.insertSublayer(gradientLayer, at: 0)

    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(text: String, isMe: Bool) {
    self.isMe = isMe
    label.text = text
  }

  func apply(
    tokens: ChatAppearanceSemanticTokens,
    isMe: Bool,
    containerSize: CGSize,
    sampleY: CGFloat
  ) {
    self.isMe = isMe
    let fontSize = 13.0 * tokens.textScale
    label.font = .systemFont(ofSize: fontSize, weight: .medium)
    label.textColor = isMe ? tokens.textColorMe : tokens.textColorThem
    label.textAlignment = .left

    let radius = tokens.messageCornerRadius
    layer.cornerRadius = radius
    if #available(iOS 13.0, *) {
      layer.cornerCurve = .continuous
    }

    if isMe {
      gradientLayer.isHidden = false
      gradientLayer.colors = tokens.bubbleMeGradient.map(\.cgColor)
      backgroundColor = .clear
    } else {
      gradientLayer.isHidden = true
      gradientLayer.colors = nil
      let appearance = tokens.asChatListAppearance
      let plate = appearance.wallpaperPlateColor(
        isMe: false,
        sampleRect: CGRect(x: 0, y: sampleY, width: containerSize.width * 0.55, height: 36),
        containerSize: containerSize
      )
      backgroundColor = plate
    }
    invalidateIntrinsicContentSize()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    gradientLayer.frame = bounds
  }

  override var intrinsicContentSize: CGSize {
    let maxLabelWidth: CGFloat = 220
    let labelSize = label.sizeThatFits(
      CGSize(width: maxLabelWidth, height: CGFloat.greatestFiniteMagnitude)
    )
    return CGSize(
      width: min(maxLabelWidth, labelSize.width) + 24,
      height: max(32, labelSize.height + 16)
    )
  }
}

private func chatAppearanceColorHex(_ color: UIColor) -> String {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
    let ri = Int(round(r * 255))
    let gi = Int(round(g * 255))
    let bi = Int(round(b * 255))
    if a < 0.999 {
      let ai = Int(round(a * 255))
      return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
    }
    return String(format: "#%02X%02X%02X", ri, gi, bi)
  }
  return "#000000"
}
